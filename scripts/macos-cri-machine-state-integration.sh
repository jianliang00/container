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
validates compatibility, deletes the Pod, and restores the same durable
workload into a new Pod UID with the next writable storage generation. The
restored Pod and container must become ready, and the guest PID and in-memory
counter must continue. A separate negative case verifies that a disconnected
local NBD socket is rejected before container creation without leaving private
state or control artifacts.

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
  MACOS_CRI_MACHINE_STATE_STORAGE_ROOT  persistent state root (default: /var/lib/container/cri-shim-macos/machine-state/v1)
  MACOS_CRI_MACHINE_STATE_LEASE_ROOT    persistent lease root (default: /var/lib/container/cri-shim-macos/machine-state-leases/v1)
  MACOS_CRI_MACHINE_STATE_TIMEOUT       single operation and cleanup deadline, 1-600 seconds (default: 180s)
  MACOS_CRI_MACHINE_STATE_PREPARE_RESTORE_HELPER
                                        absolute executable invoked after the old Pod is removed;
                                        receives NBD socket, state ID, saved generation, new generation,
                                        and an idempotency key used to own the clone and export
  MACOS_CRI_MACHINE_STATE_CLEANUP_HELPER
                                        required absolute executable; receives "cleanup" and a
                                        0600 JSON request path, synchronously removes and reads back
                                        exact CRI, lease, socket, state, clone, and export resources
  MACOS_CRI_MACHINE_STATE_ALLOW_IN_PLACE_RESTORE
                                        set to true only for a runtime-only check that reuses the
                                        quiesced disk instead of validating snapshot/clone (default: false)

The NBD socket path is part of the saved VM configuration and must remain
stable. Before the restore Pod is created, its backing service must expose a
writable disk generation cloned from the disk point paired with the saved
machine state. This script performs no storage snapshot, clone, or export
switching itself.

The cleanup helper is called twice with the same idempotency key. Both calls
must succeed and return one JSON object on stdout whose schemaVersion is 1,
operation, idempotencyKey, and SHA-256 requestDigest match the request, and
whose readback object sets
criObjectsPresent, leasesPresent, controlSocketsPresent, machineStatePresent,
ownedSnapshotsPresent, ownedClonesPresent, ownedExportsPresent, and
socketBoundToOwnedExport to false. The helper must refuse external-storage
cleanup while any named Pod UID or lease remains active, and must validate the
requested roots against trusted runtime configuration instead of treating a
request path as deletion authority. Exit 75 is retryable within the single
cleanup deadline; every other nonzero exit is terminal.
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
LEASE_ROOT="${MACOS_CRI_MACHINE_STATE_LEASE_ROOT:-/var/lib/container/cri-shim-macos/machine-state-leases/v1}"
WAIT_TIMEOUT_INPUT="${MACOS_CRI_MACHINE_STATE_TIMEOUT:-180s}"
PREPARE_RESTORE_HELPER="${MACOS_CRI_MACHINE_STATE_PREPARE_RESTORE_HELPER:-}"
CLEANUP_HELPER="${MACOS_CRI_MACHINE_STATE_CLEANUP_HELPER:-}"
ALLOW_IN_PLACE_RESTORE="${MACOS_CRI_MACHINE_STATE_ALLOW_IN_PLACE_RESTORE:-false}"
if [[ "${WAIT_TIMEOUT_INPUT}" =~ ^([1-9][0-9]*)s?$ ]]; then
    if ((${#BASH_REMATCH[1]} > 3)); then
        echo "MACOS_CRI_MACHINE_STATE_TIMEOUT must not exceed the sidecar protocol limit of 600 seconds" >&2
        exit 2
    fi
    WAIT_TIMEOUT_SECONDS=$((10#${BASH_REMATCH[1]}))
else
    echo "MACOS_CRI_MACHINE_STATE_TIMEOUT must be a positive number of seconds, optionally followed by s" >&2
    exit 2
fi
if ((WAIT_TIMEOUT_SECONDS > 600)); then
    echo "MACOS_CRI_MACHINE_STATE_TIMEOUT must not exceed the sidecar protocol limit of 600 seconds" >&2
    exit 2
fi
WAIT_TIMEOUT="${WAIT_TIMEOUT_SECONDS}s"
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
if [[ "${CLEANUP_HELPER}" != /* || ! -x "${CLEANUP_HELPER}" ]]; then
    echo "MACOS_CRI_MACHINE_STATE_CLEANUP_HELPER must be an absolute executable path" >&2
    exit 2
fi
for managed_root in "${CONTROL_ROOT}" "${STORAGE_ROOT}" "${LEASE_ROOT}"; do
    if [[ "${managed_root}" != /* ]]; then
        echo "machine-state managed roots must be absolute" >&2
        exit 2
    fi
done
SUFFIX="$(date +%s)-$$"
POD_NAME="machine-state-${SUFFIX}"
RESTORE_POD_NAME="machine-state-restore-${SUFFIX}"
DISCONNECTED_POD_NAME="machine-state-nbd-disconnected-${SUFFIX}"
PERSISTENCE_ID="cri-integration-${SUFFIX}"
DISCONNECTED_PERSISTENCE_ID="cri-nbd-disconnected-${SUFFIX}"
STATE_ID="checkpoint-${SUFFIX}"
SAVED_STORAGE_GENERATION=1
RESTORE_STORAGE_GENERATION=$((SAVED_STORAGE_GENERATION + 1))
CONTROL_SOCKET="${CONTROL_ROOT}/${PERSISTENCE_ID}.sock"
DISCONNECTED_CONTROL_SOCKET="${CONTROL_ROOT}/${DISCONNECTED_PERSISTENCE_ID}.sock"
STORAGE_DIRECTORY="${STORAGE_ROOT}/${PERSISTENCE_ID}"
DISCONNECTED_STORAGE_DIRECTORY="${STORAGE_ROOT}/${DISCONNECTED_PERSISTENCE_ID}"
LEASE_FILE="${LEASE_ROOT}/${PERSISTENCE_ID}.json"
DISCONNECTED_LEASE_FILE="${LEASE_ROOT}/${DISCONNECTED_PERSISTENCE_ID}.json"
DISCONNECTED_SOCKET="$(dirname "${NBD_SOCKET}")/missing-${SUFFIX}.sock"
IDEMPOTENCY_KEY="${PERSISTENCE_ID}:${STATE_ID}:${SAVED_STORAGE_GENERATION}:${RESTORE_STORAGE_GENERATION}"
umask 077
TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/container-cri-machine-state.XXXXXX")"
INITIAL_MANIFEST="${TEMP_ROOT}/initial.json"
RESTORE_MANIFEST="${TEMP_ROOT}/restore.json"
DISCONNECTED_MANIFEST="${TEMP_ROOT}/disconnected.json"
PENDING_OPERATION_FILE="${TEMP_ROOT}/sidecar-operation-pending"
CLEANUP_CONTEXT="${TEMP_ROOT}/cleanup-context.json"
INITIAL_UID=""
RESTORE_UID=""
DISCONNECTED_UID=""
INITIAL_CONTAINER_ID=""
RESTORE_CONTAINER_ID=""
SUCCESS_MESSAGE=""
RUN_SUCCEEDED=false
CLEANUP_RUNNING=false

cleanup() {
    local original_status=$?
    local cleanup_failed=0
    local cleanup_deadline=$((SECONDS + WAIT_TIMEOUT_SECONDS))

    trap - EXIT INT TERM
    if [[ "${CLEANUP_RUNNING}" == "true" ]]; then
        exit "${original_status}"
    fi
    CLEANUP_RUNNING=true
    set +e

    if [[ -e "${PENDING_OPERATION_FILE}" ]]; then
        echo "sidecar operation outcome is unresolved; preserving Pod, lease, storage, and ${TEMP_ROOT} for reconciliation" >&2
        cleanup_failed=1
    else
        delete_owned_pod "${POD_NAME}" "${INITIAL_UID}" "${cleanup_deadline}" || cleanup_failed=1
        delete_owned_pod "${RESTORE_POD_NAME}" "${RESTORE_UID}" "${cleanup_deadline}" || cleanup_failed=1
        delete_owned_pod "${DISCONNECTED_POD_NAME}" "${DISCONNECTED_UID}" "${cleanup_deadline}" || cleanup_failed=1
        if ((cleanup_failed == 0)); then
            wait_for_runtime_binding_absent "${PERSISTENCE_ID}" "${cleanup_deadline}" || cleanup_failed=1
            wait_for_runtime_binding_absent "${DISCONNECTED_PERSISTENCE_ID}" "${cleanup_deadline}" || cleanup_failed=1
        fi
        if ((cleanup_failed == 0)); then
            write_cleanup_context || cleanup_failed=1
        fi
        if ((cleanup_failed == 0)); then
            run_cleanup_helper_twice "${cleanup_deadline}" || cleanup_failed=1
        fi
        if ((cleanup_failed == 0)); then
            require_managed_paths_absent || cleanup_failed=1
        fi
    fi

    if ((original_status == 0)) && [[ "${RUN_SUCCEEDED}" != "true" ]]; then
        cleanup_failed=1
    fi
    if ((original_status == 0 && cleanup_failed == 0)); then
        rm -rf "${TEMP_ROOT}"
        printf '%s\n' "${SUCCESS_MESSAGE}"
        exit 0
    fi
    if ((cleanup_failed != 0)); then
        echo "machine-state cleanup did not complete; evidence retained at ${TEMP_ROOT}" >&2
    fi
    if ((original_status != 0)); then
        exit "${original_status}"
    fi
    exit 1
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

pod_identity() {
    local pod_name=$1
    "${KUBECTL_BIN}" --namespace "${NAMESPACE}" get pod "${pod_name}" \
        --ignore-not-found -o json | python3 -c '
import json
import sys

raw = sys.stdin.read()
if raw:
    pod = json.loads(raw)
    print("{}\t{}".format(
        pod.get("metadata", {}).get("uid", ""),
        pod.get("metadata", {}).get("labels", {}).get("container-machine-state-run", ""),
    ))
'
}

delete_owned_pod() {
    local pod_name=$1
    local expected_uid=$2
    local deadline=$3
    local identity
    local current_uid
    local run_token
    local remaining

    identity="$(pod_identity "${pod_name}")" || return 1
    if [[ -z "${identity}" ]]; then
        return 0
    fi
    IFS=$'\t' read -r current_uid run_token <<<"${identity}"
    if [[ "${run_token}" != "${SUFFIX}" ]]; then
        echo "refusing to delete Pod ${pod_name}: run label changed" >&2
        return 1
    fi
    if [[ -n "${expected_uid}" && "${current_uid}" != "${expected_uid}" ]]; then
        echo "refusing to delete Pod ${pod_name}: UID changed from ${expected_uid} to ${current_uid}" >&2
        return 1
    fi
    expected_uid="${current_uid}"
    remaining=$((deadline - SECONDS))
    if ((remaining <= 0)); then
        echo "cleanup deadline expired before deleting Pod ${pod_name}" >&2
        return 1
    fi
    if ! "${KUBECTL_BIN}" --namespace "${NAMESPACE}" delete pod \
        --selector="container-machine-state-run=${SUFFIX}" \
        --field-selector="metadata.name=${pod_name}" \
        --ignore-not-found --wait=true --timeout="${remaining}s" >/dev/null; then
        echo "failed to synchronously delete Pod ${pod_name}" >&2
        return 1
    fi
    while ((SECONDS < deadline)); do
        identity="$(pod_identity "${pod_name}")" || return 1
        if [[ -z "${identity}" ]]; then
            return 0
        fi
        IFS=$'\t' read -r current_uid run_token <<<"${identity}"
        if [[ "${current_uid}" != "${expected_uid}" ]]; then
            echo "Pod ${pod_name} was replaced by UID ${current_uid}; refusing to treat cleanup as complete" >&2
            return 1
        fi
        sleep 1
    done
    echo "timed out reading back deletion of Pod ${pod_name} UID ${expected_uid}" >&2
    return 1
}

write_cleanup_context() {
    CLEANUP_CONTEXT_PATH="${CLEANUP_CONTEXT}" \
        RUN_TOKEN_VALUE="${SUFFIX}" \
        IDEMPOTENCY_KEY_VALUE="${IDEMPOTENCY_KEY}" \
        NAMESPACE_VALUE="${NAMESPACE}" \
        NODE_VALUE="${NODE}" \
        POD_NAME_VALUE="${POD_NAME}" \
        POD_UID_VALUE="${INITIAL_UID}" \
        RESTORE_POD_NAME_VALUE="${RESTORE_POD_NAME}" \
        RESTORE_POD_UID_VALUE="${RESTORE_UID}" \
        DISCONNECTED_POD_NAME_VALUE="${DISCONNECTED_POD_NAME}" \
        DISCONNECTED_POD_UID_VALUE="${DISCONNECTED_UID}" \
        PERSISTENCE_ID_VALUE="${PERSISTENCE_ID}" \
        DISCONNECTED_PERSISTENCE_ID_VALUE="${DISCONNECTED_PERSISTENCE_ID}" \
        STATE_ID_VALUE="${STATE_ID}" \
        NBD_SOCKET_VALUE="${NBD_SOCKET}" \
        SAVED_GENERATION_VALUE="${SAVED_STORAGE_GENERATION}" \
        RESTORE_GENERATION_VALUE="${RESTORE_STORAGE_GENERATION}" \
        STORAGE_ROOT_VALUE="${STORAGE_ROOT}" \
        CONTROL_ROOT_VALUE="${CONTROL_ROOT}" \
        LEASE_ROOT_VALUE="${LEASE_ROOT}" \
        ALLOW_IN_PLACE_VALUE="${ALLOW_IN_PLACE_RESTORE}" \
        python3 - <<'PY'
import json
import os

def pod(name_key, uid_key):
    uid = os.environ[uid_key]
    return {"name": os.environ[name_key], "uid": uid or None}

context = {
    "schemaVersion": 1,
    "operation": "cleanup",
    "idempotencyKey": os.environ["IDEMPOTENCY_KEY_VALUE"],
    "runToken": os.environ["RUN_TOKEN_VALUE"],
    "namespace": os.environ["NAMESPACE_VALUE"],
    "node": os.environ["NODE_VALUE"],
    "pods": [
        pod("POD_NAME_VALUE", "POD_UID_VALUE"),
        pod("RESTORE_POD_NAME_VALUE", "RESTORE_POD_UID_VALUE"),
        pod("DISCONNECTED_POD_NAME_VALUE", "DISCONNECTED_POD_UID_VALUE"),
    ],
    "persistenceIDs": [
        os.environ["PERSISTENCE_ID_VALUE"],
        os.environ["DISCONNECTED_PERSISTENCE_ID_VALUE"],
    ],
    "stateID": os.environ["STATE_ID_VALUE"],
    "nbdSocket": os.environ["NBD_SOCKET_VALUE"],
    "savedGeneration": int(os.environ["SAVED_GENERATION_VALUE"]),
    "restoreGeneration": int(os.environ["RESTORE_GENERATION_VALUE"]),
    "storageRoot": os.environ["STORAGE_ROOT_VALUE"],
    "controlRoot": os.environ["CONTROL_ROOT_VALUE"],
    "leaseRoot": os.environ["LEASE_ROOT_VALUE"],
    "allowInPlaceRestore": os.environ["ALLOW_IN_PLACE_VALUE"] == "true",
}
with open(os.environ["CLEANUP_CONTEXT_PATH"], "w", encoding="utf-8") as output:
    json.dump(context, output, sort_keys=True, separators=(",", ":"))
    output.write("\n")
PY
}

validate_cleanup_receipt() {
    local receipt=$1
    CLEANUP_RECEIPT_PATH="${receipt}" \
        CLEANUP_CONTEXT_PATH="${CLEANUP_CONTEXT}" \
        python3 - <<'PY'
import hashlib
import json
import os

with open(os.environ["CLEANUP_CONTEXT_PATH"], encoding="utf-8") as source:
    context = json.load(source)
with open(os.environ["CLEANUP_CONTEXT_PATH"], "rb") as source:
    request_digest = hashlib.sha256(source.read()).hexdigest()
with open(os.environ["CLEANUP_RECEIPT_PATH"], encoding="utf-8") as source:
    receipt = json.load(source)
if receipt.get("schemaVersion") != 1 or receipt.get("operation") != "cleanup":
    raise SystemExit("cleanup helper returned an unsupported receipt")
if receipt.get("idempotencyKey") != context["idempotencyKey"]:
    raise SystemExit("cleanup helper receipt did not match the requested ownership key")
if receipt.get("requestDigest") != request_digest:
    raise SystemExit("cleanup helper receipt did not match the exact cleanup request")
readback = receipt.get("readback")
required = {
    "criObjectsPresent",
    "leasesPresent",
    "controlSocketsPresent",
    "machineStatePresent",
    "ownedSnapshotsPresent",
    "ownedClonesPresent",
    "ownedExportsPresent",
    "socketBoundToOwnedExport",
}
if not isinstance(readback, dict) or not required.issubset(readback):
    raise SystemExit("cleanup helper receipt omitted required readback fields")
if any(readback[name] is not False for name in required):
    raise SystemExit("cleanup helper readback still reports owned resources")
PY
}

run_cleanup_helper_once() {
    local attempt=$1
    local deadline=$2
    local receipt="${TEMP_ROOT}/cleanup-receipt-${attempt}.json"
    local result

    while ((SECONDS < deadline)); do
        "${CLEANUP_HELPER}" cleanup "${CLEANUP_CONTEXT}" >"${receipt}"
        result=$?
        if ((result == 0)); then
            validate_cleanup_receipt "${receipt}" || return 1
            return 0
        fi
        if ((result != 75)); then
            echo "cleanup helper attempt ${attempt} failed with exit code ${result}" >&2
            return 1
        fi
        sleep 1
    done
    echo "cleanup helper attempt ${attempt} did not converge before the cleanup deadline" >&2
    return 1
}

run_cleanup_helper_twice() {
    local deadline=$1
    run_cleanup_helper_once 1 "${deadline}" && run_cleanup_helper_once 2 "${deadline}"
}

require_managed_paths_absent() {
    local path
    for path in \
        "${CONTROL_SOCKET}" \
        "${DISCONNECTED_CONTROL_SOCKET}" \
        "${STORAGE_DIRECTORY}" \
        "${DISCONNECTED_STORAGE_DIRECTORY}" \
        "${LEASE_FILE}" \
        "${DISCONNECTED_LEASE_FILE}"; do
        if [[ -e "${path}" || -L "${path}" ]]; then
            echo "managed machine-state path remains after cleanup: ${path}" >&2
            return 1
        fi
    done
}

make_manifest() {
    local output=$1
    local name=$2
    local storage_generation=$3
    local restore_state=${4:-}
    local restore_generation=${5:-}
    local persistence_id=${6:-${PERSISTENCE_ID}}
    local nbd_socket=${7:-${NBD_SOCKET}}
    POD_NAME_VALUE="${name}" \
        NODE_VALUE="${NODE}" \
        IMAGE_VALUE="${IMAGE}" \
        RUNTIME_CLASS_VALUE="${RUNTIME_CLASS}" \
        PERSISTENCE_ID_VALUE="${persistence_id}" \
        NBD_SOCKET_VALUE="${nbd_socket}" \
        STORAGE_GENERATION_VALUE="${storage_generation}" \
        RESTORE_STATE_VALUE="${restore_state}" \
        RESTORE_GENERATION_VALUE="${restore_generation}" \
        RUN_TOKEN_VALUE="${SUFFIX}" \
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
    "metadata": {
        "name": os.environ["POD_NAME_VALUE"],
        "labels": {"container-machine-state-run": os.environ["RUN_TOKEN_VALUE"]},
        "annotations": annotations,
    },
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
                "printf 'machine-state-sample:%s:%s:%s\\n' \"$boot_token\" \"$$$$\" \"$n\"; "
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
    local mutating=false
    local result
    case "${method}" in
        vm.pause | vm.resume | vm.saveMachineState | vm.deleteMachineState)
            mutating=true
            printf '%s %s\n' "${method}" "${state_id}" >"${PENDING_OPERATION_FILE}"
            ;;
    esac
    if python3 - \
        "${CONTROL_SOCKET}" \
        "${method}" \
        "${state_id}" \
        "${WAIT_TIMEOUT_SECONDS}" \
        "${SAVED_STORAGE_GENERATION}" <<'PY'
import base64
import json
import socket
import struct
import sys
import time
import uuid

socket_path, method, state_id, timeout_value, saved_generation = sys.argv[1:]
timeout_seconds = float(timeout_value)
saved_generation = int(saved_generation)
deadline = time.monotonic() + timeout_seconds
transitional_states = {"pausing", "resuming", "saving", "restoring", "stopping", "starting"}
expected_states = {
    "vm.pause": "paused",
    "vm.resume": "running",
    "vm.saveMachineState": "paused",
}
source_states = {
    "vm.pause": {"running", "paused"},
    "vm.resume": {"paused", "running"},
    "vm.saveMachineState": {"paused"},
}
mutating_methods = set(expected_states) | {"vm.deleteMachineState"}


class TransportFailure(Exception):
    pass


def remaining():
    return deadline - time.monotonic()


def recv_exact(client, count):
    data = b""
    while len(data) < count:
        chunk = client.recv(count - len(data))
        if not chunk:
            raise TransportFailure("sidecar closed before the complete response frame")
        data += chunk
    return data


def rpc_once(request_method, request_state_id=""):
    budget = remaining()
    if budget <= 0:
        raise TransportFailure("sidecar RPC deadline expired")
    request_id = str(uuid.uuid4())
    request = {"requestID": request_id, "method": request_method, "protocolVersion": 2}
    if request_method in {"vm.pause", "vm.resume", "vm.saveMachineState", "vm.restoreMachineState"}:
        request["machineState"] = {"timeoutSeconds": max(1.0, min(600.0, budget))}
    if request_state_id:
        request.setdefault("machineState", {})["stateID"] = request_state_id
    payload = json.dumps({"kind": "request", "request": request}, separators=(",", ":")).encode()
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.settimeout(max(0.1, min(5.0, budget)))
    try:
        client.connect(socket_path)
        client.sendall(struct.pack(">I", len(payload)) + payload)
        header = recv_exact(client, 4)
        length = struct.unpack(">I", header)[0]
        if length <= 0 or length > 16 * 1024 * 1024:
            raise TransportFailure("sidecar returned an invalid frame length")
        response_envelope = json.loads(recv_exact(client, length))
    except (OSError, TimeoutError, json.JSONDecodeError, TransportFailure) as error:
        raise TransportFailure(str(error)) from error
    finally:
        client.close()
    response = response_envelope.get("response")
    if (
        response_envelope.get("kind") != "response"
        or not isinstance(response, dict)
        or response.get("requestID") != request_id
    ):
        raise TransportFailure("sidecar returned an invalid response envelope")
    version = response.get("protocolVersion")
    if type(version) is not int or version < 2:
        raise TransportFailure("sidecar response did not report a machine-state capable protocol version")
    return response


def response_payload(response):
    encoded = response.get("data")
    if not isinstance(encoded, str) or not encoded:
        raise TransportFailure("sidecar response omitted its structured data payload")
    try:
        return json.loads(base64.b64decode(encoded, validate=True))
    except (ValueError, json.JSONDecodeError) as error:
        raise TransportFailure("sidecar returned an invalid structured data payload") from error


def error_code(response):
    error = response.get("error")
    return error.get("code") if isinstance(error, dict) else None


def fail_remote(response):
    print(json.dumps(response.get("error", {}), sort_keys=True), file=sys.stderr)
    raise SystemExit(64)


def print_success(response):
    print(json.dumps(response, sort_keys=True))
    raise SystemExit(0)


def validate_operation(response, operation):
    payload = response_payload(response)
    if operation == "vm.deleteMachineState":
        if payload.get("stateID") != state_id or not isinstance(payload.get("deleted"), bool):
            raise TransportFailure("delete response did not identify the requested machine state")
        return
    expected = expected_states[operation]
    if payload.get("lifecycleState") != expected:
        raise TransportFailure(f"{operation} response did not reach {expected}")
    if operation == "vm.saveMachineState" and payload.get("stateID") != state_id:
        raise TransportFailure("save response did not identify the requested machine state")


def query_capabilities():
    response = rpc_once("vm.capabilities")
    if not response.get("ok"):
        raise TransportFailure("capability query failed during reconciliation")
    payload = response_payload(response)
    versions = payload.get("supportedProtocolVersions", [])
    if (
        payload.get("protocolVersion") != response.get("protocolVersion")
        or 2 not in versions
        or not payload.get("machineState", {}).get("supported")
    ):
        raise TransportFailure("machine-state capability disappeared during reconciliation")
    state = payload.get("lifecycleState")
    if not isinstance(state, str):
        raise TransportFailure("capability response omitted lifecycle state")
    return response, state


def query_saved_state():
    response = rpc_once("vm.compatibilityDescription", state_id)
    if not response.get("ok"):
        return response, False
    payload = response_payload(response)
    saved = payload.get("saved")
    committed = (
        payload.get("compatible") is True
        and not payload.get("reasons")
        and isinstance(saved, dict)
        and saved.get("storageGeneration") == saved_generation
    )
    return response, committed


ambiguous = False
retry_operation = True
last_transport_error = None
while remaining() > 0:
    if retry_operation:
        try:
            response = rpc_once(method, state_id)
        except TransportFailure as error:
            last_transport_error = error
            if method not in mutating_methods:
                time.sleep(min(0.25, max(0.0, remaining())))
                continue
            ambiguous = True
        else:
            if response.get("ok"):
                try:
                    validate_operation(response, method) if method in mutating_methods else None
                except TransportFailure as error:
                    last_transport_error = error
                    ambiguous = True
                else:
                    if method in {"vm.saveMachineState", "vm.deleteMachineState"}:
                        ambiguous = True
                    else:
                        print_success(response)
            elif error_code(response) == "operationInProgress" and method in mutating_methods:
                ambiguous = True
            else:
                fail_remote(response)
        retry_operation = False

    if method not in mutating_methods:
        continue
    try:
        capability_response, lifecycle_state = query_capabilities()
    except TransportFailure as error:
        last_transport_error = error
        time.sleep(min(0.25, max(0.0, remaining())))
        continue

    if method == "vm.deleteMachineState":
        try:
            compatibility_response, committed = query_saved_state()
        except TransportFailure as error:
            last_transport_error = error
            time.sleep(min(0.25, max(0.0, remaining())))
            continue
        if not compatibility_response.get("ok") and error_code(compatibility_response) == "machineStateNotFound":
            print_success(capability_response)
        if compatibility_response.get("ok") or error_code(compatibility_response) == "machineStateIncomplete":
            retry_operation = True
            continue
        fail_remote(compatibility_response)

    if lifecycle_state in transitional_states:
        time.sleep(min(0.25, max(0.0, remaining())))
        continue
    if lifecycle_state == expected_states[method]:
        if method != "vm.saveMachineState":
            print_success(capability_response)
        try:
            compatibility_response, committed = query_saved_state()
        except TransportFailure as error:
            last_transport_error = error
            time.sleep(min(0.25, max(0.0, remaining())))
            continue
        if committed:
            print_success(compatibility_response)
        if error_code(compatibility_response) == "machineStateNotFound":
            retry_operation = True
            continue
        fail_remote(compatibility_response)
    if lifecycle_state in source_states[method]:
        retry_operation = True
        continue
    if ambiguous:
        last_transport_error = TransportFailure(
            f"{method} reached unexpected lifecycle state {lifecycle_state} after a transport failure"
        )
        break
    print(f"{method} cannot run from lifecycle state {lifecycle_state}", file=sys.stderr)
    raise SystemExit(64)

if method in mutating_methods and ambiguous:
    detail = str(last_transport_error) if last_transport_error else "deadline expired"
    print(f"{method} outcome remains unresolved: {detail}", file=sys.stderr)
    raise SystemExit(75)
detail = str(last_transport_error) if last_transport_error else "deadline expired"
raise SystemExit(f"{method} failed before the deadline: {detail}")
PY
    then
        result=0
    else
        result=$?
    fi
    if [[ "${mutating}" == "true" && (${result} -eq 0 || ${result} -eq 64) ]]; then
        rm -f "${PENDING_OPERATION_FILE}"
    fi
    return "${result}"
}

validate_sidecar_payload() {
    local kind=$1
    local response=$2
    SIDECAR_PAYLOAD_KIND="${kind}" \
        SIDECAR_RESPONSE="${response}" \
        SAVED_GENERATION_VALUE="${SAVED_STORAGE_GENERATION}" \
        python3 - <<'PY'
import base64
import json
import os

kind = os.environ["SIDECAR_PAYLOAD_KIND"]
response = json.loads(os.environ["SIDECAR_RESPONSE"])
response_version = response.get("protocolVersion")
if type(response_version) is not int or response_version < 2:
    raise SystemExit("sidecar response did not report a machine-state capable protocol version")
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
        "vm.deleteMachineState",
        "vm.compatibilityDescription",
    }
    if payload.get("protocolVersion") != response_version or 2 not in payload.get("supportedProtocolVersions", []):
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
        if description.get("storageGeneration") != int(os.environ["SAVED_GENERATION_VALUE"]):
            raise SystemExit(f"compatibility response reported the wrong {description_name} storage generation")
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
    local deadline=$((SECONDS + WAIT_TIMEOUT_SECONDS))
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
    local deadline=${2:-$((SECONDS + WAIT_TIMEOUT_SECONDS))}
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
    local deadline=$((SECONDS + WAIT_TIMEOUT_SECONDS))
    local sample
    while :; do
        sample="$(read_process_sample "${pod_name}" "${deadline}")"
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

wait_for_runtime_binding_absent() {
    local persistence_id=$1
    local deadline=$2
    local control_socket="${CONTROL_ROOT}/${persistence_id}.sock"
    local lease_file="${LEASE_ROOT}/${persistence_id}.json"

    while ((SECONDS < deadline)); do
        if [[ ! -e "${control_socket}" && ! -L "${control_socket}" \
            && ! -e "${lease_file}" && ! -L "${lease_file}" ]]; then
            return 0
        fi
        sleep 1
    done
    echo "timed out reading back lease and control-socket removal for ${persistence_id}" >&2
    return 1
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

CAPABILITIES_RESPONSE="$(sidecar_rpc vm.capabilities)"
validate_sidecar_payload capabilities "${CAPABILITIES_RESPONSE}"
SAMPLE_BEFORE="$(read_process_sample "${POD_NAME}")"
sidecar_rpc vm.pause >/dev/null
sidecar_rpc vm.resume >/dev/null
SAMPLE_AFTER_RESUME="$(wait_for_advanced_process_sample "${POD_NAME}" "${SAMPLE_BEFORE}")"

CHECKPOINT_SAMPLE="${SAMPLE_AFTER_RESUME}"
sidecar_rpc vm.pause >/dev/null
sidecar_rpc vm.saveMachineState "${STATE_ID}" >/dev/null
COMPATIBILITY_RESPONSE="$(sidecar_rpc vm.compatibilityDescription "${STATE_ID}")"
validate_sidecar_payload compatibility "${COMPATIBILITY_RESPONSE}"

echo "machine state ${STATE_ID} is committed with storage generation ${SAVED_STORAGE_GENERATION}; the VM remains paused" >&2
echo "the stable NBD socket must now select a writable clone for storage generation ${RESTORE_STORAGE_GENERATION}" >&2

phase_deadline=$((SECONDS + WAIT_TIMEOUT_SECONDS))
delete_owned_pod "${POD_NAME}" "${INITIAL_UID}" "${phase_deadline}"
wait_for_runtime_binding_absent "${PERSISTENCE_ID}" "${phase_deadline}"
if [[ -n "${PREPARE_RESTORE_HELPER}" ]]; then
    "${PREPARE_RESTORE_HELPER}" \
        "${NBD_SOCKET}" \
        "${STATE_ID}" \
        "${SAVED_STORAGE_GENERATION}" \
        "${RESTORE_STORAGE_GENERATION}" \
        "${IDEMPOTENCY_KEY}"
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

sidecar_rpc vm.deleteMachineState "${STATE_ID}" >/dev/null

if [[ -e "${DISCONNECTED_SOCKET}" || -L "${DISCONNECTED_SOCKET}" ]]; then
    echo "disconnected NBD test socket unexpectedly exists: ${DISCONNECTED_SOCKET}" >&2
    exit 1
fi
make_manifest \
    "${DISCONNECTED_MANIFEST}" \
    "${DISCONNECTED_POD_NAME}" \
    "${SAVED_STORAGE_GENERATION}" \
    "" \
    "" \
    "${DISCONNECTED_PERSISTENCE_ID}" \
    "${DISCONNECTED_SOCKET}"
"${KUBECTL_BIN}" --namespace "${NAMESPACE}" apply -f "${DISCONNECTED_MANIFEST}" >/dev/null
DISCONNECTED_UID="$("${KUBECTL_BIN}" --namespace "${NAMESPACE}" get pod "${DISCONNECTED_POD_NAME}" -o jsonpath='{.metadata.uid}')"

deadline=$((SECONDS + WAIT_TIMEOUT_SECONDS))
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

SUCCESS_MESSAGE="machine-state restore passed: pod UID ${INITIAL_UID}->${RESTORE_UID}, container ${INITIAL_CONTAINER_ID}->${RESTORE_CONTAINER_ID}, guest sample ${CHECKPOINT_SAMPLE}->${RESTORED_SAMPLE_LATER}; disconnected NBD was rejected before container creation and final cleanup was read back twice"
RUN_SUCCEEDED=true
