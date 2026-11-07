# Native ASIF overlay probe

This standalone diagnostic requires macOS 27 at runtime. Xcode 27 and the macOS
27 SDK are required only on the build machine. The basic `native-overlay-probe`
does not start a VM. Neither diagnostic installs a runtime, changes a cluster,
or upgrades macOS.

Build on a machine with the SDK, then copy the signed executable to the test Mac:

```sh
xcrun swiftc -O -target arm64-apple-macosx27.0 \
  scripts/macos-native-overlay-probe/Probe.swift -o native-overlay-probe
```

The dedicated GitHub Actions workflow uses `xcode-27`. It publishes a Developer
ID signed diagnostic artifact with a SHA-256 digest and build provenance. This
artifact is not a notarized production node package.

```sh
./native-overlay-probe self-test
./native-overlay-probe create-overlay /absolute/base.img /absolute/new-overlay.asif
./native-overlay-probe inspect-overlay /absolute/base.img /absolute/new-overlay.asif
```

`self-test` creates a private 64 MiB RAW fixture and ASIF overlay, constructs a VZ
storage attachment, closes and reopens the stack, checks that the base is
unchanged, and removes its fixture. Other commands retain the specified files.
Use only stopped, dedicated test images. A RAW base has no layer UUID; production
archive manifests must independently bind its content digest to the overlay.

Passing these checks establishes API availability and stack construction only.
Guest writes, flush and pause consistency, crash recovery, data corruption,
TOS archive round trips, and performance require separate VM validation.

## Isolated guest write and cold boot check

`native-overlay-vm-probe` boots one dedicated macOS test fixture with two CPUs,
4 GiB RAM, a display and a virtio socket. It configures no networking. The fixture
must contain a private RAW clone named `base.img`, its ASIF `overlay.asif`, and
private copies of `HardwareModel.bin`, `MachineIdentifier.bin`, and
`AuxiliaryStorage`. Never point it at a live runtime directory. Confirm available
VM capacity and that no other process has the fixture open before starting.
Reserve at least 20 GiB of free disk space before booting this small test; an
APFS clone shares initial data but guest writes still allocate new blocks.

The guest must run the container guest agent on virtio socket port 27000. The
fixed command writes or checks a UUID marker in the guest's temporary directory;
it cannot run an arbitrary supplied command. It stops its own VM after the check
or an ordinary error. Host failure or forced termination requires an independent
process and disk-handle cleanup check.

```sh
./native-overlay-vm-probe /absolute/private-fixture write UUID
# After confirmed VM stop, preserve the overlay and AuxiliaryStorage together.
# Copy them into another private fixture sharing the same immutable base.
./native-overlay-vm-probe /absolute/restored-fixture read UUID
```

This verifies cold boot persistence after stopping the test VM. It does not
establish that cloning an overlay while a VM is paused provides a consistent
snapshot, nor does it verify machine-state restoration or TOS durability.

## Paused copy experiment

`pause` writes and syncs a marker, pauses the VM, and uses APFS `clonefile` to
copy the base, ASIF and identity files into a new `paused-checkpoint` directory.
It then resumes the source, overwrites the same marker with a different value,
and stops the VM. Run `read` against the checkpoint to verify that it retains
the original value. The checkpoint directory must not already exist.

`pause-dirty` omits the guest `sync` before pausing. Missing unsynced guest data
is a separate observation from disk corruption: a cold disk snapshot does not
preserve guest RAM. Neither mode issues a host fsync on the source image.

```sh
./native-overlay-vm-probe /absolute/private-fixture pause UUID
./native-overlay-vm-probe /absolute/private-fixture/paused-checkpoint read UUID
```

These experiments measure the behavior of a specific host and guest combination.
A successful marker check alone is not a guarantee of crash consistency under
concurrent writes, database WAL activity or power failure.

`pause-wal` uses SQLite WAL mode with `synchronous=FULL`, commits a UUID row,
checks that a nonempty WAL exists and keeps the SQLite connection open while
pausing and cloning. It updates the source row after resuming. `read-wal`
checks `PRAGMA integrity_check` and the original row in the copied fixture.
The guest needs `/usr/bin/sqlite3`; the held writer exits after 120 seconds or
when the diagnostic stops its VM.

`pause-wal-sync` adds a guest-wide `sync` after the WAL commit and before
pausing. Compare it with `pause-wal` to distinguish the stronger pre-pause
flush from SQLite's own commit synchronization. Preserve an untouched copy of
each checkpoint before booting it; boot and WAL recovery can modify the files.

For a matched RAW control, provide another private writable APFS clone named
`raw.img` and use `raw-pause-wal`, `raw-pause-wal-sync` and `raw-read-wal`.
These modes attach `raw.img` through the existing URL-based VZ API and clone
it with the same pause procedure. The base and ASIF fixture files are retained
for a consistent fixture layout but are not attached in RAW mode.
