#!/usr/bin/env python3
"""Opt-in local ASIF generation store and resumable compactor; no runtime installation."""

import argparse
import contextlib
import fcntl
import hashlib
from itertools import groupby
import json
import os
from pathlib import Path
import plistlib
import re
import signal
import subprocess
import sys
import tempfile
import time
import uuid

import asif_index
import image
import layer_depth as disks

FORMAT = 'container.macos.local-layers.v1'
TRIGGER = 4
LIMIT = 5
SEGMENT = 256 << 20
BLOCK = 1 << 20
RESERVE = 40 << 30


def durable(path, value):
    image.write_json(path, value)
    fd = os.open(path.parent, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def read(path):
    return json.loads(image.regular(path).read_bytes())


def identifier(value):
    image.require(isinstance(value, str) and re.fullmatch(r'[a-zA-Z0-9][a-zA-Z0-9_-]{0,79}', value), 'invalid generation ID')
    return value


def store_path(path):
    with image.locked(path):
        image.require(read(path / 'store.json') == {'format': FORMAT, 'trigger': TRIGGER, 'limit': LIMIT}, 'invalid store policy')
    return path


def initialize(path):
    image.private_dir(path)
    for name in ('generations', 'jobs'):
        image.private_dir(path / name)
    durable(path / 'store.json', {'format': FORMAT, 'trigger': TRIGGER, 'limit': LIMIT})


def disk_names(config):
    names = [*config['readOnly'], config['writable']]
    image.require(config.get('backend') == 'asif' and 2 <= len(names) <= LIMIT, 'ASIF running chain exceeds five layers')
    image.require(len(set(names)) == len(names) and all(isinstance(n, str) and Path(n).name == n and n not in ('', '.', '..') for n in names),
                  'invalid layer filenames')
    return names


def inventory(root, records):
    for record in records:
        path = root / record['name']
        image.require(Path(record['name']).name == record['name'] and record['name'] not in ('', '.', '..'), 'invalid stored filename')
        image.require(path.stat().st_mode & 0o222 == 0 and image.stamp(path) == record['stamp'], 'immutable input changed')
        image.require(re.fullmatch(r'[0-9a-f]{64}', record['sha256']) is not None, 'invalid stored digest')


def generation(store, name):
    root = store / 'generations' / identifier(name)
    manifest = read(root / 'manifest.json')
    image.require(manifest['format'] == FORMAT and manifest['id'] == name, 'generation identity mismatch')
    image.require(2 <= len(manifest['disks']) <= LIMIT, 'invalid sealed depth')
    expected = ['base.img', *(f'layer-{i:02d}.asif' for i in range(1, len(manifest['disks'])))]
    image.require([r['name'] for r in manifest['disks']] == expected
                  and [r['name'] for r in manifest['identity']] == image.IDENTITY, 'generation inventory mismatch')
    inventory(root, manifest['disks'] + manifest['identity'])
    image.require(manifest['logicalBytes'] == disks.disk_size(root / 'base.img'), 'generation disk size mismatch')
    return root, manifest


def kick(store):
    # Each publisher queues a serialized worker. Blocking flock prevents the
    # lost-wakeup window between an older worker's final scan and its exit.
    with (store / 'worker.log').open('ab') as log:
        process = subprocess.Popen([sys.executable, str(Path(__file__).resolve()), 'work', str(store)],
                                   stdin=subprocess.DEVNULL, stdout=log, stderr=log, start_new_session=True)
    return process.pid


def ingest(store, source, name, background=True):
    store_path(store)
    identifier(name)
    target = store / 'generations' / name
    stage = None
    started = time.monotonic()
    with image.locked(source):
        config = read(source / 'runtime.json')
        names = disk_names(config)
        cached = {}
        if (source / 'local-instance.json').exists():
            local = read(source / 'local-instance.json')
            image.require(local['sealAllowed'], 'instance did not stop successfully')
            cached = {r['name']: r for r in local.get('immutableRecords', [])}
            if cached:
                image.require(set(cached) == set(config['readOnly']), 'parent digest inventory mismatch')
                inventory(source, list(cached.values()))
        paths = [source / n for n in names + image.IDENTITY]
        image.idle(paths)
        origins = {n: image.stamp(source / n) for n in names + image.IDENTITY}
        origin = {'path': str(source), 'runtime': config, 'stamps': origins}
        if target.exists():
            _, prior = generation(store, name)
            image.require(prior['origin'] == origin, 'generation ID reused for different input')
        else:
            image.capacity(store, RESERVE)
            stage = Path(tempfile.mkdtemp(prefix='.ingest-', dir=store))
            for i, original in enumerate(names + image.IDENTITY):
                dest = ('base.img' if i == 0 else f'layer-{i:02d}.asif') if i < len(names) else original
                image.clone(source / original, stage / dest, 0o400)
            image.require(origins == {n: image.stamp(source / n) for n in origins}, 'source changed while sealing')
    # Hash only private immutable clones, after releasing the VM operation lock.
    # Parent digests from a verified checkout avoid rescanning an imported RAW base.
    capture_seconds = time.monotonic() - started
    if stage is not None:
        records = []
        for i, original in enumerate(names + image.IDENTITY):
            dest = ('base.img' if i == 0 else f'layer-{i:02d}.asif') if i < len(names) else original
            sha = cached[original]['sha256'] if original in cached else image.digest(stage / dest)
            records.append({'name': dest, 'sha256': sha, 'stamp': image.stamp(stage / dest)})
        manifest = {'format': FORMAT, 'id': name, 'logicalBytes': disks.disk_size(stage / 'base.img'),
                    'origin': origin, 'disks': records[:len(names)], 'identity': records[len(names):]}
        durable(stage / 'manifest.json', manifest)
        with image.locked(store):
            image.require(not target.exists(), 'generation was published concurrently; inspect staged import')
            os.rename(stage, target)
            durable(store / 'last-published.json', {'generation': name})
    scheduled = len(names) + 1 >= TRIGGER
    complete = (target / 'ready.json').exists()
    if complete:
        _, sealed = generation(store, name)
        artifact(store, name, sealed)
    pid = kick(store) if background and scheduled and not complete else None
    return {'generation': name, 'sealedLayers': len(names), 'nextRuntimeLayers': len(names) + 1,
            'compactionScheduled': scheduled, 'workerPID': pid, 'captureSeconds': capture_seconds,
            'ingestSeconds': time.monotonic() - started}


def artifact(store, name, manifest):
    root = store / 'jobs' / name
    ready = read(store / 'generations' / name / 'ready.json')
    image.require(ready['sourceManifest'] == hashlib.sha256(image.encoded(manifest)).hexdigest(), 'stale compacted generation')
    image.require(ready['artifact'] == 'result.json', 'invalid artifact path')
    result = read(root / 'result.json')
    image.require(ready['sha256'] == hashlib.sha256(image.encoded(result)).hexdigest()
                  and result['sourceManifest'] == ready['sourceManifest'], 'compaction publication mismatch')
    image.require([r['name'] for r in result['disks']] == ['base.img', 'merged.asif']
                  and result['logicalBytes'] == manifest['logicalBytes'], 'invalid compacted layout')
    if result.get('mode', 'full') == 'full':
        image.require(valid_hash(result.get('logicalSHA256')), 'invalid logical disk digest')
    else:
        image.require(result['mode'] == 'sparse-v1' and valid_hash(result.get('planSHA256'))
                      and valid_hash(result.get('rangeSHA256')), 'invalid sparse verification receipt')
    inventory(root / 'output', result['disks'])
    return root / 'output', result['disks']


def checkout(store, name, instance):
    store_path(store)
    parent, manifest = generation(store, name)
    if (parent / 'ready.json').exists():
        origin, records = artifact(store, name, manifest)
    else:
        origin, records = parent, manifest['disks']
        if len(records) + 1 >= TRIGGER:
            kick(store)
    image.require(len(records) + 1 <= LIMIT, 'compaction pending: creating a sixth runtime layer is prohibited')
    image.capacity(instance.parent, RESERVE)
    image.private_dir(instance)
    for record in records:
        image.clone(origin / record['name'], instance / record['name'], 0o400)
    for record in manifest['identity']:
        image.clone(parent / record['name'], instance / record['name'])
    names = [r['name'] for r in records]
    writable = 'writable.asif'
    with disks.attached(instance / names[0], [*(instance / n for n in names[1:]), instance / writable], manifest['logicalBytes']):
        pass
    config = {'backend': 'asif', 'readOnly': names, 'writable': writable}
    durable(instance / 'runtime.json', config)
    durable(instance / 'local-instance.json', {'format': FORMAT, 'generation': name, 'sealAllowed': True,
                                             'immutable': {n: image.stamp(instance / n) for n in names},
                                             'immutableRecords': [{**r, 'stamp': image.stamp(instance / r['name'])} for r in records]})
    return {'generation': name, 'layers': len(names) + 1, 'compacted': origin != parent}


def run(instance, runner, script):
    with image.locked(instance):
        state = read(instance / 'local-instance.json')
        config = read(instance / 'runtime.json')
        names = disk_names(config)
        image.require(state['immutable'] == {n: image.stamp(instance / n) for n in config['readOnly']}, 'instance parent changed')
        image.idle([instance / n for n in names + image.IDENTITY])
        image.capacity(instance, RESERVE)
        state['sealAllowed'] = False
        durable(instance / 'local-instance.json', state)
        log = instance / f'run-{time.time_ns()}.jsonl'
        with log.open('xb') as output, log.with_suffix('.stderr').open('xb') as error:
            result = subprocess.run([str(runner), 'run-depth', str(instance), str(image.regular(script))],
                                    stdout=output, stderr=error, timeout=1560)
        events = [json.loads(line) for line in log.read_text().splitlines()]
        stopped = any(x.get('stage') == 'vmStopped' and x.get('stopped') for x in events)
        image.idle([instance / n for n in names + image.IDENTITY])
        state['sealAllowed'] = result.returncode == 0 and stopped
        durable(instance / 'local-instance.json', state)
        image.require(state['sealAllowed'], 'guest failed; preserve instance and logs')
        return {'stopped': True, 'log': str(log)}


def recover_attachments(job, size):
    # Only the worker's two private clone bases can be recovered. A real disk,
    # mounted filesystem or foreign image always stops recovery.
    expected = {str(job / side / 'base.img') for side in ('input', 'output')}
    entries = plistlib.loads(subprocess.check_output(['hdiutil', 'info', '-plist']))['images']
    for entry in entries:
        if entry.get('image-path') not in expected:
            continue
        image.require(not any(x.get('mount-point') for x in entry.get('system-entities', [])), 'recovery image is mounted')
        devices = []
        for entity in entry.get('system-entities', []):
            path = entity.get('dev-entry', '')
            if not re.fullmatch(r'/dev/disk[0-9]+', path):
                continue
            info = plistlib.loads(subprocess.check_output(['diskutil', 'info', '-plist', path]))
            try:
                disks.validate_device(info, size)
                devices.append(path)
            except ValueError:
                continue
        image.require(len(devices) == 1, 'cannot identify private recovery device')
        subprocess.run(['diskutil', 'eject', devices[0]], check=True, capture_output=True, timeout=90)


def crash(point, selected):
    if point == selected:
        os.kill(os.getpid(), signal.SIGKILL)


def checkpoint(job, progress):
    durable(job / 'progress.json', progress)
    print(json.dumps({'stage': 'checkpoint', 'job': job.name, 'segments': len(progress['hashes'])}), flush=True)


def valid_hash(value):
    return isinstance(value, str) and re.fullmatch(r'[0-9a-f]{64}', value) is not None


def segments_for(size, offsets=None):
    if offsets is None:
        return [range(start, min(size, start + SEGMENT), BLOCK) for start in range(0, size, SEGMENT)]
    return [list(batch) for _, batch in groupby(offsets, key=lambda offset: offset // SEGMENT)]


def merge_plan(paths, size, progress, full_scan):
    if progress is not None:
        mode = progress.get('mode', 'full')  # Old journals were always full scans.
        image.require(mode in ('full', 'sparse-v1'), 'invalid compaction mode')
        if mode == 'full':
            return None, {'mode': 'full'}
        image.require(not full_scan, 'cannot change mode of an interrupted sparse job')
    elif full_scan:
        return None, {'mode': 'full', 'fallbackReason': 'explicit full scan'}

    offsets = set()
    unsupported = None
    for path in paths:
        try:
            offsets.update(asif_index.candidates(path, size))
        except asif_index.UnsupportedLayout as error:
            unsupported = str(error)
    if unsupported:
        image.require(progress is None, 'sparse checkpoint input layout changed')
        return None, {'mode': 'full', 'fallbackReason': unsupported}
    offsets = sorted(offsets)
    plan = {'mode': 'sparse-v1', 'planSHA256': hashlib.sha256(image.encoded(offsets)).hexdigest(),
            'candidateBytes': len(offsets) * BLOCK}
    if progress is not None:
        image.require(all(progress.get(key) == value for key, value in plan.items()), 'sparse checkpoint plan changed')
    return offsets, plan


def copy_blocks(base, source, target, size, progress, save, after_segment, segments=None):
    """Resume only verified segments. Newer source layers and zero writes win."""
    if segments is None:
        segments = segments_for(size)
    hashes = progress['hashes']
    image.require(isinstance(hashes, list) and len(hashes) <= len(segments)
                  and all(valid_hash(h) for h in hashes), 'invalid checkpoint journal')
    digest = hashlib.sha256()
    resumed = len(hashes)
    completed_bytes = 0
    for index, offsets in enumerate(segments):
        expected = hashlib.sha256()
        for offset in offsets:
            count = min(BLOCK, size - offset)
            completed_bytes += count
            data = os.pread(source, count, offset)
            image.require(len(data) == count, 'short source read')
            expected.update(data)
            digest.update(data)
            if index >= resumed:
                original = os.pread(base, count, offset)
                image.require(len(original) == count, 'short base read')
                if original != data:
                    image.require(os.pwrite(target, data, offset) == count, 'short compaction write')
        if index >= resumed:
            os.fsync(target)
        actual = hashlib.sha256()
        for offset in offsets:
            count = min(BLOCK, size - offset)
            data = os.pread(target, count, offset)
            image.require(len(data) == count, 'short compacted read')
            actual.update(data)
        image.require(actual.hexdigest() == expected.hexdigest(), 'compacted segment mismatch; preserve job and reset explicitly')
        if index < resumed:
            image.require(hashes[index] == expected.hexdigest(), 'checkpoint input mismatch')
        else:
            hashes.append(expected.hexdigest())
            if progress.get('mode') == 'sparse-v1':
                progress['completedBytes'] = completed_bytes
            save(progress)
            after_segment()
    return digest.hexdigest(), resumed


def verify_blocks(fd, size, hashes, segments=None):
    if segments is None:
        segments = segments_for(size)
    image.require(len(hashes) == len(segments), 'incomplete verification journal')
    digest = hashlib.sha256()
    for offsets, expected in zip(segments, hashes):
        part = hashlib.sha256()
        for offset in offsets:
            count = min(BLOCK, size - offset)
            data = os.pread(fd, count, offset)
            image.require(len(data) == count, 'short verification read')
            part.update(data)
            digest.update(data)
        image.require(part.hexdigest() == expected, 'final compaction verification mismatch')
    return digest.hexdigest()


def compact(store, name, failpoint=None, full_scan=False):
    parent, manifest = generation(store, name)
    job = store / 'jobs' / name
    source_hash = hashlib.sha256(image.encoded(manifest)).hexdigest()
    size = manifest['logicalBytes']
    if not job.exists():
        image.private_dir(job)
    recover_attachments(job, size)
    if (parent / 'ready.json').exists():
        artifact(store, name, manifest)
        durable(job / 'status.json', {'phase': 'READY'})
        return {'generation': name, 'phase': 'READY', 'reused': True}
    image.capacity(store, RESERVE)
    if not (job / 'input.json').exists():
        image.require(not (job / 'input').exists(), 'incomplete job preparation; reset explicitly')
        for side in ('input', 'output'):
            image.private_dir(job / side)
        records = []
        for record in manifest['disks']:
            path = job / 'input' / record['name']
            image.clone(parent / record['name'], path, 0o400)
            records.append({**record, 'stamp': image.stamp(path)})
        image.clone(parent / 'base.img', job / 'output/base.img', 0o400)
        durable(job / 'input.json', {'sourceManifest': source_hash, 'disks': records,
                                    'outputBase': image.stamp(job / 'output/base.img')})
    binding = read(job / 'input.json')
    image.require(binding['sourceManifest'] == source_hash, 'job input generation changed')
    inventory(job / 'input', binding['disks'])
    image.require(binding['outputBase'] == image.stamp(job / 'output/base.img'), 'output base changed')
    started = time.monotonic()
    if not (job / 'result.json').exists():
        source_layers = [job / 'input' / r['name'] for r in binding['disks']]
        target = job / 'output/merged.asif'
        progress_path = job / 'progress.json'
        progress = read(progress_path) if progress_path.exists() else None
        if progress is not None:
            image.require(progress['sourceManifest'] == source_hash, 'checkpoint generation mismatch')
        # A pre-upgrade worker may have attached an output before writing its first checkpoint.
        offsets, plan = merge_plan(source_layers[1:], size, progress, full_scan or (progress is None and target.exists()))
        segments = segments_for(size, offsets)
        if progress is None:
            progress = {'sourceManifest': source_hash, 'hashes': [], **plan}
            durable(progress_path, progress)
        if 'fallbackReason' in progress:
            plan['fallbackReason'] = progress['fallbackReason']
        durable(job / 'status.json', {'phase': 'COPYING', 'startedAt': time.time(), **plan})
        print(json.dumps({'stage': 'plan', 'job': name, **plan}), flush=True)
        if target.exists():
            image.regular(target).chmod(0o600)
        with contextlib.ExitStack() as stack:
            src = stack.enter_context(disks.attached(source_layers[0], source_layers[1:], size, readonly=True))
            dst = stack.enter_context(disks.attached(job / 'output/base.img', [target], size))
            with disks.read_file(job / 'output/base.img') as base, open(src, 'rb', buffering=0) as source, open(dst, 'r+b', buffering=0) as output:
                def save(value):
                    image.capacity(store, RESERVE)
                    with target.open('rb') as file:
                        fcntl.fcntl(file.fileno(), fcntl.F_FULLFSYNC)
                    checkpoint(job, value)
                digest, resumed = copy_blocks(base.fileno(), source.fileno(), output.fileno(), size, progress, save,
                                              lambda: crash('checkpoint', failpoint), segments)
                durable(job / 'status.json', {'phase': 'VERIFYING', **plan})
                if offsets is None:
                    image.require(verify_blocks(output.fileno(), size, progress['hashes'], segments) == digest,
                                  'logical disk digest mismatch')
        if offsets is not None:
            image.require(asif_index.candidates(target, size).issubset(offsets), 'unexpected changes outside the sparse plan')
            with disks.attached(job / 'output/base.img', [target], size, readonly=True) as device:
                with open(device, 'rb', buffering=0) as output:
                    image.require(verify_blocks(output.fileno(), size, progress['hashes'], segments) == digest,
                                  'sparse range digest mismatch')
        inventory(parent, manifest['disks'] + manifest['identity'])
        inventory(job / 'input', binding['disks'])
        target.chmod(0o400)
        records = [{'name': 'base.img', 'sha256': manifest['disks'][0]['sha256'], 'stamp': image.stamp(job / 'output/base.img')},
                   {'name': 'merged.asif', 'sha256': image.digest(target), 'stamp': image.stamp(target)}]
        digest_key = 'logicalSHA256' if offsets is None else 'rangeSHA256'
        result = {**plan, 'sourceManifest': source_hash, digest_key: digest, 'logicalBytes': size,
                  'seconds': time.monotonic() - started, 'resumedSegments': resumed, 'disks': records}
        durable(job / 'result.json', result)
    result = read(job / 'result.json')
    image.require(result['sourceManifest'] == source_hash, 'stale result')
    inventory(job / 'output', result['disks'])
    crash('verified', failpoint)
    durable(parent / 'ready.json', {'sourceManifest': source_hash, 'artifact': 'result.json',
                                  'sha256': hashlib.sha256(image.encoded(result)).hexdigest()})
    crash('published', failpoint)
    durable(job / 'status.json', {'phase': 'READY'})
    fields = ('mode', 'logicalSHA256', 'rangeSHA256', 'candidateBytes', 'fallbackReason', 'seconds', 'resumedSegments')
    return {'generation': name, 'phase': 'READY', **{k: result[k] for k in fields if k in result}}


def work(store, only=None, failpoint=None, full_scan=False):
    store_path(store)
    os.nice(10)
    fd = os.open(store / '.worker.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        names = [identifier(only)] if only else sorted(p.name for p in (store / 'generations').iterdir())
        results = []
        for name in names:
            _, manifest = generation(store, name)
            if len(manifest['disks']) + 1 < TRIGGER:
                continue
            try:
                results.append(compact(store, name, failpoint, full_scan))
            except Exception as error:
                job = store / 'jobs' / name
                if job.is_dir():
                    durable(job / 'status.json', {'phase': 'FAILED', 'error': str(error), 'time': time.time()})
                if only:
                    raise
                results.append({'generation': name, 'phase': 'FAILED', 'error': str(error)})
        return results
    finally:
        os.close(fd)


def reset(store, name):
    store_path(store)
    parent, manifest = generation(store, name)
    image.require(not (parent / 'ready.json').exists(), 'cannot reset a published result')
    fd = os.open(store / '.worker.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        image.require(not (parent / 'ready.json').exists(), 'cannot reset a published result')
        job = store / 'jobs' / name
        recover_attachments(job, manifest['logicalBytes'])
        image.require(job.exists(), 'job does not exist')
        retained = store / 'jobs' / ('.failed-' + name + '-' + uuid.uuid4().hex)
        os.rename(job, retained)
        durable(store / 'last-reset.json', {'generation': name, 'retained': retained.name})
        return {'retained': str(retained)}
    finally:
        os.close(fd)


def status(store, name):
    store_path(store)
    parent, manifest = generation(store, name)
    runtime_layers = len(manifest['disks']) + 1
    if (parent / 'ready.json').exists():
        artifact(store, name, manifest)
        return {'generation': name, 'phase': 'READY', 'runtimeLayers': 3}
    job = store / 'jobs' / name
    state = read(job / 'status.json') if (job / 'status.json').exists() else {'phase': 'QUEUED' if runtime_layers >= TRIGGER else 'NOT_REQUIRED'}
    progress = read(job / 'progress.json') if (job / 'progress.json').exists() else {'hashes': []}
    completed = (progress.get('completedBytes', 0) if progress.get('mode') == 'sparse-v1'
                 else min(len(progress['hashes']) * SEGMENT, manifest['logicalBytes']))
    return {**state, 'generation': name, 'runtimeLayers': runtime_layers, 'completedBytes': completed,
            'logicalBytes': manifest['logicalBytes']}


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    for command in ('init', 'ingest', 'checkout', 'work', 'reset', 'status', 'run'):
        p = commands.add_parser(command)
        if command == 'run':
            for name in ('instance', 'runner', 'script'):
                p.add_argument(name, type=Path)
            continue
        p.add_argument('store', type=Path)
        if command == 'ingest':
            p.add_argument('source', type=Path)
            p.add_argument('generation')
            p.add_argument('--no-start', action='store_true', help='queue only, for isolated failure tests')
        elif command in ('checkout', 'reset', 'status'):
            p.add_argument('generation')
            if command == 'checkout':
                p.add_argument('instance', type=Path)
        elif command == 'work':
            p.add_argument('--generation')
            p.add_argument('--full-scan', action='store_true', help='use the native full-scan path for a new job')
            p.add_argument('--crash-at', choices=['checkpoint', 'verified', 'published'],
                           help='isolated fault injection: SIGKILL this worker')
    args = parser.parse_args()
    for name, value in vars(args).items():
        if isinstance(value, Path):
            setattr(args, name, value.absolute())
    if args.command == 'init': result = initialize(args.store)
    elif args.command == 'ingest': result = ingest(args.store, args.source, args.generation, not args.no_start)
    elif args.command == 'checkout': result = checkout(args.store, args.generation, args.instance)
    elif args.command == 'work': result = work(args.store, args.generation, args.crash_at, args.full_scan)
    elif args.command == 'reset': result = reset(args.store, args.generation)
    elif args.command == 'status': result = status(args.store, args.generation)
    else: result = run(args.instance, args.runner, args.script)
    print(json.dumps(result), flush=True)
    if isinstance(result, list) and any(r.get('phase') == 'FAILED' for r in result):
        sys.exit(1)


if __name__ == '__main__':
    main()
