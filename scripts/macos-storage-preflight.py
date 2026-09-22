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

"""Fail-closed, node-local admission for bounded storage validation commands.

Never deletes images, changes kubelet configuration, or invokes RemoveImage.
The optional command runs once, under a cooperative lock, after live checks.
"""

import argparse
import fcntl
import json
import math
import os
from pathlib import Path
import platform
import re
import stat
import subprocess
import sys
import time


class Rejected(ValueError):
    pass


def integer(value, name, minimum=0):
    if type(value) is not int or value < minimum:
        raise Rejected(f"{name} must be an integer >= {minimum}")
    return value


def validate_config(evidence, node, uid, now):
    if not isinstance(evidence, dict):
        raise Rejected("kubelet evidence must be an object")
    if evidence.get("nodeName") != node or evidence.get("nodeUID") != uid:
        raise Rejected("kubelet evidence node identity mismatch")
    observed = evidence.get("observedAtUnix")
    if type(observed) not in (int, float) or not math.isfinite(observed) or not 0 <= now - observed <= 120:
        raise Rejected("kubelet evidence must be collected within the last 120 seconds")
    configz = evidence.get("configz")
    if not isinstance(configz, dict) or not isinstance(configz.get("kubeletconfig"), dict):
        raise Rejected("kubelet configuration is missing")
    config = configz["kubeletconfig"]
    high = integer(config.get("imageGCHighThresholdPercent"), "image GC high threshold", 1)
    low = integer(config.get("imageGCLowThresholdPercent"), "image GC low threshold")
    if not 0 <= low < high <= 100:
        raise Rejected("invalid image GC threshold pair")
    return high


def headroom(total, available, budget, high, margin):
    integer(total, "capacity", 1)
    integer(available, "available bytes")
    integer(budget, "peak additional bytes", 1)
    integer(high, "image GC high threshold", 1)
    integer(margin, "margin percentage points", 5)
    if available > total or high > 100 or margin >= high:
        raise Rejected("invalid filesystem or threshold values")
    projected = total - available + budget
    limit = total * (high - margin) // 100
    # Equality is rejected so callers retain headroom beyond the reserved margin.
    if projected >= limit:
        raise Rejected(
            f"insufficient headroom: projected={projected}, limit={limit}, "
            f"available={available}, peakAdditional={budget}"
        )
    return {"capacityBytes": total, "availableBytes": available,
            "peakAdditionalBytes": budget, "projectedUsedBytes": projected,
            "admissionLimitBytes": limit}


def validate_images(payload, required_ids):
    if not isinstance(payload, dict):
        raise Rejected("CRI image response must be an object")
    images = payload.get("images")
    if not isinstance(images, list) or not images:
        raise Rejected("CRI image listing missing or empty")
    inventory = []
    for image in images:
        if not isinstance(image, dict) or not isinstance(image.get("id"), str) or not image["id"]:
            raise Rejected("CRI image has no identity")
        tags = image.get("repoTags", [])
        digests = image.get("repoDigests", [])
        if not isinstance(tags, list) or not isinstance(digests, list) or not all(
            isinstance(value, str) for value in tags + digests
        ):
            raise Rejected("invalid CRI image references")
        inventory.append({"id": image["id"], "repoTags": sorted(tags),
                          "repoDigests": sorted(digests), "pinned": image.get("pinned") is True})
    for digest in required_ids:
        if not re.fullmatch(r"sha256:[0-9a-f]{64}", digest):
            raise Rejected("required image must be a complete sha256 image ID")
        matches = [image for image in inventory if image["id"] == digest]
        if not matches or not all(image["pinned"] for image in matches):
            raise Rejected(f"required image missing or not pinned by installed CRI: {digest}")
    return sorted(inventory, key=lambda image: json.dumps(image, sort_keys=True))


def cri_json(args, operation):
    result = subprocess.run(
        [args.crictl, "--runtime-endpoint", args.endpoint, "--image-endpoint", args.endpoint,
         "--timeout", "15s", operation, "-o", "json"],
        check=True, capture_output=True, text=True, timeout=20,
    )
    return json.loads(result.stdout)


def inspect(args, high):
    payload = cri_json(args, "imagefsinfo")
    if not isinstance(payload, dict):
        raise Rejected("CRI filesystem response must be an object")
    filesystems = payload.get("imageFilesystems")
    if not isinstance(filesystems, list) or not filesystems:
        raise Rejected("CRI did not report its image filesystem")
    roots = list(args.storage_root)
    for fs in filesystems:
        if not isinstance(fs, dict) or not isinstance(fs.get("fsId"), dict):
            raise Rejected("CRI image filesystem identity is missing")
        root = fs.get("fsId", {}).get("mountpoint")
        if not isinstance(root, str) or not os.path.isabs(root):
            raise Rejected("CRI image filesystem mountpoint is missing")
        roots.append(root)
    checks = []
    # Apply the whole remaining budget to each volume conservatively. This also
    # avoids treating APFS clones as free or double-counting shared free space.
    for root in sorted({str(Path(path).resolve(strict=True)) for path in roots}):
        if not Path(root).is_dir():
            raise Rejected("storage roots must be existing directories")
        stats = os.statvfs(root)
        checks.append({"path": root, **headroom(
            stats.f_blocks * stats.f_frsize, stats.f_bavail * stats.f_frsize,
            args.peak_additional_bytes, high, args.margin_percent,
        )})
    return {"filesystems": checks, "images": validate_images(cri_json(args, "images"), args.require_pinned)}


def guarded_run(args, high, inspect_fn=inspect, run_fn=subprocess.run, lock_fd=None):
    before = inspect_fn(args, high)
    print(json.dumps({"phase": "admitted", **before}), flush=True)
    if not args.command:
        return 0
    try:
        # Keep the lock held by the immediate child even if this wrapper dies.
        result = run_fn(args.command, check=False, pass_fds=() if lock_fd is None else (lock_fd,))
    finally:
        # Even a failed command needs postflight. Do not repair unexpected changes.
        after = inspect_fn(args, high)
        print(json.dumps({"phase": "postflight", **after}), flush=True)
        if before["images"] != after["images"]:
            raise Rejected("CRI image inventory changed during validation; stop further samples")
    return result.returncode


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--node", required=True)
    parser.add_argument("--node-uid", required=True)
    parser.add_argument("--kubelet-evidence", required=True)
    parser.add_argument("--endpoint", required=True, help="Installed CRI Unix endpoint")
    parser.add_argument("--crictl", default="crictl")
    parser.add_argument("--storage-root", action="append", required=True, help="Existing test disk/artifact directories")
    parser.add_argument("--peak-additional-bytes", type=int, required=True, help="Conservative remaining peak, including CoW and copies")
    parser.add_argument("--margin-percent", type=int, default=5)
    parser.add_argument("--require-pinned", action="append", required=True, help="Required full sha256 image ID; repeatable")
    parser.add_argument("--lock-file", required=True, help="Same administrator-owned lock path for all validation commands")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    try:
        if platform.system() != "Darwin" or platform.node() != args.node:
            raise Rejected("run on the specified Mac host, not a master or guest")
        if not args.endpoint.startswith("unix:///"):
            raise Rejected("a local absolute CRI Unix endpoint is required")
        if any(not os.path.isabs(path) for path in args.storage_root + [args.lock_file]):
            raise Rejected("storage and lock paths must be absolute")
        if args.command[:1] == ["--"]:
            args.command = args.command[1:]
        with open(args.kubelet_evidence, encoding="utf-8") as source:
            evidence = json.load(source)
        # Check evidence only after obtaining the lock; stale evidence never queues work.
        fd = os.open(args.lock_file, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        try:
            lock_stat = os.fstat(fd)
            if not stat.S_ISREG(lock_stat.st_mode) or lock_stat.st_uid != os.geteuid() or lock_stat.st_mode & 0o022:
                raise Rejected("lock must be a regular file owned by this user, not group/world writable")
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            high = validate_config(evidence, args.node, args.node_uid, time.time())
            return guarded_run(args, high, lock_fd=fd)
        finally:
            os.close(fd)
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        # Subprocess output can contain configuration details; report no raw output.
        print(json.dumps({"phase": "blocked", "reason": str(error)}), file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
