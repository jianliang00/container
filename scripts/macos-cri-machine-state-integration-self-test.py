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

import base64
import hashlib
import json
import os
from pathlib import Path
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import unittest


SCRIPT = Path(__file__).with_name("macos-cri-machine-state-integration.sh")
SOURCE = SCRIPT.read_text(encoding="utf-8")


def heredoc(function_name: str, next_function: str) -> str:
    body = SOURCE.split(f"{function_name}() {{", 1)[1].split(f"\n}}\n\n{next_function}()", 1)[0]
    return body.split("<<'PY'\n", 1)[1].rsplit("\nPY", 1)[0]


RPC_CLIENT = heredoc("sidecar_rpc", "validate_sidecar_payload")
MANIFEST_RENDERER = heredoc("make_manifest", "sidecar_rpc")
PAYLOAD_VALIDATOR = heredoc("validate_sidecar_payload", "created_container_count")
CLEANUP_RECEIPT_VALIDATOR = heredoc("validate_cleanup_receipt", "run_cleanup_helper_once")
CLEANUP_FUNCTION = "cleanup() {" + SOURCE.split("cleanup() {", 1)[1].split("\n}\ntrap cleanup EXIT", 1)[0] + "\n}"


def encoded(value: dict) -> str:
    return base64.b64encode(json.dumps(value, separators=(",", ":")).encode()).decode()


class FakeSidecar:
    def __init__(self, directory: str, mode: str):
        self.path = os.path.join(directory, "sidecar.sock")
        self.mode = mode
        self.methods = []
        self.listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.listener.bind(self.path)
        self.listener.listen()
        self.listener.settimeout(0.1)
        self.stop_event = threading.Event()
        self.thread = threading.Thread(target=self.serve, daemon=True)

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, _type, _value, _traceback):
        self.stop_event.set()
        self.listener.close()
        self.thread.join(timeout=2)

    def serve(self):
        while not self.stop_event.is_set():
            try:
                connection, _ = self.listener.accept()
            except (TimeoutError, OSError):
                continue
            with connection:
                try:
                    length = struct.unpack(">I", self.read_exact(connection, 4))[0]
                    envelope = json.loads(self.read_exact(connection, length))
                    request = envelope["request"]
                    self.methods.append(request["method"])
                    response = self.response(request)
                    if response is None:
                        continue
                    payload = json.dumps({"kind": "response", "response": response}).encode()
                    connection.sendall(struct.pack(">I", len(payload)) + payload)
                except (ConnectionError, OSError, ValueError):
                    continue

    @staticmethod
    def read_exact(connection: socket.socket, count: int) -> bytes:
        value = b""
        while len(value) < count:
            chunk = connection.recv(count - len(value))
            if not chunk:
                raise ConnectionError("early EOF")
            value += chunk
        return value

    def response(self, request: dict):
        method = request["method"]
        if method in {"vm.saveMachineState", "vm.deleteMachineState"} and self.methods.count(method) == 1:
            return None
        if method == "vm.capabilities":
            if self.mode == "unresolved":
                return None
            return self.success(
                request,
                {
                    "protocolVersion": 5,
                    "supportedProtocolVersions": [1, 2, 3, 4, 5],
                    "lifecycleState": "paused" if self.mode == "save" else "running",
                    "machineState": {"supported": True},
                    "methods": [],
                },
            )
        if method == "vm.compatibilityDescription":
            if self.mode == "delete":
                return {
                    "requestID": request["requestID"],
                    "ok": False,
                    "error": {"code": "machineStateNotFound", "message": "absent"},
                    "protocolVersion": 5,
                }
            description = {"storageGeneration": 1}
            return self.success(
                request,
                {"current": description, "saved": description, "compatible": True, "reasons": []},
            )
        raise AssertionError(f"unexpected method {method}")

    @staticmethod
    def success(request: dict, data: dict):
        return {
            "requestID": request["requestID"],
            "ok": True,
            "data": encoded(data),
            "protocolVersion": 5,
        }


class IntegrationScriptTests(unittest.TestCase):
    def run_rpc(self, sidecar: FakeSidecar, method: str, timeout: int = 2):
        return subprocess.run(
            [sys.executable, "-", sidecar.path, method, "state-1", str(timeout), "1"],
            input=RPC_CLIENT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

    def test_guest_pid_survives_kubelet_dollar_expansion(self):
        with tempfile.TemporaryDirectory() as directory:
            output = os.path.join(directory, "pod.json")
            environment = os.environ | {
                "POD_NAME_VALUE": "pod",
                "NODE_VALUE": "node",
                "IMAGE_VALUE": "image",
                "RUNTIME_CLASS_VALUE": "macos",
                "PERSISTENCE_ID_VALUE": "binding",
                "NBD_SOCKET_VALUE": "/tmp/root.sock",
                "STORAGE_GENERATION_VALUE": "1",
                "RESTORE_STATE_VALUE": "",
                "RESTORE_GENERATION_VALUE": "",
                "RUN_TOKEN_VALUE": "run",
            }
            subprocess.run(
                [sys.executable, "-", output],
                input=MANIFEST_RENDERER,
                text=True,
                env=environment,
                check=True,
            )
            command = json.loads(Path(output).read_text(encoding="utf-8"))["spec"]["containers"][0]["args"][0]
            self.assertIn('"$$$$"', command)
            self.assertIn('"$$"', command.replace("$$", "$"))

    def test_save_disconnect_reconciles_without_second_save(self):
        with tempfile.TemporaryDirectory() as directory, FakeSidecar(directory, "save") as sidecar:
            result = self.run_rpc(sidecar, "vm.saveMachineState")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(
                sidecar.methods,
                ["vm.saveMachineState", "vm.capabilities", "vm.compatibilityDescription"],
            )

    def test_delete_disconnect_is_confirmed_by_missing_state(self):
        with tempfile.TemporaryDirectory() as directory, FakeSidecar(directory, "delete") as sidecar:
            result = self.run_rpc(sidecar, "vm.deleteMachineState")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(
                sidecar.methods,
                ["vm.deleteMachineState", "vm.capabilities", "vm.compatibilityDescription"],
            )

    def test_unresolved_save_uses_indeterminate_exit_code(self):
        with tempfile.TemporaryDirectory() as directory, FakeSidecar(directory, "unresolved") as sidecar:
            result = self.run_rpc(sidecar, "vm.saveMachineState", timeout=1)
            self.assertEqual(result.returncode, 75, result.stderr)

    def test_current_protocol_capability_is_accepted(self):
        methods = [
            "vm.pause",
            "vm.resume",
            "vm.saveMachineState",
            "vm.restoreMachineState",
            "vm.deleteMachineState",
            "vm.compatibilityDescription",
        ]
        response = {
            "protocolVersion": 5,
            "data": encoded(
                {
                    "protocolVersion": 5,
                    "supportedProtocolVersions": [1, 2, 3, 4, 5],
                    "lifecycleState": "running",
                    "machineState": {"supported": True},
                    "methods": methods,
                }
            ),
        }
        result = subprocess.run(
            [sys.executable, "-"],
            input=PAYLOAD_VALIDATOR,
            text=True,
            env=os.environ
            | {
                "SIDECAR_PAYLOAD_KIND": "capabilities",
                "SIDECAR_RESPONSE": json.dumps(response),
                "SAVED_GENERATION_VALUE": "1",
            },
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_cleanup_receipt_rejects_a_remaining_resource(self):
        readback = {
            "criObjectsPresent": False,
            "leasesPresent": False,
            "controlSocketsPresent": False,
            "machineStatePresent": False,
            "ownedSnapshotsPresent": False,
            "ownedClonesPresent": False,
            "ownedExportsPresent": False,
            "socketBoundToOwnedExport": False,
        }
        with tempfile.TemporaryDirectory() as directory:
            context = Path(directory, "context.json")
            receipt = Path(directory, "receipt.json")
            context.write_text(json.dumps({"idempotencyKey": "owner"}), encoding="utf-8")
            request_digest = hashlib.sha256(context.read_bytes()).hexdigest()
            receipt.write_text(
                json.dumps(
                    {
                        "schemaVersion": 1,
                        "operation": "cleanup",
                        "idempotencyKey": "owner",
                        "requestDigest": request_digest,
                        "readback": readback | {"ownedExportsPresent": True},
                    }
                ),
                encoding="utf-8",
            )
            result = subprocess.run(
                [sys.executable, "-"],
                input=CLEANUP_RECEIPT_VALIDATOR,
                text=True,
                env=os.environ
                | {
                    "CLEANUP_CONTEXT_PATH": str(context),
                    "CLEANUP_RECEIPT_PATH": str(receipt),
                },
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            self.assertNotEqual(result.returncode, 0)

            receipt.write_text(
                json.dumps(
                    {
                        "schemaVersion": 1,
                        "operation": "cleanup",
                        "idempotencyKey": "owner",
                        "requestDigest": request_digest,
                        "readback": readback,
                    }
                ),
                encoding="utf-8",
            )
            result = subprocess.run(
                [sys.executable, "-"],
                input=CLEANUP_RECEIPT_VALIDATOR,
                text=True,
                env=os.environ
                | {
                    "CLEANUP_CONTEXT_PATH": str(context),
                    "CLEANUP_RECEIPT_PATH": str(receipt),
                },
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_cleanup_failure_overrides_success(self):
        with tempfile.TemporaryDirectory() as directory:
            program = f"""
{CLEANUP_FUNCTION}
delete_owned_pod() {{ return 0; }}
wait_for_runtime_binding_absent() {{ return 0; }}
write_cleanup_context() {{ return 0; }}
run_cleanup_helper_twice() {{ return 1; }}
require_managed_paths_absent() {{ return 0; }}
WAIT_TIMEOUT_SECONDS=1
SECONDS=0
CLEANUP_RUNNING=false
RUN_SUCCEEDED=true
PENDING_OPERATION_FILE={json.dumps(os.path.join(directory, "pending"))}
TEMP_ROOT={json.dumps(directory)}
POD_NAME=initial
RESTORE_POD_NAME=restore
DISCONNECTED_POD_NAME=negative
INITIAL_UID=uid-1
RESTORE_UID=uid-2
DISCONNECTED_UID=uid-3
PERSISTENCE_ID=binding
DISCONNECTED_PERSISTENCE_ID=negative-binding
SUCCESS_MESSAGE=passed
true
cleanup
"""
            result = subprocess.run(
                ["bash"],
                input=program,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertIn("cleanup did not complete", result.stderr)


if __name__ == "__main__":
    unittest.main()
