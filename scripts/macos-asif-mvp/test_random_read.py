import hashlib
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


@unittest.skipUnless(sys.platform == "darwin", "uses macOS F_NOCACHE")
class RandomReadTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.root = Path(cls.temp.name).resolve()
        cls.binary = cls.root / "random-read"
        subprocess.run(["xcrun", "clang", "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror", "-pthread",
                        str(Path(__file__).with_name("random-read.c")), "-o", str(cls.binary)], check=True)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def test_parallel_reads_verify_contents_and_reject_corruption(self):
        data = self.root / "data.bin"
        subprocess.run([str(self.binary), "prepare", str(data), "1048576"], check=True, capture_output=True)
        for threads in (1, 16):
            result = subprocess.run([str(self.binary), "read", str(data), str(threads), "1024", "20261109"], capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
        with data.open("r+b") as stream:
            for offset in range(0, data.stat().st_size, 4096):
                stream.seek(offset)
                stream.write(bytes(8))
        failed = subprocess.run([str(self.binary), "read", str(data), "16", "1024", "20261109"], capture_output=True)
        self.assertNotEqual(failed.returncode, 0)
        self.assertIn(b"dataset content differs", failed.stderr)

    def test_prepare_never_replaces_existing_file(self):
        data = self.root / "existing.bin"
        data.write_bytes(b"preserve original")
        expected = hashlib.sha256(data.read_bytes()).digest()
        result = subprocess.run([str(self.binary), "prepare", str(data), "1048576"], capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(hashlib.sha256(data.read_bytes()).digest(), expected)


if __name__ == "__main__":
    unittest.main()
