#!/usr/bin/env python3
"""Private offline layer-depth fixtures; never operates on runtime-owned images."""

import argparse
import base64
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import time

import image

BLOCK = 1 << 20
DEPTHS = (2, 3, 5, 9)
RESERVE = 40 << 30


def read_file(path):
    stream = image.regular(path).open("rb")
    fcntl.fcntl(stream.fileno(), fcntl.F_NOCACHE, 1)
    return stream


def disk_size(path):
    size = image.regular(path).stat().st_size
    image.require(0 < size <= 300 << 30 and size % BLOCK == 0, "unsupported fixture size")
    return size


def scan(base, reference, output):
    image.require(not output.exists(), "diff receipt already exists")
    size = disk_size(base)
    image.require(size == disk_size(reference), "fixture sizes differ")
    image.idle([base, reference])
    stamps = [image.stamp(base), image.stamp(reference)]
    changed = []
    hashes = [hashlib.sha256(), hashlib.sha256()]
    started = time.monotonic()
    with read_file(base) as left, read_file(reference) as right:
        for offset in range(0, size, BLOCK):
            a, b = left.read(BLOCK), right.read(BLOCK)
            image.require(len(a) == len(b) == BLOCK, "short fixture read")
            hashes[0].update(a)
            hashes[1].update(b)
            if a != b:
                changed.append(offset)
            if (offset + BLOCK) % (32 << 30) == 0:
                print(json.dumps({"stage": "scanProgress", "bytes": offset + BLOCK}), flush=True)
    image.require(stamps == [image.stamp(base), image.stamp(reference)], "input changed while scanning")
    receipt = {"blockBytes": BLOCK, "logicalBytes": size, "changedOffsets": changed,
               "inputStamps": stamps, "sha256": [h.hexdigest() for h in hashes],
               "seconds": time.monotonic() - started}
    image.write_json(output, receipt)
    print(json.dumps({"stage": "diffScanned", "changedBytes": len(changed) * BLOCK,
                      "seconds": receipt["seconds"]}), flush=True)


def validate_device(info, size):
    image.require(info.get("BusProtocol") == "Disk Image" and info.get("Internal") is False
                  and info.get("VirtualOrPhysical") == "Virtual" and info.get("WholeDisk") is True
                  and info.get("Size") == size and not info.get("MountPoint"),
                  "refusing a non-fixture or mounted device")


@contextlib.contextmanager
def attached(base, shadows, size, readonly=False):
    existing = [base, *(p for p in shadows if p.exists())]
    image.idle(existing)
    command = ["/usr/sbin/diskutil", "image", "attach", "--noMount", "--plist"]
    if readonly:
        command.append("--readOnly")
    command.append(str(base))
    for path in shadows:
        command.extend(["--shadow", str(path)])
    response = plistlib.loads(subprocess.check_output(command, timeout=90))
    entities = response.get("system-entities", [])
    whole = [x["dev-entry"].removeprefix("/dev/") for x in entities
             if re.fullmatch(r"(?:/dev/)?disk[0-9]+", x.get("dev-entry", ""))]
    candidates = []
    # APFS exposes additional synthesized whole devices for its containers.
    # Only the backing image has the exact logical size of the input disk.
    for name in whole:
        info = plistlib.loads(subprocess.check_output(["/usr/sbin/diskutil", "info", "-plist", "/dev/" + name]))
        try:
            validate_device(info, size)
        except ValueError:
            continue
        candidates.append(name)
    image.require(len(candidates) == 1, "cannot identify attached fixture device; inspect host attachments")
    device = "/dev/" + candidates[0]
    inventory = plistlib.loads(subprocess.check_output(["/usr/bin/hdiutil", "info", "-plist"]))
    owned = [item for item in inventory.get("images", []) if item.get("image-path") == str(base)]
    image.require(len(owned) == 1 and any(x.get("dev-entry") == device for x in owned[0].get("system-entities", [])),
                  "attached device does not match the private source")
    try:
        image.require(not any(x.get("mount-point") for x in owned[0].get("system-entities", [])),
                      "fixture filesystem unexpectedly mounted")
        yield "/dev/r" + candidates[0]
    finally:
        subprocess.run(["/usr/sbin/diskutil", "eject", device], check=True, capture_output=True, timeout=90)
    image.idle(existing)


def build(base, reference, diff_path, depth, root):
    build_started = time.monotonic()
    image.require(depth in DEPTHS, "unsupported test depth")
    diff = json.loads(image.regular(diff_path).read_text())
    image.require(diff["inputStamps"] == [image.stamp(base), image.stamp(reference)], "diff inputs changed")
    size = disk_size(base)
    image.require(size == disk_size(reference) == diff["logicalBytes"] and diff["blockBytes"] == BLOCK,
                  "diff dimensions differ")
    offsets = diff["changedOffsets"]
    image.require(len(offsets) >= depth - 1 and offsets == sorted(set(offsets))
                  and all(type(x) is int and 0 <= x < size and x % BLOCK == 0 for x in offsets),
                  "invalid or insufficient changed blocks")
    image.capacity(root.parent, RESERVE + len(offsets) * BLOCK * 2)
    image.private_dir(root)
    image.clone(base, root / "base.img", 0o400)
    layers = []
    counts = []
    with image.locked(root), read_file(reference) as source:
        for layer in range(depth - 1):
            top = root / f"layer-{layer + 1:02d}.asif"
            previous = [image.stamp(p) for p in [root / "base.img", *layers]]
            subset = offsets[layer::depth - 1]
            with attached(root / "base.img", [*layers, top], size) as device:
                fd = os.open(device, os.O_RDWR)
                try:
                    for offset in subset:
                        data = os.pread(source.fileno(), BLOCK, offset)
                        image.require(len(data) == BLOCK, "short source read")
                        image.require(os.pwrite(fd, data, offset) == BLOCK, "short fixture write")
                    os.fsync(fd)
                finally:
                    os.close(fd)
            image.require(previous == [image.stamp(p) for p in [root / "base.img", *layers]],
                          "writing child modified a parent")
            layers.append(top)
            top.chmod(0o400 if layer < depth - 2 else 0o600)
            counts.append(len(subset))
            print(json.dumps({"stage": "layerPrepared", "depth": depth, "layer": layer + 1,
                              "blocks": len(subset), "allocatedBytes": top.stat().st_blocks * 512}), flush=True)
        expected = hashlib.sha256()
        started = time.monotonic()
        with attached(root / "base.img", layers, size, readonly=True) as device:
            fd = os.open(device, os.O_RDONLY)
            try:
                for offset in range(0, size, BLOCK):
                    actual = os.pread(fd, BLOCK, offset)
                    image.require(len(actual) == BLOCK, f"short composed disk read at {offset}")
                    expected.update(actual)
                    if (offset + BLOCK) % (32 << 30) == 0:
                        print(json.dumps({"stage": "verifyProgress", "depth": depth, "bytes": offset + BLOCK}), flush=True)
            finally:
                os.close(fd)
        image.require(expected.hexdigest() == diff["sha256"][1], "composed disk digest differs")
        image.require(diff["inputStamps"] == [image.stamp(base), image.stamp(reference)], "reference changed")
        config = {"backend": "asif", "readOnly": ["base.img", *(p.name for p in layers[:-1])], "writable": layers[-1].name}
        image.write_json(root / "runtime.json", config)
        receipt = {"layerCount": depth, "logicalBytes": size, "sha256": expected.hexdigest(),
                   "blocksPerOverlay": counts, "allocatedBytes": [p.stat().st_blocks * 512 for p in layers],
                   "validationSeconds": time.monotonic() - started,
                   "buildSeconds": time.monotonic() - build_started,
                   "files": {p.name: image.stamp(p) for p in [root / "base.img", *layers]}}
        image.write_json(root / "chain.json", receipt)
        print(json.dumps({"stage": "chainVerified", **receipt}), flush=True)


def measure(chain, identity, instance, runner, script):
    config = json.loads(image.regular(chain / "runtime.json").read_text())
    receipt = json.loads(image.regular(chain / "chain.json").read_text())
    depth = receipt["layerCount"]
    names = [*config["readOnly"], config["writable"]]
    image.require(depth in DEPTHS and len(names) == depth and len(set(names)) == depth,
                  "invalid fixture depth")
    image.require(set(names) == set(receipt["files"])
                  and all(Path(n).name == n and n not in ("", ".", "..") for n in names), "invalid fixture inventory")
    with image.locked(chain):
        image.require(receipt["files"] == {n: image.stamp(image.regular(chain / n)) for n in names}, "fixture changed")
        image.idle([*(chain / n for n in names), *(identity / n for n in image.IDENTITY)])
        image.capacity(instance.parent, RESERVE)
        image.private_dir(instance)
        for name in names:
            image.clone(chain / name, instance / name, 0o600 if name == config["writable"] else 0o400)
        for name in image.IDENTITY:
            image.clone(identity / name, instance / name)
        image.write_json(instance / "runtime.json", config)
        log = instance / "run.jsonl"
        with log.open("xb") as output, (instance / "run.stderr").open("xb") as errors:
            start = time.time()
            result = subprocess.run([str(runner), "run-depth", str(instance), str(script)],
                                    stdout=output, stderr=errors, timeout=1560)
        rows = [json.loads(line) for line in log.read_text().splitlines()]
        stopped = any(r.get("stage") == "vmStopped" and r.get("stopped") for r in rows)
        image.require(result.returncode == 0 and stopped, "depth VM failed; preserve instance and inspect log")
        image.idle([instance / config["writable"], instance / "AuxiliaryStorage"])
        output = "".join(base64.b64decode(r["data"]).decode() for r in rows if r.get("stage") == "stdout")
        ready = [r["time"] for r in rows if r.get("stage") == "stdout"
                 and "DEPTH_ADMIN_READY" in base64.b64decode(r["data"]).decode()]
        started = [r["time"] for r in rows if r.get("stage") == "starting"]
        boot = [r for r in rows if r.get("stage") == "vmStarted"]
        image.require(len(ready) == len(started) == len(boot) == 1 and boot[0]["hostCaching"] == "uncached"
                      and boot[0]["layerCount"] == depth and boot[0]["networkDevices"] == 0, "invalid VM timing or cache conditions")
        results = [json.loads(line) for line in output.splitlines() if line.startswith("{")]
        reads = [r for r in results if "queueDepth" in r]
        builds = [r for r in results if r.get("operation") == "measure"]
        image.require(len(reads) == 4 and [r["queueDepth"] for r in reads] == [1, 16, 1, 16]
                      and all(r["verified"] and r["guestNoCache"] for r in reads)
                      and len(builds) == 1 and builds[0]["binary"]["roundTripPassed"], "missing benchmark evidence")
        result = {"layerCount": depth, "firstAdminExecSeconds": ready[0] - started[0],
                  "launchToFirstAdminExecSeconds": ready[0] - start, "randomReads": reads, "xcode": builds[0],
                  "inputDiskSHA256": receipt["sha256"], "vmStopped": True, "instance": str(instance)}
        image.write_json(instance / "result.json", result)
        image.require(receipt["files"] == {n: image.stamp(chain / n) for n in names}, "sample changed its source fixture")
        print(json.dumps(result), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    p = commands.add_parser("scan")
    p.add_argument("base", type=Path)
    p.add_argument("reference", type=Path)
    p.add_argument("output", type=Path)
    p = commands.add_parser("build")
    p.add_argument("base", type=Path)
    p.add_argument("reference", type=Path)
    p.add_argument("diff", type=Path)
    p.add_argument("depth", type=int, choices=DEPTHS)
    p.add_argument("output", type=Path)
    p = commands.add_parser("measure")
    for name in ("chain", "identity", "instance", "runner", "script"):
        p.add_argument(name, type=Path)
    args = parser.parse_args()
    os.umask(0o077)
    if args.command == "scan":
        scan(args.base, args.reference, args.output)
    elif args.command == "build":
        build(args.base, args.reference, args.diff, args.depth, args.output)
    else:
        measure(args.chain, args.identity, args.instance, args.runner, args.script)


if __name__ == "__main__":
    main()
