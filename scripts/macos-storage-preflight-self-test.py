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

import contextlib
import copy
import importlib.util
import io
import os
from pathlib import Path
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

spec = importlib.util.spec_from_file_location("preflight", Path(__file__).with_name("macos-storage-preflight.py"))
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)
DIGEST = "sha256:" + "a" * 64


class StoragePreflightTests(unittest.TestCase):
    def evidence(self):
        return {"nodeName": "node", "nodeUID": "uid", "observedAtUnix": 1000,
                "configz": {"kubeletconfig": {"imageGCHighThresholdPercent": 85,
                                             "imageGCLowThresholdPercent": 80}}}

    def test_capacity_accounts_for_peak_and_margin(self):
        self.assertEqual(gate.headroom(1000, 300, 99, 85, 5)["projectedUsedBytes"], 799)
        for available, peak in [(300, 100), (200, 1), (100, 1), (300, 301)]:
            with self.subTest(available=available, peak=peak), self.assertRaises(gate.Rejected):
                gate.headroom(1000, available, peak, 85, 5)

    def test_invalid_or_unknown_capacity_fails_closed(self):
        for values in [(0, 1, 1, 85, 5), (100, 101, 1, 85, 5), (100, -1, 1, 85, 5),
                       (100, 50, 0, 85, 5), (100, 50, True, 85, 5), (100, 50, 1, 85, 4),
                       (100, 50, 1, 101, 5), (100, 50, 1, 5, 5)]:
            with self.subTest(values=values), self.assertRaises(gate.Rejected):
                gate.headroom(*values)

    def test_config_identity_and_freshness(self):
        self.assertEqual(gate.validate_config(self.evidence(), "node", "uid", 1001), 85)
        for node, uid, now in [("other", "uid", 1001), ("node", "other", 1001),
                               ("node", "uid", 999), ("node", "uid", 1121)]:
            with self.subTest(node=node, uid=uid, now=now), self.assertRaises(gate.Rejected):
                gate.validate_config(self.evidence(), node, uid, now)

    def test_bad_configuration_is_not_defaulted(self):
        for value in [None, "85", True, 0, 80, 101]:
            evidence = self.evidence()
            evidence["configz"]["kubeletconfig"]["imageGCHighThresholdPercent"] = value
            with self.subTest(value=value), self.assertRaises(gate.Rejected):
                gate.validate_config(evidence, "node", "uid", 1001)
        for value in [None, "1000", float("nan"), float("inf"), True]:
            evidence = self.evidence()
            evidence["observedAtUnix"] = value
            with self.subTest(value=value), self.assertRaises(gate.Rejected):
                gate.validate_config(evidence, "node", "uid", 1001)

    def test_installed_cri_must_report_pinned(self):
        for value in [None, False, "true", 1]:
            with self.subTest(value=value), self.assertRaises(gate.Rejected):
                gate.validate_images({"images": [{"id": DIGEST, "pinned": value}]}, [DIGEST])
        self.assertTrue(gate.validate_images({"images": [{"id": DIGEST, "pinned": True}]}, [DIGEST])[0]["pinned"])

    def test_missing_and_alias_images_cannot_bypass(self):
        for payload in [{}, {"images": []}, {"images": [{"id": "short", "pinned": True}]},
                        {"images": [{"id": DIGEST, "pinned": True}, {"id": DIGEST}]},
                        {"images": [{"id": DIGEST, "pinned": True, "repoTags": "tag"}]}]:
            with self.subTest(payload=payload), self.assertRaises(gate.Rejected):
                gate.validate_images(payload, [DIGEST])
        with self.assertRaises(gate.Rejected):
            gate.validate_images({"images": [{"id": "tag", "pinned": True}]}, ["tag"])

    def test_inventory_order_does_not_matter(self):
        images = [{"id": DIGEST, "pinned": True, "repoTags": ["b", "a"]}, {"id": "workload"}]
        reversed_images = copy.deepcopy(images[::-1])
        reversed_images[1]["repoTags"].reverse()
        self.assertEqual(gate.validate_images({"images": images}, [DIGEST]),
                         gate.validate_images({"images": reversed_images}, [DIGEST]))

    def test_rejection_never_runs_command(self):
        run = Mock()
        with self.assertRaises(gate.Rejected):
            gate.guarded_run(SimpleNamespace(command=["test"]), 85, Mock(side_effect=gate.Rejected("full")), run)
        run.assert_not_called()

    def test_command_runs_once_and_postflight_always_runs(self):
        for code in [0, 7]:
            inspect = Mock(return_value={"images": [], "filesystems": []})
            run = Mock(return_value=SimpleNamespace(returncode=code))
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(gate.guarded_run(SimpleNamespace(command=["test"]), 85, inspect, run), code)
            run.assert_called_once_with(["test"], check=False, pass_fds=())
            self.assertEqual(inspect.call_count, 2)

    def test_inventory_change_blocks(self):
        inspect = Mock(side_effect=[{"images": ["before"]}, {"images": ["after"]}])
        with contextlib.redirect_stdout(io.StringIO()), self.assertRaises(gate.Rejected):
            gate.guarded_run(SimpleNamespace(command=["test"]), 85, inspect, Mock())

    def test_command_inherits_cooperative_lock(self):
        run = Mock(return_value=SimpleNamespace(returncode=0))
        with contextlib.redirect_stdout(io.StringIO()):
            gate.guarded_run(SimpleNamespace(command=["test"]), 85, Mock(return_value={"images": []}), run, lock_fd=9)
        run.assert_called_once_with(["test"], check=False, pass_fds=(9,))

    def test_read_only_does_not_execute(self):
        run = Mock()
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(gate.guarded_run(SimpleNamespace(command=[]), 85, Mock(return_value={}), run), 0)
        run.assert_not_called()

    def test_missing_live_filesystem_fails_closed(self):
        for response in [None, {}, {"imageFilesystems": []}, {"imageFilesystems": [None]},
                         {"imageFilesystems": [{"fsId": {}}]}]:
            with patch.object(gate, "cri_json", return_value=response), self.assertRaises(gate.Rejected):
                gate.inspect(SimpleNamespace(storage_root=[]), 85)

    def test_live_capacity_checks_image_and_test_volumes(self):
        with tempfile.TemporaryDirectory() as root:
            image_root = Path(root, "images")
            image_root.mkdir()
            responses = [{"imageFilesystems": [{"fsId": {"mountpoint": str(image_root)}}]},
                         {"images": [{"id": DIGEST, "pinned": True}]}]
            args = SimpleNamespace(storage_root=[root], peak_additional_bytes=10, margin_percent=5, require_pinned=[DIGEST])
            stats = SimpleNamespace(f_blocks=1000, f_frsize=1, f_bavail=300)
            with patch.object(gate, "cri_json", side_effect=responses), patch.object(gate.os, "statvfs", return_value=stats):
                result = gate.inspect(args, 85)
            self.assertEqual(len(result["filesystems"]), 2)
            self.assertTrue(all(fs["projectedUsedBytes"] == 710 for fs in result["filesystems"]))

    def test_failed_command_still_checks_postflight(self):
        inspect = Mock(return_value={"images": []})
        with contextlib.redirect_stdout(io.StringIO()), self.assertRaises(OSError):
            gate.guarded_run(SimpleNamespace(command=["missing"]), 85, inspect, Mock(side_effect=OSError("missing")))
        self.assertEqual(inspect.call_count, 2)

    def test_machine_state_entrypoint_rejects_missing_gate_settings(self):
        env = {key: value for key, value in os.environ.items() if not key.startswith("MACOS_STORAGE_")}
        with tempfile.TemporaryDirectory() as root:
            env["CONTAINER_MACOS_MACHINE_STATE_INTEGRATION_ROOT"] = root
            result = subprocess.run(["sh", str(Path(__file__).with_name("macos-node-machine-state-integration.sh"))],
                                    env=env, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("MACOS_STORAGE_NODE", result.stderr)


if __name__ == "__main__":
    unittest.main()
