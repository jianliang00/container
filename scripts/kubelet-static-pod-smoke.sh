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
Usage: scripts/kubelet-static-pod-smoke.sh

Runs a local kubelet static Pod smoke test against container-cri-shim-macos
using a temporary runtime socket, kubelet root directory, shim state directory,
and CNI config directory.

Required:
  CONTAINER_CRI_MACOS_WORKLOAD_IMAGE   macOS workload image used by the static Pod

Optional:
  KUBELET=/path/to/kubelet             kubelet executable
                                       default: kubelet from PATH
  CONTAINER_CRI_MACOS_SANDBOX_IMAGE    macOS sandbox image used by RunPodSandbox
                                       default: localhost/macos-sandbox:latest
  CONTAINER_CRI_MACOS_SANDBOX_CPUS     sandbox vCPU count
                                       default: 4
  CONTAINER_CRI_MACOS_SANDBOX_MEMORY_BYTES
                                       sandbox memory in bytes
                                       default: 8589934592
  CONTAINER_CRI_MACOS_GUI_ENABLED      enable macOS guest GUI for sandbox start
                                       default: false
  CONTAINER_CRI_MACOS_IMAGE_PULL_POLICY
                                       static Pod imagePullPolicy
                                       default: IfNotPresent
  CONTAINER_CRI_MACOS_SKIP_PULL=1      skip crictl pull for the workload image
  CONTAINER_CRI_MACOS_KEEP_WORKDIR=1   keep the generated temp directory
  CONTAINER_CRI_MACOS_WORKDIR_PARENT   parent directory for smoke temp state
                                       default: /tmp
  CONTAINER_CRI_MACOS_KUBELET_TIMEOUT_SECONDS
                                       static Pod start timeout
                                       default: 300
  CONTAINER_CRI_MACOS_CLEANUP_TIMEOUT_SECONDS
                                       static Pod runtime cleanup timeout
                                       default: 120
  CONTAINER_CRI_MACOS_EXECSYNC_TIMEOUT_SECONDS
                                       synchronous exec timeout for crictl exec fallback
                                       default: 30
  BUILD_CONFIGURATION=debug|release    Swift build configuration
  CRICTL=/path/to/crictl               crictl executable
  CRICTL_TIMEOUT=120s                  crictl request timeout
  SWIFT=/path/to/swift                 Swift executable

Prerequisites:
  - container services are running and reachable by ContainerKit
  - the configured default network exists and is running
  - the sandbox image exists in the local container image store
  - the workload image is pullable or already present when SKIP_PULL=1
  - kubelet is built for this host and can run in standalone static Pod mode
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
KUBELET_BIN="${KUBELET:-kubelet}"
SANDBOX_IMAGE="${CONTAINER_CRI_MACOS_SANDBOX_IMAGE:-localhost/macos-sandbox:latest}"
SANDBOX_CPUS="${CONTAINER_CRI_MACOS_SANDBOX_CPUS:-4}"
SANDBOX_MEMORY_BYTES="${CONTAINER_CRI_MACOS_SANDBOX_MEMORY_BYTES:-8589934592}"
SANDBOX_GUI_ENABLED="${CONTAINER_CRI_MACOS_GUI_ENABLED:-false}"
WORKLOAD_IMAGE="${CONTAINER_CRI_MACOS_WORKLOAD_IMAGE:-}"
IMAGE_PULL_POLICY="${CONTAINER_CRI_MACOS_IMAGE_PULL_POLICY:-IfNotPresent}"
SKIP_PULL="${CONTAINER_CRI_MACOS_SKIP_PULL:-0}"
KEEP_WORKDIR="${CONTAINER_CRI_MACOS_KEEP_WORKDIR:-0}"
WORKDIR_PARENT="${CONTAINER_CRI_MACOS_WORKDIR_PARENT:-/tmp}"
KUBELET_TIMEOUT_SECONDS="${CONTAINER_CRI_MACOS_KUBELET_TIMEOUT_SECONDS:-300}"
CLEANUP_TIMEOUT_SECONDS="${CONTAINER_CRI_MACOS_CLEANUP_TIMEOUT_SECONDS:-120}"
EXECSYNC_TIMEOUT_SECONDS="${CONTAINER_CRI_MACOS_EXECSYNC_TIMEOUT_SECONDS:-30}"
NODE_NAME="${CONTAINER_CRI_MACOS_NODE_NAME:-macos-static-e2e}"
POD_NAME="${CONTAINER_CRI_MACOS_STATIC_POD_NAME:-macos-static-smoke}"
CONTAINER_NAME="${CONTAINER_CRI_MACOS_STATIC_CONTAINER_NAME:-workload}"

if [[ -z "${WORKLOAD_IMAGE}" ]]; then
    echo "error: CONTAINER_CRI_MACOS_WORKLOAD_IMAGE is required" >&2
    usage >&2
    exit 2
fi

if ! command -v "${CRICTL_BIN}" >/dev/null 2>&1; then
    echo "error: crictl not found; set CRICTL=/path/to/crictl" >&2
    exit 2
fi

if ! command -v "${KUBELET_BIN}" >/dev/null 2>&1; then
    echo "error: kubelet not found; set KUBELET=/path/to/kubelet" >&2
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

if [[ ! "${KUBELET_TIMEOUT_SECONDS}" =~ ^[1-9][0-9]*$ ]]; then
    echo "error: CONTAINER_CRI_MACOS_KUBELET_TIMEOUT_SECONDS must be a positive integer" >&2
    exit 2
fi

if [[ ! "${CLEANUP_TIMEOUT_SECONDS}" =~ ^[1-9][0-9]*$ ]]; then
    echo "error: CONTAINER_CRI_MACOS_CLEANUP_TIMEOUT_SECONDS must be a positive integer" >&2
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

case "${IMAGE_PULL_POLICY}" in
    Always | IfNotPresent | Never) ;;
    *)
        echo "error: CONTAINER_CRI_MACOS_IMAGE_PULL_POLICY must be Always, IfNotPresent, or Never" >&2
        exit 2
        ;;
esac

log() {
    printf '[kubelet-static-smoke] %s\n' "$*"
}

fail() {
    echo "error: $*" >&2
    if [[ -n "${KUBELET_LOG:-}" && -f "${KUBELET_LOG}" ]]; then
        echo "---- kubelet log ----" >&2
        tail -n 200 "${KUBELET_LOG}" >&2 || true
        echo "---------------------" >&2
    fi
    if [[ -n "${SHIM_LOG:-}" && -f "${SHIM_LOG}" ]]; then
        echo "---- container-cri-shim-macos log ----" >&2
        tail -n 200 "${SHIM_LOG}" >&2 || true
        echo "--------------------------------------" >&2
    fi
    exit 1
}

WORK_DIR="$(mktemp -d "${WORKDIR_PARENT%/}/container-kubelet-static-e2e.XXXXXX")"
RUNTIME_ENDPOINT="${WORK_DIR}/container-cri-shim-macos.sock"
STATE_DIR="${WORK_DIR}/state"
CNI_BIN_DIR=""
CNI_CONF_DIR="${WORK_DIR}/cni/net.d"
CNI_STATE_DIR="${WORK_DIR}/cni/state"
STATIC_POD_DIR="${WORK_DIR}/static-pods"
POD_LOG_DIR="${WORK_DIR}/pod-logs"
KUBELET_ROOT="${WORK_DIR}/kubelet-root"
SHIM_CONFIG="${WORK_DIR}/container-cri-shim-macos-config.json"
CNI_CONFIG="${CNI_CONF_DIR}/10-macvmnet.conflist"
KUBELET_CONFIG="${WORK_DIR}/kubelet-config.yaml"
STATIC_POD_MANIFEST="${STATIC_POD_DIR}/${POD_NAME}.yaml"
SHIM_LOG="${WORK_DIR}/shim.log"
KUBELET_LOG="${WORK_DIR}/kubelet.log"
SHIM_PID=""
KUBELET_PID=""
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

cleanup_runtime_objects() {
    set +e

    if [[ -n "${CONTAINER_ID}" ]]; then
        run_crictl stop "${CONTAINER_ID}" >/dev/null 2>&1
        run_crictl rm "${CONTAINER_ID}" >/dev/null 2>&1
    fi

    if [[ -n "${POD_ID}" ]]; then
        run_crictl stopp "${POD_ID}" >/dev/null 2>&1
        run_crictl rmp "${POD_ID}" >/dev/null 2>&1
    fi
}

cleanup() {
    local exit_code=$?
    set +e

    rm -f "${STATIC_POD_MANIFEST}" >/dev/null 2>&1

    if [[ -n "${KUBELET_PID}" ]] && kill -0 "${KUBELET_PID}" >/dev/null 2>&1; then
        kill "${KUBELET_PID}" >/dev/null 2>&1
        wait "${KUBELET_PID}" >/dev/null 2>&1
    fi

    cleanup_runtime_objects

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

wait_for_kubelet_container() {
    local attempts="${KUBELET_TIMEOUT_SECONDS}"
    while (( attempts > 0 )); do
        if [[ -n "${KUBELET_PID}" ]] && ! kill -0 "${KUBELET_PID}" >/dev/null 2>&1; then
            fail "kubelet exited before starting the static Pod"
        fi

        POD_ID="$(run_crictl pods --name "${POD_NAME}" -q 2>/dev/null | head -n 1 | tr -d '[:space:]' || true)"
        CONTAINER_ID="$(run_crictl ps -a --name "^${CONTAINER_NAME}$" -q 2>/dev/null | head -n 1 | tr -d '[:space:]' || true)"
        if [[ -n "${POD_ID}" && -n "${CONTAINER_ID}" ]]; then
            if run_crictl ps --id "${CONTAINER_ID}" -q 2>/dev/null | grep -F "${CONTAINER_ID}" >/dev/null; then
                return 0
            fi
        fi

        sleep 1
        attempts=$((attempts - 1))
    done
    fail "timed out waiting for static Pod container to reach running state"
}

wait_for_log_line() {
    local needle=$1
    local attempts=90
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

wait_for_static_pod_cleanup() {
    local attempts="${1:-30}"
    while (( attempts > 0 )); do
        local containers pods
        containers="$(run_crictl ps -a --name "^${CONTAINER_NAME}$" -q 2>/dev/null || true)"
        pods="$(run_crictl pods --name "${POD_NAME}" -q 2>/dev/null || true)"
        if [[ -z "${containers}" && -z "${pods}" ]]; then
            CONTAINER_ID=""
            POD_ID=""
            return 0
        fi
        if [[ -n "${KUBELET_PID}" ]] && ! kill -0 "${KUBELET_PID}" >/dev/null 2>&1; then
            fail "kubelet exited before cleaning up the static Pod"
        fi
        sleep 1
        attempts=$((attempts - 1))
    done
    return 1
}

log "building CRI shim and CNI plugin"
"${SWIFT_BIN}" build -c "${BUILD_CONFIGURATION}" --product container-cri-shim-macos >/dev/null
"${SWIFT_BIN}" build -c "${BUILD_CONFIGURATION}" --product container-cni-macvmnet >/dev/null
CNI_BIN_DIR="$("${SWIFT_BIN}" build -c "${BUILD_CONFIGURATION}" --show-bin-path)"

mkdir -p \
    "${STATE_DIR}" \
    "${CNI_CONF_DIR}" \
    "${CNI_STATE_DIR}" \
    "${STATIC_POD_DIR}" \
    "${POD_LOG_DIR}" \
    "${KUBELET_ROOT}/pki"

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

cat >"${KUBELET_CONFIG}" <<EOF
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
staticPodPath: "${STATIC_POD_DIR}"
podLogsDir: "${POD_LOG_DIR}"
containerRuntimeEndpoint: "unix://${RUNTIME_ENDPOINT}"
imageServiceEndpoint: "unix://${RUNTIME_ENDPOINT}"
syncFrequency: 5s
fileCheckFrequency: 2s
runtimeRequestTimeout: 2m
failSwapOn: false
failCgroupV1: false
cgroupsPerQOS: false
enforceNodeAllocatable: [none]
eventRecordQPS: 0
enableServer: false
readOnlyPort: 0
healthzPort: 0
localStorageCapacityIsolation: false
makeIPTablesUtilChains: false
authentication:
  anonymous:
    enabled: true
  webhook:
    enabled: false
  x509: {}
authorization:
  mode: AlwaysAllow
EOF

cat >"${STATIC_POD_MANIFEST}" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${POD_NAME}
  namespace: default
  labels:
    app: ${POD_NAME}
spec:
  runtimeClassName: macos
  nodeSelector:
    kubernetes.io/os: darwin
  restartPolicy: Always
  containers:
  - name: ${CONTAINER_NAME}
    image: ${WORKLOAD_IMAGE}
    imagePullPolicy: ${IMAGE_PULL_POLICY}
    command:
    - /bin/sh
    - -c
    - echo kubelet-static-ready; cat /etc/hosts | head -n 1; exec sleep 300
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

log "starting kubelet"
"${KUBELET_BIN}" \
    --config "${KUBELET_CONFIG}" \
    --root-dir "${KUBELET_ROOT}" \
    --cert-dir "${KUBELET_ROOT}/pki" \
    --hostname-override "${NODE_NAME}" \
    --pod-manifest-path "${STATIC_POD_DIR}" \
    --container-runtime-endpoint "unix://${RUNTIME_ENDPOINT}" \
    --image-service-endpoint "unix://${RUNTIME_ENDPOINT}" \
    --register-node=false \
    --fail-swap-on=false \
    --cgroups-per-qos=false \
    --enforce-node-allocatable=none \
    --event-qps=0 \
    --enable-server=false \
    --read-only-port=0 \
    --healthz-port=0 \
    --eviction-hard="" \
    --eviction-soft="" \
    --eviction-soft-grace-period="" \
    --make-iptables-util-chains=false \
    >"${KUBELET_LOG}" 2>&1 &
KUBELET_PID=$!

log "waiting for kubelet to start static Pod"
wait_for_kubelet_container

log "validating static Pod logs"
wait_for_log_line "kubelet-static-ready" >/dev/null

log "validating execsync against kubelet-created container"
run_crictl_execsync "${CONTAINER_ID}" /bin/echo kubelet-execsync-ok | grep -F "kubelet-execsync-ok" >/dev/null || fail "execsync output did not contain kubelet-execsync-ok"

log "removing static Pod manifest"
rm -f "${STATIC_POD_MANIFEST}"
if wait_for_static_pod_cleanup "${CLEANUP_TIMEOUT_SECONDS}"; then
    log "kubelet removed static Pod runtime objects"
else
    log "kubelet did not fully remove static Pod runtime objects before timeout; forcing CRI cleanup"
    cleanup_runtime_objects
    CONTAINER_ID=""
    POD_ID=""
fi

log "kubelet static Pod smoke completed"
