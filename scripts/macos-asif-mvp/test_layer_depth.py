import copy
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

import layer_depth as depth


class DeviceSafetyTests(unittest.TestCase):
    def test_only_matching_unmounted_image_device_is_accepted(self):
        good = {"BusProtocol": "Disk Image", "Internal": False, "VirtualOrPhysical": "Virtual",
                "WholeDisk": True, "Size": 64 << 20, "MountPoint": ""}
        depth.validate_device(good, 64 << 20)
        for changed in ({"Internal": True}, {"BusProtocol": "PCI-Express"},
                        {"VirtualOrPhysical": "Physical"}, {"MountPoint": "/"},
                        {"WholeDisk": False}, {"Size": 128 << 20}):
            with self.subTest(changed=changed), self.assertRaises(ValueError):
                depth.validate_device({**good, **changed}, 64 << 20)


@unittest.skipUnless(sys.platform == "darwin", "uses macOS file-cache controls")
class FixtureTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.base = self.root / "base.img"
        self.reference = self.root / "reference.img"
        self.base.write_bytes(bytes(3 * depth.BLOCK))
        self.reference.write_bytes(bytes(depth.BLOCK) + b"x" * depth.BLOCK + bytes(depth.BLOCK))
        self.receipt = self.root / "diff.json"
        with patch.object(depth.image, "idle"):
            depth.scan(self.base, self.reference, self.receipt)

    def test_scan_accounts_for_all_changed_blocks_and_full_content(self):
        result = json.loads(self.receipt.read_text())
        self.assertEqual(result["changedOffsets"], [depth.BLOCK])
        self.assertEqual(result["sha256"][1], hashlib.sha256(self.reference.read_bytes()).hexdigest())

    def test_modified_reference_rejected_before_device_attach(self):
        with self.reference.open("r+b") as stream:
            stream.write(b"y")
        with patch.object(depth, "attached") as attach, self.assertRaises(ValueError):
            depth.build(self.base, self.reference, self.receipt, 2, self.root / "out")
        attach.assert_not_called()
        self.assertFalse((self.root / "out").exists())

    def test_bad_extents_rejected_before_output_or_device_attach(self):
        valid = json.loads(self.receipt.read_text())
        for offsets in ([1], [-depth.BLOCK], [3 * depth.BLOCK], [0, 0], [True]):
            with self.subTest(offsets=offsets):
                bad = copy.deepcopy(valid)
                bad["changedOffsets"] = offsets
                self.receipt.write_text(json.dumps(bad))
                with patch.object(depth, "attached") as attach, self.assertRaises(ValueError):
                    depth.build(self.base, self.reference, self.receipt, 2, self.root / "out")
                attach.assert_not_called()
                self.assertFalse((self.root / "out").exists())


if __name__ == "__main__":
    unittest.main()
