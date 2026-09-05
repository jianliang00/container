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

import io
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
import uuid
from unittest.mock import Mock, patch

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

    def cases(self, matrix="all"):
        return [
            {"case": case, "passed": True, "cleanupConfirmed": True, **({"nativeRealizationStatus": "hostBridgeObserved"} if case.endswith("-vz") else {})}
            for case in run.MATRICES[matrix]
        ]

    def test_complete_matrix_pass_is_not_connectivity_pass(self):
        result = run.checked_summary(self.cases(), {"passed": True}, configured=True)
        self.assertTrue(result["passed"])
        self.assertTrue(result["fullDualStackConfigured"])
        self.assertFalse(result["guestConnectivityValidated"])
        unconfigured = run.checked_summary(self.cases(), {"passed": True}, configured=False)
        self.assertFalse(unconfigured["passed"])
        self.assertFalse(unconfigured["fullDualStackConfigured"])
        self.assertFalse(unconfigured["comparisonValid"])

    def test_family_summary_requires_matching_plan_and_limits_vz_evidence(self):
        for matrix in ("all", "native", "vz"):
            with self.subTest(matrix=matrix):
                result = run.checked_summary(self.cases(matrix), {"passed": True}, configured=True, matrix=matrix, planned_cases=run.MATRICES[matrix])
                self.assertTrue(result["passed"])
                self.assertTrue(result["comparisonValid"])
                self.assertEqual(result["plannedCases"], list(run.MATRICES[matrix]))
                self.assertFalse(result["nativeDataplaneValidated"])
                self.assertFalse(result["guestConnectivityValidated"])
                if matrix == "vz":
                    self.assertEqual(result["scope"], "vz-control-plane-observation")
        for matrix, planned in (("unknown", ()), ("vz", run.CASES), ("native", run.MATRICES["native"][:-1])):
            result = run.checked_summary(self.cases(), {"passed": True}, configured=True, matrix=matrix, planned_cases=planned)
            self.assertFalse(result["planValid"])
            self.assertFalse(result["complete"])
            self.assertFalse(result["passed"])

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
            code, output = commands.run("case", [sys.executable, "-c", "import time; print('partial evidence', flush=True); time.sleep(60)"], timeout=0.5)
            self.assertEqual(code, 124)
            self.assertIn("partial evidence", output)
            self.assertTrue((Path(directory) / "case.stderr").exists())
            receipt = json.loads((Path(directory) / "case.cleanup.json").read_text())
            self.assertTrue(receipt["processExited"])
            self.assertFalse(receipt["nativeCleanupConfirmed"])
            self.assertEqual(receipt["reason"], "timeout")

    def test_parent_interruption_stops_and_reaps_live_child(self):
        with tempfile.TemporaryDirectory() as directory:
            commands = run.Commands(Path(directory))
            real_popen = subprocess.Popen
            children = []
            interruption = KeyboardInterrupt("parent-only interruption")

            def start(*args, **kwargs):
                child = real_popen(*args, **kwargs)
                children.append(child)
                real_wait = child.wait
                first_wait = True

                def wait(timeout=None):
                    nonlocal first_wait
                    if first_wait:
                        first_wait = False
                        raise interruption
                    return real_wait(timeout=timeout)

                child.wait = wait
                return child

            try:
                with patch.object(run.subprocess, "Popen", side_effect=start):
                    with self.assertRaises(KeyboardInterrupt) as raised:
                        commands.run("case", [sys.executable, "-c", "import time; time.sleep(60)"])
                self.assertIs(raised.exception, interruption)
                self.assertIsNotNone(children[0].poll())
                self.assertTrue(commands.cancellations[0]["processExited"])
                self.assertFalse(commands.cancellations[0]["nativeCleanupConfirmed"])
            finally:
                for child in children:
                    if child.poll() is None:
                        child.kill()
                        child.wait(timeout=5)

    def test_timeout_escalates_when_child_ignores_termination(self):
        with tempfile.TemporaryDirectory() as directory:
            commands = run.Commands(Path(directory))
            child_code = "import signal, time; signal.signal(signal.SIGTERM, signal.SIG_IGN); print('ready', flush=True); time.sleep(60)"
            code, output = commands.run("case", [sys.executable, "-c", child_code], timeout=0.5)
            self.assertEqual(code, 124)
            self.assertIn("ready", output)
            self.assertTrue(commands.cancellations[0]["killRequested"])
            self.assertTrue(commands.cancellations[0]["processExited"])

    def test_bounded_cleanup_failure_preserves_original_interruption(self):
        with tempfile.TemporaryDirectory() as directory:
            commands = run.Commands(Path(directory))
            interruption = KeyboardInterrupt("original interruption")
            child = Mock(pid=123)
            child.poll.return_value = None
            child.wait.side_effect = [interruption, subprocess.TimeoutExpired("probe", 2), subprocess.TimeoutExpired("probe", 3)]
            with patch.object(run.subprocess, "Popen", return_value=child):
                with self.assertRaises(KeyboardInterrupt) as raised:
                    commands.run("case", ["probe"])
            self.assertIs(raised.exception, interruption)
            self.assertFalse(commands.cancellations[0]["processExited"])
            self.assertEqual(commands.cancellations[0]["cleanupError"], "TimeoutExpired")
            child.terminate.assert_called_once_with()
            child.kill.assert_called_once_with()

    def test_native_source_has_no_runtime_or_network_configuration_mutations(self):
        source = Path(__file__).with_name("Probe.swift").read_text()
        self.assertIn(".VMNET_HOST_MODE", source)
        self.assertIn("vmnet_stop_interface(handle", source)
        self.assertIn("vmnet_network_configuration_set_ipv6_prefix", source)
        for forbidden in ("VZNATNetworkDeviceAttachment", "VMNET_SHARED_MODE", "xpc_copy_description", "kubernetes-pod", "flannel"):
            self.assertNotIn(forbidden, source)

    def simulate(self, fault=None, matrix="all", diagnostic_default="baseline"):
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
            args = SimpleNamespace(binary=binary, seed=seed, ipv4="192.168.247.0/24", ipv6="fdab::/64", bootstrap_domain="system" if os.geteuid() == 0 else f"gui/{os.geteuid()}", matrix=matrix, diagnostic_default=diagnostic_default, dry_run=False, confirm_unused_subnets=True, confirm_stopped_seed=True)
            calls = []
            booted_seeds = []
            class FakeCommands:
                def __init__(self, _evidence):
                    self.service = ""
                    self.cancellations = []

                def run(self, name, argv, timeout=50):
                    calls.append(name)
                    if name.startswith("clone-"):
                        shutil.copyfile(argv[-2], argv[-1])
                    if name == "owner-ready":
                        self.service = argv[2]
                        result = {"stage": "case.result", "ownerPID": 123, "diagnosticDefault": diagnostic_default, "configurationReadBack": False, "network": {"ipv4Address": "192.168.247.1", "ipv4Mask": "255.255.255.0", "ipv6Prefix": "fdab::", "ipv6PrefixLength": 64}}
                        if fault == "owner-receipt-missing":
                            result.pop("diagnosticDefault")
                        if fault == "owner-receipt-mismatch":
                            result["diagnosticDefault"] = "unexpected-default"
                        if fault == "owner-receipt-readback":
                            result["configurationReadBack"] = True
                        return 0, json.dumps(result)
                    if name.startswith("case-"):
                        index = int(name.split("-", 2)[1])
                        if argv[3].endswith("-vz"):
                            disposable = Path(argv[4])
                            if (disposable / "Disk.img").read_bytes() != b"stopped-fixture":
                                raise AssertionError("a VZ case reused an already booted disk")
                            (disposable / "Disk.img").write_bytes(b"booted-fixture")
                            booted_seeds.append(str(disposable))
                        result = {"stage": "case.result", "ownerPID": 123, "passed": True, "cleanupConfirmed": True}
                        if argv[3].endswith("-vz"):
                            result["nativeRealizationStatus"] = "hostBridgeObserved"
                            if fault == "vz-no-receipt-baseline" and index == 1:
                                result.pop("nativeRealizationStatus")
                            if fault == "vz-no-receipt-import" and index == 3:
                                result.pop("nativeRealizationStatus")
                            if fault == "vz-empty-receipt-import" and index == 3:
                                result["nativeRealizationStatus"] = ""
                            if fault == "vz-error-and-no-receipt-import" and index == 3:
                                result.pop("nativeRealizationStatus")
                                result["error"] = "originalNativeFailure"
                                result["errorDomain"] = "probe.native"
                                result["errorCode"] = 17
                        if index == 3:
                            if fault == "cleanup":
                                result["cleanupConfirmed"] = False
                            if fault == "owner":
                                result["ownerPID"] = 456
                            if fault in ("rejection", "rejection-then-baseline"):
                                result["passed"] = False
                            if fault == "cancelled":
                                self.cancellations.append({"processExited": True, "nativeCleanupConfirmed": False})
                        if (fault == "first-baseline" and index == 1) or (fault == "rejection-then-baseline" and index == 4):
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
                    if fault and fault.startswith("owner-receipt-"):
                        with self.assertRaisesRegex(ValueError, "owner diagnostic configuration receipt differs"):
                            run.execute(args)
                        code = 1
                    else:
                        code = run.execute(args)
            finally:
                os.umask(old_umask)
            result = json.loads((evidence / "summary.json").read_text())
            self.assertIn("bootout", calls)
            self.assertIn("job-after", calls)
            for name in run.SEED_FILES:
                self.assertEqual((seed / name).read_bytes(), b"stopped-fixture")
            clone_retained = any(evidence.glob("seed-*/Disk.img"))
            self.last_run = {"plan": json.loads((evidence / "plan.json").read_text()), "job": plistlib.loads((evidence / "owner.plist").read_bytes()), "calls": calls, "bootedSeeds": booted_seeds}
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
        self.assertTrue(result["comparisonValid"])
        self.assertFalse(result["passed"])
        self.assertTrue(retained)

    def test_default_matrix_preserves_original_twelve_case_order(self):
        code, result, _ = self.simulate()
        self.assertEqual(code, 0)
        self.assertEqual(result["matrix"], "all")
        self.assertEqual([case["case"] for case in result["cases"]], list(run.CASES))
        self.assertEqual(len(result["cases"]), 12)

    def test_independent_native_family_does_not_boot_vz_or_clone_disks(self):
        code, result, retained = self.simulate(matrix="native")
        self.assertEqual(code, 0)
        self.assertEqual([case["case"] for case in result["cases"]], list(run.MATRICES["native"]))
        self.assertEqual(self.last_run["bootedSeeds"], [])
        self.assertFalse(any(name.startswith("clone-") for name in self.last_run["calls"]))
        self.assertFalse(retained)

    def test_vz_family_gives_each_repeated_baseline_a_fresh_clone(self):
        code, result, retained = self.simulate(matrix="vz")
        self.assertEqual(code, 0)
        self.assertEqual([case["case"] for case in result["cases"]], list(run.MATRICES["vz"]))
        self.assertEqual(len(self.last_run["bootedSeeds"]), 6)
        self.assertEqual(len(set(self.last_run["bootedSeeds"])), 6)
        self.assertFalse(retained)
        self.assertEqual(result["scope"], "vz-control-plane-observation")

    def test_failed_first_baseline_stops_each_family_despite_confirmed_cleanup(self):
        for matrix in ("all", "native", "vz"):
            with self.subTest(matrix=matrix):
                code, result, _ = self.simulate("first-baseline", matrix=matrix)
                self.assertEqual(code, 1)
                self.assertEqual(len(result["cases"]), 1)
                self.assertTrue(result["cases"][0]["cleanupConfirmed"])
                self.assertEqual(result["stopReason"], {"code": "baselineFailed", "case": run.MATRICES[matrix][0], "index": 1})
                self.assertFalse(result["comparisonValid"])

    def test_clean_import_rejection_requires_successful_following_baseline(self):
        for matrix in ("native", "vz"):
            with self.subTest(matrix=matrix):
                code, result, _ = self.simulate("rejection-then-baseline", matrix=matrix)
                self.assertEqual(code, 1)
                self.assertEqual(len(result["cases"]), 4)
                self.assertEqual(result["stopReason"]["code"], "baselineFailed")
                self.assertFalse(result["comparisonValid"])
                self.assertFalse(result["complete"])

    def test_native_defaults_are_explicitly_not_live_readback(self):
        self.simulate(matrix="native")
        defaults = self.last_run["plan"]["unchangedNativeDefaults"]
        self.assertFalse(defaults["readBack"])
        self.assertIn("documented defaults", defaults["basis"])
        for feature in ("nat44", "nat66", "dnsProxy", "routerAdvertisements"):
            self.assertTrue(defaults[feature])

    def test_diagnostic_override_changes_one_requested_default_and_one_owner_argument(self):
        baseline = run.requested_native_configuration("baseline")
        for option, changed in (("disable-nat66", "nat66"), ("disable-router-advertisement", "routerAdvertisements")):
            with self.subTest(option=option):
                code, _, _ = self.simulate(matrix="native", diagnostic_default=option)
                self.assertEqual(code, 0)
                requested = self.last_run["plan"]["requestedNativeConfiguration"]
                self.assertEqual({key for key in baseline if baseline[key] != requested[key]}, {"diagnosticDefault", changed})
                self.assertFalse(requested[changed])
                self.assertFalse(requested["readBack"])
                self.assertNotIn(changed, self.last_run["plan"]["unchangedNativeDefaults"])
                self.assertEqual(self.last_run["job"]["ProgramArguments"][-1], option)
                self.assertEqual(len(self.last_run["job"]["ProgramArguments"]), 6)
        self.simulate(matrix="native")
        self.assertEqual(len(self.last_run["job"]["ProgramArguments"]), 5)

    def test_diagnostic_override_rejects_invalid_combinations_before_mutation(self):
        for matrix in ("all", "vz"):
            for option in run.DIAGNOSTIC_DEFAULTS[1:]:
                with self.subTest(matrix=matrix, option=option):
                    args = SimpleNamespace(matrix=matrix, diagnostic_default=option)
                    with patch.object(run.tempfile, "mkdtemp") as evidence, patch.object(run, "Commands") as commands:
                        with self.assertRaisesRegex(ValueError, "require --matrix native"):
                            run.execute(args)
                        evidence.assert_not_called()
                        commands.assert_not_called()
        service = run.SERVICE_PREFIX + str(uuid.uuid4())
        with self.assertRaisesRegex(ValueError, "unknown diagnostic default"):
            run.make_job(service, Path("/test/probe"), Path("/test/evidence"), "10.0.0.0/24", "fdab::/64", diagnostic_default="disable-both")

    def test_repeated_diagnostic_selection_fails_before_execute(self):
        argv = ["run.py", "--binary", "/test/probe", "--seed", "/test/seed", "--ipv4", "192.168.247.0/24", "--ipv6", "fdab::/64", "--bootstrap-domain", "system", "--matrix", "native", "--dry-run"]
        for first, second in (("baseline", "baseline"), ("disable-nat66", "disable-nat66"), ("baseline", "disable-nat66"), ("disable-router-advertisement", "disable-nat66")):
            with self.subTest(first=first, second=second):
                repeated = [*argv, "--diagnostic-default", first, "--diagnostic-default", second]
                with patch.object(sys, "argv", repeated), patch.object(run, "execute") as execute, patch("sys.stderr", new=io.StringIO()) as error:
                    with self.assertRaises(SystemExit) as raised:
                        run.main()
                    self.assertEqual(raised.exception.code, 2)
                    self.assertIn("--diagnostic-default may be supplied only once", error.getvalue())
                    execute.assert_not_called()

    def test_diagnostic_override_dry_run_reports_request_without_owner_mutation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            binary = root / "probe"
            binary.write_bytes(b"probe")
            seed = root / "seed"
            seed.mkdir()
            for name in run.SEED_FILES:
                (seed / name).write_bytes(b"seed")
            argv = ["run.py", "--binary", str(binary), "--seed", str(seed), "--ipv4", "192.168.247.0/24", "--ipv6", "fdab::/64", "--bootstrap-domain", "system" if os.geteuid() == 0 else f"gui/{os.geteuid()}", "--matrix", "native", "--diagnostic-default", "disable-nat66", "--dry-run"]
            with patch.object(sys, "argv", argv), patch.object(run.tempfile, "mkdtemp") as evidence, patch.object(run, "Commands") as commands, patch.object(run.signal, "signal"), patch("builtins.print") as output:
                self.assertEqual(run.main(), 0)
                plan = json.loads(output.call_args.args[0])
                self.assertFalse(plan["requestedNativeConfiguration"]["nat66"])
                self.assertFalse(plan["requestedNativeConfiguration"]["readBack"])
                self.assertEqual(plan["matrix"], "native")
                evidence.assert_not_called()
                commands.assert_not_called()

    def test_owner_configuration_receipt_must_match_before_first_case(self):
        for fault in ("owner-receipt-missing", "owner-receipt-mismatch", "owner-receipt-readback"):
            with self.subTest(fault=fault):
                code, result, _ = self.simulate(fault, matrix="native", diagnostic_default="disable-nat66")
                self.assertEqual(code, 1)
                self.assertEqual(result["cases"], [])
                self.assertFalse(result["fullDualStackConfigured"])
                self.assertEqual(result["stopReason"]["code"], "ownerConfigurationReceiptMismatch")
                self.assertFalse(any(name.startswith("case-") for name in self.last_run["calls"]))

    def test_each_diagnostic_invocation_uses_one_fresh_owner(self):
        services = []
        for option in ("baseline", "disable-nat66"):
            self.simulate(matrix="native", diagnostic_default=option)
            services.append(self.last_run["plan"]["service"])
            self.assertEqual(self.last_run["calls"].count("bootstrap"), 1)
            self.assertEqual(self.last_run["calls"].count("owner-ready"), 1)
        self.assertNotEqual(services[0], services[1])

    def test_vz_missing_or_empty_native_realization_receipt_stops_immediately(self):
        for fault, count in (("vz-no-receipt-baseline", 1), ("vz-no-receipt-import", 3), ("vz-empty-receipt-import", 3)):
            with self.subTest(fault=fault):
                code, result, retained = self.simulate(fault, matrix="vz")
                self.assertEqual(code, 1)
                self.assertEqual(len(result["cases"]), count)
                self.assertEqual(result["cases"][-1]["error"], "nativeRealizationUnobserved")
                self.assertFalse(result["cases"][-1]["passed"])
                self.assertFalse(result["comparisonValid"])
                self.assertEqual(result["stopReason"]["evidence"], "nativeRealizationUnobserved")
                self.assertTrue(retained)

    def test_summary_rejects_vz_legacy_or_unobserved_receipts_even_if_payload_passes(self):
        for status in (None, "", "bridgeMissing", "hostBridgeObservedUnexpected"):
            with self.subTest(status=status):
                cases = self.cases("vz")
                if status is None:
                    cases[2].pop("nativeRealizationStatus")
                else:
                    cases[2]["nativeRealizationStatus"] = status
                result = run.checked_summary(cases, {"passed": True}, configured=True, matrix="vz")
                self.assertTrue(result["complete"])
                self.assertFalse(result["comparisonValid"])
                self.assertFalse(result["passed"])

    def test_missing_realization_does_not_overwrite_original_native_error(self):
        code, result, _ = self.simulate("vz-error-and-no-receipt-import", matrix="vz")
        self.assertEqual(code, 1)
        self.assertEqual(len(result["cases"]), 3)
        self.assertEqual(result["cases"][-1]["error"], "originalNativeFailure")
        self.assertEqual(result["cases"][-1]["errorDomain"], "probe.native")
        self.assertEqual(result["cases"][-1]["errorCode"], 17)
        self.assertEqual(result["stopReason"]["evidence"], "nativeRealizationUnobserved")

    def test_owner_cleanup_cannot_attest_cancelled_client_native_cleanup(self):
        code, result, retained = self.simulate("cancelled")
        self.assertEqual(code, 1)
        self.assertFalse(result["complete"])
        self.assertEqual(len(result["cases"]), 3)
        self.assertFalse(result["cases"][-1]["cleanupConfirmed"])
        self.assertTrue(result["cleanup"]["ownerReleaseConfirmed"])
        self.assertFalse(result["cleanup"]["passed"])
        self.assertEqual(len(result["cleanup"]["cancelledCommands"]), 1)
        self.assertTrue(retained)


if __name__ == "__main__":
    unittest.main()
