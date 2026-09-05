#!/usr/bin/env python3
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

"""Bounded, standalone dual-stack vmnet reservation diagnostic. No SSH or runtime API."""

import argparse
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import platform
import plistlib
import signal
import stat
import subprocess
import sys
import tempfile
import uuid


CASES = (
    "direct", "direct", "same-import", "direct", "cross-native", "direct",
    "direct-vz", "direct", "same-import-vz", "direct", "cross-vz", "direct",
)
SERVICE_PREFIX = "com.apple.container.vmnet-probe."
SEED_FILES = ("HardwareModel.bin", "AuxiliaryStorage", "Disk.img")


def dual_stack(ipv4, ipv6):
    v4 = ipaddress.IPv4Network(ipv4, strict=True)
    v6 = ipaddress.IPv6Network(ipv6, strict=True)
    private = tuple(ipaddress.IPv4Network(cidr) for cidr in ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"))
    if v4.prefixlen != 24 or not any(v4.subnet_of(block) for block in private):
        raise ValueError("IPv4 must be an unused, canonical RFC1918 /24")
    if v6.prefixlen != 64 or not v6.subnet_of(ipaddress.IPv6Network("fd00::/8")):
        raise ValueError("IPv6 must be an unused, canonical locally assigned ULA /64")
    return str(v4), str(v6)


def bootstrap_domain(domain, uid):
    if domain != ("system" if uid == 0 else f"gui/{uid}"):
        raise ValueError("bootstrap domain must match the current effective UID; no automatic elevation")
    return domain


def regular_file(path):
    path = Path(path).absolute()
    for component in (path, *path.parents):
        if component.is_symlink():
            raise ValueError("symlink paths are not accepted")
    info = path.stat()
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
        raise ValueError("input must be a regular, non-hardlinked file")
    return path


def make_job(service, binary, evidence, ipv4, ipv6):
    if not service.startswith(SERVICE_PREFIX):
        raise ValueError("not a temporary probe service")
    uuid.UUID(service[len(SERVICE_PREFIX):])
    return {
        "Label": service,
        "ProgramArguments": [str(binary), "owner", service, ipv4, ipv6],
        "MachServices": {service: True},
        "RunAtLoad": True,
        "KeepAlive": False,
        "LaunchOnlyOnce": True,
        "ExitTimeOut": 25,
        "Umask": 0o077,
        "StandardOutPath": str(evidence / "owner.jsonl"),
        "StandardErrorPath": str(evidence / "owner.stderr"),
    }


def result_from(output):
    events = [json.loads(line) for line in output.splitlines() if line.strip()]
    results = [event for event in events if event.get("stage") == "case.result"]
    if len(results) != 1:
        raise ValueError("exactly one case.result required; truncated output is not success")
    return results[0]


def checked_summary(cases, cleanup, configured=False):
    complete = [entry["case"] for entry in cases] == list(CASES)
    passed = complete and all(entry.get("passed") is True and entry.get("cleanupConfirmed") is True for entry in cases)
    return {
        "schemaVersion": 1,
        "scope": "native-attachment-only",
        "fullDualStackConfigured": configured,
        "guestConnectivityValidated": False,
        "complete": complete,
        "passed": configured and passed and cleanup.get("passed") is True,
        "cases": cases,
        "cleanup": cleanup,
    }


def job_absent(code, error, service):
    return code == 113 and f'Could not find service "{service}"' in error


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


class Commands:
    def __init__(self, evidence):
        self.evidence = evidence
        self.cancellations = []

    def stop_child(self, name, process, reason):
        receipt = {
            "command": name, "pid": process.pid, "reason": reason,
            "terminateRequested": False, "killRequested": False,
            "processExited": False, "nativeCleanupConfirmed": False,
        }
        # A second ordinary signal must not leave a client holding a native VM
        # while the runner proceeds to remove only the reservation owner.
        handlers = {number: signal.getsignal(number) for number in (signal.SIGINT, signal.SIGTERM)}
        try:
            for number in handlers:
                signal.signal(number, signal.SIG_IGN)
            if process.poll() is None:
                receipt["terminateRequested"] = True
                try:
                    process.terminate()
                except ProcessLookupError:
                    pass
                try:
                    process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    receipt["killRequested"] = True
                    try:
                        process.kill()
                    except ProcessLookupError:
                        pass
                    process.wait(timeout=3)
            receipt["processExited"] = process.poll() is not None
        except BaseException as error:
            # Preserve the original interruption or timeout; this receipt makes
            # the bounded cleanup failure independently visible.
            receipt["cleanupError"] = type(error).__name__
        finally:
            for number, handler in handlers.items():
                signal.signal(number, handler)
            self.cancellations.append(receipt)
            try:
                (self.evidence / f"{name}.cleanup.json").write_text(json.dumps(receipt, indent=2) + "\n")
            except OSError:
                receipt["evidenceWriteFailed"] = True

    def run(self, name, args, timeout=50):
        # Only explicit, local argv. Preserve diagnostics even when a command fails.
        with (self.evidence / f"{name}.stdout").open("wb") as output, (self.evidence / f"{name}.stderr").open("wb") as error:
            process = subprocess.Popen(args, stdout=output, stderr=error)
            try:
                code = process.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                self.stop_child(name, process, "timeout")
                code = 124
            except BaseException:
                self.stop_child(name, process, "interrupted")
                raise
        return code, (self.evidence / f"{name}.stdout").read_text(errors="replace")

    def stderr(self, name):
        return (self.evidence / f"{name}.stderr").read_text(errors="replace")


def cleanup_owner(commands, binary, service, domain):
    shutdown_code, output = commands.run("shutdown", [str(binary), "case", service, "shutdown"])
    try:
        shutdown = result_from(output)
    except ValueError:
        shutdown = {"cleanupConfirmed": False, "referenceReleased": False}
    target = f"{domain}/{service}"
    commands.run("bootout", ["/bin/launchctl", "bootout", target])
    # Absence alone does not establish orderly native reference/interface release.
    absent_code, _ = commands.run("job-after", ["/bin/launchctl", "print", target])
    absent = job_absent(absent_code, commands.stderr("job-after"), service)
    confirmed = shutdown_code == 0 and shutdown.get("cleanupConfirmed") is True and shutdown.get("referenceReleased") is True
    return {"passed": confirmed and absent, "ownerReleaseConfirmed": confirmed, "jobAbsent": absent}


def execute(args):
    ipv4, ipv6 = dual_stack(args.ipv4, args.ipv6)
    domain = bootstrap_domain(args.bootstrap_domain, os.geteuid())
    binary = regular_file(args.binary)
    seed = {name: regular_file(Path(args.seed) / name) for name in SEED_FILES}
    service = SERVICE_PREFIX + str(uuid.uuid4())
    plan = {
        "schemaVersion": 1, "service": service, "bootstrapDomain": domain,
        "mode": "hostOnly", "dhcp": False, "ipv4": ipv4, "ipv6": ipv6,
        "cases": CASES, "existingNetworksTouched": False,
    }
    if args.dry_run:
        print(json.dumps(plan, indent=2))
        return 0
    if not args.confirm_unused_subnets or not args.confirm_stopped_seed:
        raise ValueError("live run requires --confirm-unused-subnets and --confirm-stopped-seed")
    if platform.system() != "Darwin" or int(platform.mac_ver()[0].split(".")[0]) < 26:
        raise ValueError("native run requires macOS 26 or newer")
    os.umask(0o077)
    # Resolve the newly allocated directory, never an arbitrary cleanup target.
    evidence = Path(tempfile.mkdtemp(prefix="container-vmnet-probe-")).resolve()
    print(f"Evidence: {evidence}", flush=True)
    commands = Commands(evidence)
    plan["binarySHA256"] = sha256(binary)
    (evidence / "plan.json").write_text(json.dumps(plan, indent=2) + "\n")
    clones = {}
    for case in CASES:
        if not case.endswith("-vz"):
            continue
        disposable = evidence / f"seed-{case}"
        disposable.mkdir(mode=0o700)
        for name, source in seed.items():
            # APFS clone only: never boot or rewrite the supplied source image.
            code, _ = commands.run(f"clone-{case}-{name}", ["/bin/cp", "-c", str(source), str(disposable / name)], timeout=120)
            if code != 0:
                raise ValueError(f"APFS clone failed for {name}; evidence retained at {evidence}")
            (disposable / name).chmod(0o600)
        (disposable / ".probe-seed").write_text("vmnet-native-probe-v1\n")
        clones[case] = disposable
    plist = evidence / "owner.plist"
    plist.write_bytes(plistlib.dumps(make_job(service, binary, evidence, ipv4, ipv6)))
    commands.run("host-build", ["/usr/bin/sw_vers"])
    commands.run("signature", ["/usr/bin/codesign", "-d", "--entitlements", ":-", str(binary)])
    verification, _ = commands.run("signature-verify", ["/usr/bin/codesign", "--verify", "--strict", str(binary)])
    if verification != 0:
        raise ValueError(f"binary signature verification failed; evidence retained at {evidence}")
    cases = []
    configured = False
    try:
        code, _ = commands.run("bootstrap", ["/bin/launchctl", "bootstrap", domain, str(plist)])
        if code != 0:
            raise ValueError("temporary owner bootstrap failed")
        # One request only; LaunchOnlyOnce also prevents implicit recreation.
        code, output = commands.run("owner-ready", [str(binary), "case", service, "status"], timeout=45)
        if code != 0:
            raise ValueError("temporary owner did not become ready")
        status = result_from(output)
        owner_pid = status["ownerPID"]
        network = status["network"]
        actual_v4 = ipaddress.IPv4Address(network["ipv4Address"])
        if (
            actual_v4 not in ipaddress.IPv4Network(ipv4)
            or network["ipv4Mask"] != "255.255.255.0"
            or network["ipv6Prefix"] != ipv6.split("/")[0]
            or network["ipv6PrefixLength"] != 64
        ):
            raise ValueError("reserved dual-stack configuration differs from request")
        configured = True
        for index, case in enumerate(CASES, start=1):
            argv = [str(binary), "case", service, case]
            if case.endswith("-vz"):
                argv.append(str(clones[case]))
            code, output = commands.run(f"case-{index}-{case}", argv, timeout=50)
            result = result_from(output)
            result["case"] = case
            result["index"] = index
            if code != 0:
                result["passed"] = False
            if getattr(commands, "cancellations", []):
                result["cleanupConfirmed"] = False
                result.setdefault("error", "clientTerminationInterruptedCleanup")
            cases.append(result)
            if result.get("ownerPID") != owner_pid:
                result["passed"] = False
                result["error"] = "ownerIdentityChangedOrMissing"
                break
            # A rejected interface can be compared further only if it was cleaned.
            if result.get("cleanupConfirmed") is not True:
                break
    finally:
        # Once cleanup starts, a second ordinary signal must not skip bootout.
        signal.signal(signal.SIGINT, signal.SIG_IGN)
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        cleanup = cleanup_owner(commands, binary, service, domain)
        cleanup["cancelledCommands"] = getattr(commands, "cancellations", [])
        # Process exit establishes that no client remains, but cannot attest to
        # native stop callbacks interrupted by termination or forced killing.
        if cleanup["cancelledCommands"]:
            cleanup["passed"] = False
        summary = checked_summary(cases, cleanup, configured=configured)
        (evidence / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
        # Retain all evidence and disposable files on failure, but no live test job.
        # Successful cleanup removes only the three cloned files and our marker.
        if summary["passed"]:
            for disposable in clones.values():
                for name in (*SEED_FILES, ".probe-seed"):
                    (disposable / name).unlink()
                disposable.rmdir()
        print(json.dumps(summary, indent=2), flush=True)
    return 0 if summary["passed"] else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True, help="signed standalone probe executable")
    parser.add_argument("--seed", required=True, help="stopped VM seed containing HardwareModel.bin, AuxiliaryStorage and Disk.img")
    parser.add_argument("--ipv4", required=True)
    parser.add_argument("--ipv6", required=True)
    parser.add_argument("--bootstrap-domain", required=True)
    parser.add_argument("--confirm-unused-subnets", action="store_true")
    parser.add_argument("--confirm-stopped-seed", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    def interrupted(_number, _frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, interrupted)
    try:
        return execute(args)
    except (ValueError, OSError, KeyError, KeyboardInterrupt) as error:
        print(f"probe failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
