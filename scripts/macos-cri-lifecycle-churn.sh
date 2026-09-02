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
Usage: scripts/macos-cri-lifecycle-churn.sh [--dry-run]

Runs a fast, API-backed macOS CRI lifecycle regression against one explicitly
selected node. Each group runs 10 rounds by default, for 50 total rounds:
direct CRI StopContainer, concurrent streaming exec, readiness ExecSync with
CRI StopPodSandbox, natural exit, and forced exit. The script never creates or
deletes a Namespace.

Required environment:
  MACOS_CRI_LIFECYCLE_KUBECONFIG       kubeconfig file
  MACOS_CRI_LIFECYCLE_CONTEXT          kubeconfig context
  MACOS_CRI_LIFECYCLE_NODE             already isolated macOS node
  MACOS_CRI_LIFECYCLE_NAMESPACE        existing Namespace
  MACOS_CRI_LIFECYCLE_RUNTIME_CLASS    macOS RuntimeClass
  MACOS_CRI_LIFECYCLE_IMAGE            macOS workload image
  MACOS_CRI_LIFECYCLE_RUNTIME_ENDPOINT CRI endpoint passed to crictl
  MACOS_CRI_LIFECYCLE_SHIM_PID         PID of the CRI shim on this host

Optional environment:
  MACOS_CRI_LIFECYCLE_ROUNDS_PER_GROUP rounds in each of the five groups (default: 10)
  MACOS_CRI_LIFECYCLE_HOLD_SECONDS     live observation time per round (default: 5)
  MACOS_CRI_LIFECYCLE_COMPLETION_DELAY seconds before natural/forced exit (default: 5)
  MACOS_CRI_LIFECYCLE_EXEC_CONCURRENCY concurrent exec workers (default: 8)
  MACOS_CRI_LIFECYCLE_EXEC_ITERATIONS  exec calls per worker and round (default: 4)
  MACOS_CRI_LIFECYCLE_WAIT_TIMEOUT     create/cleanup timeout in seconds (default: 180)
  MACOS_CRI_LIFECYCLE_REQUIRE_CORDONED require spec.unschedulable=true (default: 1)
  MACOS_CRI_LIFECYCLE_REQUIRE_DUAL_STACK
                                       require both IPv4 and IPv6 Pod addresses (default: 1)
  MACOS_CRI_LIFECYCLE_KEEP_WORKDIR     keep successful-run evidence (default: 0)
  MACOS_CRI_LIFECYCLE_WORKDIR_PARENT   evidence parent directory (default: /tmp)
  KUBECTL                              kubectl executable (default: kubectl)
  CRICTL                               crictl executable (default: crictl)
  CRICTL_TIMEOUT                       crictl request timeout (default: 30s)
  PYTHON                               Python 3 executable (default: python3)

Failure policy:
  The first failure stops the run without further cluster cleanup and retains
  the evidence directory. Successful rounds delete only the Pod whose UID and
  unique run/case labels match, then wait for that case's CRI objects to disappear.

--dry-run validates parameters and generated manifests without contacting the
cluster or runtime.
EOF
}

DRY_RUN=0
case "${1:-}" in
    "") ;;
    -h | --help)
        usage
        exit 0
        ;;
    --dry-run)
        DRY_RUN=1
        ;;
    *)
        echo "error: unknown argument: $1" >&2
        usage >&2
        exit 2
        ;;
esac
if (($# > 1)); then
    echo "error: expected at most one argument" >&2
    usage >&2
    exit 2
fi

KUBECONFIG_PATH="${MACOS_CRI_LIFECYCLE_KUBECONFIG:-}"
KUBE_CONTEXT="${MACOS_CRI_LIFECYCLE_CONTEXT:-}"
NODE_NAME="${MACOS_CRI_LIFECYCLE_NODE:-}"
NAMESPACE="${MACOS_CRI_LIFECYCLE_NAMESPACE:-}"
RUNTIME_CLASS="${MACOS_CRI_LIFECYCLE_RUNTIME_CLASS:-}"
WORKLOAD_IMAGE="${MACOS_CRI_LIFECYCLE_IMAGE:-}"
RUNTIME_ENDPOINT="${MACOS_CRI_LIFECYCLE_RUNTIME_ENDPOINT:-}"
SHIM_PID="${MACOS_CRI_LIFECYCLE_SHIM_PID:-}"
ROUNDS_PER_GROUP="${MACOS_CRI_LIFECYCLE_ROUNDS_PER_GROUP:-10}"
HOLD_SECONDS="${MACOS_CRI_LIFECYCLE_HOLD_SECONDS:-5}"
COMPLETION_DELAY="${MACOS_CRI_LIFECYCLE_COMPLETION_DELAY:-5}"
EXEC_CONCURRENCY="${MACOS_CRI_LIFECYCLE_EXEC_CONCURRENCY:-8}"
EXEC_ITERATIONS="${MACOS_CRI_LIFECYCLE_EXEC_ITERATIONS:-4}"
WAIT_TIMEOUT="${MACOS_CRI_LIFECYCLE_WAIT_TIMEOUT:-180}"
REQUIRE_CORDONED="${MACOS_CRI_LIFECYCLE_REQUIRE_CORDONED:-1}"
REQUIRE_DUAL_STACK="${MACOS_CRI_LIFECYCLE_REQUIRE_DUAL_STACK:-1}"
KEEP_WORKDIR="${MACOS_CRI_LIFECYCLE_KEEP_WORKDIR:-0}"
WORKDIR_PARENT="${MACOS_CRI_LIFECYCLE_WORKDIR_PARENT:-/tmp}"
KUBECTL_BIN="${KUBECTL:-kubectl}"
CRICTL_BIN="${CRICTL:-crictl}"
CRICTL_TIMEOUT="${CRICTL_TIMEOUT:-30s}"
PYTHON_BIN="${PYTHON:-python3}"

required_variables=(
    MACOS_CRI_LIFECYCLE_KUBECONFIG
    MACOS_CRI_LIFECYCLE_CONTEXT
    MACOS_CRI_LIFECYCLE_NODE
    MACOS_CRI_LIFECYCLE_NAMESPACE
    MACOS_CRI_LIFECYCLE_RUNTIME_CLASS
    MACOS_CRI_LIFECYCLE_IMAGE
    MACOS_CRI_LIFECYCLE_RUNTIME_ENDPOINT
    MACOS_CRI_LIFECYCLE_SHIM_PID
)
missing_variables=()
for variable in "${required_variables[@]}"; do
    if [[ -z "${!variable:-}" ]]; then
        missing_variables+=("${variable}")
    fi
done
if ((${#missing_variables[@]} > 0)); then
    printf 'error: required environment variable is unset: %s\n' "${missing_variables[@]}" >&2
    usage >&2
    exit 2
fi

for value_name in ROUNDS_PER_GROUP HOLD_SECONDS COMPLETION_DELAY EXEC_CONCURRENCY EXEC_ITERATIONS WAIT_TIMEOUT SHIM_PID; do
    value="${!value_name}"
    if [[ ! "${value}" =~ ^[1-9][0-9]*$ ]]; then
        echo "error: ${value_name} must be a positive integer" >&2
        exit 2
    fi
done
for value_name in REQUIRE_CORDONED REQUIRE_DUAL_STACK KEEP_WORKDIR; do
    value="${!value_name}"
    case "${value}" in
        0 | 1 | false | true) ;;
        *)
            echo "error: ${value_name} must be 0, 1, false, or true" >&2
            exit 2
            ;;
    esac
done

log() {
    printf '[macos-cri-lifecycle] %s\n' "$*"
}

WORK_DIR=""
RUN_SUCCEEDED=0
FAILURE_RECORDED=0
CURRENT_GROUP="preflight"
CURRENT_ROUND=0
CURRENT_POD_NAME=""
CURRENT_POD_UID=""
BACKGROUND_PIDS=()

write_summary() {
    local status=$1
    local group=$2
    local round=$3
    local line
    line="{\"group\":\"${group}\",\"round\":${round},\"status\":\"${status}\"}"
    printf '%s\n' "${line}"
    if [[ -n "${WORK_DIR}" ]]; then
        printf '%s\n' "${line}" >>"${WORK_DIR}/summary.ndjson"
    fi
}

fail() {
    local message=$*
    if [[ "${FAILURE_RECORDED}" == "0" ]]; then
        FAILURE_RECORDED=1
        write_summary failed "${CURRENT_GROUP}" "${CURRENT_ROUND}"
    fi
    echo "error: ${message}" >&2
    exit 1
}

terminate_background_workers() {
    local pid
    for pid in "${BACKGROUND_PIDS[@]}"; do
        kill -KILL "${pid}" >/dev/null 2>&1 || true
    done
    for pid in "${BACKGROUND_PIDS[@]}"; do
        wait "${pid}" >/dev/null 2>&1 || true
    done
    BACKGROUND_PIDS=()
}

on_exit() {
    local exit_code=$?
    trap - EXIT
    set +e
    set +u
    if [[ "${exit_code}" != "0" && "${FAILURE_RECORDED}" == "0" ]]; then
        FAILURE_RECORDED=1
        write_summary failed "${CURRENT_GROUP}" "${CURRENT_ROUND}"
    fi
    terminate_background_workers
    if [[ "${RUN_SUCCEEDED}" == "1" && -n "${WORK_DIR}" ]]; then
        if [[ "${KEEP_WORKDIR}" == "1" || "${KEEP_WORKDIR}" == "true" ]]; then
            echo "kept lifecycle evidence directory: ${WORK_DIR}" >&2
        else
            rm -rf "${WORK_DIR}"
        fi
    elif [[ -n "${WORK_DIR}" ]]; then
        echo "lifecycle failure stopped at Pod ${CURRENT_POD_NAME:-<none>}; retained evidence: ${WORK_DIR}" >&2
    fi
    exit "${exit_code}"
}
trap on_exit EXIT

require_executable() {
    local executable=$1
    if [[ "${executable}" == */* ]]; then
        [[ -x "${executable}" ]] || fail "executable not found or not executable: ${executable}"
    elif ! command -v "${executable}" >/dev/null 2>&1; then
        fail "required command not found: ${executable}"
    fi
}

require_executable "${PYTHON_BIN}"
mkdir -p "${WORKDIR_PARENT}"
WORK_DIR="$(mktemp -d "${WORKDIR_PARENT%/}/macos-cri-lifecycle.XXXXXX")"
RUN_TOKEN="$(date -u +%Y%m%d%H%M%S)-$$-${RANDOM}"
RUN_LABEL_KEY="macos-cri-lifecycle-run"
CASE_LABEL_KEY="macos-cri-lifecycle-case"
CRI_POD_UID_LABEL="io.kubernetes.pod.uid"
RUN_SELECTOR="${RUN_LABEL_KEY}=${RUN_TOKEN}"
LIFECYCLE_GROUPS=(control exec readiness natural forced)
TOTAL_ROUNDS=$((${#LIFECYCLE_GROUPS[@]} * ROUNDS_PER_GROUP))
RUN_POD_UIDS=()

run_kubectl() {
    "${KUBECTL_BIN}" --kubeconfig "${KUBECONFIG_PATH}" --context "${KUBE_CONTEXT}" "$@"
}

run_kubectl_namespace() {
    run_kubectl --namespace "${NAMESPACE}" "$@"
}

run_crictl() {
    "${CRICTL_BIN}" --runtime-endpoint "${RUNTIME_ENDPOINT}" --timeout "${CRICTL_TIMEOUT}" "$@"
}

make_manifest() {
    local group=$1
    local pod_name=$2
    local case_token=$3
    local output=$4
    GROUP_VALUE="${group}" \
        POD_NAME_VALUE="${pod_name}" \
        CASE_TOKEN_VALUE="${case_token}" \
        RUN_TOKEN_VALUE="${RUN_TOKEN}" \
        RUN_LABEL_KEY_VALUE="${RUN_LABEL_KEY}" \
        CASE_LABEL_KEY_VALUE="${CASE_LABEL_KEY}" \
        NAMESPACE_VALUE="${NAMESPACE}" \
        NODE_VALUE="${NODE_NAME}" \
        RUNTIME_CLASS_VALUE="${RUNTIME_CLASS}" \
        IMAGE_VALUE="${WORKLOAD_IMAGE}" \
        COMPLETION_DELAY_VALUE="${COMPLETION_DELAY}" \
        "${PYTHON_BIN}" - "${output}" <<'PY'
import json
import os
import sys

group = os.environ["GROUP_VALUE"]
commands = {
    "control": "trap '' TERM INT; echo lifecycle-control-ready; while :; do sleep 1; done",
    "exec": "trap '' TERM INT; echo lifecycle-exec-ready; while :; do sleep 1; done",
    "readiness": (
        "trap '' TERM INT; rm -f /tmp/macos-cri-lifecycle-readiness; "
        "echo lifecycle-readiness-ready; "
        "while [ ! -f /tmp/macos-cri-lifecycle-readiness ]; do sleep 1; done; "
        "echo readiness-execsync-observed; while :; do sleep 1; done"
    ),
    "natural": (
        "echo lifecycle-natural-ready; sleep "
        + os.environ["COMPLETION_DELAY_VALUE"]
        + "; exit 0"
    ),
    "forced": (
        "echo lifecycle-forced-ready; sleep "
        + os.environ["COMPLETION_DELAY_VALUE"]
        + "; kill -9 $$"
    ),
}
if group not in commands:
    raise SystemExit(f"unsupported lifecycle group: {group}")

labels = {
    os.environ["RUN_LABEL_KEY_VALUE"]: os.environ["RUN_TOKEN_VALUE"],
    os.environ["CASE_LABEL_KEY_VALUE"]: os.environ["CASE_TOKEN_VALUE"],
}
container = {
    "name": "workload",
    "image": os.environ["IMAGE_VALUE"],
    "command": ["/bin/sh", "-lc"],
    "args": [commands[group]],
    "imagePullPolicy": "IfNotPresent",
}
if group == "readiness":
    container["readinessProbe"] = {
        "exec": {
            "command": [
                "/bin/sh",
                "-lc",
                "touch /tmp/macos-cri-lifecycle-readiness",
            ]
        },
        "periodSeconds": 1,
        "timeoutSeconds": 1,
        "failureThreshold": 30,
    }

manifest = {
    "apiVersion": "v1",
    "kind": "Pod",
    "metadata": {
        "name": os.environ["POD_NAME_VALUE"],
        "namespace": os.environ["NAMESPACE_VALUE"],
        "labels": labels,
    },
    "spec": {
        "nodeName": os.environ["NODE_VALUE"],
        "runtimeClassName": os.environ["RUNTIME_CLASS_VALUE"],
        "automountServiceAccountToken": False,
        "enableServiceLinks": False,
        "restartPolicy": "Never",
        "terminationGracePeriodSeconds": 0,
        "containers": [container],
    },
}
with open(sys.argv[1], "w", encoding="utf-8") as output_file:
    json.dump(manifest, output_file, separators=(",", ":"))
PY
}

if [[ "${DRY_RUN}" == "1" ]]; then
    for group in "${LIFECYCLE_GROUPS[@]}"; do
        make_manifest "${group}" "cri-life-${group}-dry-run" "${group}-dry-run" "${WORK_DIR}/${group}.json"
    done
    "${PYTHON_BIN}" - "${WORK_DIR}" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
expected = {"control", "exec", "readiness", "natural", "forced"}
seen = set()
for path in root.glob("*.json"):
    manifest = json.loads(path.read_text(encoding="utf-8"))
    assert manifest["kind"] == "Pod"
    assert manifest["spec"]["restartPolicy"] == "Never"
    assert manifest["spec"]["terminationGracePeriodSeconds"] == 0
    assert len(manifest["spec"]["containers"]) == 1
    container = manifest["spec"]["containers"][0]
    if path.stem == "readiness":
        assert "readinessProbe" in container
    else:
        assert "readinessProbe" not in container
    if path.stem == "natural":
        assert "; exit 0" in container["args"][0]
    if path.stem == "forced":
        assert "kill -9 $$" in container["args"][0]
    seen.add(path.stem)
assert seen == expected
PY
    log "dry-run validated ${TOTAL_ROUNDS} rounds across: ${LIFECYCLE_GROUPS[*]}"
    RUN_SUCCEEDED=1
    exit 0
fi

require_executable "${KUBECTL_BIN}"
require_executable "${CRICTL_BIN}"
[[ -r "${KUBECONFIG_PATH}" ]] || fail "kubeconfig is not readable: ${KUBECONFIG_PATH}"

SHIM_IDENTITY=""
assert_shim_alive() {
    if ! kill -0 "${SHIM_PID}" >/dev/null 2>&1; then
        fail "CRI shim PID ${SHIM_PID} is not running"
    fi
    local identity
    identity="$(ps -p "${SHIM_PID}" -o lstart= -o command= 2>/dev/null || true)"
    [[ -n "${identity}" ]] || fail "could not read CRI shim identity for PID ${SHIM_PID}"
    if [[ -z "${SHIM_IDENTITY}" ]]; then
        SHIM_IDENTITY="${identity}"
        printf '%s\n' "${SHIM_IDENTITY}" >"${WORK_DIR}/shim-identity.txt"
    elif [[ "${identity}" != "${SHIM_IDENTITY}" ]]; then
        fail "CRI shim identity changed during the run"
    fi
}

read_node_runtime_version() {
    local snapshot=$1
    "${PYTHON_BIN}" - "${snapshot}" "${REQUIRE_CORDONED}" <<'PY'
import json
import sys

node = json.load(open(sys.argv[1], encoding="utf-8"))
ready = next(
    (item.get("status") for item in node.get("status", {}).get("conditions", []) if item.get("type") == "Ready"),
    None,
)
if ready != "True":
    raise SystemExit("selected node is not Ready")
require_cordoned = sys.argv[2] in {"1", "true"}
if require_cordoned and not node.get("spec", {}).get("unschedulable", False):
    raise SystemExit("selected node is not cordoned")
runtime_version = node.get("status", {}).get("nodeInfo", {}).get("containerRuntimeVersion", "")
if not runtime_version:
    raise SystemExit("selected node did not report a container runtime version")
print(runtime_version)
PY
}

assert_no_run_objects() {
    local kubernetes_objects runtime_containers runtime_sandboxes uid uid_selector
    kubernetes_objects="$(run_kubectl_namespace get pods --selector "${RUN_SELECTOR}" -o name)" || fail "failed to list this run's Kubernetes objects"
    if [[ -n "${kubernetes_objects}" ]]; then
        fail "objects with this run's unique label already exist"
    fi
    if ((${#RUN_POD_UIDS[@]} > 0)); then
        for uid in "${RUN_POD_UIDS[@]}"; do
            uid_selector="${CRI_POD_UID_LABEL}=${uid}"
            runtime_containers="$(run_crictl ps -a --label "${uid_selector}" -q)" || fail "ListContainers failed while checking for residual objects"
            runtime_sandboxes="$(run_crictl pods --label "${uid_selector}" -q)" || fail "ListPodSandbox failed while checking for residual objects"
            if [[ -n "${runtime_containers}" || -n "${runtime_sandboxes}" ]]; then
                fail "CRI objects remain for a Pod UID created by this run"
            fi
        done
    fi
}

log "checking Kubernetes API, selected node, Namespace, RuntimeClass, and CRI"
readyz="$(run_kubectl get --raw=/readyz)"
[[ "${readyz}" == "ok" ]] || fail "Kubernetes API /readyz did not return ok"
run_kubectl get namespace "${NAMESPACE}" -o json >"${WORK_DIR}/namespace.json"
run_kubectl get runtimeclass "${RUNTIME_CLASS}" -o json >"${WORK_DIR}/runtime-class.json"
run_kubectl get node "${NODE_NAME}" -o json >"${WORK_DIR}/node-before.json"
NODE_RUNTIME_VERSION="$(read_node_runtime_version "${WORK_DIR}/node-before.json")"
run_crictl version >"${WORK_DIR}/cri-version-before.txt"
run_crictl info >"${WORK_DIR}/cri-info-before.json"
assert_shim_alive
assert_no_run_objects

OBSERVATION_INDEX=0
POD_UID="-"
POD_PHASE="-"
POD_READY="false"
POD_CONTAINER_STATE="-"
POD_EXIT_CODE="-"
POD_FINISHED_AT="-"
POD_RESTART_COUNT="0"
POD_CONTAINER_ID="-"
POD_IPV4_COUNT="0"
POD_IPV6_COUNT="0"
POD_RUN_LABEL="-"
POD_CASE_LABEL="-"
CRI_STATE="-"
CRI_EXIT_CODE="-"
CRI_FINISHED_AT="-"
CASE_TOKEN=""
CASE_SELECTOR=""
CASE_DIR=""
CRI_CONTAINER_ID=""
CRI_SANDBOX_ID=""
CASE_SAW_137=0

next_observation_path() {
    local kind=$1
    OBSERVATION_INDEX=$((OBSERVATION_INDEX + 1))
    OBSERVATION_PATH="${CASE_DIR}/${kind}-$(printf '%04d' "${OBSERVATION_INDEX}").json"
}

capture_pod() {
    local pod_name=$1
    local output=$2
    local temporary="${output}.tmp"
    if ! run_kubectl_namespace get pod "${pod_name}" -o json >"${temporary}" 2>"${output}.stderr"; then
        rm -f "${temporary}"
        return 1
    fi
    mv "${temporary}" "${output}"
    rm -f "${output}.stderr"
}

pod_capture_was_not_found() {
    local output=$1
    [[ -f "${output}.stderr" ]] && grep -Eiq 'not[[:space:]_-]*found|NotFound' "${output}.stderr"
}

read_pod_state() {
    local snapshot=$1
    local state
    state="$("${PYTHON_BIN}" - "${snapshot}" "${RUN_LABEL_KEY}" "${CASE_LABEL_KEY}" <<'PY'
import ipaddress
import json
import sys

pod = json.load(open(sys.argv[1], encoding="utf-8"))
labels = pod.get("metadata", {}).get("labels", {})
status = pod.get("status", {})
container_statuses = status.get("containerStatuses", [])
container_status = container_statuses[0] if container_statuses else {}
state = container_status.get("state", {})
state_name = "-"
exit_code = "-"
finished_at = "-"
if state.get("running") is not None:
    state_name = "running"
elif state.get("waiting") is not None:
    state_name = "waiting"
elif state.get("terminated") is not None:
    state_name = "terminated"
    terminated = state["terminated"]
    exit_code = str(terminated.get("exitCode", "-"))
    finished_at = str(terminated.get("finishedAt") or "-")
ready = any(
    condition.get("type") == "Ready" and condition.get("status") == "True"
    for condition in status.get("conditions", [])
)
container_id = str(container_status.get("containerID") or "-")
if "://" in container_id:
    container_id = container_id.split("://", 1)[1]
ipv4_count = 0
ipv6_count = 0
for item in status.get("podIPs", []):
    try:
        version = ipaddress.ip_address(item.get("ip", "")).version
    except ValueError:
        continue
    if version == 4:
        ipv4_count += 1
    elif version == 6:
        ipv6_count += 1
fields = [
    str(pod.get("metadata", {}).get("uid") or "-"),
    str(status.get("phase") or "-"),
    "true" if ready else "false",
    state_name,
    exit_code,
    finished_at,
    str(container_status.get("restartCount", 0)),
    container_id,
    str(ipv4_count),
    str(ipv6_count),
    str(labels.get(sys.argv[2]) or "-"),
    str(labels.get(sys.argv[3]) or "-"),
]
print("\t".join(fields))
PY
)"
    IFS=$'\t' read -r POD_UID POD_PHASE POD_READY POD_CONTAINER_STATE POD_EXIT_CODE POD_FINISHED_AT POD_RESTART_COUNT POD_CONTAINER_ID POD_IPV4_COUNT POD_IPV6_COUNT POD_RUN_LABEL POD_CASE_LABEL <<<"${state}"
}

validate_pod_identity_and_history() {
    [[ "${POD_RUN_LABEL}" == "${RUN_TOKEN}" ]] || fail "Pod run label no longer matches"
    [[ "${POD_CASE_LABEL}" == "${CASE_TOKEN}" ]] || fail "Pod case label no longer matches"
    if [[ -z "${CURRENT_POD_UID}" ]]; then
        [[ "${POD_UID}" != "-" ]] || fail "Pod UID is missing"
        CURRENT_POD_UID="${POD_UID}"
    elif [[ "${POD_UID}" != "${CURRENT_POD_UID}" ]]; then
        fail "Pod UID changed during a lifecycle round"
    fi
    [[ "${POD_RESTART_COUNT}" == "0" ]] || fail "Pod restarted during lifecycle round"
    if [[ "${POD_CONTAINER_STATE}" == "terminated" ]]; then
        if [[ "${POD_FINISHED_AT}" == "-" || "${POD_FINISHED_AT}" == 1970-01-01T00:00:00* ]]; then
            fail "Pod reported a missing or epoch finishedAt"
        fi
        if [[ "${CASE_SAW_137}" == "1" && "${POD_EXIT_CODE}" == "0" ]]; then
            fail "Pod exit code regressed from 137 to 0"
        fi
        if [[ "${POD_EXIT_CODE}" == "137" ]]; then
            CASE_SAW_137=1
        fi
    fi
}

read_cri_state() {
    local snapshot=$1
    local state
    state="$("${PYTHON_BIN}" - "${snapshot}" <<'PY'
import json
import sys

document = json.load(open(sys.argv[1], encoding="utf-8"))
status = document.get("status") or document
print("\t".join([
    str(status.get("state") or "-"),
    str(status.get("exitCode", "-")),
    str(status.get("finishedAt", "-")),
]))
PY
)"
    IFS=$'\t' read -r CRI_STATE CRI_EXIT_CODE CRI_FINISHED_AT <<<"${state}"
}

validate_cri_terminal_history() {
    case "${CRI_STATE}" in
        CONTAINER_EXITED | exited)
            if [[ ! "${CRI_FINISHED_AT}" =~ ^[1-9][0-9]*$ ]]; then
                fail "CRI reported an exited container without a valid finishedAt"
            fi
            if [[ "${CASE_SAW_137}" == "1" && "${CRI_EXIT_CODE}" == "0" ]]; then
                fail "CRI exit code regressed from 137 to 0"
            fi
            if [[ "${CRI_EXIT_CODE}" == "137" ]]; then
                CASE_SAW_137=1
            fi
            ;;
    esac
}

assert_dual_stack() {
    if [[ "${REQUIRE_DUAL_STACK}" == "1" || "${REQUIRE_DUAL_STACK}" == "true" ]]; then
        if ((POD_IPV4_COUNT < 1 || POD_IPV6_COUNT < 1)); then
            fail "Pod did not receive both IPv4 and IPv6 addresses"
        fi
    fi
}

wait_for_pod_running() {
    local require_ready=$1
    local deadline=$((SECONDS + WAIT_TIMEOUT))
    while ((SECONDS < deadline)); do
        next_observation_path pod
        capture_pod "${CURRENT_POD_NAME}" "${OBSERVATION_PATH}" || fail "failed to read the newly created Pod"
        read_pod_state "${OBSERVATION_PATH}"
        validate_pod_identity_and_history
        if [[ "${POD_PHASE}" == "Succeeded" || "${POD_PHASE}" == "Failed" || "${POD_CONTAINER_STATE}" == "terminated" ]]; then
            fail "Pod terminated before its live observation window"
        fi
        if [[ "${POD_CONTAINER_STATE}" == "running" ]]; then
            if [[ "${require_ready}" == "0" || "${POD_READY}" == "true" ]]; then
                assert_dual_stack
                return 0
            fi
        fi
        assert_shim_alive
        sleep 1
    done
    fail "timed out waiting for Pod to become running"
}

capture_runtime_ids() {
    local deadline=$((SECONDS + WAIT_TIMEOUT))
    while ((SECONDS < deadline)); do
        next_observation_path pod
        capture_pod "${CURRENT_POD_NAME}" "${OBSERVATION_PATH}" || fail "Pod disappeared while resolving runtime IDs"
        read_pod_state "${OBSERVATION_PATH}"
        validate_pod_identity_and_history
        if [[ "${POD_CONTAINER_ID}" != "-" ]]; then
            CRI_CONTAINER_ID="${POD_CONTAINER_ID}"
        fi
        local containers sandboxes
        containers="$(run_crictl ps -a --label "${CASE_SELECTOR}" -q)" || fail "ListContainers failed while resolving runtime IDs"
        sandboxes="$(run_crictl pods --label "${CASE_SELECTOR}" -q)" || fail "ListPodSandbox failed while resolving runtime IDs"
        if (( $(sed '/^$/d' <<<"${containers}" | wc -l | tr -d ' ') > 1 )); then
            fail "multiple containers matched this round's unique label"
        fi
        if (( $(sed '/^$/d' <<<"${sandboxes}" | wc -l | tr -d ' ') > 1 )); then
            fail "multiple sandboxes matched this round's unique label"
        fi
        if [[ -n "${CRI_CONTAINER_ID}" ]] && grep -Fx "${CRI_CONTAINER_ID}" <<<"${containers}" >/dev/null; then
            if [[ "$(sed '/^$/d' <<<"${sandboxes}" | wc -l | tr -d ' ')" == "1" ]]; then
                CRI_SANDBOX_ID="$(sed '/^$/d' <<<"${sandboxes}")"
                printf '%s\n' "${CRI_CONTAINER_ID}" >"${CASE_DIR}/container-id.txt"
                printf '%s\n' "${CRI_SANDBOX_ID}" >"${CASE_DIR}/sandbox-id.txt"
                return 0
            fi
        fi
        assert_shim_alive
        sleep 1
    done
    fail "timed out resolving this round's CRI container and sandbox"
}

assert_runtime_running() {
    local containers sandboxes
    containers="$(run_crictl ps -a --label "${CASE_SELECTOR}" -q)"
    sandboxes="$(run_crictl pods --label "${CASE_SELECTOR}" -q)"
    grep -Fx "${CRI_CONTAINER_ID}" <<<"${containers}" >/dev/null || fail "ListContainers omitted the running workload"
    grep -Fx "${CRI_SANDBOX_ID}" <<<"${sandboxes}" >/dev/null || fail "ListPodSandbox omitted the running sandbox"

    next_observation_path cri-container
    run_crictl inspect "${CRI_CONTAINER_ID}" >"${OBSERVATION_PATH}" || fail "ContainerStatus failed for the live workload"
    read_cri_state "${OBSERVATION_PATH}"
    validate_cri_terminal_history
    case "${CRI_STATE}" in
        CONTAINER_RUNNING | running) ;;
        *) fail "ContainerStatus did not report the live workload as running" ;;
    esac

    next_observation_path cri-sandbox
    run_crictl inspectp "${CRI_SANDBOX_ID}" >"${OBSERVATION_PATH}" || fail "PodSandboxStatus failed for the live sandbox"
    "${PYTHON_BIN}" - "${OBSERVATION_PATH}" <<'PY' || fail "PodSandboxStatus did not report the live sandbox as ready"
import json
import sys

document = json.load(open(sys.argv[1], encoding="utf-8"))
state = (document.get("status") or document).get("state")
if state not in {"SANDBOX_READY", "ready"}:
    raise SystemExit(1)
PY
    assert_shim_alive
}

assert_pod_live() {
    next_observation_path pod
    capture_pod "${CURRENT_POD_NAME}" "${OBSERVATION_PATH}" || fail "live Pod disappeared"
    read_pod_state "${OBSERVATION_PATH}"
    validate_pod_identity_and_history
    if [[ "${POD_PHASE}" == "Succeeded" || "${POD_PHASE}" == "Failed" || "${POD_CONTAINER_STATE}" != "running" ]]; then
        fail "Pod left Running before requested termination"
    fi
    [[ "${POD_READY}" == "true" ]] || fail "Pod lost Ready during live observation"
    assert_dual_stack
    assert_runtime_running
}

monitor_live() {
    local second
    for ((second = 0; second < HOLD_SECONDS; second++)); do
        assert_pod_live
        sleep 1
    done
}

run_exec_group() {
    local worker iteration output pid status_file worker_status
    local deadline all_done index
    local -a status_files=()
    BACKGROUND_PIDS=()
    for ((worker = 1; worker <= EXEC_CONCURRENCY; worker++)); do
        output="${CASE_DIR}/exec-${worker}.log"
        status_file="${CASE_DIR}/exec-${worker}.status"
        status_files+=("${status_file}")
        (
            worker_status=0
            for ((iteration = 1; iteration <= EXEC_ITERATIONS; iteration++)); do
                if ! KUBECTL_REMOTE_COMMAND_WEBSOCKETS=true run_kubectl_namespace exec "${CURRENT_POD_NAME}" -- \
                    /bin/sh -lc 'printf lifecycle-exec-ok' | grep -F lifecycle-exec-ok >/dev/null; then
                    worker_status=1
                    break
                fi
            done
            printf '%s\n' "${worker_status}" >"${status_file}"
            exit "${worker_status}"
        ) >"${output}" 2>&1 &
        pid=$!
        BACKGROUND_PIDS+=("${pid}")
    done
    monitor_live

    deadline=$((SECONDS + WAIT_TIMEOUT))
    while :; do
        all_done=1
        for ((index = 0; index < ${#status_files[@]}; index++)); do
            status_file="${status_files[index]}"
            if [[ ! -f "${status_file}" ]]; then
                all_done=0
                continue
            fi
            worker_status="$(<"${status_file}")"
            if [[ "${worker_status}" != "0" ]]; then
                terminate_background_workers
                fail "concurrent kubectl exec worker $((index + 1)) failed"
            fi
        done
        if [[ "${all_done}" == "1" ]]; then
            break
        fi
        if ((SECONDS >= deadline)); then
            terminate_background_workers
            fail "timed out waiting for concurrent kubectl exec workers"
        fi
        sleep 0.2
    done
    for pid in "${BACKGROUND_PIDS[@]}"; do
        if ! wait "${pid}"; then
            terminate_background_workers
            fail "concurrent kubectl exec worker failed"
        fi
    done
    BACKGROUND_PIDS=()
    assert_pod_live
}

wait_for_terminal() {
    local expected_exit=$1
    local expected_phase=$2
    local deadline=$((SECONDS + WAIT_TIMEOUT))
    while ((SECONDS < deadline)); do
        next_observation_path pod
        capture_pod "${CURRENT_POD_NAME}" "${OBSERVATION_PATH}" || fail "Pod disappeared before terminal status was observed"
        read_pod_state "${OBSERVATION_PATH}"
        validate_pod_identity_and_history
        if [[ "${POD_CONTAINER_STATE}" == "terminated" ]]; then
            [[ "${POD_EXIT_CODE}" == "${expected_exit}" ]] || fail "Pod exit code ${POD_EXIT_CODE} did not match ${expected_exit}"
            if [[ "${POD_PHASE}" == "${expected_phase}" ]]; then
                return 0
            fi
            if [[ "${POD_PHASE}" == "Succeeded" || "${POD_PHASE}" == "Failed" ]]; then
                fail "Pod phase ${POD_PHASE} did not match ${expected_phase}"
            fi
        elif [[ "${POD_PHASE}" == "Succeeded" || "${POD_PHASE}" == "Failed" ]]; then
            fail "Pod reached a terminal phase without container termination details"
        fi
        assert_shim_alive
        sleep 1
    done
    fail "timed out waiting for Pod terminal status"
}

assert_cri_terminal() {
    local expected_exit=$1
    local first_finished_at=""
    for _ in 1 2 3; do
        next_observation_path cri-container-terminal
        run_crictl inspect "${CRI_CONTAINER_ID}" >"${OBSERVATION_PATH}" || fail "ContainerStatus lost the terminal workload"
        read_cri_state "${OBSERVATION_PATH}"
        validate_cri_terminal_history
        case "${CRI_STATE}" in
            CONTAINER_EXITED | exited) ;;
            *) fail "ContainerStatus did not report the workload as exited" ;;
        esac
        [[ "${CRI_EXIT_CODE}" == "${expected_exit}" ]] || fail "CRI exit code ${CRI_EXIT_CODE} did not match ${expected_exit}"
        if [[ -z "${first_finished_at}" ]]; then
            first_finished_at="${CRI_FINISHED_AT}"
        elif [[ "${CRI_FINISHED_AT}" != "${first_finished_at}" ]]; then
            fail "CRI finishedAt changed across repeated ContainerStatus calls"
        fi
        sleep 0.2
    done
    next_observation_path cri-sandbox-terminal
    run_crictl inspectp "${CRI_SANDBOX_ID}" >"${OBSERVATION_PATH}" || fail "PodSandboxStatus lost the terminal workload's sandbox"
}

assert_forced_terminal() {
    wait_for_terminal 137 Failed
    assert_cri_terminal 137
    [[ "${CASE_SAW_137}" == "1" ]] || fail "forced termination was not observed with exit code 137"
}

verify_owned_pod() {
    local snapshot=$1
    "${PYTHON_BIN}" - "${snapshot}" "${CURRENT_POD_UID}" "${RUN_LABEL_KEY}" "${RUN_TOKEN}" "${CASE_LABEL_KEY}" "${CASE_TOKEN}" <<'PY'
import json
import sys

pod = json.load(open(sys.argv[1], encoding="utf-8"))
metadata = pod.get("metadata", {})
labels = metadata.get("labels", {})
if metadata.get("uid") != sys.argv[2]:
    raise SystemExit("Pod UID does not match")
if labels.get(sys.argv[3]) != sys.argv[4] or labels.get(sys.argv[5]) != sys.argv[6]:
    raise SystemExit("Pod ownership labels do not match")
PY
}

cri_object_is_missing() {
    local kind=$1
    local id=$2
    local output=$3
    local status=0
    case "${kind}" in
        container)
            run_crictl inspect "${id}" >"${output}" 2>"${output}.stderr" || status=$?
            ;;
        sandbox)
            run_crictl inspectp "${id}" >"${output}" 2>"${output}.stderr" || status=$?
            ;;
        *) fail "unsupported CRI object kind: ${kind}" ;;
    esac
    if [[ "${status}" == "0" ]]; then
        rm -f "${output}.stderr"
        return 1
    fi
    if grep -Eiq 'not[[:space:]_-]*found|NotFound' "${output}.stderr"; then
        return 0
    fi
    fail "CRI ${kind} inspection failed without a not-found result"
}

wait_for_case_cleanup() {
    local expected_exit=$1
    local deadline=$((SECONDS + WAIT_TIMEOUT))
    local kubernetes_present containers sandboxes
    while ((SECONDS < deadline)); do
        kubernetes_present=0
        next_observation_path cleanup-pod
        if capture_pod "${CURRENT_POD_NAME}" "${OBSERVATION_PATH}"; then
            kubernetes_present=1
            read_pod_state "${OBSERVATION_PATH}"
            validate_pod_identity_and_history
            if [[ "${POD_CONTAINER_STATE}" == "terminated" && "${POD_EXIT_CODE}" != "${expected_exit}" ]]; then
                fail "Pod cleanup exit code ${POD_EXIT_CODE} did not match ${expected_exit}"
            fi
            if [[ "${expected_exit}" == "137" && "${POD_PHASE}" == "Succeeded" ]]; then
                fail "force-stopped Pod was reported as Succeeded"
            fi
        elif ! pod_capture_was_not_found "${OBSERVATION_PATH}"; then
            fail "failed to read Pod status during cleanup"
        fi

        next_observation_path cleanup-cri-container
        if run_crictl inspect "${CRI_CONTAINER_ID}" >"${OBSERVATION_PATH}" 2>"${OBSERVATION_PATH}.stderr"; then
            rm -f "${OBSERVATION_PATH}.stderr"
            read_cri_state "${OBSERVATION_PATH}"
            validate_cri_terminal_history
            case "${CRI_STATE}" in
                CONTAINER_EXITED | exited)
                    [[ "${CRI_EXIT_CODE}" == "${expected_exit}" ]] || fail "CRI cleanup exit code ${CRI_EXIT_CODE} did not match ${expected_exit}"
                    ;;
            esac
        fi

        containers="$(run_crictl ps -a --label "${CASE_SELECTOR}" -q)" || fail "ListContainers failed during cleanup"
        sandboxes="$(run_crictl pods --label "${CASE_SELECTOR}" -q)" || fail "ListPodSandbox failed during cleanup"
        if [[ "${kubernetes_present}" == "0" && -z "${containers}" && -z "${sandboxes}" ]]; then
            next_observation_path missing-container
            if cri_object_is_missing container "${CRI_CONTAINER_ID}" "${OBSERVATION_PATH}"; then
                next_observation_path missing-sandbox
                if cri_object_is_missing sandbox "${CRI_SANDBOX_ID}" "${OBSERVATION_PATH}"; then
                    return 0
                fi
            fi
        fi
        assert_shim_alive
        sleep 0.2
    done
    fail "timed out waiting for this round's Pod, container, and sandbox cleanup"
}

delete_owned_pod() {
    local expected_exit=$1
    next_observation_path delete-pod
    capture_pod "${CURRENT_POD_NAME}" "${OBSERVATION_PATH}" || fail "Pod disappeared before ownership-checked cleanup"
    verify_owned_pod "${OBSERVATION_PATH}" || fail "refusing to delete a Pod whose UID or labels changed"
    run_kubectl_namespace delete pod "${CURRENT_POD_NAME}" --wait=false >"${CASE_DIR}/delete.log" 2>&1 || fail "kubectl delete failed"
    wait_for_case_cleanup "${expected_exit}"
    CURRENT_POD_NAME=""
    CURRENT_POD_UID=""
}

run_case() {
    local group=$1
    local round=$2
    local expected_cleanup_exit=137

    CURRENT_GROUP="${group}"
    CURRENT_ROUND="${round}"
    CURRENT_POD_UID=""
    CRI_CONTAINER_ID=""
    CRI_SANDBOX_ID=""
    CASE_SAW_137=0
    OBSERVATION_INDEX=0
    CASE_TOKEN="${group}-${round}-${RUN_TOKEN}"
    CASE_SELECTOR=""
    CURRENT_POD_NAME="cri-life-${group}-${round}-${RUN_TOKEN}"
    CASE_DIR="${WORK_DIR}/${group}-${round}"
    mkdir -p "${CASE_DIR}"

    log "starting ${group} round ${round}/${ROUNDS_PER_GROUP}"
    make_manifest "${group}" "${CURRENT_POD_NAME}" "${CASE_TOKEN}" "${CASE_DIR}/pod.json"
    run_kubectl_namespace create -f "${CASE_DIR}/pod.json" >"${CASE_DIR}/create.log"

    case "${group}" in
        control | exec | readiness)
            wait_for_pod_running 1
            ;;
        natural | forced)
            wait_for_pod_running 0
            ;;
        *) fail "unsupported group: ${group}" ;;
    esac
    CASE_SELECTOR="${CRI_POD_UID_LABEL}=${CURRENT_POD_UID}"
    RUN_POD_UIDS+=("${CURRENT_POD_UID}")
    capture_runtime_ids

    case "${group}" in
        control)
            monitor_live
            run_crictl stop --timeout 0 "${CRI_CONTAINER_ID}" >"${CASE_DIR}/stop-container.log" 2>&1 || fail "StopContainer failed"
            assert_forced_terminal
            ;;
        exec)
            run_exec_group
            ;;
        readiness)
            monitor_live
            run_kubectl_namespace logs "${CURRENT_POD_NAME}" >"${CASE_DIR}/pod.log"
            grep -F readiness-execsync-observed "${CASE_DIR}/pod.log" >/dev/null || fail "readiness ExecSync was not observed by the workload"
            run_crictl stopp "${CRI_SANDBOX_ID}" >"${CASE_DIR}/stop-sandbox.log" 2>&1 || fail "StopPodSandbox failed"
            assert_forced_terminal
            ;;
        natural)
            wait_for_terminal 0 Succeeded
            assert_cri_terminal 0
            expected_cleanup_exit=0
            ;;
        forced)
            assert_forced_terminal
            expected_cleanup_exit=137
            ;;
    esac

    delete_owned_pod "${expected_cleanup_exit}"
    assert_shim_alive
    write_summary passed "${group}" "${round}"
}

for group in "${LIFECYCLE_GROUPS[@]}"; do
    for ((round = 1; round <= ROUNDS_PER_GROUP; round++)); do
        run_case "${group}" "${round}"
    done
done

CURRENT_GROUP="final"
CURRENT_ROUND=0
assert_no_run_objects
run_kubectl get node "${NODE_NAME}" -o json >"${WORK_DIR}/node-after.json"
FINAL_RUNTIME_VERSION="$(read_node_runtime_version "${WORK_DIR}/node-after.json")"
[[ "${FINAL_RUNTIME_VERSION}" == "${NODE_RUNTIME_VERSION}" ]] || fail "node container runtime version changed during the run"
[[ "$(run_kubectl get --raw=/readyz)" == "ok" ]] || fail "Kubernetes API /readyz was not ok after the run"
run_crictl version >"${WORK_DIR}/cri-version-after.txt"
assert_shim_alive
write_summary passed final 0
log "completed ${TOTAL_ROUNDS} lifecycle rounds without premature success, epoch timestamps, exit-code regression, shim restart, or residual CRI objects"
RUN_SUCCEEDED=1
