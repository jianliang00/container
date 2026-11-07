#!/usr/bin/env python3
"""Private, offline macOS image experiment. Not a production runtime backend."""

import argparse
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import tempfile
import time

FORMAT = "container.macos.asif-mvp.v1"
MEDIA = "application/vnd.container.macos.asif-mvp"
IDENTITY = ["HardwareModel.bin", "MachineIdentifier.bin", "AuxiliaryStorage"]
MAX_IMAGE_BYTES = 300 << 30


def require(ok, message):
    if not ok:
        raise ValueError(message)


def digest(path):
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(4 << 20), b""):
            h.update(block)
    return h.hexdigest()


def encoded(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


def write_json(path, value):
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as stream:
        temporary = Path(stream.name)
        stream.write(encoded(value) + b"\n")
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)


def regular(path):
    require(path.absolute() == path.resolve(), "symlink paths are not supported")
    require(stat.S_ISREG(path.stat().st_mode), "expected a regular file")
    return path


def stamp(path):
    s = regular(path).stat()
    return [s.st_dev, s.st_ino, s.st_size, s.st_mtime_ns, s.st_ctime_ns, s.st_mode]


def clone(source, destination, mode=0o600):
    require(not destination.exists(), "destination already exists")
    subprocess.run(["/bin/cp", "-c", str(regular(source)), str(destination)], check=True)
    destination.chmod(mode)


def private_dir(path):
    require(path.absolute() == path.resolve(), "directory path must be canonical")
    path.mkdir(mode=0o700)


def capacity(path):
    require(shutil.disk_usage(path).free >= 20 << 30, "requires 20 GiB free before operation")


def idle(paths):
    result = subprocess.run(["/usr/sbin/lsof", "-t", "--", *map(str, paths)], capture_output=True)
    require(result.returncode == 1 and not result.stdout and not result.stderr,
            "image has an open handle, or lsof could not verify ownership")


@contextlib.contextmanager
def locked(root):
    s = root.stat()
    require(root.absolute() == root.resolve() and s.st_uid == os.getuid() and s.st_mode & 0o077 == 0,
            "instance must be a private, owned directory")
    lock = os.open(root / ".lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield
    finally:
        os.close(lock)


def load(root):
    state = json.loads(regular(root / "instance.json").read_bytes())
    require(state["format"] == FORMAT, "unknown instance format")
    config = state["runtime"]
    expected = [] if config["backend"] == "raw" else ["base.img"]
    if len(config["readOnly"]) == 2:
        expected.append("parent.asif")
    require(config["backend"] in ("raw", "asif") and config["readOnly"] == expected,
            "invalid layer order or depth")
    require(config["writable"] == ("Disk.img" if config["backend"] == "raw" else "writable.asif"),
            "invalid writable layer")
    for name in [*config["readOnly"], config["writable"], *IDENTITY]:
        regular(root / name)
    require(set(state["immutable"]) == set(config["readOnly"]), "immutable inventory mismatch")
    for name, record in state["immutable"].items():
        require((root / name).stat().st_mode & 0o222 == 0, "immutable layer is writable")
        require(stamp(root / name) == record["stamp"], "immutable layer changed; re-import image")
    return state


def finish_instance(root, config, runner, new_identity=False, verified=None):
    write_json(root / "runtime.json", config)
    if config["backend"] == "asif":
        subprocess.run([runner, "create-overlay", str(root)], check=True)
        (root / config["writable"]).chmod(0o600)
    if new_identity:
        subprocess.run([runner, "new-identity", str(root)], check=True)
    records = {name: {"sha256": (verified or {}).get(name) or digest(root / name), "stamp": stamp(root / name)}
               for name in config["readOnly"]}
    write_json(root / "instance.json", {"format": FORMAT, "runtime": config,
                                       "immutable": records, "sealAllowed": True})


def initialize(args):
    source, root = args.source, args.instance
    files = [source / "Disk.img", *(source / name for name in IDENTITY)]
    for path in files:
        regular(path)
    idle(files)
    capacity(root.parent)
    private_dir(root)
    for name in IDENTITY:
        clone(source / name, root / name)
    if args.backend == "raw":
        clone(source / "Disk.img", root / "Disk.img")
        config = {"backend": "raw", "readOnly": [], "writable": "Disk.img"}
    else:
        clone(source / "Disk.img", root / "base.img", 0o400)
        config = {"backend": "asif", "readOnly": ["base.img"], "writable": "writable.asif"}
    finish_instance(root, config, args.runner)


def run(args):
    root = args.instance
    with locked(root):
        state = load(root)
        config = state["runtime"]
        idle([root / name for name in [*config["readOnly"], config["writable"], *IDENTITY]])
        capacity(root)
        state["sealAllowed"] = False
        write_json(root / "instance.json", state)
        write_json(root / "runtime.json", config)
        command = [args.runner, "run", str(root), str(regular(args.script))]
        if args.inputs:
            require(args.inputs.is_dir() and args.inputs.absolute() == args.inputs.resolve(),
                    "input directory must be canonical")
            command.append(str(args.inputs))
        started = time.monotonic()
        # Preserve the complete bounded guest output and stop acknowledgement.
        log = root / ("run-" + str(time.time_ns()) + ".jsonl")
        with log.open("xb") as output, log.with_suffix(".stderr").open("xb") as errors:
            result = subprocess.run(command, stdout=output, stderr=errors, timeout=1560)
        rows = [json.loads(line) for line in log.read_bytes().splitlines()]
        stopped = any(row.get("stage") == "vmStopped" and row.get("stopped") for row in rows)
        success = result.returncode == 0 and stopped
        idle([root / config["writable"], root / "AuxiliaryStorage"])
        state["sealAllowed"] = success
        write_json(root / "instance.json", state)
        print(json.dumps({"passed": success, "seconds": time.monotonic() - started, "log": str(log)}), flush=True)
        require(success, "guest command failed; inspect the private run log")


def descriptor(path, media):
    return {"mediaType": media, "digest": "sha256:" + digest(path), "size": path.stat().st_size}


def check_descriptor(value):
    require(isinstance(value, dict) and re.fullmatch(r"sha256:[0-9a-f]{64}", value.get("digest", "")),
            "invalid OCI digest")
    require(type(value.get("size")) is int and 0 <= value["size"] <= MAX_IMAGE_BYTES,
            "invalid OCI object size")


def blob(layout, value):
    check_descriptor(value)
    path = regular(layout / "blobs/sha256" / value["digest"][7:])
    require(path.stat().st_size == value["size"] and digest(path) == value["digest"][7:],
            "OCI blob checksum mismatch")
    return path


def metadata(layout, value, media):
    raw = encoded(value)
    h = hashlib.sha256(raw).hexdigest()
    path = layout / "blobs/sha256" / h
    if not path.exists():
        path.write_bytes(raw)
    return {"mediaType": media, "digest": "sha256:" + h, "size": len(raw)}


def compress_cached(path, cache, raw_digest, kind):
    cached = cache / (raw_digest + ".json")
    if cached.exists():
        record = json.loads(cached.read_bytes())
        compressed = cache / (raw_digest + ".zst")
        require(stamp(compressed) == record["stamp"], "compressed cache changed")
        require(record["descriptor"]["mediaType"] == MEDIA + "." + kind + "+zstd", "cache type mismatch")
        return compressed, record["descriptor"], True
    compressed = cache / (raw_digest + ".zst")
    require(not compressed.exists(), "incomplete cache entry; use a fresh cache directory")
    with compressed.open("xb") as out:
        subprocess.run(["zstd", "-q", "-3", "-T1", "-c", str(path)], stdout=out, check=True)
        out.flush()
        os.fsync(out.fileno())
    compressed.chmod(0o400)
    desc = descriptor(compressed, MEDIA + "." + kind + "+zstd")
    write_json(cached, {"stamp": stamp(compressed), "descriptor": desc})
    return compressed, desc, False


def commit(args):
    root, layout, cache = args.instance, args.image, args.cache
    with locked(root), locked(cache):
        started = time.monotonic()
        state = load(root)
        config = state["runtime"]
        require(state["sealAllowed"], "cannot seal an instance after an unverified run")
        require(len(config["readOnly"]) <= 1, "MVP permits one derived image layer; flatten before further commits")
        names = [*config["readOnly"], config["writable"], *IDENTITY]
        idle([root / name for name in names])
        capacity(layout.parent)
        private_dir(layout)
        (layout / "blobs/sha256").mkdir(parents=True)
        records, new_bytes, reused_bytes = [], 0, 0
        for i, name in enumerate(names):
            path = root / name
            before = stamp(path)
            raw_digest = state["immutable"].get(name, {}).get("sha256") or digest(path)
            kind = "identity" if name in IDENTITY else "raw" if i == 0 else "asif"
            compressed, desc, reused = compress_cached(path, cache, raw_digest, kind)
            destination = layout / "blobs/sha256" / desc["digest"][7:]
            if not destination.exists():
                clone(compressed, destination, 0o400)
            require(stamp(path) == before, "image changed while sealing")
            records.append({"name": name, "kind": kind, "sha256": raw_digest,
                            "bytes": path.stat().st_size, "blob": desc})
            if reused:
                reused_bytes += desc["size"]
            else:
                new_bytes += desc["size"]
        image_config = {"format": FORMAT, "backend": config["backend"], "files": records}
        desc = metadata(layout, image_config, MEDIA + ".config.v1+json")
        manifest = {"schemaVersion": 2, "mediaType": "application/vnd.oci.image.manifest.v1+json",
                    "artifactType": MEDIA + ".v1", "config": desc,
                    "layers": [record["blob"] for record in records]}
        manifest_desc = metadata(layout, manifest, manifest["mediaType"])
        write_json(layout / "index.json", {"schemaVersion": 2, "manifests": [manifest_desc]})
        write_json(layout / "oci-layout", {"imageLayoutVersion": "1.0.0"})
        print(json.dumps({"seconds": time.monotonic() - started, "newBlobBytes": new_bytes,
                          "reusedBlobBytes": reused_bytes, "manifest": manifest_desc["digest"]}), flush=True)


def image_config(layout):
    require(json.loads(regular(layout / "oci-layout").read_bytes()) == {"imageLayoutVersion": "1.0.0"}, "invalid OCI layout")
    index = json.loads(regular(layout / "index.json").read_bytes())
    require(index["schemaVersion"] == 2 and len(index["manifests"]) == 1, "expected exactly one OCI manifest")
    manifest = json.loads(blob(layout, index["manifests"][0]).read_bytes())
    require(manifest.get("artifactType") == MEDIA + ".v1", "unknown image artifact type")
    config = json.loads(blob(layout, manifest["config"]).read_bytes())
    require(config.get("format") == FORMAT and config.get("backend") in ("raw", "asif"), "unknown image format")
    files = config["files"]
    kinds = ["raw"] + (["asif"] if config["backend"] == "asif" else []) + ["identity"] * 3
    names = (["base.img", "writable.asif"] if config["backend"] == "asif" else ["Disk.img"]) + IDENTITY
    require([r["kind"] for r in files] == kinds and [r["name"] for r in files] == names,
            "invalid image layer order, depth or identity inventory")
    require([r["blob"] for r in files] == manifest["layers"], "config and manifest layer order differ")
    for record in files:
        require(re.fullmatch(r"[0-9a-f]{64}", record["sha256"]) and type(record["bytes"]) is int
                and 0 < record["bytes"] <= MAX_IMAGE_BYTES, "invalid decoded layer size or checksum")
        require(record["blob"]["mediaType"] == MEDIA + "." + record["kind"] + "+zstd", "wrong layer media type")
    return config


def decompress(source, target, expected):
    h, total = hashlib.sha256(), 0
    with subprocess.Popen(["zstd", "-q", "-d", "-c", str(source)], stdout=subprocess.PIPE) as process:
        try:
            with target.open("xb") as out:
                for chunk in iter(lambda: process.stdout.read(4 << 20), b""):
                    total += len(chunk)
                    require(total <= expected["bytes"], "decoded layer exceeds declared size")
                    h.update(chunk)
                    # Keep zero ranges sparse in large RAW and ASIF disk files.
                    if chunk.count(0) == len(chunk):
                        out.seek(len(chunk), os.SEEK_CUR)
                    else:
                        out.write(chunk)
                out.truncate(total)
                out.flush()
                os.fsync(out.fileno())
            require(process.wait() == 0, "layer decompression failed")
        finally:
            if process.poll() is None:
                process.kill()
    require(total == expected["bytes"] and h.hexdigest() == expected["sha256"], "decoded layer checksum mismatch")


def restore(args):
    started = time.monotonic()
    with locked(args.cache):
        config = image_config(args.image)
        capacity(args.instance.parent)
        private_dir(args.instance)
        verified, reused_bytes = {}, 0
        for record in config["files"]:
            name = "parent.asif" if record["name"] == "writable.asif" else record["name"]
            target = args.instance / name
            cache_file = args.cache / (record["sha256"] + ".decoded")
            cache_record = args.cache / (record["sha256"] + ".decoded.json")
            immutable = name in ("base.img", "parent.asif")
            if immutable and cache_record.exists():
                receipt = json.loads(regular(cache_record).read_bytes())
                require(receipt["sha256"] == record["sha256"] and receipt["stamp"] == stamp(cache_file)
                        and cache_file.stat().st_mode & 0o222 == 0, "decoded cache changed; re-import using a fresh cache")
                clone(cache_file, target, 0o400)
                reused_bytes += record["blob"]["size"]
            else:
                source = blob(args.image, record["blob"])
                decompress(source, target, record)
                target.chmod(0o400 if immutable else 0o600)
                if immutable:
                    clone(target, cache_file, 0o400)
                    write_json(cache_record, {"sha256": record["sha256"], "stamp": stamp(cache_file)})
            if immutable:
                verified[name] = record["sha256"]
        runtime = {"backend": config["backend"], "readOnly": [], "writable": "Disk.img"}
        if config["backend"] == "asif":
            runtime.update(readOnly=["base.img", "parent.asif"], writable="writable.asif")
        finish_instance(args.instance, runtime, args.runner, args.new_identity, verified)
        print(json.dumps({"seconds": time.monotonic() - started, "restored": True,
                          "reusedBlobBytes": reused_bytes}), flush=True)


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runner", default=str(Path(__file__).with_name("macos-asif-runner")))
    commands = parser.add_subparsers(dest="command", required=True)
    p = commands.add_parser("init")
    p.add_argument("source", type=Path)
    p.add_argument("instance", type=Path)
    p.add_argument("--backend", choices=["raw", "asif"], required=True)
    p = commands.add_parser("run")
    p.add_argument("instance", type=Path)
    p.add_argument("script", type=Path)
    p.add_argument("--inputs", type=Path)
    p = commands.add_parser("commit")
    p.add_argument("instance", type=Path)
    p.add_argument("image", type=Path)
    p.add_argument("--cache", type=Path, required=True)
    p = commands.add_parser("restore")
    p.add_argument("image", type=Path)
    p.add_argument("instance", type=Path)
    p.add_argument("--new-identity", action="store_true")
    p.add_argument("--cache", type=Path, required=True)
    args = parser.parse_args()
    {"init": initialize, "run": run, "commit": commit, "restore": restore}[args.command](args)


if __name__ == "__main__":
    main()
