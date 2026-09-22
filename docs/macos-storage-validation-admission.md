# Storage admission for Mac validation

Storage validation must not rely on APFS clones having zero initial allocation.
Each clone can allocate new blocks while booting or building software, and those
blocks share capacity with kubelet image storage. Pinning base images prevents
their automatic removal; it does not create capacity or disable disk pressure.

## Runtime protection

The installed CRI must advertise sandbox images as `pinned=true` in both
ListImages and ImageStatus, and reject RemoveImage by tag, digest, and digest
alias. This behavior requires the sandbox role annotation
`org.apple.container.macos.image.role=sandbox`, or an explicit runtime pin.
Unannotated legacy images are not automatically protected. Installing only a
candidate sidecar or guest agent does not update the installed CRI image service.
Do not test RemoveImage against business images to discover whether protection
is installed. Validate rejection with the gRPC regression fixtures first; a
node-level negative test requires a separately owned disposable image.

Rebuilds sharing a manifest hold the same process lock. Cache GC skips an entry
while rebuilding, and waiting rebuilds reuse completed output. This protection
does not cover arbitrary CLI deletions or unrelated host cleanup processes.

## Admission and postflight

`scripts/macos-storage-preflight.py` runs on the target Mac. It reads the
installed CRI image filesystem and image inventory through a local Unix socket,
then uses `statvfs` available bytes, without counting purgeable space as free.
It requires a fresh kubelet evidence file, full image IDs that must be pinned,
all test storage roots, and a conservative **additional peak byte budget**.
Include downloads and extraction, full copies, potential CoW divergence,
machine-state memory files, logs, and builds. Already allocated bytes are
included in the measured usage. If a tighter CoW bound cannot be justified,
budget the full virtual disk size for each concurrently retained writable clone.

For every reported image filesystem and supplied storage root:

```text
projected_used = capacity - available + peak_additional_bytes
require projected_used < capacity * (gc_high_percent - margin_percent) / 100
margin_percent >= 5
```

The same total budget is checked conservatively on each volume; APFS shared
capacity is not added together. Unknown capacity, stale evidence, invalid
thresholds, missing images, missing pin flags, and unavailable CRI all block.
At an 85% GC threshold, projected usage must be below 80%, not merely below 85%.

The optional command executes once, without a shell or retries. A cooperative
file lock prevents overlapping runs using the same administrator-owned lock
path. Postflight runs even when the command fails, and rejects any image ID,
reference, or pin-state change. Keep this lock file; deleting it can split lock
ownership. Output is JSON on stdout, with rejection on stderr and exit code 2.
No command means read-only admission, apart from creation of the lock file.

This is an admission check, not a disk quota or continuous watchdog. It cannot
prevent an unrelated writer from consuming capacity during a command. Wrap each
bounded sample separately, retain its output, and stop new samples on any
rejection. The command remains responsible for stopping its own test VM in a
finally/EXIT handler. Do not bypass admission for an older installed runtime.

## Kubelet evidence

After verifying cluster context, API identity and readiness, fetch the exact
Node object and `/api/v1/nodes/<node>/proxy/configz` through the approved master
access path. Verify the expected UID, cordon, Ready and no active business Pods.
Package only the following fields into a credential-free JSON file, timestamped
at collection, and transfer it via the approved path. Do not transfer kubeconfig
or tokens to the Mac. The gate requires collection within 120 seconds, including
transfer time; do not refresh timestamps on old data.

```json
{
  "nodeName": "target-node",
  "nodeUID": "verified-node-uid",
  "observedAtUnix": 0,
  "configz": {
    "kubeletconfig": {
      "imageGCHighThresholdPercent": 85,
      "imageGCLowThresholdPercent": 80
    }
  }
}
```

The values above illustrate the schema, not defaults. The evidence is a trusted
operator input, not a signed cluster attestation. The gate checks its binding,
age and content; it does not independently contact the Kubernetes API.

Run a bounded sample on the verified, idle Mac using full SHA-256 image IDs:

```sh
python3 scripts/macos-storage-preflight.py \
  --node "$VALIDATION_NODE" --node-uid "$VALIDATION_NODE_UID" \
  --kubelet-evidence "$VALIDATION_EVIDENCE" \
  --endpoint "$VALIDATION_CRI_ENDPOINT" \
  --storage-root "$VALIDATION_DISK_ROOT" \
  --storage-root "$VALIDATION_ARTIFACT_ROOT" \
  --peak-additional-bytes "$VALIDATION_PEAK_BYTES" \
  --require-pinned "$VALIDATION_BASE_IMAGE_ID" \
  --lock-file "$VALIDATION_LOCK_FILE" \
  -- python3 /absolute/path/to/one-owned-sample.py
```

On Kubernetes nodes use `sh scripts/macos-node-machine-state-integration.sh`,
which invokes the gate before the VM integration entrypoint. It requires
`MACOS_STORAGE_NODE`, `MACOS_STORAGE_NODE_UID`, `MACOS_STORAGE_KUBELET_EVIDENCE`,
`MACOS_STORAGE_CRI_ENDPOINT`, `MACOS_STORAGE_BASE_IMAGE_ID`,
`MACOS_STORAGE_PEAK_ADDITIONAL_BYTES`, and `MACOS_STORAGE_LOCK_FILE`, in addition
to `CONTAINER_MACOS_MACHINE_STATE_INTEGRATION_ROOT`. Its budget must include
Swift build output. Cluster-side CRI/PPE orchestration is not automatically
wrapped: its node-local sample preparation must use this gate before writes.
The original `macos-machine-state-integration.sh` remains available for
standalone development Macs without kubelet; it provides no Kubernetes GC
admission protection and must not be used directly on a cluster node.

If protection is missing, stop. Updating an installed runtime requires a
separate node maintenance step with workload-idle verification and rollback.
Do not disable kubelet GC, raise thresholds, delete historical disks, or repull
images automatically. Continue only after installed-runtime pin readback and
the capacity check pass. A local mock test is not node acceptance.

## Regression

```sh
python3 scripts/macos-storage-preflight-self-test.py
swift test --filter CRIShimImageServiceTests
swift test --filter CRIShimRuntimeServerTests
swift test --filter MacOSGuestCacheTests
swift test --filter ZstdCodecTests
```

CI runs the admission self-test without SSH, VM startup, or live image deletion.
