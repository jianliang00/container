#!/bin/bash
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
Usage: scripts/macos-cri-machine-state-integration.sh

Runs the Kubernetes CRI machine-state safety boundary on a real macOS node:
starts a counter workload on an NBD root disk, calls protocol v2 capability,
exercises pause/resume through the stable sidecar socket, saves while paused,
deletes the Pod, and restores the same durable workload into a new Pod UID with
the next writable storage generation. The check requires the restored Pod and
container to become ready and verifies that the guest PID and counter continue.
The counter process keeps its random boot token and counter only in process
memory and emits continuity samples to stdout. It never writes either value to
the VM filesystem. Restore must preserve the token, PID, and advancing counter.

Required environment:
  MACOS_CRI_MACHINE_STATE_NODE          Kubernetes node name
  MACOS_CRI_MACHINE_STATE_IMAGE         macOS workload image
  MACOS_CRI_MACHINE_STATE_NBD_SOCKET    absolute host Unix socket exporting a bootable root disk

Optional environment:
  KUBECTL                               kubectl executable (default: kubectl)
  MACOS_CRI_MACHINE_STATE_NAMESPACE     namespace (default: default)
  MACOS_CRI_MACHINE_STATE_RUNTIME_CLASS RuntimeClass (default: macos)
  MACOS_CRI_MACHINE_STATE_CONTROL_ROOT  sidecar socket root (default: /var/run/container/machine-state/v1)
  MACOS_CRI_MACHINE_STATE_TIMEOUT       wait timeout (default: 180s)
  MACOS_CRI_MACHINE_STATE_PREPARE_RESTORE_HELPER
                                        absolute executable invoked after the old Pod is removed;
                                        receives NBD socket, state ID, saved generation, new generation
  MACOS_CRI_MACHINE_STATE_ALLOW_IN_PLACE_RESTORE
                                        set to true only for a runtime-only check that reuses the
                                        quiesced disk instead of validating snapshot/clone (default: false)

The NBD socket path is part of the saved VM configuration and must remain
stable. Before the restore Pod is created, its backing service must expose a
writable disk generation cloned from the disk point paired with the saved
machine state. This script performs no storage snapshot, clone, or export
switching itself.
EOF
}

for command in "${KUBECTL:-kubectl}" python3; do
    if ! command -v "${command}" >/dev/null 2>&1; then
        echo "required command not found: ${command}" >&2
        exit 2
    fi
done

NODE="${MACOS_CRI_MACHINE_STATE_NODE:-}"
IMAGE="${MACOS_CRI_MACHINE_STATE_IMAGE:-}"
NBD_SOCKET="${MACOS_CRI_MACHINE_STATE_NBD_SOCKET:-}"
if [[ -z "${NODE}" || -z "${IMAGE}" || -z "${NBD_SOCKET}" ]]; then
    usage >&2
    exit 2
fi
if [[ "${NBD_SOCKET}" != /* ]]; then
    echo "MACOS_CRI_MACHINE_STATE_NBD_SOCKET must be absolute" >&2
    exit 2
fi

KUBECTL_BIN="${KUBECTL:-kubectl}"
NAMESPACE="${MACOS_CRI_MACHINE_STATE_NAMESPACE:-default}"
RUNTIME_CLASS="${MACOS_CRI_MACHINE_STATE_RUNTIME_CLASS:-macos}"
CONTROL_ROOT="${MACOS_CRI_MACHINE_STATE_CONTROL_ROOT:-/var/run/container/machine-state/v1}"
WAIT_TIMEOUT="${MACOS_CRI_MACHINE_STATE_TIMEOUT:-180s}"
PREPARE_RESTORE_HELPER="${MACOS_CRI_MACHINE_STATE_PREPARE_RESTORE_HELPER:-}"
ALLOW_IN_PLACE_RESTORE="${MACOS_CRI_MACHINE_STATE_ALLOW_IN_PLACE_RESTORE:-false}"
if [[ "${ALLOW_IN_PLACE_RESTORE}" != "true" && "${ALLOW_IN_PLACE_RESTORE}" != "false" ]]; then
    echo "MACOS_CRI_MACHINE_STATE_ALLOW_IN_PLACE_RESTORE must be true or false" >&2
    exit 2
fi
if [[ -n "${PREPARE_RESTORE_HELPER}" ]]; then
    if [[ "${PREPARE_RESTORE_HELPER}" != /* || ! -x "${PREPARE_RESTORE_HELPER}" ]]; then
        echo "MACOS_CRI_MACHINE_STATE_PREPARE_RESTORE_HELPER must be an absolute executable path" >&2
        exit 2
    fi
elif [[ "${ALLOW_IN_PLACE_RESTORE}" != "true" ]]; then
    echo "set MACOS_CRI_MACHINE_STATE_PREPARE_RESTORE_HELPER for storage validation, or explicitly allow an in-place runtime-only restore" >&2
    exit 2
fi
SUFFIX="$(date +%s)-$$"
POD_NAME="machine-state-${SUFFIX}"
RESTORE_POD_NAME="machine-state-restore-${SUFFIX}"
PERSISTENCE_ID="cri-integration-${SUFFIX}"
STATE_ID="checkpoint-${SUFFIX}"
SAVED_STORAGE_GENERATION=1
RESTORE_STORAGE_GENERATION=$((SAVED_STORAGE_GENERATION + 1))
CONTROL_SOCKET="${CONTROL_ROOT}/${PERSISTENCE_ID}.sock"
TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/container-cri-machine-state.XXXXXX")"
INITIAL_MANIFEST="${TEMP_ROOT}/initial.json"
RESTORE_MANIFEST="${TEMP_ROOT}/restore.json"

cleanup() {
    "${KUBECTL_BIN}" --namespace "${NAMESPACE}" delete pod "${POD_NAME}" "${RESTORE_POD_NAME}" \
        --ignore-not-found --wait=false >/dev/null 2>&1 || true
    rm -rf "${TEMP_ROOT}"
}
trap cleanup EXIT

make_manifest() {
    local output=$1
    local name=$2
    local storage_generation=$3
    local restore_state=${4:-}
    local restore_generation=${5:-}
    POD_NAME_VALUE="${name}" \
        NODE_VALUE="${NODE}" \
        IMAGE_VALUE="${IMAGE}" \
        RUNTIME_CLASS_VALUE="${RUNTIME_CLASS}" \
        PERSISTENCE_ID_VALUE="${PERSISTENCE_ID}" \
        NBD_SOCKET_VALUE="${NBD_SOCKET}" \
        STORAGE_GENERATION_VALUE="${storage_generation}" \
        RESTORE_STATE_VALUE="${restore_state}" \
        RESTORE_GENERATION_VALUE="${restore_generation}" \
        python3 - "${output}" <<'PY'
import json
import os
import sys

annotations = {
    "io.container.runtime.macos.machine-state.v1/enabled": "true",
    "io.container.runtime.macos.machine-state.v1/persistence-id": os.environ["PERSISTENCE_ID_VALUE"],
    "io.container.runtime.macos.machine-state.v1/storage-generation": os.environ["STORAGE_GENERATION_VALUE"],
    "io.container.runtime.macos.machine-state.v1/block-devices": json.dumps(
        [{
            "identifier": "root",
            "unixSocket": os.environ["NBD_SOCKET_VALUE"],
            "exportName": "root",
            "readOnly": False,
            "timeoutSeconds": 30,
        }],
        separators=(",", ":"),
    ),
}
if os.environ["RESTORE_STATE_VALUE"]:
    annotations["io.container.runtime.macos.machine-state.v1/restore-state-id"] = os.environ["RESTORE_STATE_VALUE"]
    annotations["io.container.runtime.macos.machine-state.v1/restore-state-generation"] = os.environ[
        "RESTORE_GENERATION_VALUE"
    ]

manifest = {
    "apiVersion": "v1",
    "kind": "Pod",
    "metadata": {"name": os.environ["POD_NAME_VALUE"], "annotations": annotations},
    "spec": {
        "nodeName": os.environ["NODE_VALUE"],
        "runtimeClassName": os.environ["RUNTIME_CLASS_VALUE"],
        "automountServiceAccountToken": False,
        "restartPolicy": "Never",
        "containers": [{
            "name": "counter",
            "image": os.environ["IMAGE_VALUE"],
            "command": ["/bin/sh", "-lc"],
            "args": [
                "boot_token=$(/usr/bin/uuidgen) || exit 1; "
                "n=0; while :; do n=$((n+1)); "
                "printf 'machine-state-sample:%s:%s:%s\\n' \"$boot_token\" \"$$\" \"$n\"; "
                "sleep 1; done"
            ],
        }],
    },
}
with open(sys.argv[1], "w", encoding="utf-8") as output:
    json.dump(manifest, output)
PY
}

sidecar_rpc() {
    local method=$1
    local state_id=${2:-}
    python3 - "${CONTROL_SOCKET}" "${method}" "${state_id}" <<'PY'
import json
import socket
import struct
import sys
import uuid

socket_path, method, state_id = sys.argv[1:]
request_id = str(uuid.uuid4())
request = {"requestID": request_id, "method": method, "protocolVersion": 2}
if method in {"vm.pause", "vm.resume", "vm.saveMachineState"}:
    request["machineState"] = {"timeoutSeconds": 600}
if state_id:
    request["machineState"]["stateID"] = state_id
envelope = {"kind": "request", "request": request}
payload = json.dumps(envelope, separators=(",", ":")).encode()

client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
client.settimeout(610)
client.connect(socket_path)
client.sendall(struct.pack(">I", len(payload)) + payload)
header = client.recv(4)
if len(header) != 4:
    raise SystemExit("sidecar returned an incomplete frame header")
length = struct.unpack(">I", header)[0]
data = b""
while len(data) < length:
    chunk = client.recv(length - len(data))
    if not chunk:
        raise SystemExit("sidecar closed before the complete response frame")
    data += chunk
response_envelope = json.loads(data)
response = response_envelope.get("response")
if response_envelope.get("kind") != "response" or not response or response.get("requestID") != request_id:
    raise SystemExit("sidecar returned an invalid response envelope")
if not response.get("ok"):
    raise SystemExit(json.dumps(response.get("error", {}), sort_keys=True))
print(json.dumps(response, sort_keys=True))
PY
}

wait_for_control_socket() {
    local deadline=$((SECONDS + 180))
    while [[ ! -S "${CONTROL_SOCKET}" ]]; do
        if ((SECONDS >= deadline)); then
            echo "timed out waiting for sidecar control socket ${CONTROL_SOCKET}" >&2
            exit 1
        fi
        sleep 1
    done
}

read_process_sample() {
    local pod_name=$1
    local deadline=$((SECONDS + 180))
    local line
    local logs
    local sample
    while :; do
        logs="$("${KUBECTL_BIN}" --namespace "${NAMESPACE}" logs "${pod_name}" \
            --container counter --tail=128 2>/dev/null || true)"
        sample=""
        while IFS= read -r line; do
            if [[ "${line}" =~ ^machine-state-sample:([[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}):([1-9][0-9]*):([1-9][0-9]*)$ ]]; then
                sample="${BASH_REMATCH[1]}:${BASH_REMATCH[2]}:${BASH_REMATCH[3]}"
            fi
        done <<<"${logs}"
        if [[ -n "${sample}" ]]; then
            printf '%s\n' "${sample}"
            return
        fi
        if ((SECONDS >= deadline)); then
            echo "timed out waiting for an in-memory process sample in logs for ${pod_name}" >&2
            exit 1
        fi
        sleep 1
    done
}

wait_for_advanced_process_sample() {
    local pod_name=$1
    local baseline=$2
    local deadline=$((SECONDS + 180))
    local sample
    while :; do
        sample="$(read_process_sample "${pod_name}")"
        if [[ "$(sample_boot_token "${sample}")" != "$(sample_boot_token "${baseline}")" \
            || "$(sample_pid "${sample}")" != "$(sample_pid "${baseline}")" ]]; then
            echo "guest process identity changed: baseline=${baseline} observed=${sample}" >&2
            exit 1
        fi
        if (( $(sample_counter "${sample}") > $(sample_counter "${baseline}") )); then
            printf '%s\n' "${sample}"
            return
        fi
        if ((SECONDS >= deadline)); then
            echo "timed out waiting for guest process progress: baseline=${baseline} observed=${sample}" >&2
            exit 1
        fi
        sleep 1
    done
}

sample_boot_token() {
    printf '%s\n' "${1%%:*}"
}

sample_pid() {
    local remainder=${1#*:}
    printf '%s\n' "${remainder%%:*}"
}

sample_counter() {
    printf '%s\n' "${1##*:}"
}

require_running_pod() {
    local pod_name=$1
    local phase
    phase="$("${KUBECTL_BIN}" --namespace "${NAMESPACE}" get pod "${pod_name}" \
        -o jsonpath='{.status.phase}')"
    if [[ "${phase}" != "Running" ]]; then
        echo "Pod ${pod_name} is Ready but has unexpected phase ${phase}" >&2
        exit 1
    fi
}

container_id() {
    local pod_name=$1
    local id
    id="$("${KUBECTL_BIN}" --namespace "${NAMESPACE}" get pod "${pod_name}" \
        -o jsonpath='{.status.containerStatuses[0].containerID}')"
    if [[ -z "${id}" ]]; then
        echo "Pod ${pod_name} has no CRI container ID" >&2
        exit 1
    fi
    printf '%s\n' "${id}"
}

make_manifest "${INITIAL_MANIFEST}" "${POD_NAME}" "${SAVED_STORAGE_GENERATION}"
"${KUBECTL_BIN}" --namespace "${NAMESPACE}" apply -f "${INITIAL_MANIFEST}" >/dev/null
"${KUBECTL_BIN}" --namespace "${NAMESPACE}" wait pod/"${POD_NAME}" --for=condition=Ready --timeout="${WAIT_TIMEOUT}"
require_running_pod "${POD_NAME}"
INITIAL_UID="$("${KUBECTL_BIN}" --namespace "${NAMESPACE}" get pod "${POD_NAME}" -o jsonpath='{.metadata.uid}')"
INITIAL_CONTAINER_ID="$(container_id "${POD_NAME}")"
wait_for_control_socket

sidecar_rpc vm.capabilities >/dev/null
SAMPLE_BEFORE="$(read_process_sample "${POD_NAME}")"
sidecar_rpc vm.pause >/dev/null
sidecar_rpc vm.resume >/dev/null
SAMPLE_AFTER_RESUME="$(wait_for_advanced_process_sample "${POD_NAME}" "${SAMPLE_BEFORE}")"

CHECKPOINT_SAMPLE="${SAMPLE_AFTER_RESUME}"
sidecar_rpc vm.pause >/dev/null
sidecar_rpc vm.saveMachineState "${STATE_ID}" >/dev/null

echo "machine state ${STATE_ID} is committed with storage generation ${SAVED_STORAGE_GENERATION}; the VM remains paused" >&2
echo "the stable NBD socket must now select a writable clone for storage generation ${RESTORE_STORAGE_GENERATION}" >&2

"${KUBECTL_BIN}" --namespace "${NAMESPACE}" delete pod "${POD_NAME}" --wait --timeout="${WAIT_TIMEOUT}" >/dev/null
if [[ -n "${PREPARE_RESTORE_HELPER}" ]]; then
    "${PREPARE_RESTORE_HELPER}" \
        "${NBD_SOCKET}" \
        "${STATE_ID}" \
        "${SAVED_STORAGE_GENERATION}" \
        "${RESTORE_STORAGE_GENERATION}"
else
    echo "warning: reusing the quiesced NBD backing; external snapshot, clone, and stale-writer fencing are not validated" >&2
fi
make_manifest \
    "${RESTORE_MANIFEST}" \
    "${RESTORE_POD_NAME}" \
    "${RESTORE_STORAGE_GENERATION}" \
    "${STATE_ID}" \
    "${SAVED_STORAGE_GENERATION}"
"${KUBECTL_BIN}" --namespace "${NAMESPACE}" apply -f "${RESTORE_MANIFEST}" >/dev/null
if ! "${KUBECTL_BIN}" --namespace "${NAMESPACE}" wait pod/"${RESTORE_POD_NAME}" \
    --for=condition=Ready --timeout="${WAIT_TIMEOUT}"; then
    "${KUBECTL_BIN}" --namespace "${NAMESPACE}" describe pod "${RESTORE_POD_NAME}" >&2 || true
    exit 1
fi
RESTORE_UID="$("${KUBECTL_BIN}" --namespace "${NAMESPACE}" get pod "${RESTORE_POD_NAME}" -o jsonpath='{.metadata.uid}')"
if [[ "${RESTORE_UID}" == "${INITIAL_UID}" ]]; then
    echo "recreated Pod unexpectedly reused UID ${RESTORE_UID}" >&2
    exit 1
fi
require_running_pod "${RESTORE_POD_NAME}"
RESTORE_CONTAINER_ID="$(container_id "${RESTORE_POD_NAME}")"
if [[ "${RESTORE_CONTAINER_ID}" == "${INITIAL_CONTAINER_ID}" ]]; then
    echo "recreated Pod unexpectedly reused CRI container ID ${RESTORE_CONTAINER_ID}" >&2
    exit 1
fi
if ! "${KUBECTL_BIN}" --namespace "${NAMESPACE}" exec "${RESTORE_POD_NAME}" \
    --container counter -- /usr/bin/true; then
    echo "first exec readiness probe failed for restored Pod ${RESTORE_POD_NAME}" >&2
    exit 1
fi
RESTORED_SAMPLE="$(read_process_sample "${RESTORE_POD_NAME}")"
RESTORED_SAMPLE_LATER="$(wait_for_advanced_process_sample "${RESTORE_POD_NAME}" "${RESTORED_SAMPLE}")"

CHECKPOINT_PID="$(sample_pid "${CHECKPOINT_SAMPLE}")"
RESTORED_PID="$(sample_pid "${RESTORED_SAMPLE}")"
CHECKPOINT_BOOT_TOKEN="$(sample_boot_token "${CHECKPOINT_SAMPLE}")"
RESTORED_BOOT_TOKEN="$(sample_boot_token "${RESTORED_SAMPLE}")"
if [[ "${RESTORED_BOOT_TOKEN}" != "${CHECKPOINT_BOOT_TOKEN}" \
    || "$(sample_boot_token "${RESTORED_SAMPLE_LATER}")" != "${CHECKPOINT_BOOT_TOKEN}" \
    || "${RESTORED_PID}" != "${CHECKPOINT_PID}" \
    || "$(sample_pid "${RESTORED_SAMPLE_LATER}")" != "${CHECKPOINT_PID}" ]]; then
    echo "guest boot token or PID was not adopted across restore: checkpoint=${CHECKPOINT_SAMPLE} restored=${RESTORED_SAMPLE} later=${RESTORED_SAMPLE_LATER}" >&2
    exit 1
fi
if (( $(sample_counter "${RESTORED_SAMPLE}") < $(sample_counter "${CHECKPOINT_SAMPLE}") )); then
    echo "guest counter did not continue across restore: checkpoint=${CHECKPOINT_SAMPLE} restored=${RESTORED_SAMPLE} later=${RESTORED_SAMPLE_LATER}" >&2
    exit 1
fi

echo "machine-state restore passed: pod UID ${INITIAL_UID}->${RESTORE_UID}, container ${INITIAL_CONTAINER_ID}->${RESTORE_CONTAINER_ID}, guest sample ${CHECKPOINT_SAMPLE}->${RESTORED_SAMPLE_LATER}"
