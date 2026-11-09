from pathlib import Path
import struct
import tempfile
import unittest

import asif_index
import layers


class IndexTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.path = Path(directory.name).resolve() / 'index.asif'
        self.size = 4 * asif_index.BLOCK
        self.write(0, b'shdw' + struct.pack('>IIIQQ', 1, 512, 0, 512, 1024))
        sectors = self.size // asif_index.SECTOR
        self.write(48, struct.pack('>QQIHH', sectors, sectors, asif_index.BLOCK, 512, 0))
        self.write(512, struct.pack('>QQ', 9, 1))
        self.write(1024, struct.pack('>QQ', 8, 0))
        self.write(4 * asif_index.BLOCK - 1, b'\0')
        self.write(asif_index.BLOCK, struct.pack('>QQQQ', (1 << 62) | 2, 2 << 62, 3 << 62, 0))
        self.write(asif_index.BLOCK + asif_index.ENTRIES * 8, struct.pack('>Q', 3))

    def write(self, offset, data):
        with self.path.open('r+b' if self.path.exists() else 'w+b') as file:
            file.seek(offset)
            file.write(data)

    def test_latest_directory_includes_unmap_and_partial_without_payload(self):
        self.assertEqual(asif_index.candidates(self.path, self.size), {0, asif_index.BLOCK, 2 * asif_index.BLOCK})

    def test_unknown_format_uses_full_scan(self):
        self.write(4, struct.pack('>I', 2))
        offsets, plan = layers.merge_plan([self.path], self.size, None, False)
        self.assertIsNone(offsets)
        self.assertEqual(plan['mode'], 'full')

    def test_corrupt_known_index_cannot_fall_back(self):
        self.write(520, struct.pack('>Q', 4))  # Table points beyond the file.
        with self.assertRaisesRegex(ValueError, 'table reference'):
            layers.merge_plan([self.path], self.size, None, False)

    def test_sparse_resume_rejects_changed_plan_and_full_scan_mode(self):
        _, plan = layers.merge_plan([self.path], self.size, None, False)
        with self.assertRaisesRegex(ValueError, 'cannot change mode'):
            layers.merge_plan([self.path], self.size, plan, True)
        self.write(asif_index.BLOCK + 8, b'\0' * 8)
        with self.assertRaisesRegex(ValueError, 'plan changed'):
            layers.merge_plan([self.path], self.size, plan, False)

    def test_legacy_checkpoint_remains_full_scan(self):
        offsets, plan = layers.merge_plan([self.path], self.size, {'hashes': []}, False)
        self.assertIsNone(offsets)
        self.assertEqual(plan['mode'], 'full')
