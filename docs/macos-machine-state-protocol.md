# macOS VM machine-state protocol

The macOS runtime sidecar exposes a versioned framed-JSON control protocol for discovering, saving, and restoring Virtualization.framework machine state. The capability is local to the runtime and does not assume any external orchestration or storage system.

## Transport and versions

Each message is a four-byte big-endian payload length followed by one JSON envelope. Protocol version 1 is the original unversioned protocol. A missing `protocolVersion` is therefore interpreted as version 1 for existing methods such as `vm.stop`. Protocol version 2 adds machine-state operations.

`vm.capabilities` accepts an unversioned request so an older client can discover supported versions. All other machine-state methods require `protocolVersion: 2`. An unsupported explicit version returns a normal response envelope with:

```json
{
  "kind": "response",
  "response": {
    "requestID": "request-id",
    "ok": false,
    "protocolVersion": 2,
    "error": {
      "code": "protocolVersionMismatch",
      "message": "unsupported sidecar protocol version 99",
      "metadata": {
        "requestedVersion": "99",
        "currentVersion": "2",
        "supportedVersions": "1,2"
      }
    }
  }
}
```

Unknown methods are decoded without dropping the request id and return `unknownMethod`. The connection remains available for subsequent frames. Invalid device configuration and operation failures follow the same response-envelope rule.

## Methods

| Method | Version | Request payload | Result |
| --- | --- | --- | --- |
| `vm.capabilities` | 1 or 2 | none | Supported versions, lifecycle state, methods, and structured machine-state support reason |
| `vm.pause` | 2 | optional `machineState.timeoutSeconds` | Lifecycle state |
| `vm.resume` | 2 | optional `machineState.timeoutSeconds` | Lifecycle state and restored state id, if any |
| `vm.saveMachineState` | 2 | `machineState.stateID`, optional timeout | Lifecycle state, state id, and compatibility description |
| `vm.restoreMachineState` | 2 | `machineState.stateID`, optional timeout | Paused lifecycle state, state id, and saved compatibility description |
| `vm.compatibilityDescription` | 2 | optional `machineState.stateID` | Current description and, when requested, saved description plus mismatch reasons |
| `vm.stop` | 1 or 2 | none | Existing stop behavior |

Capability discovery calls `validateSaveRestoreSupport()` on the effective `VZVirtualMachineConfiguration`. Validation failure is returned as `machineState.supported: false` with a structured `unsupportedReason` containing a stable code, message, and configuration component when known.

## Lifecycle and concurrency

The sidecar serializes VM lifecycle transitions through one coordinator.

| Operation | Valid source | Transitional state | Success state | Idempotent state |
| --- | --- | --- | --- | --- |
| start | `created`, `stopped` | `starting` | `running` | `running` |
| pause | `running` | `pausing` | `paused` | `paused` |
| resume | `paused` | `resuming` | `running` | `running` |
| save | `paused` | `saving` | `paused` | Existing completed state id returns its description |
| restore | `created`, `stopped` | `restoring` | `paused` | The same active state id while paused |
| stop | `running`, `paused`, `failed` | `stopping` | `stopped` | `created` becomes `stopped`; `stopped` is unchanged |

Only one transitional operation may exist. A concurrent stop, save, restore, pause, resume, or start returns `operationInProgress` with the current operation and lifecycle state. An invalid source state returns `invalidLifecycleState`. A failed operation returns to its stable source state; an inconsistent internal completion moves the coordinator to `failed`.

`timeoutSeconds` must be finite and between 1 and 600 seconds. It is the caller's response deadline and does not cancel an operation already submitted to Virtualization.framework. When a client times out, it closes that control connection; the sidecar keeps the lifecycle state transitional until the framework callback completes. The client must reconnect and query `vm.capabilities` or the requested compatibility description before retrying. This prevents a timeout from allowing a concurrent stop or a second save/restore to race an operation that is still active.

## Managed files

Machine states are stored below `<runtime-root>/MachineStates/<stateID>/`:

```text
machine-state.vzstate
compatibility.json
```

The caller supplies only an opaque state id. It may contain letters, digits, dot, underscore, and hyphen and is limited to 128 characters. Slash, `.` and `..` ids are rejected. The runtime root and every existing path component are checked with `lstat`; symbolic links are rejected. The managed directory is mode `0700`, and state and compatibility files are mode `0600`.

Saving first reserves the final state directory with mode `0700`. Virtualization.framework writes the machine state directly to its stable final URL because the saved state is bound to that URL. The runtime then validates the state as a regular file and atomically writes the compatibility manifest as the commit marker. Any validation, framework, or manifest failure removes the reserved directory. A completed state id is immutable and is not overwritten.

Restore validates that the state file and compatibility description are regular files below the managed directory before calling `restoreMachineStateFrom(url:)`.

## Compatibility description

The compatibility schema contains:

- compatibility schema and runtime protocol versions;
- exact host macOS build;
- Mac model and IOPlatform hardware UUID;
- SHA-256 fingerprints of `VZMacHardwareModel` and `VZMacMachineIdentifier` data;
- effective CPU count, memory size, boot loader, network backend, ordered block devices, directory-share count, graphics and virtio-socket presence;
- a SHA-256 fingerprint of critical runtime configuration, including block devices, mounts, GUI mode, and guest-agent port.

Restore performs a conservative exact comparison before invoking Virtualization.framework. A different IOPlatform UUID returns `differentPhysicalHost`; a host update returns `hostBuildMismatch`; hardware, machine identifier, or configuration changes return their corresponding mismatch codes. Machine state is never presented as portable across physical Macs. Virtualization.framework additionally enforces its host-bound encryption and saved-state format checks.

## Block-device configuration

`macosGuest.blockDevices` is an ordered, vendor-neutral list. An absent or empty list preserves the existing writable `Disk.img` root device.

Two backing kinds are supported:

- `runtimeDiskImage`: `path` must be relative to the runtime directory and cannot escape it or traverse a symbolic link.
- `nbdUnixSocket`: `path` must be an absolute local Unix-domain socket. TCP NBD endpoints and relative paths are not accepted. `exportName`, read-only mode, timeout, and full or no synchronization are explicit configuration fields.

For an NBD Unix socket, the sidecar checks the final object with `lstat`, requires it to be a socket, performs a connection probe, validates the generated `nbd+unix` URL, and constructs `VZNetworkBlockDeviceStorageDeviceAttachment`. The framework owns the NBD protocol connection and transparent reconnection behavior. A retained attachment delegate records first connection, subsequent reconnections, and terminal errors. Duplicate or empty device identifiers, invalid timeouts, non-socket paths, and failed connection probes are rejected before VM creation.

## Errors

Stable machine-state error codes include:

- `protocolVersionMismatch`
- `unknownMethod`
- `operationInProgress`
- `invalidLifecycleState`
- `invalidTimeout`
- `invalidMachineStateID`
- `machineStateNotFound`
- `machineStateIncomplete`
- `machineStateAlreadyExists`
- `unsafeMachineStatePath`
- `machineStateIncompatible`
- `unsupportedHostArchitecture`
- `unsupportedVMConfiguration`
- `invalidStorageConfiguration`
- `storageUnavailable`

The response preserves the request id and includes diagnostic `details` or string metadata when available. Existing `ContainerizationError` codes remain unchanged for legacy methods.

## Real-Mac validation

The integration entry requires a provisioned runtime directory containing `config.json`, `HardwareModel.bin`, `AuxiliaryStorage`, and the configured block device:

```sh
CONTAINER_MACOS_MACHINE_STATE_INTEGRATION_ROOT=/absolute/runtime/root \
  scripts/macos-machine-state-integration.sh
```

The test discovers save/restore support, starts the VM, pauses it, saves state, stops it, creates a fresh sidecar service over the same runtime directory, restores to paused, resumes, and stops. Compatibility unit tests cover a different physical host, host-build change, and configuration change without requiring access to a second Mac. Storage tests cover invalid paths, Unix-socket connection, reconnect observation, and managed-file cleanup.
