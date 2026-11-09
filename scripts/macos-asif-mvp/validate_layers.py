#!/usr/bin/env python3
"""Explicit native failure tests. Uses only newly created private disk images; no VM."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time
from unittest.mock import patch

import image
import layer_depth as disks
import layers


def worker(store, name, failpoint=None):
    log = store / ('attempt-' + str(time.time_ns()))
    command = [sys.executable, str(Path(layers.__file__).resolve()), 'work', str(store), '--generation', name]
    if failpoint:
        command += ['--crash-at', failpoint]
    with log.with_suffix('.jsonl').open('xb') as out, log.with_suffix('.stderr').open('xb') as err:
        result = subprocess.run(command, stdout=out, stderr=err, timeout=180)
    image.require(result.returncode == (-9 if failpoint else 0), 'unexpected worker result; inspect ' + str(log))
    return log


def prepare(root, identity):
    size = 512 << 20
    work = root / 'fixture'
    image.private_dir(work)
    base = work / 'base.img'
    with base.open('xb') as stream:
        stream.truncate(size)
        stream.write(b'a' * disks.BLOCK)
    base.chmod(0o400)
    image.clone(base, work / 'expected.img')
    changes = [[(0, b'b'), (64 << 20, b'c')], [(0, b'\0'), (256 << 20, b'd')],
               [(64 << 20, b'\0'), (384 << 20, b'e')], [(0, b'z'), (256 << 20, b'f')]]
    shadows, expected = [], {}
    for index, updates in enumerate(changes, 1):
        top = work / f'layer-{index:02d}.asif'
        with disks.attached(base, [*shadows, top], size) as device:
            fd = os.open(device, os.O_RDWR)
            try:
                with (work / 'expected.img').open('r+b') as reference:
                    for offset, value in updates:
                        data = value * disks.BLOCK
                        assert os.pwrite(fd, data, offset) == disks.BLOCK
                        reference.seek(offset)
                        reference.write(data)
                os.fsync(fd)
            finally:
                os.close(fd)
        top.chmod(0o400)
        shadows.append(top)
        source = root / f'source-{index + 1}'
        image.private_dir(source)
        names = ['base.img', *(p.name for p in shadows)]
        for name in names:
            image.clone(work / name, source / name, 0o600 if name == top.name else 0o400)
        for name in image.IDENTITY:
            image.clone(identity / name, source / name)
        image.write_json(source / 'runtime.json', {'backend': 'asif', 'readOnly': names[:-1], 'writable': names[-1]})
        expected[index + 1] = image.digest(work / 'expected.img')
    return expected


def check_result(store, name, expected):
    parent, manifest = layers.generation(store, name)
    layers.artifact(store, name, manifest)
    result = layers.read(store / 'jobs' / name / 'result.json')
    assert result['logicalSHA256'] == expected
    target = store / 'restored'
    assert layers.checkout(store, name, target)['layers'] == 3
    config = layers.read(target / 'runtime.json')
    paths = [target / x for x in [*config['readOnly'], config['writable']]]
    h = hashlib.sha256()
    with disks.attached(paths[0], paths[1:], result['logicalBytes'], readonly=True) as device:
        fd = os.open(device, os.O_RDONLY)
        try:
            for offset in range(0, result['logicalBytes'], disks.BLOCK):
                h.update(os.pread(fd, disks.BLOCK, offset))
        finally:
            os.close(fd)
    assert h.hexdigest() == expected
    image.idle(paths)
    return result


def validate(root, identity):
    image.capacity(root.parent, layers.RESERVE)
    image.private_dir(root)
    expected = prepare(root, identity)
    results = []
    # Three sealed layers plus a future writable layer triggers at exactly four.
    auto = root / 'automatic'
    layers.initialize(auto)
    queued = layers.ingest(auto, root / 'source-3', 'g3')
    deadline = time.monotonic() + 180
    while not (auto / 'generations/g3/ready.json').exists():
        image.require(time.monotonic() < deadline, 'background worker did not publish')
        time.sleep(0.25)
    _, status = os.waitpid(queued['workerPID'], 0)
    assert status == 0
    check_result(auto, 'g3', expected[3])
    results.append({'case': 'automatic-four-layer-trigger', 'passed': True})
    for depth in (4, 5):
        store = root / f'admission-{depth}'
        layers.initialize(store)
        layers.ingest(store, root / f'source-{depth}', 'parent', background=False)
        lock = os.open(store / '.worker.lock', os.O_CREAT | os.O_RDWR, 0o600)
        fcntl.flock(lock, fcntl.LOCK_EX)
        children = []
        original_kick = layers.kick
        def capture_kick(path):
            pid = original_kick(path)
            children.append(pid)
            return pid
        try:
            with patch.object(layers, 'kick', side_effect=capture_kick):
                if depth == 4:
                    admitted = layers.checkout(store, 'parent', store / 'old-chain')
                    assert admitted['layers'] == 5 and not admitted['compacted']
                else:
                    try:
                        layers.checkout(store, 'parent', store / 'prohibited')
                    except ValueError as error:
                        assert 'sixth' in str(error)
                    else:
                        raise AssertionError('sixth layer was admitted')
                    assert not (store / 'prohibited').exists()
        finally:
            os.close(lock)
        assert len(children) == 1
        _, status = os.waitpid(children[0], 0)
        assert status == 0
        check_result(store, 'parent', expected[depth])
        results.append({'case': f'admission-sealed-{depth}', 'passed': True})
    for point in ('checkpoint', 'verified', 'published'):
        store = root / ('crash-' + point)
        layers.initialize(store)
        layers.ingest(store, root / 'source-5', 'g5', background=False)
        worker(store, 'g5', point)
        assert (store / 'generations/g5/ready.json').exists() == (point == 'published')
        before = (store / 'jobs/g5/result.json').read_bytes() if point != 'checkpoint' else None
        worker(store, 'g5')
        result = check_result(store, 'g5', expected[5])
        if before:
            assert before == (store / 'jobs/g5/result.json').read_bytes()
        else:
            assert result['resumedSegments'] == 1
        worker(store, 'g5')
        results.append({'case': 'kill-' + point, 'passed': True, 'resumedSegments': result['resumedSegments']})
    store = root / 'corrupt-checkpoint'
    layers.initialize(store)
    layers.ingest(store, root / 'source-5', 'g5', background=False)
    worker(store, 'g5', 'checkpoint')
    job = store / 'jobs/g5'
    layers.recover_attachments(job, 512 << 20)
    with disks.attached(job / 'output/base.img', [job / 'output/merged.asif'], 512 << 20) as device:
        fd = os.open(device, os.O_RDWR)
        try:
            os.pwrite(fd, b'corruption' * 4096, 0)
            os.fsync(fd)
        finally:
            os.close(fd)
    failed = subprocess.run([sys.executable, str(Path(layers.__file__).resolve()), 'work', str(store), '--generation', 'g5'],
                            capture_output=True, text=True, timeout=180)
    assert failed.returncode != 0 and 'segment mismatch' in failed.stderr
    assert not (store / 'generations/g5/ready.json').exists()
    retained = layers.reset(store, 'g5')
    assert Path(retained['retained']).is_dir()
    worker(store, 'g5')
    check_result(store, 'g5', expected[5])
    results.append({'case': 'corrupt-checkpoint-fail-closed-and-reset', 'passed': True, **retained})
    image.write_json(root / 'results.json', results)
    print(json.dumps(results), flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    parser.add_argument('identity', type=Path)
    args = parser.parse_args()
    os.umask(0o077)
    validate(args.output.absolute(), args.identity.absolute())
