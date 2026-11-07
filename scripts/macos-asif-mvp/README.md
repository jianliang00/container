# macOS ASIF image MVP

This experiment runs a real macOS guest from an existing container macOS image,
commits its changed disk blocks as an OCI image, and boots a reconstructed
instance. It leaves the installed runtime, existing containers and cluster
configuration unchanged. Linux guests are outside its scope.

The host must run macOS 27 on Apple silicon. The guest can run macOS 26.
[DiskImageKit](https://developer.apple.com/documentation/diskimagekit) supplies
the native layered disk attachment. The build machine needs the macOS 27 SDK;
the test host does not need Xcode 27. Guest build tests need Xcode and CMake.

```mermaid
flowchart LR
    A[Existing OCI macOS image] --> B[Private stopped Disk.img copy]
    B --> C[Immutable RAW base]
    C --> D[Per-instance writable ASIF]
    D --> E[Guest build and sync]
    E --> F[Stop owned VM]
    F --> G[OCI manifest: base + sealed ASIF + VM identity]
    G --> H[Validate and reconstruct]
    H --> I[Readonly base + readonly ASIF + new writable ASIF]
    I --> J[Boot guest and verify build outputs]
```

## Build and run

The `macOS ASIF image MVP` workflow produces a Developer ID signed
`macos-asif-runner`, its checksum, signing details and compiler provenance.
It is an experimental executable, not a notarized node release. Keep the runner
beside `image.py` or supply `--runner /absolute/path/macos-asif-runner`.
Python 3 and `zstd` must be installed on the host. Use absolute canonical paths.

The input directory must be a **stopped, dedicated copy** containing `Disk.img`,
`HardwareModel.bin`, `MachineIdentifier.bin`, and `AuxiliaryStorage`. Confirm the
source is not a live runtime. The tool checks open handles before cloning. It
uses APFS clones; running and importing still consume additional physical space.
Reserve at least 20 GiB for writes and sufficient capacity for a cold base import
and compressed blobs. A large source image can require considerably more.

```sh
mkdir -m 700 /private/var/tmp/image-cache
python3 image.py init /absolute/stopped-source /absolute/raw --backend raw
python3 image.py init /absolute/stopped-source /absolute/asif --backend asif
python3 image.py run /absolute/asif /absolute/build.sh
python3 image.py commit /absolute/asif /absolute/oci-image --cache /private/var/tmp/image-cache
python3 image.py restore /absolute/oci-image /absolute/restored --cache /private/var/tmp/image-cache
python3 image.py run /absolute/restored /absolute/verify.sh
```

`run` starts one VM with four CPUs, 8 GiB memory and no networking. Build inputs must already be present in the dedicated test image. The script runs
as root through the existing guest-agent protocol on vsock port 27000; use `su`
inside the script for an ordinary build user. Only trusted local scripts are
supported. Output is retained as framed JSON in the private instance directory.
The wrapper waits for guest `sync` after the script and stops its own VM before
allowing a commit. A failed or timed-out run prevents commit. It does not preserve
memory, running processes or GUI sessions.

## Image and cache contract

The OCI artifact binds the ordered RAW base, ASIF layer and VM identity files by
SHA-256 and size. Every compressed and decoded file is verified during a cold
import. Missing, reordered, corrupted or unsupported entries prevent a runnable
instance from being finalized. Filenames are fixed, with no archive extraction
paths. This custom format is read only by this MVP; installed `container` versions
do not understand it yet. OCI registry upload is separate from local layout tests.

The private cache stores immutable files and their validated inode, size, mode
and modification metadata. Cache hits avoid a full base scan at every boot.
Changed cache files fail closed. This assumes one trusted local owner; it is not
a cache shared across security domains. Locks prevent this tool from running,
committing or importing into the same instance/cache concurrently. There is no
automatic cache eviction or background cleanup.

The MVP supports one derived image: base + sealed ASIF + active ASIF, at most
three disk layers while running. Further image commits are rejected until a
flattening path is implemented. Default restoration preserves VM identity for
an offline checkpoint. `restore --new-identity` creates a new machine identifier
for a separate test instance; this is not a general image sanitization workflow.

## Guest build measurement

`benchmark.py` runs as `admin` inside the test guest. It verifies zstd revision
`f8745da6ff1ad1e7bab384bd1f9d742439278e99` (v1.5.7) against the pinned source
archive checksum, generates an Xcode project, and records clean, incremental and
no-change build times. It also verifies compression/decompression with the built
binary. No network is used to fetch dependencies during measurement.

Before cloning the two test instances, place the pinned source tarball and
`benchmark.py` in `/Users/admin/MVPInput` in the private, stopped source image.
Use the existing image build workflow or mount only that private source copy,
copy the files to its Data volume, and unmount it before cloning. The files must
be readable by the guest admin user. A guest script invokes the benchmark:

```sh
set -eu
su -l admin -c '/opt/homebrew/opt/python@3.13/libexec/bin/python3 /Users/admin/MVPInput/benchmark.py prepare'
```

Run `prepare` once on each backend, then alternate RAW/ASIF boots running
`measure --sample N`. Use identical guest resources, source, toolchain and sample
numbers. After committing and restoring, run `verify` to compare source and
binary checksums and execute the restored binary. Report startup, build,
publication and reconstruction separately, including cold versus cached base
handling. Small sample counts establish pilot results, not production percentiles.

Host-side integrity tests:

```sh
python3 -m unittest discover -s scripts/macos-asif-mvp -p 'test_*.py' -v
```

## Restore comparison

Compare three decoded-cache states independently: no cached disk, only the
parent disk cached, and the complete target image cached. Keep OCI blobs local
for this experiment and report transfer costs separately. A cold-versus-warm
comparison of one backend does not measure a format speedup.

`MacOSImageRestoreExperimentTests` is an opt-in timing harness for the production
RAW `MacOSDiskRebuilder` and `FilesystemClone` path. Prepare a private, owned
directory containing `layout.json`, verified OCI blobs under `oci/blobs/sha256`,
the three VM identity files under `identity`, and `request.json` with distinct
`sample` and `cache` directory names. The harness is disabled unless
`MACOS_IMAGE_RESTORE_EXPERIMENT` points to that directory:

```sh
MACOS_IMAGE_RESTORE_EXPERIMENT="$EXPERIMENT_ROOT" \
  swift test -c release --filter MacOSImageRestoreExperimentTests
```

The harness records disk reconstruction and clone times and creates a private
RAW instance that the signed runner can boot. Use a fresh cache for the cold
sample, the same cache for target-image hits, and a separate parent cache when
measuring a new derived image. The existing RAW cache is keyed by the complete
image, so a decoded parent does not avoid rebuilding a new target image.

For each backend, also boot the prepared instance, run a command as the normal
guest user, and verify restored files and executable output. Report disk
preparation and preparation-to-first-user-command separately; neither metric
includes scheduling, network download or desktop readiness. Include any import
validation within the measured restore path. The ASIF MVP rechecks compressed
blobs and serially decodes and hashes the full logical disk, whereas the RAW
rebuilder processes sparse chunks in parallel after content-store verification.
This difference is an implementation cost, not an inherent property of ASIF.

Production adoption still requires runtime/OCI format negotiation, image ancestry
and GC integration, bounded flattening, encrypted TOS archive integration, power
failure testing and sustained guest workload acceptance. This experiment does
not change Suspend, Resume or the production image format.
