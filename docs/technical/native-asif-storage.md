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

For a cold restore, clone the sealed cumulative overlay into a new writable file and attach it over the exact same verified RAW base. This keeps the running stack at two layers. Preserve the VM identity and auxiliary storage alongside the overlay when restoring the same VM.

## Build and validation

The manual signed build workflow accepts `native_asif_build=true` to select the macOS 27 SDK runner. The default remains the existing runner. Dispatch against a branch for isolated validation; a branch build does not publish a release tag.

Tests cover legacy configuration decoding, explicit storage kinds, managed paths, immutable base permissions, missing layers, mixed storage rejection and unsupported SDK handling. A macOS 27 SDK build additionally opens a real two-layer attachment and rejects a RAW file supplied as the overlay. Real guest pause/seal/restore, corrupted base handling, TOS reconstruction and sustained workload validation remain separate acceptance requirements.

## Derived cold restore

The optional `machineState.nativeASIFChainEnabled` CRI setting defaults to false.
It also requires the existing native ASIF policy. A trusted storage controller
supplies `native-parent-count` only for an authenticated version 4 cold bundle.
The bundle pins the RAW base and contains ordered, digest-bound `parent-NN.asif`
members plus VM identity. The runtime creates a fresh writable `active.asif`
and attaches the immutable parents oldest first. A running chain is limited to
five total layers. The version 1 RAW and version 3 native imports remain valid.

`container-runtime-macos compact-asif` processes detached clones in a private
job. It uses the observed ASIF v1 index to select ranges and macOS native disk
devices to resolve data. An unrecognized input layout uses a native full scan.
The job revalidates checkpoints and publishes only a verified cumulative ASIF.
The storage controller can use it before publishing a derived restore bundle
when the next start would reach four layers. It does not replace the disk of an
active VM.
