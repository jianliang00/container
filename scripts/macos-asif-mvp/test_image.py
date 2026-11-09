import argparse
import contextlib
import io
import json
import plistlib
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import image


class ImageTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve()
        self.instance = self.root / "instance"
        self.cache = self.root / "cache"
        for root in (self.instance, self.cache):
            image.private_dir(root)
        (self.instance / "base.img").write_bytes(b"base" * 4096)
        (self.instance / "base.img").chmod(0o400)
        (self.instance / "writable.asif").write_bytes(b"overlay" * 4096)
        for name in image.IDENTITY:
            (self.instance / name).write_bytes(name.encode())
        runtime = {"backend": "asif", "readOnly": ["base.img"], "writable": "writable.asif"}
        image.write_json(self.instance / "instance.json", {
            "format": image.FORMAT, "runtime": runtime, "sealAllowed": True,
            "immutable": {"base.img": {"sha256": image.digest(self.instance / "base.img"),
                                        "stamp": image.stamp(self.instance / "base.img")}}})

    def tearDown(self):
        self.temporary.cleanup()

    def commit(self):
        layout = self.root / "image"
        args = argparse.Namespace(instance=self.instance, image=layout, cache=self.cache)
        with patch.object(image, "idle"), patch.object(image, "capacity"), contextlib.redirect_stdout(io.StringIO()):
            image.commit(args)
        return layout

    def rewrite_config(self, layout, edit, edit_manifest=None):
        index = json.loads((layout / "index.json").read_bytes())
        manifest = json.loads(image.blob(layout, index["manifests"][0]).read_bytes())
        config = json.loads(image.blob(layout, manifest["config"]).read_bytes())
        edit(config)
        manifest["config"] = image.metadata(layout, config, image.MEDIA + ".config.v1+json")
        if edit_manifest:
            edit_manifest(manifest)
        index["manifests"] = [image.metadata(layout, manifest, manifest["mediaType"])]
        image.write_json(layout / "index.json", index)

    def test_round_trip_and_cached_restore(self):
        layout = self.commit()
        for i in range(2):
            args = argparse.Namespace(image=layout, instance=self.root / str(i), cache=self.cache,
                                      runner="unused", new_identity=False)
            with patch.object(image, "finish_instance") as finish, patch.object(image, "capacity"):
                image.restore(args)
                self.assertEqual(finish.call_args.args[1]["readOnly"], ["base.img", "parent.asif"])
            self.assertEqual((args.instance / "parent.asif").read_bytes(), (self.instance / "writable.asif").read_bytes())
            self.assertEqual((args.instance / "base.img").read_bytes(), (self.instance / "base.img").read_bytes())

    def test_missing_blob(self):
        layout = self.commit()
        config = image.image_config(layout)
        image.blob(layout, config["files"][1]["blob"]).unlink()
        with self.assertRaises(FileNotFoundError):
            image.blob(layout, config["files"][1]["blob"])

    def test_corrupt_decoded_cache_blocks_restore(self):
        layout = self.commit()
        args = argparse.Namespace(image=layout, instance=self.root / "restored", cache=self.cache,
                                  runner="unused", new_identity=False)
        with patch.object(image, "finish_instance"), patch.object(image, "capacity"):
            image.restore(args)
        cached = next(self.cache.glob("*.decoded"))
        cached.chmod(0o600)
        cached.write_bytes(b"bad cache")
        cached.chmod(0o400)
        args.instance = self.root / "second"
        with patch.object(image, "finish_instance") as finish, patch.object(image, "capacity"):
            with self.assertRaisesRegex(ValueError, "cache changed"):
                image.restore(args)
            finish.assert_not_called()

    def test_symlink_parent_rejected(self):
        parent = self.instance / "base.img"
        copy = self.root / "real-base"
        parent.rename(copy)
        parent.symlink_to(copy)
        with self.assertRaisesRegex(ValueError, "symlink"):
            image.load(self.instance)

    def test_host_attachment_rejected_before_lsof(self):
        path = self.instance / "base.img"
        mounts = plistlib.dumps({"images": [{"image-path": str(path)}]})
        with patch.object(image.subprocess, "check_output", return_value=mounts), patch.object(image.subprocess, "run") as run:
            with self.assertRaisesRegex(ValueError, "attached"):
                image.idle([path])
            run.assert_not_called()

    def test_reordered_layers(self):
        layout = self.commit()
        self.rewrite_config(layout, lambda c: c["files"].reverse())
        with self.assertRaisesRegex(ValueError, "order"):
            image.image_config(layout)

    def test_manifest_order_mismatch(self):
        layout = self.commit()
        self.rewrite_config(layout, lambda c: None, lambda m: m["layers"].reverse())
        with self.assertRaisesRegex(ValueError, "order"):
            image.image_config(layout)

    def test_path_escape(self):
        layout = self.commit()
        self.rewrite_config(layout, lambda c: c["files"][0].update(name="../escape"))
        with self.assertRaisesRegex(ValueError, "inventory"):
            image.image_config(layout)

    def test_corrupted_blob(self):
        layout = self.commit()
        desc = image.image_config(layout)["files"][1]["blob"]
        path = image.blob(layout, desc)
        path.chmod(0o600)
        path.write_bytes(b"bad")
        with self.assertRaisesRegex(ValueError, "checksum"):
            image.blob(layout, desc)

    def test_corrupt_compressed_cache_descriptor(self):
        self.commit()
        entry = next(self.cache.glob("*.json"))
        record = json.loads(entry.read_bytes())
        record["descriptor"]["digest"] = "sha256:../../escape"
        image.write_json(entry, record)
        with self.assertRaisesRegex(ValueError, "digest"):
            image.compress_cached(self.instance / "base.img", self.cache, entry.stem, "raw")

    def test_invalid_immutable_checksum(self):
        path = self.instance / "instance.json"
        state = json.loads(path.read_bytes())
        state["immutable"]["base.img"]["sha256"] = "../../escape"
        image.write_json(path, state)
        with self.assertRaisesRegex(ValueError, "checksum"):
            image.load(self.instance)

    def test_decoded_digest_and_size_are_checked(self):
        layout = self.commit()
        record = image.image_config(layout)["files"][1]
        source = image.blob(layout, record["blob"])
        with self.assertRaisesRegex(ValueError, "checksum"):
            image.decompress(source, self.root / "bad-digest", dict(record, sha256="0" * 64))
        with self.assertRaisesRegex(ValueError, "declared size"):
            image.decompress(source, self.root / "bad-size", dict(record, bytes=1))

    def test_changed_parent_rejected_without_full_scan(self):
        parent = self.instance / "base.img"
        parent.chmod(0o600)
        with self.assertRaisesRegex(ValueError, "writable"):
            image.load(self.instance)
        parent.write_bytes(b"changed")
        parent.chmod(0o400)
        with self.assertRaisesRegex(ValueError, "changed"):
            image.load(self.instance)

    def test_concurrent_operation_rejected(self):
        with image.locked(self.instance):
            with self.assertRaises(BlockingIOError):
                with image.locked(self.instance):
                    self.fail("concurrent lock accepted")

    def test_unverified_stop_cannot_commit(self):
        path = self.instance / "instance.json"
        state = json.loads(path.read_bytes())
        state["sealAllowed"] = False
        image.write_json(path, state)
        with self.assertRaisesRegex(ValueError, "unverified"):
            self.commit()


class ChunkedBaseTests(unittest.TestCase):
    tearDown = ImageTests.tearDown
    rewrite_config = ImageTests.rewrite_config
    def setUp(self):
        ImageTests.setUp(self)
        self.chunked = self.root / "chunked"
        image.private_dir(self.chunked)
        (self.chunked / "blobs/sha256").mkdir(parents=True)
        raw = self.instance / "base.img"
        chunk = self.chunked / "content"
        chunk.write_bytes(b"compressed sparse chunk fixture")
        desc = image.descriptor(chunk, image.MEDIA + ".raw-chunk+tar+zstd")
        chunk.rename(self.chunked / "blobs/sha256" / desc["digest"][7:])
        path = self.chunked / "blobs/sha256" / desc["digest"][7:]
        path.chmod(0o400)
        disk = {"version": 1, "logicalSize": raw.stat().st_size, "chunkSize": 1 << 30,
                "chunkCount": 1, "compression": {"type": "zstd", "level": 3},
                "tar": {"format": "pax", "sparse": True},
                "chunks": [{"index": 0, "offset": 0, "length": raw.stat().st_size,
                            "rawLength": raw.stat().st_size, "rawDigest": image.digest(raw),
                            "layerDigest": desc["digest"], "layerSize": desc["size"]}]}
        image.write_json(self.chunked / "layout.json", disk)
        image.write_json(self.chunked / "binding.json", {
            "sha256": image.digest(raw), "layoutStamp": image.stamp(self.chunked / "layout.json"),
            "blobs": {desc["digest"]: image.stamp(path)}})

    def commit(self):
        layout = self.root / "image"
        args = argparse.Namespace(instance=self.instance, image=layout, cache=self.cache, base_chunks=self.chunked)
        with patch.object(image, "idle"), patch.object(image, "capacity"), contextlib.redirect_stdout(io.StringIO()):
            image.commit(args)
        return layout

    def test_chunked_base_cold_and_warm_restore(self):
        layout = self.commit()
        config = image.image_config(layout)
        self.assertEqual(config["format"], image.CHUNKED_FORMAT)
        actual_run = image.subprocess.run
        calls = []
        def run(command, **kwargs):
            if command[0] != "raw-import":
                return actual_run(command, **kwargs)
            calls.append(command)
            Path(command[-1]).write_bytes((self.instance / "base.img").read_bytes())
        with patch.object(image.subprocess, "run", side_effect=run):
            for i in range(2):
                args = argparse.Namespace(image=layout, instance=self.root / str(i), cache=self.cache,
                                          runner="unused", new_identity=False, raw_importer="raw-import")
                with patch.object(image, "finish_instance"), patch.object(image, "capacity"):
                    image.restore(args)
                self.assertEqual((args.instance / "base.img").read_bytes(), (self.instance / "base.img").read_bytes())
        self.assertEqual(len(calls), 1)

    def test_wrong_parent_binding(self):
        path = self.chunked / "binding.json"
        data = json.loads(path.read_bytes()); data["sha256"] = "0" * 64
        image.write_json(path, data)
        with self.assertRaisesRegex(ValueError, "binding mismatch"):
            self.commit()

    def test_changed_export_chunk(self):
        path = next((self.chunked / "blobs/sha256").iterdir())
        path.chmod(0o600); path.write_bytes(b"bad"); path.chmod(0o400)
        with self.assertRaisesRegex(ValueError, "changed after export"):
            self.commit()

    def test_changed_layout_binding(self):
        path = self.chunked / "layout.json"
        path.write_bytes(path.read_bytes() + b" ")
        with self.assertRaisesRegex(ValueError, "binding mismatch"):
            self.commit()

    def test_chunk_inventory_mismatch(self):
        layout = self.commit()
        self.rewrite_config(layout, lambda c: c["files"][0]["chunks"][0].update(size=1),
                            lambda m: m["layers"][1].update(size=1))
        with self.assertRaisesRegex(ValueError, "chunk inventory"):
            image.image_config(layout)

    def test_failed_import_does_not_finalize_or_cache_base(self):
        layout = self.commit()
        args = argparse.Namespace(image=layout, instance=self.root / "failed", cache=self.cache,
                                  runner="unused", new_identity=False, raw_importer="raw-import")
        with patch.object(image, "finish_instance") as finish, patch.object(image, "capacity"), \
             patch.object(image.subprocess, "run", side_effect=RuntimeError("interrupted")):
            with self.assertRaisesRegex(RuntimeError, "interrupted"):
                image.restore(args)
            finish.assert_not_called()
        self.assertFalse(list(self.cache.glob("chunks-*.decoded.json")))


    def test_rebuild_capacity_checked_before_instance_creation(self):
        layout = self.commit()
        args = argparse.Namespace(image=layout, instance=self.root / "no-space", cache=self.cache,
                                  runner="unused", new_identity=False, raw_importer="unused")
        usage = __import__("collections").namedtuple("Usage", "total used free")(100 << 30, 79 << 30, 21 << 30)
        with patch.object(image.shutil, "disk_usage", return_value=usage), patch.object(image.subprocess, "run") as run:
            with self.assertRaisesRegex(ValueError, "requires"):
                image.restore(args)
            run.assert_not_called()
        self.assertFalse(args.instance.exists())

    def test_changed_acquired_chunk_rejected_before_importer(self):
        layout = self.commit()
        cfg = image.image_config(layout)
        path = layout / "blobs/sha256" / cfg["files"][0]["chunks"][0]["digest"][7:]
        path.chmod(0o600);path.write_bytes(b"corrupt" * 4);path.chmod(0o400)
        args = argparse.Namespace(image=layout, instance=self.root / "corrupt", cache=self.cache,
                                  runner="unused", new_identity=False, raw_importer="unused")
        with patch.object(image, "capacity"), patch.object(image.subprocess, "run") as run:
            with self.assertRaisesRegex(ValueError, "checksum"):
                image.restore(args)
            run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
