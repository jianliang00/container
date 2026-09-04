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

import json
import os
from pathlib import Path
import shutil
import tempfile
from types import SimpleNamespace
import unittest
import uuid
from unittest.mock import patch

import run


class ProbeTests(unittest.TestCase):
    def test_dual_stack_canonical(self):
        self.assertEqual(run.dual_stack("192.168.247.0/24", "fdab:1234:5678:9::/64"), ("192.168.247.0/24", "fdab:1234:5678:9::/64"))

    def test_invalid_prefixes_fail_closed(self):
        for ipv4 in ("8.8.8.0/24", "127.0.0.0/24", "192.168.0.1/24", "10.0.0.0/16", "", "../network"):
            with self.subTest(ipv4=ipv4), self.assertRaises(ValueError):
                run.dual_stack(ipv4, "fdab::/64")
        for ipv6 in ("", "::/64", "::1/128", "fe80::/64", "ff00::/64", "2001:db8::/64", "fdab::1/64", "fdab::/48"):
            with self.subTest(ipv6=ipv6), self.assertRaises(ValueError):
                run.dual_stack("10.0.0.0/24", ipv6)

    def test_bootstrap_domain_cannot_change_identity(self):
        self.assertEqual(run.bootstrap_domain("system", 0), "system")
        self.assertEqual(run.bootstrap_domain("gui/501", 501), "gui/501")
        for domain, uid in (("system", 501), ("gui/502", 501), ("gui/501", 0), ("user/501", 501)):
            with self.assertRaises(ValueError):
                run.bootstrap_domain(domain, uid)

    def test_symlink_and_hardlink_seed_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            file = root / "disk"
            file.write_bytes(b"seed")
            self.assertEqual(run.regular_file(file), file)
            link = root / "link"
            link.symlink_to(file)
            with self.assertRaises(ValueError):
                run.regular_file(link)
            link.unlink()
            os.link(file, link)
            with self.assertRaises(ValueError):
                run.regular_file(file)
            with self.assertRaises(ValueError):
                run.regular_file(root)

    def test_parent_symlink_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            (root / "seed").mkdir()
            (root / "seed/disk").write_bytes(b"seed")
            (root / "alias").symlink_to(root / "seed", target_is_directory=True)
            with self.assertRaises(ValueError):
                run.regular_file(root / "alias/disk")

    def test_job_has_only_one_temporary_service_and_no_respawn(self):
        service = run.SERVICE_PREFIX + str(uuid.uuid4())
        job = run.make_job(service, Path("/test/probe"), Path("/test/evidence"), "10.0.0.0/24", "fdab::/64")
        self.assertEqual(job["MachServices"], {service: True})
        self.assertEqual(job["Label"], service)
        self.assertTrue(job["LaunchOnlyOnce"])
        self.assertFalse(job["KeepAlive"])
        self.assertEqual(job["Umask"], 0o077)
        self.assertEqual(job["ProgramArguments"][1:3], ["owner", service])
        for invalid in ("kubernetes-pod", "com.apple.container.network", run.SERVICE_PREFIX + "../existing"):
            with self.assertRaises(ValueError):
                run.make_job(invalid, Path("/test/probe"), Path("/test/evidence"), "10.0.0.0/24", "fdab::/64")

    def cases(self):
        return [{"case": case, "passed": True, "cleanupConfirmed": True} for case in run.CASES]

    def test_complete_matrix_pass_is_not_connectivity_pass(self):
        result = run.checked_summary(self.cases(), {"passed": True}, configured=True)
        self.assertTrue(result["passed"])
        self.assertTrue(result["fullDualStackConfigured"])
        self.assertFalse(result["guestConnectivityValidated"])
        unconfigured = run.checked_summary(self.cases(), {"passed": True}, configured=False)
        self.assertFalse(unconfigured["passed"])
        self.assertFalse(unconfigured["fullDualStackConfigured"])

    def test_incomplete_failed_reordered_or_unclean_matrix_fails(self):
        cases = self.cases()
        for variant in (cases[:-1], list(reversed(cases))):
            self.assertFalse(run.checked_summary(variant, {"passed": True}, configured=True)["passed"])
        for key in ("passed", "cleanupConfirmed"):
            variant = self.cases()
            variant[2][key] = False
            self.assertFalse(run.checked_summary(variant, {"passed": True}, configured=True)["passed"])
        self.assertFalse(run.checked_summary(cases, {"passed": False}, configured=True)["passed"])

    def test_missing_and_duplicate_responses_are_not_success(self):
        response = json.dumps({"stage": "case.result", "passed": True})
        self.assertTrue(run.result_from(response)["passed"])
        for output in ("", '{"stage":"vz.start","passed":true}', response + "\n" + response, "partial"):
            with self.assertRaises(ValueError):
                run.result_from(output)

    def test_cleanup_targets_only_unique_job(self):
        service = run.SERVICE_PREFIX + str(uuid.uuid4())
        calls = []
        class Fake:
            def run(self, name, args):
                calls.append((name, args))
                if name == "shutdown":
                    return 0, json.dumps({"stage": "case.result", "cleanupConfirmed": True, "referenceReleased": True})
                return (113 if name == "job-after" else 0), ""
            def stderr(self, name):
                return f'Could not find service "{service}"'
        self.assertTrue(run.cleanup_owner(Fake(), Path("/test/probe"), service, "gui/501")["passed"])
        self.assertEqual(calls[1][1], ["/bin/launchctl", "bootout", f"gui/501/{service}"])

    def test_job_absence_is_not_native_cleanup_confirmation(self):
        service = run.SERVICE_PREFIX + str(uuid.uuid4())
        class Fake:
            def run(self, name, args):
                return 113, ""
            def stderr(self, name):
                return f'Could not find service "{service}"'
        result = run.cleanup_owner(Fake(), Path("/test/probe"), service, "system")
        self.assertTrue(result["jobAbsent"])
        self.assertFalse(result["ownerReleaseConfirmed"])
        self.assertFalse(result["passed"])

    def test_permission_or_domain_failure_is_not_job_absence(self):
        service = run.SERVICE_PREFIX + str(uuid.uuid4())
        for code, error in ((1, "permission denied"), (113, "Could not find domain"), (124, ""), (113, 'Could not find service "different"')):
            self.assertFalse(run.job_absent(code, error, service))

    def test_timeout_preserves_output(self):
        with tempfile.TemporaryDirectory() as directory:
            commands = run.Commands(Path(directory))
            with patch.object(run.subprocess, "run", side_effect=run.subprocess.TimeoutExpired(["probe"], 1)):
                code, _ = commands.run("case", ["probe"], timeout=1)
            self.assertEqual(code, 124)
            self.assertTrue((Path(directory) / "case.stdout").exists())
            self.assertTrue((Path(directory) / "case.stderr").exists())

    def test_native_source_has_no_runtime_or_network_configuration_mutations(self):
        source = Path(__file__).with_name("Probe.swift").read_text()
        self.assertIn(".VMNET_HOST_MODE", source)
        self.assertIn("vmnet_stop_interface(handle", source)
        self.assertIn("vmnet_network_configuration_set_ipv6_prefix", source)
        for forbidden in ("VZNATNetworkDeviceAttachment", "VMNET_SHARED_MODE", "xpc_copy_description", "kubernetes-pod", "flannel"):
            self.assertNotIn(forbidden, source)

    def simulate(self, fault=None):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            evidence = root / "evidence"
            evidence.mkdir()
            binary = root / "probe"
            binary.write_bytes(b"offline-fixture")
            seed = root / "seed"
            seed.mkdir()
            for name in run.SEED_FILES:
                (seed / name).write_bytes(b"stopped-fixture")
            args = SimpleNamespace(binary=binary, seed=seed, ipv4="192.168.247.0/24", ipv6="fdab::/64", bootstrap_domain="system" if os.geteuid() == 0 else f"gui/{os.geteuid()}", dry_run=False, confirm_unused_subnets=True, confirm_stopped_seed=True)
            calls = []
            class FakeCommands:
                def __init__(self, _evidence):
                    self.service = ""

                def run(self, name, argv, timeout=50):
                    calls.append(name)
                    if name.startswith("clone-"):
                        shutil.copyfile(argv[-2], argv[-1])
                    if name == "owner-ready":
                        self.service = argv[2]
                        result = {"stage": "case.result", "ownerPID": 123, "network": {"ipv4Address": "192.168.247.1", "ipv4Mask": "255.255.255.0", "ipv6Prefix": "fdab::", "ipv6PrefixLength": 64}}
                        return 0, json.dumps(result)
                    if name.startswith("case-"):
                        result = {"stage": "case.result", "ownerPID": 123, "passed": True, "cleanupConfirmed": True}
                        if name == "case-3-same-import":
                            if fault == "cleanup":
                                result["cleanupConfirmed"] = False
                            if fault == "owner":
                                result["ownerPID"] = 456
                            if fault == "rejection":
                                result["passed"] = False
                        return 0, json.dumps(result)
                    if name == "shutdown":
                        return 0, json.dumps({"stage": "case.result", "cleanupConfirmed": True, "referenceReleased": True})
                    return (113 if name == "job-after" else 0), ""

                def stderr(self, name):
                    return f'Could not find service "{self.service}"'

            old_umask = os.umask(0o077)
            try:
                with patch.object(run, "Commands", FakeCommands), patch.object(run.tempfile, "mkdtemp", return_value=str(evidence)), patch.object(run.platform, "system", return_value="Darwin"), patch.object(run.platform, "mac_ver", return_value=("26.5.1", (), "arm64")), patch.object(run.signal, "signal"), patch("builtins.print"):
                    code = run.execute(args)
            finally:
                os.umask(old_umask)
            result = json.loads((evidence / "summary.json").read_text())
            self.assertIn("bootout", calls)
            self.assertIn("job-after", calls)
            for name in run.SEED_FILES:
                self.assertEqual((seed / name).read_bytes(), b"stopped-fixture")
            clone_retained = (evidence / "seed-cross-vz/Disk.img").exists()
            return code, result, clone_retained

    def test_complete_mock_run_cleans_only_clones(self):
        code, result, retained = self.simulate()
        self.assertEqual(code, 0)
        self.assertTrue(result["passed"])
        self.assertFalse(retained)

    def test_cleanup_uncertainty_stops_matrix_and_retains_clones(self):
        code, result, retained = self.simulate("cleanup")
        self.assertEqual(code, 1)
        self.assertEqual(len(result["cases"]), 3)
        self.assertTrue(retained)

    def test_owner_change_stops_matrix_and_retains_clones(self):
        code, result, retained = self.simulate("owner")
        self.assertEqual(code, 1)
        self.assertEqual(result["cases"][-1]["error"], "ownerIdentityChangedOrMissing")
        self.assertEqual(len(result["cases"]), 3)
        self.assertTrue(retained)

    def test_clean_rejection_keeps_comparison_but_cannot_pass(self):
        code, result, retained = self.simulate("rejection")
        self.assertEqual(code, 1)
        self.assertTrue(result["complete"])
        self.assertFalse(result["passed"])
        self.assertTrue(retained)


if __name__ == "__main__":
    unittest.main()
