# Native ASIF disk attachment

`nativeASIFOverlay` attaches one existing writable ASIF overlay over one immutable RAW base. It requires macOS 27 and a runtime built with the macOS 27 SDK. The default disk and NBD paths retain their existing behavior. An unavailable framework produces `nativeStorageUnavailable`; the runtime never treats an ASIF file as a RAW disk.

The initial contract supports one cold-boot disk, with no machine-state configuration. The trusted storage caller prepares both files below the private runtime root before starting the sidecar:

```json
{
  "identifier": "root",
  "kind": "nativeASIFOverlay",
  "path": "active.asif",
  "nativeBasePath": "base.img",
  "readOnly": false,
  "timeoutSeconds": 5,
  "synchronizationMode": "full"
}
```

Both paths must name existing, nonempty, distinct regular files within the runtime root, without symbolic links. The base must have no write permission bits; the overlay must be owner-writable. DiskImageKit must identify the base as RAW and the top layer as an ASIF overlay. The runtime opens the base read-only and uses full disk synchronization. No layer is created, flattened or replaced while attaching.

The materializer must verify the immutable base content against its archive or image digest before publishing the runtime configuration, retain that base for the lifetime of its dependent overlays, and exclude concurrent replacement or modification of these trusted files. RAW bases have no native parent UUID, so native stack construction alone does not authenticate the base's content. The attachment does not scan the entire base at every startup or maintain its own cache ledger.

## Checkpoint ownership

Use [filesystem checkpoint prepare and finish](filesystem-checkpoint.md) to reserve the paused interval. Storage-specific sealing remains the caller's responsibility. Full synchronization on the disk attachment and a guest sync acknowledgement do not by themselves prove that copying ASIF metadata while paused produces a valid cold snapshot. That boundary requires isolated VM validation before this attachment is used in a snapshot service.

For a version 3 cold restore, clone the sealed cumulative overlay into a new writable file and attach it over the exact same verified RAW base. This keeps the running stack at two layers. Preserve the VM identity and auxiliary storage alongside the overlay when restoring the same VM.

## Build and validation

The manual signed build workflow accepts `native_asif_build=true` to select the macOS 27 SDK runner. The default remains the existing runner. Dispatch against a branch for isolated validation; a branch build does not publish a release tag.

Tests cover legacy configuration decoding, explicit storage kinds, managed paths, immutable base permissions, missing layers, mixed storage rejection and unsupported SDK handling. A macOS 27 SDK build additionally opens a real two-layer attachment and rejects a RAW file supplied as the overlay. Real guest pause/seal/restore, corrupted base handling, TOS reconstruction and sustained workload validation remain separate acceptance requirements.

## Derived cold restore

The optional `machineState.nativeASIFChainEnabled` CRI setting defaults to false.
With the native ASIF policy enabled, it permits new OCI-derived chains and
version 4 cold restores. A trusted storage controller supplies
`native-parent-count` for a version 4 or 5 cold bundle. Both bundle versions pin
the RAW base and contain ordered, digest-bound `parent-NN.asif` members and VM
identity. Version 4 creates a fresh writable `active.asif`; version 5 restores
the archived `active.asif` and remains available when new-chain admission is
closed. A running chain is limited to five total layers.

`container create --os darwin --macos-asif` and `container run` with the same
flags enable native ASIF for CLI-managed instances. `container commit` seals a
writable layer into a derived OCI image. At four disk layers, the runtime queues
compaction and publishes an equivalent cached parent for future instances
using the same image digest. Existing instances retain their disk chains.

`container-runtime-macos compact-asif` processes detached clones in a private
job. It uses the observed ASIF v1 index to select ranges and macOS native disk
devices to resolve data. For full-discards-only regions, it skips blocks that
are holes in the RAW base. It keeps partial discards and any block with data
in the chain. An unrecognized input layout uses a native full scan.
The job revalidates checkpoints and publishes only a verified cumulative ASIF.
The storage controller can use it before publishing a derived restore bundle
when the next start would reach four layers. It does not replace the disk of an
active VM.
