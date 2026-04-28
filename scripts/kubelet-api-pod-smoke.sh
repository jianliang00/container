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
Usage: scripts/kubelet-api-pod-smoke.sh

Runs an API-backed local kubelet smoke test against container-cri-shim-macos.
The script starts temporary etcd, kube-apiserver, CRI shim, CNI config, and
kubelet processes, then validates one macOS RuntimeClass Pod through kubectl
and one static Pod through its mirror Pod API path.

Required:
  CONTAINER_CRI_MACOS_WORKLOAD_IMAGE   macOS workload image used by the Pod

Optional:
  KUBE_DIR=/path/to/kubernetes         Kubernetes source tree with built binaries
                                       default: $HOME/Code/kubernetes
  KUBE_BIN=/path/to/bin                Kubernetes binary directory
                                       default: $KUBE_DIR/_output/bin
  KUBE_APISERVER=/path/to/kube-apiserver
  KUBECTL=/path/to/kubectl
  KUBELET=/path/to/kubelet
  ETCD=/path/to/etcd                   default: $KUBE_DIR/third_party/etcd/etcd
  ETCDCTL=/path/to/etcdctl             default: $KUBE_DIR/third_party/etcd/etcdctl
  CONTAINER_CRI_MACOS_SANDBOX_IMAGE    macOS sandbox image used by RunPodSandbox
                                       default: localhost/macos-sandbox:latest
  CONTAINER_CRI_MACOS_SANDBOX_CPUS     sandbox vCPU count
                                       default: 4
  CONTAINER_CRI_MACOS_SANDBOX_MEMORY_BYTES
                                       sandbox memory in bytes
                                       default: 8589934592
  CONTAINER_CRI_MACOS_GUI_ENABLED      enable macOS guest GUI for sandbox start
                                       default: false
  CONTAINER_CRI_MACOS_NODE_NAME        kubelet node name
                                       default: macos-api-e2e
  CONTAINER_CRI_MACOS_NODE_IP          kubelet node IP
                                       default: first host non-loopback IPv4
  CONTAINER_CRI_MACOS_POD_NAME         API-backed Pod name
                                       default: macos-api-smoke
  CONTAINER_CRI_MACOS_CONTAINER_NAME   workload container name
                                       default: workload
  CONTAINER_CRI_MACOS_STATIC_POD_NAME  static Pod name used for mirror access
                                       default: macos-static-smoke
  CONTAINER_CRI_MACOS_STATIC_CONTAINER_NAME
                                       static Pod workload container name
                                       default: static-workload
  CONTAINER_CRI_MACOS_PORT_FORWARD_GUEST_PORT
                                       guest vsock port used for kubectl port-forward
                                       default: 27000
  CONTAINER_CRI_MACOS_PORT_FORWARD_LOCAL_PORT
                                       local host port for kubectl port-forward
                                       default: randomly selected high port
  CONTAINER_CRI_MACOS_SKIP_PORT_FORWARD=1
                                       skip kubectl port-forward validation
  CONTAINER_CRI_MACOS_KEEP_WORKDIR=1   keep the generated temp directory
  CONTAINER_CRI_MACOS_WORKDIR_PARENT   parent directory for smoke temp state
                                       default: /tmp
  BUILD_CONFIGURATION=debug|release    Swift build configuration
  CRICTL=/path/to/crictl               crictl executable
  CRICTL_TIMEOUT=120s                  crictl request timeout
  PYTHON=/path/to/python3              Python used to validate port-forward frames
  SWIFT=/path/to/swift                 Swift executable

Prerequisites:
  - container services are running and reachable by ContainerKit
  - the configured default network exists and is running
  - the sandbox image exists in the local container image store
  - the workload image is present or pullable through the CRI image service
  - kube-apiserver, kubectl, kubelet, etcd, and etcdctl are built for this host
  - kubelet can run on darwin with the local CRI endpoint
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KUBE_DIR="${KUBE_DIR:-${HOME}/Code/kubernetes}"
KUBE_BIN="${KUBE_BIN:-${KUBE_DIR}/_output/bin}"
KUBE_APISERVER_BIN="${KUBE_APISERVER:-${KUBE_BIN}/kube-apiserver}"
KUBECTL_BIN="${KUBECTL:-${KUBE_BIN}/kubectl}"
KUBELET_BIN="${KUBELET:-${KUBE_BIN}/kubelet}"
ETCD_BIN="${ETCD:-${KUBE_DIR}/third_party/etcd/etcd}"
ETCDCTL_BIN="${ETCDCTL:-${KUBE_DIR}/third_party/etcd/etcdctl}"
BUILD_CONFIGURATION="${BUILD_CONFIGURATION:-debug}"
SWIFT_BIN="${SWIFT:-/usr/bin/swift}"
PYTHON_BIN="${PYTHON:-python3}"
CRICTL_BIN="${CRICTL:-crictl}"
CRICTL_TIMEOUT="${CRICTL_TIMEOUT:-120s}"
SANDBOX_IMAGE="${CONTAINER_CRI_MACOS_SANDBOX_IMAGE:-localhost/macos-sandbox:latest}"
SANDBOX_CPUS="${CONTAINER_CRI_MACOS_SANDBOX_CPUS:-4}"
SANDBOX_MEMORY_BYTES="${CONTAINER_CRI_MACOS_SANDBOX_MEMORY_BYTES:-8589934592}"
SANDBOX_GUI_ENABLED="${CONTAINER_CRI_MACOS_GUI_ENABLED:-false}"
WORKLOAD_IMAGE="${CONTAINER_CRI_MACOS_WORKLOAD_IMAGE:-}"
KEEP_WORKDIR="${CONTAINER_CRI_MACOS_KEEP_WORKDIR:-0}"
WORKDIR_PARENT="${CONTAINER_CRI_MACOS_WORKDIR_PARENT:-/tmp}"
NODE_NAME="${CONTAINER_CRI_MACOS_NODE_NAME:-macos-api-e2e}"
NODE_IP="${CONTAINER_CRI_MACOS_NODE_IP:-}"
POD_NAME="${CONTAINER_CRI_MACOS_POD_NAME:-macos-api-smoke}"
CONTAINER_NAME="${CONTAINER_CRI_MACOS_CONTAINER_NAME:-workload}"
STATIC_POD_NAME="${CONTAINER_CRI_MACOS_STATIC_POD_NAME:-macos-static-smoke}"
STATIC_CONTAINER_NAME="${CONTAINER_CRI_MACOS_STATIC_CONTAINER_NAME:-static-workload}"
PORT_FORWARD_GUEST_PORT="${CONTAINER_CRI_MACOS_PORT_FORWARD_GUEST_PORT:-27000}"
PORT_FORWARD_LOCAL_PORT="${CONTAINER_CRI_MACOS_PORT_FORWARD_LOCAL_PORT:-}"
SKIP_PORT_FORWARD="${CONTAINER_CRI_MACOS_SKIP_PORT_FORWARD:-0}"

if [[ -z "${WORKLOAD_IMAGE}" ]]; then
    echo "error: CONTAINER_CRI_MACOS_WORKLOAD_IMAGE is required" >&2
    usage >&2
    exit 2
fi

for executable in "${KUBE_APISERVER_BIN}" "${KUBECTL_BIN}" "${KUBELET_BIN}" "${ETCD_BIN}" "${ETCDCTL_BIN}" "${SWIFT_BIN}"; do
    if [[ ! -x "${executable}" ]]; then
        echo "error: executable not found or not executable: ${executable}" >&2
        exit 2
    fi
done

if ! command -v "${CRICTL_BIN}" >/dev/null 2>&1; then
    echo "error: crictl not found; set CRICTL=/path/to/crictl" >&2
    exit 2
fi

if [[ "${SKIP_PORT_FORWARD}" != "1" && "${SKIP_PORT_FORWARD}" != "true" ]]; then
    if ! command -v "${PYTHON_BIN}" >/dev/null 2>&1; then
        echo "error: python3 not found; set PYTHON=/path/to/python3 or CONTAINER_CRI_MACOS_SKIP_PORT_FORWARD=1" >&2
        exit 2
    fi
fi

if [[ ! "${SANDBOX_CPUS}" =~ ^[1-9][0-9]*$ ]]; then
    echo "error: CONTAINER_CRI_MACOS_SANDBOX_CPUS must be a positive integer" >&2
    exit 2
fi

if [[ ! "${SANDBOX_MEMORY_BYTES}" =~ ^[1-9][0-9]*$ ]]; then
    echo "error: CONTAINER_CRI_MACOS_SANDBOX_MEMORY_BYTES must be a positive integer" >&2
    exit 2
fi

if [[ ! "${PORT_FORWARD_GUEST_PORT}" =~ ^[1-9][0-9]*$ || "${PORT_FORWARD_GUEST_PORT}" -gt 65535 ]]; then
    echo "error: CONTAINER_CRI_MACOS_PORT_FORWARD_GUEST_PORT must be between 1 and 65535" >&2
    exit 2
fi

if [[ -n "${PORT_FORWARD_LOCAL_PORT}" && (! "${PORT_FORWARD_LOCAL_PORT}" =~ ^[1-9][0-9]*$ || "${PORT_FORWARD_LOCAL_PORT}" -gt 65535) ]]; then
    echo "error: CONTAINER_CRI_MACOS_PORT_FORWARD_LOCAL_PORT must be between 1 and 65535" >&2
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
    printf '[kubelet-api-smoke] %s\n' "$*"
}

select_node_ip() {
    if [[ -n "${NODE_IP}" ]]; then
        printf '%s\n' "${NODE_IP}"
        return
    fi
    ipconfig getifaddr en0 2>/dev/null ||
        ipconfig getifaddr en1 2>/dev/null ||
        ifconfig | awk '/inet / && $2 != "127.0.0.1" {print $2; exit}'
}

choose_local_port() {
    if [[ -n "${PORT_FORWARD_LOCAL_PORT}" ]]; then
        printf '%s\n' "${PORT_FORWARD_LOCAL_PORT}"
        return
    fi
    for _ in $(seq 1 200); do
        local port=$((46000 + RANDOM % 10000))
        if ! lsof -nP -iTCP:"${port}" -sTCP:LISTEN >/dev/null 2>&1; then
            printf '%s\n' "${port}"
            return
        fi
    done
    echo "error: failed to find an unused local port for kubectl port-forward" >&2
    exit 2
}

NODE_IP="$(select_node_ip)"
if [[ -z "${NODE_IP}" ]]; then
    echo "error: failed to detect node IP; set CONTAINER_CRI_MACOS_NODE_IP" >&2
    exit 2
fi
PORT_FORWARD_LOCAL_PORT="$(choose_local_port)"

WORK_DIR="$(mktemp -d "${WORKDIR_PARENT%/}/container-kubelet-api-e2e.XXXXXX")"
ln -sfn "${WORK_DIR}" "${WORKDIR_PARENT%/}/container-kubelet-api-e2e.latest"
CERT_DIR="${WORK_DIR}/certs"
ETCD_DATA="${WORK_DIR}/etcd-data"
SHIM_STATE="${WORK_DIR}/shim-state"
CNI_CONF_DIR="${WORK_DIR}/cni/net.d"
CNI_STATE_DIR="${WORK_DIR}/cni/state"
KUBELET_ROOT="${WORK_DIR}/kubelet-root"
POD_LOG_DIR="${WORK_DIR}/pod-logs"
STATIC_POD_DIR="${WORK_DIR}/static-pods"
mkdir -p "${CERT_DIR}" "${ETCD_DATA}" "${SHIM_STATE}" "${CNI_CONF_DIR}" "${CNI_STATE_DIR}" "${KUBELET_ROOT}" "${POD_LOG_DIR}" "${STATIC_POD_DIR}"

RUNTIME_ENDPOINT="${WORK_DIR}/container-cri-shim-macos.sock"
SHIM_CONFIG="${WORK_DIR}/container-cri-shim-macos-config.json"
CNI_CONFIG="${CNI_CONF_DIR}/10-macvmnet.conflist"
KUBELET_CONFIG="${WORK_DIR}/kubelet-config.yaml"
STATIC_POD_MANIFEST="${STATIC_POD_DIR}/${STATIC_POD_NAME}.yaml"
STATIC_MIRROR_POD_NAME="${STATIC_POD_NAME}-${NODE_NAME}"
ADMIN_KUBECONFIG="${WORK_DIR}/admin.kubeconfig"
KUBELET_KUBECONFIG="${WORK_DIR}/kubelet.kubeconfig"
ETCD_LOG="${WORK_DIR}/etcd.log"
APISERVER_LOG="${WORK_DIR}/kube-apiserver.log"
SHIM_LOG="${WORK_DIR}/shim.log"
KUBELET_LOG="${WORK_DIR}/kubelet.log"
PORT_FORWARD_LOG="${WORK_DIR}/kubectl-port-forward.log"
STATIC_PORT_FORWARD_LOG="${WORK_DIR}/kubectl-static-port-forward.log"
ETCD_PID=""
APISERVER_PID=""
SHIM_PID=""
KUBELET_PID=""
PORT_FORWARD_PID=""

run_crictl() {
    "${CRICTL_BIN}" \
        --runtime-endpoint "unix://${RUNTIME_ENDPOINT}" \
        --image-endpoint "unix://${RUNTIME_ENDPOINT}" \
        --timeout "${CRICTL_TIMEOUT}" \
        "$@"
}

terminate_pid() {
    local pid=$1
    if [[ -n "${pid}" ]] && kill -0 "${pid}" >/dev/null 2>&1; then
        kill "${pid}" >/dev/null 2>&1 || true
        wait "${pid}" >/dev/null 2>&1 || true
    fi
}

cleanup_runtime_objects() {
    set +e
    if [[ -S "${RUNTIME_ENDPOINT}" ]]; then
        while read -r id; do
            [[ -n "${id}" ]] && run_crictl rm -f "${id}" >/dev/null 2>&1
        done < <(run_crictl ps -a -q 2>/dev/null || true)
        while read -r id; do
            [[ -n "${id}" ]] && run_crictl rmp -f "${id}" >/dev/null 2>&1
        done < <(run_crictl pods -q 2>/dev/null || true)
    fi
}

cleanup() {
    local exit_code=$?
    set +e

    terminate_pid "${PORT_FORWARD_PID}"
    rm -f "${STATIC_POD_MANIFEST}"

    if [[ -f "${ADMIN_KUBECONFIG}" && -x "${KUBECTL_BIN}" ]]; then
        "${KUBECTL_BIN}" --kubeconfig "${ADMIN_KUBECONFIG}" delete pod "${POD_NAME}" --wait=false >/dev/null 2>&1 || true
    fi

    cleanup_runtime_objects
    terminate_pid "${KUBELET_PID}"
    terminate_pid "${SHIM_PID}"
    terminate_pid "${APISERVER_PID}"
    terminate_pid "${ETCD_PID}"

    if [[ "${KEEP_WORKDIR}" == "1" || "${KEEP_WORKDIR}" == "true" ]]; then
        echo "kept smoke work directory: ${WORK_DIR}" >&2
    else
        rm -rf "${WORK_DIR}"
        rm -f "${WORKDIR_PARENT%/}/container-kubelet-api-e2e.latest"
    fi

    exit "${exit_code}"
}
trap cleanup EXIT

fail() {
    echo "error: $*" >&2
    for log_file in "${ETCD_LOG}" "${APISERVER_LOG}" "${SHIM_LOG}" "${KUBELET_LOG}" "${PORT_FORWARD_LOG}" "${STATIC_PORT_FORWARD_LOG}"; do
        if [[ -f "${log_file}" ]]; then
            echo "---- ${log_file} ----" >&2
            tail -n 180 "${log_file}" >&2 || true
        fi
    done
    exit 1
}

wait_for_process() {
    local pid=$1
    local name=$2
    if ! kill -0 "${pid}" >/dev/null 2>&1; then
        fail "${name} exited"
    fi
}

wait_for_port_forward_ready() {
    local pid=$1
    local local_port=$2
    local process_name=$3
    for _ in $(seq 1 60); do
        if "${PYTHON_BIN}" - "${local_port}" <<'PY' >/dev/null 2>&1
import json
import socket
import struct
import sys

def recv_exact(sock, count):
    chunks = []
    remaining = count
    while remaining:
        chunk = sock.recv(remaining)
        if not chunk:
            raise RuntimeError("unexpected EOF")
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)

port = int(sys.argv[1])
with socket.create_connection(("127.0.0.1", port), timeout=2) as sock:
    header = recv_exact(sock, 4)
    length = struct.unpack(">I", header)[0]
    payload = recv_exact(sock, length)
    frame = json.loads(payload.decode("utf-8"))
    if frame.get("type") != "ready":
        raise RuntimeError(f"unexpected frame: {frame!r}")
PY
        then
            return 0
        fi
        wait_for_process "${pid}" "${process_name}"
        sleep 1
    done
    fail "timed out waiting for ${process_name} to return a guest-agent ready frame"
}

log "workdir=${WORK_DIR}"
cat >"${WORK_DIR}/env" <<EOF
KUBE_DIR=${KUBE_DIR}
KUBE_BIN=${KUBE_BIN}
KUBE_APISERVER=${KUBE_APISERVER_BIN}
KUBECTL=${KUBECTL_BIN}
KUBELET=${KUBELET_BIN}
ETCD=${ETCD_BIN}
ETCDCTL=${ETCDCTL_BIN}
NODE_NAME=${NODE_NAME}
NODE_IP=${NODE_IP}
POD_NAME=${POD_NAME}
CONTAINER_NAME=${CONTAINER_NAME}
STATIC_POD_NAME=${STATIC_POD_NAME}
STATIC_CONTAINER_NAME=${STATIC_CONTAINER_NAME}
STATIC_MIRROR_POD_NAME=${STATIC_MIRROR_POD_NAME}
RUNTIME_ENDPOINT=${RUNTIME_ENDPOINT}
ADMIN_KUBECONFIG=${ADMIN_KUBECONFIG}
KUBELET_KUBECONFIG=${KUBELET_KUBECONFIG}
PORT_FORWARD_LOCAL_PORT=${PORT_FORWARD_LOCAL_PORT}
PORT_FORWARD_GUEST_PORT=${PORT_FORWARD_GUEST_PORT}
ETCD_LOG=${ETCD_LOG}
APISERVER_LOG=${APISERVER_LOG}
SHIM_LOG=${SHIM_LOG}
KUBELET_LOG=${KUBELET_LOG}
PORT_FORWARD_LOG=${PORT_FORWARD_LOG}
STATIC_PORT_FORWARD_LOG=${STATIC_PORT_FORWARD_LOG}
EOF

log "building CRI shim and CNI plugin"
cd "${ROOT_DIR}"
"${SWIFT_BIN}" build -c "${BUILD_CONFIGURATION}" --product container-cri-shim-macos >/dev/null
"${SWIFT_BIN}" build -c "${BUILD_CONFIGURATION}" --product container-cni-macvmnet >/dev/null
CNI_BIN_DIR="$("${SWIFT_BIN}" build -c "${BUILD_CONFIGURATION}" --show-bin-path)"
echo "CNI_BIN_DIR=${CNI_BIN_DIR}" >>"${WORK_DIR}/env"

log "generating certificates and kubeconfigs"
openssl genrsa -out "${CERT_DIR}/ca.key" 2048 >/dev/null 2>&1
openssl req -x509 -new -nodes -key "${CERT_DIR}/ca.key" -sha256 -days 3650 -subj "/CN=kubernetes-ca" -out "${CERT_DIR}/ca.crt" >/dev/null 2>&1
openssl genrsa -out "${CERT_DIR}/apiserver.key" 2048 >/dev/null 2>&1
openssl req -new -key "${CERT_DIR}/apiserver.key" -subj "/CN=kube-apiserver" -out "${CERT_DIR}/apiserver.csr" -addext "subjectAltName=DNS:localhost,DNS:kubernetes,DNS:kubernetes.default,DNS:kubernetes.default.svc,IP:127.0.0.1" >/dev/null 2>&1
printf 'subjectAltName=DNS:localhost,DNS:kubernetes,DNS:kubernetes.default,DNS:kubernetes.default.svc,IP:127.0.0.1\nextendedKeyUsage=serverAuth\n' >"${CERT_DIR}/apiserver.ext"
openssl x509 -req -in "${CERT_DIR}/apiserver.csr" -CA "${CERT_DIR}/ca.crt" -CAkey "${CERT_DIR}/ca.key" -CAcreateserial -out "${CERT_DIR}/apiserver.crt" -days 365 -sha256 -extfile "${CERT_DIR}/apiserver.ext" >/dev/null 2>&1
openssl genrsa -out "${CERT_DIR}/kubelet-server.key" 2048 >/dev/null 2>&1
openssl req -new -key "${CERT_DIR}/kubelet-server.key" -subj "/CN=${NODE_NAME}" -out "${CERT_DIR}/kubelet-server.csr" -addext "subjectAltName=DNS:${NODE_NAME},IP:${NODE_IP}" >/dev/null 2>&1
printf 'subjectAltName=DNS:%s,IP:%s\nextendedKeyUsage=serverAuth\n' "${NODE_NAME}" "${NODE_IP}" >"${CERT_DIR}/kubelet-server.ext"
openssl x509 -req -in "${CERT_DIR}/kubelet-server.csr" -CA "${CERT_DIR}/ca.crt" -CAkey "${CERT_DIR}/ca.key" -CAcreateserial -out "${CERT_DIR}/kubelet-server.crt" -days 365 -sha256 -extfile "${CERT_DIR}/kubelet-server.ext" >/dev/null 2>&1
openssl genrsa -out "${CERT_DIR}/admin.key" 2048 >/dev/null 2>&1
openssl req -new -key "${CERT_DIR}/admin.key" -subj "/CN=admin/O=system:masters" -out "${CERT_DIR}/admin.csr" >/dev/null 2>&1
printf 'extendedKeyUsage=clientAuth\n' >"${CERT_DIR}/client.ext"
openssl x509 -req -in "${CERT_DIR}/admin.csr" -CA "${CERT_DIR}/ca.crt" -CAkey "${CERT_DIR}/ca.key" -CAcreateserial -out "${CERT_DIR}/admin.crt" -days 365 -sha256 -extfile "${CERT_DIR}/client.ext" >/dev/null 2>&1
openssl genrsa -out "${CERT_DIR}/kubelet.key" 2048 >/dev/null 2>&1
openssl req -new -key "${CERT_DIR}/kubelet.key" -subj "/CN=system:node:${NODE_NAME}/O=system:nodes" -out "${CERT_DIR}/kubelet.csr" >/dev/null 2>&1
openssl x509 -req -in "${CERT_DIR}/kubelet.csr" -CA "${CERT_DIR}/ca.crt" -CAkey "${CERT_DIR}/ca.key" -CAcreateserial -out "${CERT_DIR}/kubelet.crt" -days 365 -sha256 -extfile "${CERT_DIR}/client.ext" >/dev/null 2>&1
openssl genrsa -out "${CERT_DIR}/sa.key" 2048 >/dev/null 2>&1
openssl rsa -in "${CERT_DIR}/sa.key" -pubout -out "${CERT_DIR}/sa.pub" >/dev/null 2>&1

"${KUBECTL_BIN}" config set-cluster local --server=https://127.0.0.1:6443 --certificate-authority="${CERT_DIR}/ca.crt" --embed-certs=true --kubeconfig="${ADMIN_KUBECONFIG}" >/dev/null
"${KUBECTL_BIN}" config set-credentials admin --client-certificate="${CERT_DIR}/admin.crt" --client-key="${CERT_DIR}/admin.key" --embed-certs=true --kubeconfig="${ADMIN_KUBECONFIG}" >/dev/null
"${KUBECTL_BIN}" config set-context local --cluster=local --user=admin --kubeconfig="${ADMIN_KUBECONFIG}" >/dev/null
"${KUBECTL_BIN}" config use-context local --kubeconfig="${ADMIN_KUBECONFIG}" >/dev/null
"${KUBECTL_BIN}" config set-cluster local --server=https://127.0.0.1:6443 --certificate-authority="${CERT_DIR}/ca.crt" --embed-certs=true --kubeconfig="${KUBELET_KUBECONFIG}" >/dev/null
"${KUBECTL_BIN}" config set-credentials kubelet --client-certificate="${CERT_DIR}/kubelet.crt" --client-key="${CERT_DIR}/kubelet.key" --embed-certs=true --kubeconfig="${KUBELET_KUBECONFIG}" >/dev/null
"${KUBECTL_BIN}" config set-context local --cluster=local --user=kubelet --kubeconfig="${KUBELET_KUBECONFIG}" >/dev/null
"${KUBECTL_BIN}" config use-context local --kubeconfig="${KUBELET_KUBECONFIG}" >/dev/null

cat >"${SHIM_CONFIG}" <<EOF
{
  "runtimeEndpoint": "${RUNTIME_ENDPOINT}",
  "stateDirectory": "${SHIM_STATE}",
  "streaming": { "address": "127.0.0.1", "port": 0 },
  "cni": { "binDir": "${CNI_BIN_DIR}", "confDir": "${CNI_CONF_DIR}", "plugin": "macvmnet" },
  "defaults": {
    "sandboxImage": "${SANDBOX_IMAGE}",
    "workloadPlatform": { "os": "darwin", "architecture": "arm64" },
    "network": "default",
    "networkBackend": "vmnetShared",
    "guiEnabled": ${SANDBOX_GUI_ENABLED},
    "resources": { "cpus": ${SANDBOX_CPUS}, "memoryInBytes": ${SANDBOX_MEMORY_BYTES} }
  },
  "runtimeHandlers": {
    "macos": {
      "sandboxImage": "${SANDBOX_IMAGE}",
      "network": "default",
      "networkBackend": "vmnetShared",
      "guiEnabled": ${SANDBOX_GUI_ENABLED},
      "resources": { "cpus": ${SANDBOX_CPUS}, "memoryInBytes": ${SANDBOX_MEMORY_BYTES} }
    }
  },
  "networkPolicy": { "enabled": false },
  "kubeProxy": { "enabled": false }
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
enableServer: true
port: 10250
readOnlyPort: 0
healthzPort: 0
tlsCertFile: "${CERT_DIR}/kubelet-server.crt"
tlsPrivateKeyFile: "${CERT_DIR}/kubelet-server.key"
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
featureGates:
  KubeletCrashLoopBackOffMax: false
EOF

log "starting etcd"
"${ETCD_BIN}" --data-dir "${ETCD_DATA}" --listen-client-urls http://127.0.0.1:2379 --advertise-client-urls http://127.0.0.1:2379 --listen-peer-urls http://127.0.0.1:2380 --initial-advertise-peer-urls http://127.0.0.1:2380 --initial-cluster default=http://127.0.0.1:2380 >"${ETCD_LOG}" 2>&1 &
ETCD_PID=$!
for i in $(seq 1 60); do
    "${ETCDCTL_BIN}" --endpoints=http://127.0.0.1:2379 endpoint health >/dev/null 2>&1 && break
    sleep 1
    wait_for_process "${ETCD_PID}" "etcd"
    [[ "${i}" != 60 ]] || fail "timed out waiting for etcd"
done

log "starting kube-apiserver"
"${KUBE_APISERVER_BIN}" \
    --etcd-servers=http://127.0.0.1:2379 \
    --secure-port=6443 \
    --bind-address=127.0.0.1 \
    --advertise-address=127.0.0.1 \
    --endpoint-reconciler-type=none \
    --authorization-mode=AlwaysAllow \
    --anonymous-auth=false \
    --client-ca-file="${CERT_DIR}/ca.crt" \
    --tls-cert-file="${CERT_DIR}/apiserver.crt" \
    --tls-private-key-file="${CERT_DIR}/apiserver.key" \
    --service-cluster-ip-range=10.96.0.0/12 \
    --service-account-issuer=https://kubernetes.default.svc \
    --service-account-signing-key-file="${CERT_DIR}/sa.key" \
    --service-account-key-file="${CERT_DIR}/sa.pub" \
    --allow-privileged=true \
    --disable-admission-plugins=ServiceAccount \
    --feature-gates=TranslateStreamCloseWebsocketRequests=false \
    --kubelet-preferred-address-types=InternalIP,Hostname \
    --kubelet-certificate-authority="${CERT_DIR}/ca.crt" \
    --kubelet-client-certificate="${CERT_DIR}/admin.crt" \
    --kubelet-client-key="${CERT_DIR}/admin.key" \
    >"${APISERVER_LOG}" 2>&1 &
APISERVER_PID=$!
for i in $(seq 1 90); do
    "${KUBECTL_BIN}" --kubeconfig "${ADMIN_KUBECONFIG}" get --raw /readyz >/dev/null 2>&1 && break
    sleep 1
    wait_for_process "${APISERVER_PID}" "kube-apiserver"
    [[ "${i}" != 90 ]] || fail "timed out waiting for kube-apiserver"
done

log "starting CRI shim"
rm -f "${RUNTIME_ENDPOINT}"
"${CNI_BIN_DIR}/container-cri-shim-macos" --config "${SHIM_CONFIG}" >"${SHIM_LOG}" 2>&1 &
SHIM_PID=$!
for i in $(seq 1 100); do
    if [[ -S "${RUNTIME_ENDPOINT}" ]] && run_crictl version >/dev/null 2>&1; then
        break
    fi
    sleep 0.2
    wait_for_process "${SHIM_PID}" "container-cri-shim-macos"
    [[ "${i}" != 100 ]] || fail "timed out waiting for CRI shim"
done
run_crictl images "${SANDBOX_IMAGE}" >/dev/null
run_crictl images "${WORKLOAD_IMAGE}" >/dev/null

log "starting kubelet"
"${KUBELET_BIN}" \
    --config "${KUBELET_CONFIG}" \
    --kubeconfig "${KUBELET_KUBECONFIG}" \
    --root-dir "${KUBELET_ROOT}" \
    --hostname-override "${NODE_NAME}" \
    --node-ip "${NODE_IP}" \
    --feature-gates=ExtendWebSocketsToKubelet=false \
    --container-runtime-endpoint "unix://${RUNTIME_ENDPOINT}" \
    --image-service-endpoint "unix://${RUNTIME_ENDPOINT}" \
    >"${KUBELET_LOG}" 2>&1 &
KUBELET_PID=$!
for i in $(seq 1 120); do
    "${KUBECTL_BIN}" --kubeconfig "${ADMIN_KUBECONFIG}" get node "${NODE_NAME}" >/dev/null 2>&1 && break
    sleep 1
    wait_for_process "${KUBELET_PID}" "kubelet"
    [[ "${i}" != 120 ]] || fail "timed out waiting for node registration"
done
"${KUBECTL_BIN}" --kubeconfig "${ADMIN_KUBECONFIG}" wait --for=condition=Ready "node/${NODE_NAME}" --timeout=120s >/dev/null
"${KUBECTL_BIN}" --kubeconfig "${ADMIN_KUBECONFIG}" get nodes -o wide

log "creating namespaces and RuntimeClass"
"${KUBECTL_BIN}" --kubeconfig "${ADMIN_KUBECONFIG}" create namespace default >/dev/null 2>&1 || true
"${KUBECTL_BIN}" --kubeconfig "${ADMIN_KUBECONFIG}" create namespace kube-system >/dev/null 2>&1 || true
"${KUBECTL_BIN}" --kubeconfig "${ADMIN_KUBECONFIG}" apply -f - >/dev/null <<EOF
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: macos
handler: macos
EOF

log "creating API-backed Pod"
"${KUBECTL_BIN}" --kubeconfig "${ADMIN_KUBECONFIG}" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${POD_NAME}
  namespace: default
  labels:
    app: ${POD_NAME}
spec:
  nodeName: ${NODE_NAME}
  runtimeClassName: macos
  restartPolicy: Never
  containers:
  - name: ${CONTAINER_NAME}
    image: ${WORKLOAD_IMAGE}
    imagePullPolicy: IfNotPresent
    command:
    - /bin/sh
    - -c
    - |
      nc_bin="\$(command -v nc || true)"
      if [ -z "\${nc_bin}" ]; then
        echo "nc not found" >&2
        exit 1
      fi
      while true; do
        printf 'HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok' | "\${nc_bin}" -l 8080
      done &
      echo kubelet-api-ready
      while true; do sleep 30; done
    ports:
    - name: probe-http
      containerPort: 8080
    startupProbe:
      tcpSocket:
        port: 8080
      periodSeconds: 2
      failureThreshold: 60
    readinessProbe:
      exec:
        command:
        - /bin/sh
        - -c
        - echo kubelet-api-exec-probe-ok >/dev/null
      periodSeconds: 2
      failureThreshold: 30
    livenessProbe:
      httpGet:
        path: /healthz
        port: 8080
      periodSeconds: 2
      failureThreshold: 30
EOF

log "waiting for Pod Ready"
"${KUBECTL_BIN}" --kubeconfig "${ADMIN_KUBECONFIG}" wait --for=condition=Ready "pod/${POD_NAME}" --timeout=300s
"${KUBECTL_BIN}" --kubeconfig "${ADMIN_KUBECONFIG}" get pod "${POD_NAME}" -o wide

log "validating kubelet exec, TCP, and HTTP probes"
sleep 8
"${KUBECTL_BIN}" --kubeconfig "${ADMIN_KUBECONFIG}" wait --for=condition=Ready "pod/${POD_NAME}" --timeout=60s >/dev/null
restart_count="$("${KUBECTL_BIN}" --kubeconfig "${ADMIN_KUBECONFIG}" get pod "${POD_NAME}" -o "jsonpath={.status.containerStatuses[?(@.name=='${CONTAINER_NAME}')].restartCount}")"
if [[ "${restart_count}" != "0" ]]; then
    fail "expected zero restarts after probe validation, got ${restart_count}"
fi

log "validating kubectl logs"
if ! "${KUBECTL_BIN}" --kubeconfig "${ADMIN_KUBECONFIG}" logs "${POD_NAME}" | grep -F kubelet-api-ready >/dev/null; then
    fail "kubectl logs output did not contain kubelet-api-ready"
fi

log "validating kubectl exec"
exec_validation_script="echo kubelet-api-exec-ok"
if ! KUBECTL_REMOTE_COMMAND_WEBSOCKETS=true "${KUBECTL_BIN}" --kubeconfig "${ADMIN_KUBECONFIG}" exec "${POD_NAME}" -- /bin/sh -lc "${exec_validation_script}" | grep -F kubelet-api-exec-ok >/dev/null; then
    fail "kubectl exec output did not contain kubelet-api-exec-ok"
fi

if [[ "${SKIP_PORT_FORWARD}" != "1" && "${SKIP_PORT_FORWARD}" != "true" ]]; then
    log "validating kubectl port-forward"
    "${KUBECTL_BIN}" --kubeconfig "${ADMIN_KUBECONFIG}" port-forward --address 127.0.0.1 "pod/${POD_NAME}" "${PORT_FORWARD_LOCAL_PORT}:${PORT_FORWARD_GUEST_PORT}" >"${PORT_FORWARD_LOG}" 2>&1 &
    PORT_FORWARD_PID=$!
    wait_for_port_forward_ready "${PORT_FORWARD_PID}" "${PORT_FORWARD_LOCAL_PORT}" "kubectl port-forward"
    terminate_pid "${PORT_FORWARD_PID}"
    PORT_FORWARD_PID=""
fi

log "deleting Pod and waiting for CRI cleanup"
"${KUBECTL_BIN}" --kubeconfig "${ADMIN_KUBECONFIG}" delete pod "${POD_NAME}" --wait=false >/dev/null
api_cleaned=0
for i in $(seq 1 180); do
    containers="$(run_crictl ps -a --name "^${CONTAINER_NAME}$" -q 2>/dev/null || true)"
    pods="$(run_crictl pods --name "${POD_NAME}" -q 2>/dev/null || true)"
    if [[ -z "${containers}" && -z "${pods}" ]]; then
        log "kubelet cleaned API-backed Pod runtime objects"
        api_cleaned=1
        break
    fi
    sleep 1
    wait_for_process "${KUBELET_PID}" "kubelet"
done
[[ "${api_cleaned}" == "1" ]] || fail "timed out waiting for Pod cleanup"

log "creating static Pod manifest for mirror validation"
cat >"${STATIC_POD_MANIFEST}" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${STATIC_POD_NAME}
  namespace: default
  labels:
    app: ${STATIC_POD_NAME}
spec:
  runtimeClassName: macos
  nodeSelector:
    kubernetes.io/os: darwin
  restartPolicy: Always
  containers:
  - name: ${STATIC_CONTAINER_NAME}
    image: ${WORKLOAD_IMAGE}
    imagePullPolicy: IfNotPresent
    command:
    - /bin/sh
    - -c
    - 'echo kubelet-static-mirror-ready; while true; do sleep 30; done'
EOF

log "waiting for static Pod mirror"
for i in $(seq 1 300); do
    "${KUBECTL_BIN}" --kubeconfig "${ADMIN_KUBECONFIG}" get pod "${STATIC_MIRROR_POD_NAME}" >/dev/null 2>&1 && break
    sleep 1
    wait_for_process "${KUBELET_PID}" "kubelet"
    [[ "${i}" != 300 ]] || fail "timed out waiting for static Pod mirror ${STATIC_MIRROR_POD_NAME}"
done
"${KUBECTL_BIN}" --kubeconfig "${ADMIN_KUBECONFIG}" wait --for=condition=Ready "pod/${STATIC_MIRROR_POD_NAME}" --timeout=300s >/dev/null
"${KUBECTL_BIN}" --kubeconfig "${ADMIN_KUBECONFIG}" get pod "${STATIC_MIRROR_POD_NAME}" -o wide

log "validating static Pod mirror kubectl logs"
if ! "${KUBECTL_BIN}" --kubeconfig "${ADMIN_KUBECONFIG}" logs "${STATIC_MIRROR_POD_NAME}" -c "${STATIC_CONTAINER_NAME}" | grep -F kubelet-static-mirror-ready >/dev/null; then
    fail "static Pod mirror logs output did not contain kubelet-static-mirror-ready"
fi

log "validating static Pod mirror kubectl exec"
static_exec_validation_script="echo kubelet-static-mirror-exec-ok"
if ! KUBECTL_REMOTE_COMMAND_WEBSOCKETS=true "${KUBECTL_BIN}" --kubeconfig "${ADMIN_KUBECONFIG}" exec "${STATIC_MIRROR_POD_NAME}" -c "${STATIC_CONTAINER_NAME}" -- /bin/sh -lc "${static_exec_validation_script}" | grep -F kubelet-static-mirror-exec-ok >/dev/null; then
    fail "static Pod mirror exec output did not contain kubelet-static-mirror-exec-ok"
fi

if [[ "${SKIP_PORT_FORWARD}" != "1" && "${SKIP_PORT_FORWARD}" != "true" ]]; then
    log "validating static Pod mirror kubectl port-forward"
    "${KUBECTL_BIN}" --kubeconfig "${ADMIN_KUBECONFIG}" port-forward --address 127.0.0.1 "pod/${STATIC_MIRROR_POD_NAME}" "${PORT_FORWARD_LOCAL_PORT}:${PORT_FORWARD_GUEST_PORT}" >"${STATIC_PORT_FORWARD_LOG}" 2>&1 &
    PORT_FORWARD_PID=$!
    wait_for_port_forward_ready "${PORT_FORWARD_PID}" "${PORT_FORWARD_LOCAL_PORT}" "kubectl static Pod port-forward"
    terminate_pid "${PORT_FORWARD_PID}"
    PORT_FORWARD_PID=""
fi

log "removing static Pod manifest and waiting for CRI cleanup"
rm -f "${STATIC_POD_MANIFEST}"
static_cleaned=0
for i in $(seq 1 180); do
    containers="$(run_crictl ps -a --name "^${STATIC_CONTAINER_NAME}$" -q 2>/dev/null || true)"
    pods="$(
        {
            run_crictl pods --name "${STATIC_POD_NAME}" -q 2>/dev/null || true
            run_crictl pods --name "${STATIC_MIRROR_POD_NAME}" -q 2>/dev/null || true
        } | sort -u
    )"
    mirror_exists="$("${KUBECTL_BIN}" --kubeconfig "${ADMIN_KUBECONFIG}" get pod "${STATIC_MIRROR_POD_NAME}" -o name 2>/dev/null || true)"
    if [[ -z "${containers}" && -z "${pods}" && -z "${mirror_exists}" ]]; then
        log "kubelet cleaned static Pod mirror runtime objects"
        static_cleaned=1
        break
    fi
    sleep 1
    wait_for_process "${KUBELET_PID}" "kubelet"
done
[[ "${static_cleaned}" == "1" ]] || fail "timed out waiting for static Pod mirror cleanup"

log "API-backed and static mirror kubelet smoke completed"
