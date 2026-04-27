#!/usr/bin/env bash
#
# Copyright © 2026 Apple Inc. and the container project authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#   https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -euo pipefail

usage() {
    cat <<'EOF'
Usage: scripts/cri-crictl-smoke.sh

Runs a local crictl smoke test against container-cri-shim-macos using a
temporary runtime socket, shim state directory, and CNI config directory.

Required:
  CONTAINER_CRI_MACOS_WORKLOAD_IMAGE   macOS workload image used by crictl create/start

Optional:
  CONTAINER_CRI_MACOS_SANDBOX_IMAGE    macOS sandbox image used by RunPodSandbox
                                       default: localhost/macos-sandbox:latest
  CONTAINER_CRI_MACOS_SANDBOX_CPUS     sandbox vCPU count
                                       default: 4
  CONTAINER_CRI_MACOS_SANDBOX_MEMORY_BYTES
                                       sandbox memory in bytes
                                       default: 8589934592
  CONTAINER_CRI_MACOS_GUI_ENABLED      enable macOS guest GUI for sandbox start
                                       default: false
  CONTAINER_CRI_MACOS_EXECSYNC_TIMEOUT_SECONDS
                                       synchronous exec timeout for crictl exec fallback
                                       default: 30
  CONTAINER_CRI_MACOS_SKIP_PULL=1      skip crictl pull for the workload image
  CONTAINER_CRI_MACOS_KEEP_WORKDIR=1   keep the generated temp directory
  CONTAINER_CRI_MACOS_WORKDIR_PARENT   parent directory for smoke temp state
                                       default: /tmp
  BUILD_CONFIGURATION=debug|release    Swift build configuration
  CRICTL=/path/to/crictl               crictl executable
  CRICTL_TIMEOUT=120s                  crictl request timeout
  SWIFT=/path/to/swift                 Swift executable

Prerequisites:
  - container services are running and reachable by ContainerKit
  - the configured default network exists and is running
  - the sandbox image exists in the local container image store
  - the workload image is pullable or already present when SKIP_PULL=1
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_CONFIGURATION="${BUILD_CONFIGURATION:-debug}"
SWIFT_BIN="${SWIFT:-/usr/bin/swift}"
CRICTL_BIN="${CRICTL:-crictl}"
CRICTL_TIMEOUT="${CRICTL_TIMEOUT:-120s}"
SANDBOX_IMAGE="${CONTAINER_CRI_MACOS_SANDBOX_IMAGE:-localhost/macos-sandbox:latest}"
SANDBOX_CPUS="${CONTAINER_CRI_MACOS_SANDBOX_CPUS:-4}"
SANDBOX_MEMORY_BYTES="${CONTAINER_CRI_MACOS_SANDBOX_MEMORY_BYTES:-8589934592}"
SANDBOX_GUI_ENABLED="${CONTAINER_CRI_MACOS_GUI_ENABLED:-false}"
EXECSYNC_TIMEOUT_SECONDS="${CONTAINER_CRI_MACOS_EXECSYNC_TIMEOUT_SECONDS:-30}"
WORKLOAD_IMAGE="${CONTAINER_CRI_MACOS_WORKLOAD_IMAGE:-}"
SKIP_PULL="${CONTAINER_CRI_MACOS_SKIP_PULL:-0}"
KEEP_WORKDIR="${CONTAINER_CRI_MACOS_KEEP_WORKDIR:-0}"
WORKDIR_PARENT="${CONTAINER_CRI_MACOS_WORKDIR_PARENT:-/tmp}"

if [[ -z "${WORKLOAD_IMAGE}" ]]; then
    echo "error: CONTAINER_CRI_MACOS_WORKLOAD_IMAGE is required" >&2
    usage >&2
    exit 2
fi

if ! command -v "${CRICTL_BIN}" >/dev/null 2>&1; then
    echo "error: crictl not found; set CRICTL=/path/to/crictl" >&2
    exit 2
fi

if [[ ! -x "${SWIFT_BIN}" ]]; then
    echo "error: Swift executable not found or not executable: ${SWIFT_BIN}" >&2
    exit 2
fi

if [[ ! "${SANDBOX_CPUS}" =~ ^[1-9][0-9]*$ ]]; then
    echo "error: CONTAINER_CRI_MACOS_SANDBOX_CPUS must be a positive integer" >&2
    exit 2
fi

if [[ ! "${SANDBOX_MEMORY_BYTES}" =~ ^[1-9][0-9]*$ ]]; then
    echo "error: CONTAINER_CRI_MACOS_SANDBOX_MEMORY_BYTES must be a positive integer" >&2
    exit 2
fi

if [[ ! "${EXECSYNC_TIMEOUT_SECONDS}" =~ ^[1-9][0-9]*$ ]]; then
    echo "error: CONTAINER_CRI_MACOS_EXECSYNC_TIMEOUT_SECONDS must be a positive integer" >&2
    exit 2
fi

case "${SANDBOX_GUI_ENABLED}" in
    true | false) ;;
    *)
        echo "error: CONTAINER_CRI_MACOS_GUI_ENABLED must be true or false" >&2
        exit 2
        ;;
esac

log() {
    printf '[cri-smoke] %s\n' "$*"
}

fail() {
    echo "error: $*" >&2
    if [[ -n "${SHIM_LOG:-}" && -f "${SHIM_LOG}" ]]; then
        echo "---- container-cri-shim-macos log ----" >&2
        tail -n 200 "${SHIM_LOG}" >&2 || true
        echo "--------------------------------------" >&2
    fi
    exit 1
}

WORK_DIR="$(mktemp -d "${WORKDIR_PARENT%/}/container-cri-smoke.XXXXXX")"
RUNTIME_ENDPOINT="${WORK_DIR}/container-cri-shim-macos.sock"
STATE_DIR="${WORK_DIR}/state"
CNI_BIN_DIR=""
CNI_CONF_DIR="${WORK_DIR}/cni/net.d"
CNI_STATE_DIR="${WORK_DIR}/cni/state"
POD_LOG_DIR="${WORK_DIR}/pod-logs"
MOUNT_HOST_DIR="${WORK_DIR}/host-mount"
SHIM_CONFIG="${WORK_DIR}/container-cri-shim-macos-config.json"
CNI_CONFIG="${CNI_CONF_DIR}/10-macvmnet.conflist"
POD_CONFIG="${WORK_DIR}/pod.json"
CONTAINER_CONFIG="${WORK_DIR}/container.json"
SHIM_LOG="${WORK_DIR}/shim.log"
SHIM_PID=""
POD_ID=""
CONTAINER_ID=""

run_crictl() {
    "${CRICTL_BIN}" \
        --runtime-endpoint "unix://${RUNTIME_ENDPOINT}" \
        --image-endpoint "unix://${RUNTIME_ENDPOINT}" \
        --timeout "${CRICTL_TIMEOUT}" \
        "$@"
}

run_crictl_execsync() {
    if "${CRICTL_BIN}" --help 2>/dev/null | grep -Eq '^[[:space:]]+execsync[[:space:]]'; then
        run_crictl execsync "$@"
    else
        run_crictl exec --sync --transport websocket --timeout "${EXECSYNC_TIMEOUT_SECONDS}" "$@"
    fi
}

cleanup() {
    local exit_code=$?
    set +e

    if [[ -n "${CONTAINER_ID}" ]]; then
        run_crictl stop "${CONTAINER_ID}" >/dev/null 2>&1
        run_crictl rm "${CONTAINER_ID}" >/dev/null 2>&1
    fi

    if [[ -n "${POD_ID}" ]]; then
        run_crictl stopp "${POD_ID}" >/dev/null 2>&1
        run_crictl rmp "${POD_ID}" >/dev/null 2>&1
    fi

    if [[ -n "${SHIM_PID}" ]] && kill -0 "${SHIM_PID}" >/dev/null 2>&1; then
        kill "${SHIM_PID}" >/dev/null 2>&1
        wait "${SHIM_PID}" >/dev/null 2>&1
    fi

    if [[ "${KEEP_WORKDIR}" == "1" || "${KEEP_WORKDIR}" == "true" ]]; then
        echo "kept smoke work directory: ${WORK_DIR}" >&2
    else
        rm -rf "${WORK_DIR}"
    fi

    exit "${exit_code}"
}
trap cleanup EXIT

wait_for_socket() {
    local attempts=100
    while (( attempts > 0 )); do
        if [[ -S "${RUNTIME_ENDPOINT}" ]]; then
            return 0
        fi
        if [[ -n "${SHIM_PID}" ]] && ! kill -0 "${SHIM_PID}" >/dev/null 2>&1; then
            fail "container-cri-shim-macos exited before creating ${RUNTIME_ENDPOINT}"
        fi
        sleep 0.1
        attempts=$((attempts - 1))
    done
    fail "timed out waiting for runtime socket ${RUNTIME_ENDPOINT}"
}

wait_for_log_line() {
    local needle=$1
    local attempts=60
    local logs=""
    while (( attempts > 0 )); do
        logs="$(run_crictl logs "${CONTAINER_ID}" 2>/dev/null || true)"
        if grep -Fq "${needle}" <<<"${logs}"; then
            printf '%s\n' "${logs}"
            return 0
        fi
        sleep 1
        attempts=$((attempts - 1))
    done
    fail "timed out waiting for container logs to contain '${needle}'"
}

log "building CRI shim and CNI plugin"
"${SWIFT_BIN}" build -c "${BUILD_CONFIGURATION}" --product container-cri-shim-macos >/dev/null
"${SWIFT_BIN}" build -c "${BUILD_CONFIGURATION}" --product container-cni-macvmnet >/dev/null
CNI_BIN_DIR="$("${SWIFT_BIN}" build -c "${BUILD_CONFIGURATION}" --show-bin-path)"

mkdir -p "${STATE_DIR}" "${CNI_CONF_DIR}" "${CNI_STATE_DIR}" "${POD_LOG_DIR}" "${MOUNT_HOST_DIR}"
printf 'mounted-from-host\n' >"${MOUNT_HOST_DIR}/smoke.txt"

cat >"${SHIM_CONFIG}" <<EOF
{
  "runtimeEndpoint": "${RUNTIME_ENDPOINT}",
  "stateDirectory": "${STATE_DIR}",
  "streaming": {
    "address": "127.0.0.1",
    "port": 0
  },
  "cni": {
    "binDir": "${CNI_BIN_DIR}",
    "confDir": "${CNI_CONF_DIR}",
    "plugin": "macvmnet"
  },
  "defaults": {
    "sandboxImage": "${SANDBOX_IMAGE}",
    "workloadPlatform": {
      "os": "darwin",
      "architecture": "arm64"
    },
    "network": "default",
    "networkBackend": "vmnetShared",
    "guiEnabled": ${SANDBOX_GUI_ENABLED},
    "resources": {
      "cpus": ${SANDBOX_CPUS},
      "memoryInBytes": ${SANDBOX_MEMORY_BYTES}
    }
  },
  "runtimeHandlers": {
    "macos": {
      "sandboxImage": "${SANDBOX_IMAGE}",
      "network": "default",
      "networkBackend": "vmnetShared",
      "guiEnabled": ${SANDBOX_GUI_ENABLED},
      "resources": {
        "cpus": ${SANDBOX_CPUS},
        "memoryInBytes": ${SANDBOX_MEMORY_BYTES}
      }
    }
  },
  "networkPolicy": {
    "enabled": false
  },
  "kubeProxy": {
    "enabled": false
  }
}
EOF

cat >"${CNI_CONFIG}" <<EOF
{
  "cniVersion": "1.1.0",
  "name": "default",
  "plugins": [
    {
      "type": "macvmnet",
      "network": "default",
      "runtime": "container-runtime-macos",
      "stateDir": "${CNI_STATE_DIR}"
    }
  ]
}
EOF

cat >"${POD_CONFIG}" <<EOF
{
  "metadata": {
    "name": "macos-cri-smoke",
    "namespace": "default",
    "uid": "macos-cri-smoke-${RANDOM}",
    "attempt": 1
  },
  "log_directory": "${POD_LOG_DIR}",
  "labels": {
    "app": "macos-cri-smoke"
  },
  "annotations": {
    "test.container.apple.com/smoke": "crictl"
  }
}
EOF

cat >"${CONTAINER_CONFIG}" <<EOF
{
  "metadata": {
    "name": "workload",
    "attempt": 1
  },
  "image": {
    "image": "${WORKLOAD_IMAGE}"
  },
  "command": [
    "/bin/sh"
  ],
  "args": [
    "-c",
    "echo crictl-smoke-ready; cat /Users/container-cri-smoke/smoke.txt; exec sleep 300"
  ],
  "working_dir": "/",
  "log_path": "workload/0.log",
  "mounts": [
    {
      "container_path": "/Users/container-cri-smoke",
      "host_path": "${MOUNT_HOST_DIR}",
      "readonly": true
    }
  ],
  "labels": {
    "app": "macos-cri-smoke"
  },
  "annotations": {
    "test.container.apple.com/smoke": "crictl"
  }
}
EOF

log "starting container-cri-shim-macos"
"${CNI_BIN_DIR}/container-cri-shim-macos" --config "${SHIM_CONFIG}" >"${SHIM_LOG}" 2>&1 &
SHIM_PID=$!
wait_for_socket

log "checking CRI version and runtime info"
run_crictl version >/dev/null
run_crictl info >/dev/null

log "checking sandbox image is present: ${SANDBOX_IMAGE}"
run_crictl inspecti "${SANDBOX_IMAGE}" >/dev/null || fail "sandbox image is not present in the local image store: ${SANDBOX_IMAGE}"

if [[ "${SKIP_PULL}" == "1" || "${SKIP_PULL}" == "true" ]]; then
    log "skipping workload pull and checking image is present: ${WORKLOAD_IMAGE}"
    run_crictl inspecti "${WORKLOAD_IMAGE}" >/dev/null || fail "workload image is not present in the local image store: ${WORKLOAD_IMAGE}"
else
    log "pulling workload image: ${WORKLOAD_IMAGE}"
    run_crictl pull "${WORKLOAD_IMAGE}" >/dev/null
fi

log "creating pod sandbox"
POD_ID="$(run_crictl runp "${POD_CONFIG}" | tail -n 1 | tr -d '[:space:]')"
[[ -n "${POD_ID}" ]] || fail "crictl runp did not return a pod sandbox ID"

log "creating workload container"
CONTAINER_ID="$(run_crictl create "${POD_ID}" "${CONTAINER_CONFIG}" "${POD_CONFIG}" | tail -n 1 | tr -d '[:space:]')"
[[ -n "${CONTAINER_ID}" ]] || fail "crictl create did not return a container ID"

log "starting workload container"
run_crictl start "${CONTAINER_ID}" >/dev/null

log "validating workload visibility and status"
run_crictl ps -a -q | grep -F "${CONTAINER_ID}" >/dev/null || fail "container ${CONTAINER_ID} was not listed by crictl ps -a"
run_crictl inspect "${CONTAINER_ID}" >/dev/null
run_crictl inspectp "${POD_ID}" >/dev/null

log "validating logs and readonly hostPath mount"
wait_for_log_line "mounted-from-host" >/dev/null

log "validating execsync"
run_crictl_execsync "${CONTAINER_ID}" /bin/echo execsync-ok | grep -F "execsync-ok" >/dev/null || fail "execsync output did not contain execsync-ok"

log "stopping and removing workload"
run_crictl stop "${CONTAINER_ID}" >/dev/null
run_crictl rm "${CONTAINER_ID}" >/dev/null
CONTAINER_ID=""

log "stopping and removing sandbox"
run_crictl stopp "${POD_ID}" >/dev/null
run_crictl rmp "${POD_ID}" >/dev/null
POD_ID=""

log "crictl smoke completed"
