import copy
import errno
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import image
import layers


class StoreTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.store = self.root / 'store'
        layers.initialize(self.store)

    def source(self, depth):
        root = self.root / ('source-' + str(depth))
        image.private_dir(root)
        (root / 'base.img').write_bytes(bytes(1 << 20))
        names = ['base.img']
        for n in range(1, depth):
            name = f'layer-{n}.asif'
            (root / name).write_bytes(bytes([n]) * 4096)
            names.append(name)
        for name in image.IDENTITY:
            (root / name).write_bytes(name.encode())
        image.write_json(root / 'runtime.json', {'backend': 'asif', 'readOnly': names[:-1], 'writable': names[-1]})
        return root

    def ingest(self, source, name, background=False):
        with patch.object(image, 'idle'), patch.object(image, 'capacity'):
            return layers.ingest(self.store, source, name, background)

    def test_trigger_counts_the_future_writable_layer(self):
        with patch.object(layers, 'kick', return_value=123) as kick:
            self.assertFalse(self.ingest(self.source(2), 'g2', True)['compactionScheduled'])
            kick.assert_not_called()
            self.assertTrue(self.ingest(self.source(3), 'g3', True)['compactionScheduled'])
            kick.assert_called_once_with(self.store)

    def test_sixth_layer_rejected_before_creating_instance(self):
        self.ingest(self.source(5), 'g5')
        target = self.root / 'instance'
        with patch.object(layers, 'kick'), self.assertRaisesRegex(ValueError, 'sixth'):
            layers.checkout(self.store, 'g5', target)
        self.assertFalse(target.exists())

    def test_over_limit_and_path_escape_are_rejected(self):
        with self.assertRaises(ValueError):
            self.ingest(self.source(6), 'g6')
        with self.assertRaises(ValueError):
            layers.identifier('../escape')

    def test_idempotent_ingest_does_not_alias_changed_source(self):
        source = self.source(3)
        self.ingest(source, 'g3')
        before = (self.store / 'generations/g3/manifest.json').read_bytes()
        self.ingest(source, 'g3')
        self.assertEqual(before, (self.store / 'generations/g3/manifest.json').read_bytes())
        (source / 'layer-2.asif').write_bytes(b'new writes')
        with self.assertRaisesRegex(ValueError, 'reused'):
            self.ingest(source, 'g3')
        _, gen = layers.generation(self.store, 'g3')
        self.assertEqual((self.store / 'generations/g3/layer-02.asif').read_bytes(), bytes([2]) * 4096)

    def test_parent_digest_reuse_and_source_lock_release(self):
        source = self.source(3)
        config = layers.read(source / 'runtime.json')
        records = [{'name': n, 'stamp': image.stamp(source / n), 'sha256': image.digest(source / n)} for n in config['readOnly']]
        for r in records:
            (source / r['name']).chmod(0o400)
            r['stamp'] = image.stamp(source / r['name'])
        image.write_json(source / 'local-instance.json', {'sealAllowed': True, 'immutableRecords': records})
        original_digest = image.digest
        hashed = []
        def digest(path):
            # Hashing must not hold the original VM's operation lock.
            with image.locked(source):
                hashed.append(path.name)
                return original_digest(path)
        with patch.object(image, 'digest', side_effect=digest):
            self.ingest(source, 'g3')
        self.assertNotIn('base.img', hashed)
        self.assertNotIn('layer-01.asif', hashed)
        self.assertIn('layer-02.asif', hashed)

    def test_generation_replay_binds_layer_order(self):
        source = self.source(4)
        self.ingest(source, 'g4')
        config = layers.read(source / 'runtime.json')
        config['readOnly'][1:3] = reversed(config['readOnly'][1:3])
        image.write_json(source / 'runtime.json', config)
        with self.assertRaisesRegex(ValueError, 'reused'):
            self.ingest(source, 'g4')

    def test_changed_sealed_parent_is_rejected(self):
        self.ingest(self.source(3), 'g3')
        path = self.store / 'generations/g3/layer-01.asif'
        path.chmod(0o600)
        path.write_bytes(b'changed')
        path.chmod(0o400)
        with self.assertRaisesRegex(ValueError, 'immutable'):
            layers.generation(self.store, 'g3')

    def test_unverified_run_cannot_be_sealed(self):
        source = self.source(3)
        image.write_json(source / 'local-instance.json', {'sealAllowed': False})
        with self.assertRaisesRegex(ValueError, 'stop successfully'):
            self.ingest(source, 'g3')

    def test_corrupt_ready_pointer_is_not_used(self):
        self.ingest(self.source(3), 'g3')
        image.write_json(self.store / 'generations/g3/ready.json', {'sourceManifest': '0' * 64})
        with self.assertRaisesRegex(ValueError, 'stale'):
            layers.checkout(self.store, 'g3', self.root / 'instance')
        self.assertFalse((self.root / 'instance').exists())


class CopyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.original = b'a' * 32768
        # A newer layer can revert bytes to zero or to the exact base value.
        self.expected = bytes(8192) + b'z' * 8192 + b'a' * 8192 + b'x' * 8192
        self.fds = []
        for name, data in [('base', self.original), ('source', self.expected), ('target', self.original)]:
            path = self.root / name
            path.write_bytes(data)
            fd = os.open(path, os.O_RDWR)
            self.fds.append(fd)
            self.addCleanup(os.close, fd)
        self.progress = {'hashes': []}
        self.saved = {'hashes': []}
        self.segment = patch.object(layers, 'SEGMENT', 8192)
        self.block = patch.object(layers, 'BLOCK', 1024)
        self.segment.start(); self.block.start()
        self.addCleanup(self.segment.stop); self.addCleanup(self.block.stop)

    def save(self, progress):
        self.saved = copy.deepcopy(progress)

    def run_copy(self, after=lambda: None):
        return layers.copy_blocks(*self.fds, len(self.original), self.progress, self.save, after)

    def test_latest_data_and_zero_writes_match_full_digest(self):
        import hashlib
        sha, resumed = self.run_copy()
        self.assertEqual((self.root / 'target').read_bytes(), self.expected)
        self.assertEqual(sha, hashlib.sha256(self.expected).hexdigest())
        self.assertEqual(layers.verify_blocks(self.fds[2], len(self.original), self.progress['hashes']), sha)
        self.assertEqual(resumed, 0)

    def test_interrupted_copy_resumes_verified_prefix(self):
        def interrupt(): raise RuntimeError('simulated termination')
        with self.assertRaises(RuntimeError): self.run_copy(interrupt)
        self.assertEqual(len(self.saved['hashes']), 1)
        self.progress = copy.deepcopy(self.saved)
        _, resumed = self.run_copy()
        self.assertEqual(resumed, 1)
        self.assertEqual((self.root / 'target').read_bytes(), self.expected)

    def test_corrupt_completed_prefix_is_never_silently_repaired(self):
        def interrupt(): raise RuntimeError()
        with self.assertRaises(RuntimeError): self.run_copy(interrupt)
        os.pwrite(self.fds[2], b'corrupt', 0)
        self.progress = copy.deepcopy(self.saved)
        with self.assertRaisesRegex(ValueError, 'segment mismatch'): self.run_copy()
        self.assertEqual(os.pread(self.fds[2], 7, 0), b'corrupt')

    def test_full_disk_and_short_write_do_not_advance_checkpoint(self):
        for behavior in (OSError(errno.ENOSPC, 'no space'), None):
            with self.subTest(behavior=behavior):
                self.progress = {'hashes': []}
                with patch.object(layers.os, 'pwrite', side_effect=behavior, return_value=0):
                    with self.assertRaises((OSError, ValueError)): self.run_copy()
                self.assertEqual(self.progress['hashes'], [])

    def test_final_validation_catches_corruption_after_copy(self):
        self.run_copy()
        os.pwrite(self.fds[2], b'changed', 31000)
        with self.assertRaisesRegex(ValueError, 'final compaction'):
            layers.verify_blocks(self.fds[2], len(self.original), self.progress['hashes'])


if __name__ == '__main__':
    unittest.main()
