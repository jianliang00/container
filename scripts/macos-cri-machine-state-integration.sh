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
pause/save/compatibility/resume through the stable sidecar socket, deletes the
Pod, verifies that a new Pod UID requesting restore is rejected before sandbox
or container start with criWorkloadAdoptionUnavailable, and verifies that a
disconnected local NBD socket is rejected before container creation.

Required environment:
  MACOS_CRI_MACHINE_STATE_NODE          Kubernetes node name
  MACOS_CRI_MACHINE_STATE_IMAGE         macOS workload image
  MACOS_CRI_MACHINE_STATE_NBD_SOCKET    absolute host Unix socket exporting a bootable root disk

Optional environment:
  KUBECTL                               kubectl executable (default: kubectl)
  MACOS_CRI_MACHINE_STATE_NAMESPACE     namespace (default: default)
  MACOS_CRI_MACHINE_STATE_RUNTIME_CLASS RuntimeClass (default: macos)
  MACOS_CRI_MACHINE_STATE_CONTROL_ROOT  sidecar socket root (default: /var/run/container/machine-state/v1)
  MACOS_CRI_MACHINE_STATE_STORAGE_ROOT  persistent state root (default: /var/lib/container/cri-shim-macos/machine-state/v1)
  MACOS_CRI_MACHINE_STATE_TIMEOUT       wait timeout (default: 180s)
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
STORAGE_ROOT="${MACOS_CRI_MACHINE_STATE_STORAGE_ROOT:-/var/lib/container/cri-shim-macos/machine-state/v1}"
WAIT_TIMEOUT="${MACOS_CRI_MACHINE_STATE_TIMEOUT:-180s}"
SUFFIX="$(date +%s)-$$"
POD_NAME="machine-state-${SUFFIX}"
RESTORE_POD_NAME="machine-state-restore-${SUFFIX}"
DISCONNECTED_POD_NAME="machine-state-nbd-disconnected-${SUFFIX}"
PERSISTENCE_ID="cri-integration-${SUFFIX}"
DISCONNECTED_PERSISTENCE_ID="cri-nbd-disconnected-${SUFFIX}"
STATE_ID="checkpoint-${SUFFIX}"
CONTROL_SOCKET="${CONTROL_ROOT}/${PERSISTENCE_ID}.sock"
DISCONNECTED_CONTROL_SOCKET="${CONTROL_ROOT}/${DISCONNECTED_PERSISTENCE_ID}.sock"
DISCONNECTED_STORAGE_DIRECTORY="${STORAGE_ROOT}/${DISCONNECTED_PERSISTENCE_ID}"
DISCONNECTED_SOCKET="$(dirname "${NBD_SOCKET}")/missing-${SUFFIX}.sock"
TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/container-cri-machine-state.XXXXXX")"
INITIAL_MANIFEST="${TEMP_ROOT}/initial.json"
RESTORE_MANIFEST="${TEMP_ROOT}/restore.json"
DISCONNECTED_MANIFEST="${TEMP_ROOT}/disconnected.json"

cleanup() {
    "${KUBECTL_BIN}" --namespace "${NAMESPACE}" delete pod \
        "${POD_NAME}" "${RESTORE_POD_NAME}" "${DISCONNECTED_POD_NAME}" \
        --ignore-not-found --wait=false >/dev/null 2>&1 || true
    rm -rf "${TEMP_ROOT}"
}
trap cleanup EXIT

make_manifest() {
    local output=$1
    local name=$2
    local restore_state=${3:-}
    local persistence_id=${4:-${PERSISTENCE_ID}}
    local nbd_socket=${5:-${NBD_SOCKET}}
    POD_NAME_VALUE="${name}" \
        NODE_VALUE="${NODE}" \
        IMAGE_VALUE="${IMAGE}" \
        RUNTIME_CLASS_VALUE="${RUNTIME_CLASS}" \
        PERSISTENCE_ID_VALUE="${persistence_id}" \
        NBD_SOCKET_VALUE="${nbd_socket}" \
        RESTORE_STATE_VALUE="${restore_state}" \
        python3 - "${output}" <<'PY'
import json
import os
import sys

annotations = {
    "io.container.runtime.macos.machine-state.v1/enabled": "true",
    "io.container.runtime.macos.machine-state.v1/persistence-id": os.environ["PERSISTENCE_ID_VALUE"],
    "io.container.runtime.macos.machine-state.v1/block-devices": json.dumps(
        [{
            "identifier": "root",
            "unixSocket": os.environ["NBD_SOCKET_VALUE"],
            "readOnly": False,
            "timeoutSeconds": 30,
        }],
        separators=(",", ":"),
    ),
}
if os.environ["RESTORE_STATE_VALUE"]:
    annotations["io.container.runtime.macos.machine-state.v1/restore-state-id"] = os.environ["RESTORE_STATE_VALUE"]

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
                "n=0; while :; do n=$((n+1)); echo $n | tee /tmp/container-machine-state-counter; sleep 1; done"
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
    request.setdefault("machineState", {})["stateID"] = state_id
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

validate_sidecar_payload() {
    local kind=$1
    local response=$2
    SIDECAR_PAYLOAD_KIND="${kind}" SIDECAR_RESPONSE="${response}" python3 - <<'PY'
import base64
import json
import os

kind = os.environ["SIDECAR_PAYLOAD_KIND"]
response = json.loads(os.environ["SIDECAR_RESPONSE"])
if response.get("protocolVersion") != 2:
    raise SystemExit("sidecar response did not report protocol version 2")
encoded = response.get("data")
if not encoded:
    raise SystemExit("sidecar response omitted its structured data payload")
payload = json.loads(base64.b64decode(encoded, validate=True))

if kind == "capabilities":
    required_methods = {
        "vm.pause",
        "vm.resume",
        "vm.saveMachineState",
        "vm.restoreMachineState",
        "vm.compatibilityDescription",
    }
    if payload.get("protocolVersion") != 2 or 2 not in payload.get("supportedProtocolVersions", []):
        raise SystemExit("machine-state protocol version 2 was not advertised")
    if payload.get("lifecycleState") != "running":
        raise SystemExit("capabilities did not report a running VM")
    if not payload.get("machineState", {}).get("supported"):
        raise SystemExit("effective VM configuration did not support machine state")
    if not required_methods.issubset(payload.get("methods", [])):
        raise SystemExit("capabilities omitted one or more machine-state methods")
elif kind == "compatibility":
    if payload.get("compatible") is not True or payload.get("reasons"):
        raise SystemExit("newly saved machine state was not compatible with the running VM")
    required_description = {
        "schemaVersion",
        "runtimeProtocolVersion",
        "createdAt",
        "hostBuild",
        "hostModel",
        "hostIdentifier",
        "hardwareModelFingerprint",
        "machineIdentifierFingerprint",
        "configuration",
    }
    required_configuration = {
        "cpuCount",
        "memorySize",
        "bootLoader",
        "networkBackend",
        "networkDeviceMACAddresses",
        "storageDevices",
        "directoryShareCount",
        "hasGraphics",
        "hasVirtioSocket",
        "fingerprint",
    }
    for description_name in ("current", "saved"):
        description = payload.get(description_name)
        if not isinstance(description, dict) or not required_description.issubset(description):
            raise SystemExit(f"compatibility response omitted fields from {description_name} description")
        if description.get("schemaVersion") != 1 or description.get("runtimeProtocolVersion") != 2:
            raise SystemExit(f"compatibility response reported unsupported {description_name} versions")
        if not all(description.get(field) for field in (
            "hostBuild",
            "hostModel",
            "hostIdentifier",
            "hardwareModelFingerprint",
            "machineIdentifierFingerprint",
        )):
            raise SystemExit(f"compatibility response omitted host-bound {description_name} values")
        configuration = description.get("configuration", {})
        if not required_configuration.issubset(configuration):
            raise SystemExit(f"compatibility response omitted {description_name} VM configuration fields")
        storage = configuration.get("storageDevices", [])
        if (
            len(storage) != 1
            or storage[0].get("identifier") != "root"
            or storage[0].get("kind") != "nbdUnixSocket"
            or storage[0].get("readOnly") is not False
            or storage[0].get("synchronizationMode") != "full"
        ):
            raise SystemExit(f"compatibility response did not describe the synchronized root device for {description_name}")
else:
    raise SystemExit(f"unsupported sidecar payload validation kind: {kind}")
PY
}

created_container_count() {
    python3 -c '
import json
import sys

pod = json.load(sys.stdin)
statuses = pod.get("status", {}).get("containerStatuses", [])
print(sum(bool(status.get("containerID")) for status in statuses))
'
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

make_manifest "${INITIAL_MANIFEST}" "${POD_NAME}"
"${KUBECTL_BIN}" --namespace "${NAMESPACE}" apply -f "${INITIAL_MANIFEST}" >/dev/null
"${KUBECTL_BIN}" --namespace "${NAMESPACE}" wait pod/"${POD_NAME}" --for=condition=Ready --timeout="${WAIT_TIMEOUT}"
INITIAL_UID="$("${KUBECTL_BIN}" --namespace "${NAMESPACE}" get pod "${POD_NAME}" -o jsonpath='{.metadata.uid}')"
wait_for_control_socket

CAPABILITIES_RESPONSE="$(sidecar_rpc vm.capabilities)"
validate_sidecar_payload capabilities "${CAPABILITIES_RESPONSE}"
COUNTER_BEFORE="$("${KUBECTL_BIN}" --namespace "${NAMESPACE}" exec "${POD_NAME}" -- cat /tmp/container-machine-state-counter)"
sidecar_rpc vm.pause >/dev/null
sidecar_rpc vm.saveMachineState "${STATE_ID}" >/dev/null
COMPATIBILITY_RESPONSE="$(sidecar_rpc vm.compatibilityDescription "${STATE_ID}")"
validate_sidecar_payload compatibility "${COMPATIBILITY_RESPONSE}"
sidecar_rpc vm.resume >/dev/null
sleep 2
COUNTER_AFTER="$("${KUBECTL_BIN}" --namespace "${NAMESPACE}" exec "${POD_NAME}" -- cat /tmp/container-machine-state-counter)"
if ! [[ "${COUNTER_BEFORE}" =~ ^[0-9]+$ && "${COUNTER_AFTER}" =~ ^[0-9]+$ ]] \
    || ((COUNTER_AFTER <= COUNTER_BEFORE)); then
    echo "counter did not continue after short machine-state control connections: before=${COUNTER_BEFORE} after=${COUNTER_AFTER}" >&2
    exit 1
fi
LOG_TAIL="$("${KUBECTL_BIN}" --namespace "${NAMESPACE}" logs "${POD_NAME}" --tail=1)"
if ! [[ "${LOG_TAIL}" =~ ^[0-9]+$ ]]; then
    echo "workload logs were not observable after machine-state control requests" >&2
    exit 1
fi

"${KUBECTL_BIN}" --namespace "${NAMESPACE}" delete pod "${POD_NAME}" --wait --timeout="${WAIT_TIMEOUT}" >/dev/null
make_manifest "${RESTORE_MANIFEST}" "${RESTORE_POD_NAME}" "${STATE_ID}"
"${KUBECTL_BIN}" --namespace "${NAMESPACE}" apply -f "${RESTORE_MANIFEST}" >/dev/null
RESTORE_UID="$("${KUBECTL_BIN}" --namespace "${NAMESPACE}" get pod "${RESTORE_POD_NAME}" -o jsonpath='{.metadata.uid}')"
if [[ "${RESTORE_UID}" == "${INITIAL_UID}" ]]; then
    echo "recreated Pod unexpectedly reused UID ${RESTORE_UID}" >&2
    exit 1
fi

deadline=$((SECONDS + 180))
while :; do
    POD_JSON="$("${KUBECTL_BIN}" --namespace "${NAMESPACE}" get pod "${RESTORE_POD_NAME}" -o json)"
    if grep -F "criWorkloadAdoptionUnavailable" <<<"${POD_JSON}" >/dev/null; then
        break
    fi
    EVENT_JSON="$("${KUBECTL_BIN}" --namespace "${NAMESPACE}" get events \
        --field-selector "involvedObject.uid=${RESTORE_UID}" -o json 2>/dev/null || true)"
    if grep -F "criWorkloadAdoptionUnavailable" <<<"${EVENT_JSON}" >/dev/null; then
        break
    fi
    POD_PHASE="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("status", {}).get("phase", ""))' <<<"${POD_JSON}")"
    if [[ "${POD_PHASE}" == "Running" ]]; then
        echo "restore request incorrectly reached Running without workload adoption" >&2
        exit 1
    fi
    if ((SECONDS >= deadline)); then
        echo "timed out waiting for structured CRI restore rejection" >&2
        "${KUBECTL_BIN}" --namespace "${NAMESPACE}" describe pod "${RESTORE_POD_NAME}" >&2 || true
        exit 1
    fi
    sleep 2
done

FINAL_JSON="$("${KUBECTL_BIN}" --namespace "${NAMESPACE}" get pod "${RESTORE_POD_NAME}" -o json)"
CREATED_CONTAINER_COUNT="$(created_container_count <<<"${FINAL_JSON}")"
if [[ "${CREATED_CONTAINER_COUNT}" != "0" ]]; then
    echo "restore rejection occurred after a CRI container was created" >&2
    exit 1
fi

if [[ -e "${DISCONNECTED_SOCKET}" || -L "${DISCONNECTED_SOCKET}" ]]; then
    echo "disconnected NBD test socket unexpectedly exists: ${DISCONNECTED_SOCKET}" >&2
    exit 1
fi
make_manifest \
    "${DISCONNECTED_MANIFEST}" \
    "${DISCONNECTED_POD_NAME}" \
    "" \
    "${DISCONNECTED_PERSISTENCE_ID}" \
    "${DISCONNECTED_SOCKET}"
"${KUBECTL_BIN}" --namespace "${NAMESPACE}" apply -f "${DISCONNECTED_MANIFEST}" >/dev/null
DISCONNECTED_UID="$("${KUBECTL_BIN}" --namespace "${NAMESPACE}" get pod "${DISCONNECTED_POD_NAME}" -o jsonpath='{.metadata.uid}')"

deadline=$((SECONDS + 180))
while :; do
    POD_JSON="$("${KUBECTL_BIN}" --namespace "${NAMESPACE}" get pod "${DISCONNECTED_POD_NAME}" -o json)"
    EVENT_JSON="$("${KUBECTL_BIN}" --namespace "${NAMESPACE}" get events \
        --field-selector "involvedObject.uid=${DISCONNECTED_UID}" -o json 2>/dev/null || true)"
    if grep -F "NBD Unix socket does not exist" <<<"${POD_JSON}${EVENT_JSON}" >/dev/null; then
        break
    fi
    POD_PHASE="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("status", {}).get("phase", ""))' <<<"${POD_JSON}")"
    if [[ "${POD_PHASE}" == "Running" ]]; then
        echo "disconnected NBD request incorrectly reached Running" >&2
        exit 1
    fi
    if ((SECONDS >= deadline)); then
        echo "timed out waiting for disconnected NBD rejection" >&2
        "${KUBECTL_BIN}" --namespace "${NAMESPACE}" describe pod "${DISCONNECTED_POD_NAME}" >&2 || true
        exit 1
    fi
    sleep 2
done

FINAL_JSON="$("${KUBECTL_BIN}" --namespace "${NAMESPACE}" get pod "${DISCONNECTED_POD_NAME}" -o json)"
CREATED_CONTAINER_COUNT="$(created_container_count <<<"${FINAL_JSON}")"
if [[ "${CREATED_CONTAINER_COUNT}" != "0" ]]; then
    echo "disconnected NBD rejection occurred after a CRI container was created" >&2
    exit 1
fi
if [[ -e "${DISCONNECTED_STORAGE_DIRECTORY}" || -L "${DISCONNECTED_STORAGE_DIRECTORY}" \
    || -e "${DISCONNECTED_CONTROL_SOCKET}" || -L "${DISCONNECTED_CONTROL_SOCKET}" ]]; then
    echo "disconnected NBD rejection left managed machine-state artifacts" >&2
    exit 1
fi

echo "machine-state save/resume advanced counter ${COUNTER_BEFORE}->${COUNTER_AFTER}; recreated Pod UID=${RESTORE_UID} was safely rejected with criWorkloadAdoptionUnavailable; disconnected NBD was rejected before container creation"
