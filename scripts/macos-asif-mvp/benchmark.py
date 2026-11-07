#!/usr/bin/env python3
"""Run inside the dedicated macOS guest as its admin user, without network."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import resource
import shutil
import subprocess
import tarfile
import time

REVISION = "f8745da6ff1ad1e7bab384bd1f9d742439278e99"
SOURCE_SHA256 = "4b0bd1f0cfb25e61b9103c35f27395530ff5b4c0d2513a00fd745849e85ea52c"
ROOT = Path("/Users/admin/ASIFImageMVP")
SOURCE = ROOT / "source" / ("zstd-" + REVISION)
BUILD = ROOT / "build"


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def timed(command, name):
    before = resource.getrusage(resource.RUSAGE_CHILDREN)
    start = time.monotonic()
    with (ROOT / (name + ".log")).open("w") as output:
        result = subprocess.run(command, stdout=output, stderr=subprocess.STDOUT, timeout=900)
    after = resource.getrusage(resource.RUSAGE_CHILDREN)
    if result.returncode:
        raise RuntimeError("command failed; inspect " + name + ".log in the guest")
    return {"wallSeconds": time.monotonic() - start, "userSeconds": after.ru_utime - before.ru_utime,
            "systemSeconds": after.ru_stime - before.ru_stime}


def binary():
    path = BUILD / "Products/Release/zstd"
    assert path.is_file()
    version = subprocess.check_output([str(path), "--version"], text=True).strip()
    # Exercise the actual built binary on deterministic source contents.
    data = (SOURCE / "lib/compress/zstd_compress.c").read_bytes()
    compressed = subprocess.check_output([str(path), "-q", "-c"], input=data)
    assert subprocess.check_output([str(path), "-q", "-d", "-c"], input=compressed) == data
    return {"version": version, "sha256": sha(path), "roundTripPassed": True}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=["prepare", "measure", "verify"])
    parser.add_argument("--sample", type=int, default=0)
    args = parser.parse_args()
    assert os.getuid() == 501 and 0 <= args.sample <= 30
    assert shutil.disk_usage(ROOT.parent).free > 10 << 30
    os.environ["PATH"] = "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    ROOT.mkdir(mode=0o700, exist_ok=True)
    result = {"operation": args.operation, "sample": args.sample, "sourceRevision": REVISION}
    if args.operation == "prepare":
        archive = Path("/Users/admin/MVPInput/zstd-1.5.7.tar.gz")
        assert sha(archive) == SOURCE_SHA256 and not SOURCE.exists()
        SOURCE.parent.mkdir()
        with tarfile.open(archive) as data:
            data.extractall(SOURCE.parent, filter="data")
        result["configure"] = timed([
            "/opt/homebrew/bin/cmake", "-S", str(SOURCE / "build/cmake"), "-B", str(BUILD), "-G", "Xcode",
            "-DCMAKE_RUNTIME_OUTPUT_DIRECTORY=" + str(BUILD / "Products"),
            "-DZSTD_BUILD_PROGRAMS=ON", "-DZSTD_BUILD_TESTS=ON"], "configure")
        result["xcode"] = subprocess.check_output(["/usr/bin/xcodebuild", "-version"], text=True).strip()
    elif args.operation == "measure":
        for action in ["clean", "incremental", "reuse"]:
            if action == "incremental":
                with (SOURCE / "lib/compress/zstd_compress.c").open("a") as stream:
                    stream.write("\n/* image benchmark iteration " + str(args.sample) + " */\n")
            result[action] = timed([
                "/usr/bin/xcodebuild", "-project", str(BUILD / "zstd.xcodeproj"), "-target", "ALL_BUILD",
                "-configuration", "Release", "-jobs", "4", "CODE_SIGNING_ALLOWED=NO",
                "SYMROOT=" + str(BUILD / "Products"), "OBJROOT=" + str(BUILD / "Objects"),
                *(["clean", "build"] if action == "clean" else ["build"])], action + "-" + str(args.sample))
        result["binary"] = binary()
        result["sourceFileSHA256"] = sha(SOURCE / "lib/compress/zstd_compress.c")
        (ROOT / "expected.json").write_text(json.dumps(result))
    else:
        expected = json.loads((ROOT / "expected.json").read_bytes())
        result["binary"] = binary()
        result["sourceFileSHA256"] = sha(SOURCE / "lib/compress/zstd_compress.c")
        assert result["binary"] == expected["binary"]
        assert result["sourceFileSHA256"] == expected["sourceFileSHA256"]
        result["imageContentPreserved"] = True
    (ROOT / (args.operation + "-" + str(args.sample) + ".json")).write_text(json.dumps(result, indent=2))
    print(json.dumps(result), flush=True)


if __name__ == "__main__":
    main()
