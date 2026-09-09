# macOS VM machine-state protocol

The macOS runtime sidecar exposes a versioned framed-JSON control protocol for discovering, saving, and restoring Virtualization.framework machine state. The capability is local to the runtime and does not assume any external orchestration or storage system.

## Transport and versions

Each message is a four-byte big-endian payload length followed by one JSON envelope. Protocol version 1 is the original unversioned protocol. A missing `protocolVersion` is therefore interpreted as version 1 for existing methods such as `vm.stop`. Protocol version 2 adds machine-state operations. Protocol version 6 adds durable checkpoint preparation, disk/state pair receipts, storage-attachment observations, and workload adoption.

`vm.capabilities` accepts an unversioned request so an older client can discover supported versions. Existing machine-state methods accept protocol version 2 or 6; durable checkpoint methods require version 6. An unsupported explicit version returns a normal response envelope with:

```json
{
  "kind": "response",
  "response": {
    "requestID": "request-id",
    "ok": false,
    "protocolVersion": 6,
    "error": {
      "code": "protocolVersionMismatch",
      "message": "unsupported sidecar protocol version 99",
      "metadata": {
        "requestedVersion": "99",
        "currentVersion": "6",
        "supportedVersions": "1,2,3,4,5,6"
      }
    }
  }
}
```

Unknown methods are decoded without dropping the request id and return `unknownMethod`. The connection remains available for subsequent frames. Invalid device configuration and operation failures follow the same response-envelope rule.

## Methods

| Method | Version | Request payload | Result |
| --- | --- | --- | --- |
| `vm.capabilities` | 1-6 | none | Supported versions, lifecycle state, methods, and structured machine-state support reason |
| `vm.pause` | 2 or 6 | optional `machineState.timeoutSeconds` | Lifecycle state |
| `vm.resume` | 2 or 6 | optional `machineState.timeoutSeconds` | Lifecycle state and restored state id, if any |
| `vm.prepareCheckpoint` | 6 | Checkpoint, persistence, source Pod, and source generation identities | Immutable workload adoption manifest and digest |
| `vm.saveMachineState` | 2 or 6 | State id and timeout; v6 also requires the prepared checkpoint, sealed disk receipt, pair id, and compatibility class | Lifecycle state and durable pair receipt |
| `vm.machineStateReceipt` | 6 | `machineState.stateID` | Persisted durable pair and adoption manifest |
| `vm.abortCheckpoint` | 6 | `machineState.checkpointID` | Releases the checkpoint admission barrier |
| `vm.storageAttachments` | 6 | none | Writable/read-only mode, synchronization mode, connection count, and terminal error for each NBD attachment |
| `vm.restoreMachineState` | 2 or 6 | `machineState.stateID`, optional timeout | Paused lifecycle state, state id, and saved compatibility description |
| `vm.deleteMachineState` | 2 or 6 | `machineState.stateID` | State id and whether committed or incomplete state files were deleted |
| `vm.compatibilityDescription` | 2 or 6 | optional `machineState.stateID` | Current description and, when requested, saved description plus mismatch reasons |
| `vm.stop` | 1-6 | none | Existing stop behavior |

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

`process.start` acquires a short-lived lifecycle admission before contacting the guest. Admission is available only while the VM is `running` and is held through the guest start acknowledgement or failure, not for the lifetime of the process. Pause and other lifecycle transitions cannot begin while a process-start admission is held. Once a lifecycle transition begins, subsequent process starts are rejected, so a process cannot appear after the VM has entered quiescing.

`timeoutSeconds` must be finite and between 1 and 600 seconds. It is the caller's response deadline and does not cancel an operation already submitted to Virtualization.framework. When a client times out, it closes that control connection; the sidecar keeps the lifecycle state transitional until the framework callback completes. The client must reconnect and query `vm.capabilities` or the requested compatibility description before retrying. This prevents a timeout from allowing a concurrent stop or a second save/restore to race an operation that is still active.

## Managed files

Machine states are stored below `<runtime-root>/MachineStates/<stateID>/`:

```text
machine-state.vzstate
compatibility.json
adoption.json
manifest.json
```

The caller supplies only an opaque state id. It may contain letters, digits, dot, underscore, and hyphen and is limited to 128 characters. Slash, `.` and `..` ids are rejected. The runtime root and every existing path component are checked with `lstat`; symbolic links are rejected. The managed directory is mode `0700`, and state and compatibility files are mode `0600`.

Saving first reserves the final state directory with mode `0700`. Virtualization.framework writes the machine state directly to the final `machine-state.vzstate` URL because the saved state is bound to the URL passed to the framework; the state file or directory cannot be published later by rename. A version 2 save publishes `compatibility.json` as its commit marker. A version 6 save fsyncs the state, compatibility description, and `adoption.json`, then atomically publishes `manifest.json` last and fsyncs the directory. The v6 manifest contains the sealed disk receipt, canonical pair id, adoption digest, and state size. A v6 restore rejects any state without a complete, matching durable manifest. Any in-process validation, framework, or manifest failure removes the reserved directory. A completed state id is immutable and is not overwritten.

Restore validates that the state file and compatibility description are regular files below the managed directory before calling `restoreMachineStateFrom(url:)`.

Delete is idempotent: a missing state returns `deleted: false`. A completed state or an incomplete reserved directory returns `deleted: true` after its managed directory is removed. Delete is rejected while save or restore is in flight for that state. A successfully restored state also remains protected while its VM is paused or resuming; it can be deleted only after resume reaches `running`, or after the VM no longer has that state active.

## CRI configuration and binding leases

CRI integration is disabled unless `machineState.enabled` is explicitly set to `true`. The remaining node policy fields select the machine-state, sidecar-control, local-NBD, and lease directories. `machineState.runtimeOwnerUID` is the effective uid of the runtime sidecar and local NBD proxy. On startup, a root CRI shim creates the configured state, control, and NBD leaf directories with mode `0700` and transfers only those leaves to `runtimeOwnerUID`. A non-root shim requires `runtimeOwnerUID` to equal its own effective uid. The lease directory remains private to the CRI shim.

Machine-state cleanup requires an explicit `runtimeOwnerUID` that matches the owner of the retained lifecycle directory, lock and attestation (or the control socket for a legacy binding). Runtime and sidecar service removal and strict absence checks use that bound owner's launchd domain: `gui/<uid>` for a non-root owner, `user/0` for a root owner. The CRI shim's own uid and inherited launchd session do not select this domain. Missing, invalid or changed owner bindings fail before runtime deletion; launchd domain and permission errors remain errors and retain the lease. Ordinary non-machine-state service operations keep their existing caller-domain behavior.

CRI, runtime and sidecar accept both physical paths and the fixed macOS aliases `/etc`, `/tmp` and `/var`. Each alias must be a root-owned symbolic link with its exact expected `/private` target. Managed configuration and NBD allowlist comparisons use the physical spelling, independent of whether the socket already exists. Relative components, arbitrary symbolic links and untrusted owners remain rejected. Writable ancestors are forbidden except the exact system directories `/private/tmp` (root:wheel, `1777`) and `/private/var/run` (root:daemon, `0775`). These are traversal exceptions, not permissions to change system directory modes or to accept writable descendants. Control sockets remain `0600` inside runtime-managed directories.

Pod sandbox configuration uses individual annotations in the versioned `io.container.runtime.macos.machine-state.v1/` namespace:

| Annotation suffix | Requirement | Meaning |
| --- | --- | --- |
| `enabled` | Required, exactly `"true"` | Opts the sandbox into CRI machine-state handling. |
| `persistence-id` | Required | Stable identifier used for the persistent state directory, sidecar socket, lease, and durable workload identity. |
| `storage-generation` | Required, positive decimal `UInt64` | Generation of the current writable disk export. |
| `restore-state-id` | Optional as a pair | Immutable saved machine-state identifier selected for restore. |
| `restore-state-generation` | Optional as a pair | Disk generation captured by the selected state. |
| `restore-pair-id` | Required for warm restore | Canonical SHA-256 identity of the sealed disk, machine state, compatibility class, and adoption manifest. |
| `restore-manifest-digest` | Required for warm restore | SHA-256 digest of the persisted workload adoption manifest. |
| `restore-request-id` | Required for warm restore | Stable control-plane Resume operation id used to fence retries. |
| `block-devices` | Optional for cold boot; required with an NBD root for restore | Strict JSON array of local Unix-socket NBD devices. The first device must be the writable `root` device. |

Companion annotations are rejected unless `enabled` is present and true. The five restore annotations must either all be absent or all be present. A first cold boot uses `storage-generation: "1"` without restore annotations. Restoring a state saved from generation `N` supplies the complete durable tuple and uses writable `storage-generation: "N+1"`. A cold fallback after a failed warm attempt must fence generation `N+1` and use generation `N+2` or later. The runtime requires an explicit NBD root for this restore path.

Before creating sandbox metadata, the CRI shim atomically acquires `<persistence-id>.json` in the lease directory. The random CRI sandbox id remains the kubelet-facing handle; the persistence id is the stable runtime sandbox id used by the VM, sidecar, NBD socket, CNI, and workload mapping. The lease binds both ids to the Kubernetes Pod UID, selected state, pair, restore request, saved generation, and current storage generation. A retry by the same owner returns the persisted CRI sandbox id, which makes a lost `RunPodSandbox` acknowledgement idempotent. A different Pod UID, pair, request, or generation is fenced while that lease is active. `RemovePodSandbox` releases only a lease whose complete persisted owner still matches the sandbox metadata; machine-state and identity files remain available below the persistent state directory.

After failed bootstrap, a typed runtime `notFound` error, including one wrapped in internal errors across XPC, allows deletion checks to continue; it does not release the lease. Cleanup must still confirm removal of both runtime services and the control socket, acquire the matching process-lifetime lock exclusively, durably retire its attestation, and synchronize metadata deletion before releasing the lease. Permission errors, transport failures, missing files and error-message text alone do not establish runtime absence. Repeated Stop/Remove requests after completed cleanup succeed without repeating runtime deletion. An absent CRI record with an outstanding durable lease remains an explicit recovery error rather than an acknowledgement of completed cleanup.

The generation annotation does not create, clone, revoke, or fence an NBD export. A trusted storage controller must make generation `N` immutable after the save point, create one writable successor, and expose that successor through the same configured Unix-socket path before restore. The CRI lease prevents conflicting sandbox ownership on the node, while the storage service remains responsible for preventing stale writers.

## CRI Pod recreation and durable workload adoption

A machine-state restore intentionally creates new Kubernetes and CRI objects while retaining the saved VM and primary workload process state:

1. Start the initial Pod with a persistence id and writable storage generation `N`.
2. Freeze new durable process starts, require all output through the snapshot cursor to be acknowledged, capture the workload adoption manifest, pause the VM, seal the disk snapshot, and save machine state against the same canonical pair id.
3. Remove the old Pod so its sandbox lease is released. Persistent machine-state files are not removed.
4. Prepare writable generation `N+1`, then create a new Pod with the same persistence id and the complete durable restore tuple.
5. The runtime restores the VM to `paused`, resumes it, and maps each new random CRI container id to its stable runtime workload id. Each expected workload must return the exact execution id, trusted and guest launch fingerprints, process incarnation, source/current generations, and non-truncated event replay cursor from the saved manifest.
6. Treat the restore as complete only after `PodSandboxStatus(verbose=true)` reports protocol v3 `status: adopted` with exact workload and network counts, the Pod is `Ready`, and the first independent exec request succeeds.

For a Deployment or another workload controller, scale-to-zero must complete before its Pod template is changed to the restore annotations. Wait until the old Pod and sandbox are gone, prepare the writable successor, update the template, and only then scale up. Overlapping old and replacement Pods are rejected by the CRI lease while it is active and must also be prevented by the storage controller's writer fencing.

The logical execution slot is derived from the persistence id and container name. CRI attempt is deliberately excluded: an in-Pod restart with attempt greater than zero and a replacement Pod whose attempt resets to zero address the same durable execution. Adoption still requires the saved image digest, effective process configuration, and mounts to match. A conflicting payload or launch fingerprint is a hard failure.

Warm restore never creates a replacement execution when the selected state lacks the expected workload manifest. This fail-closed rule covers snapshots written with legacy metadata and snapshots whose execution id included a nonzero CRI attempt; either may still contain a durable process that the current runtime cannot identify safely. Existing attempt-zero identity records remain address-compatible. An incompatible snapshot requires an explicit offline metadata migration or a cold start and a new snapshot. Adding, removing, or renaming a primary container is likewise a cold-start topology change, not a warm-restore operation. Transient exec and attach clients reconnect through new CRI requests and are not part of the retained primary workload identity.

The runtime-to-guest durable process protocol uses four cumulative capabilities.
`durableProcessV1` provides the durable process lifecycle, `durableProcessV2`
adds storage-generation fencing, `durableProcessV3` adds acknowledged event
delivery, and `durableProcessV4` adds runtime-incarnation fencing. A
generation-fenced request carries the trusted runtime launch fingerprint, the
current writable storage generation, and, only during warm adoption, the
selected saved generation. A normal reconnect must match the process's bound
generation. Warm adoption succeeds only when the process is bound to the
selected saved generation and the current generation is newer; the guest then
advances the binding atomically after acknowledging the new controller. The
returned process status includes the guest launch fingerprint, bound generation,
and active runtime incarnation. Snapshot-capable releases require all four
capabilities so that no part of the fencing or replay contract is silently
disabled.

### Snapshot V1 durable-process boundary

Snapshot V1 is the initial CRI warm-restore feature and is independent of the sidecar and durable-process protocol version numbers. Its durable process supervisor retains the primary process and manages descendants that remain in that process's original process group. This is a process-group lifecycle contract, not macOS cgroup semantics or arbitrary process-tree discovery. A long-lived descendant that creates an independent session or process group through `setsid(2)`, `setpgid(2)`, double-fork daemonization, or an equivalent launcher escapes that contract. Snapshot V1 cannot guarantee lifecycle fencing, output adoption, or cleanup for such a descendant, even though the VM machine state may contain it.

Snapshot mode is therefore limited to workload templates whose long-lived processes remain in the primary process group. The trusted controller or admission policy must reject snapshot enablement for workloads that daemonize into independent sessions or groups, or configure those workloads to remain in the foreground. The runtime does not infer this eligibility from a command line and must not be treated as capturing an unrestricted process tree.

Verbose `Status` advertises `kross.macos.restore.capabilities.v3`. Verbose `PodSandboxStatus` exposes the basic `machineState` entry and, for a warm request, `kross.macos.restore.receipt.v3`. The receipt reaches `status: adopted` only when the persisted pair matches, the root storage generation is writable and newer, the exact non-empty workload topology has been adopted with matching process incarnations and replay cursors, and the stable network reservation is present.

These annotations select host persistence and writable node storage and therefore form a privileged orchestration boundary, not a tenant authorization token. Clusters must restrict them to a trusted controller or admission policy. The runtime validates identifiers, managed paths, NBD socket allowlists, leases, saved compatibility, and workload fingerprints, but it does not authenticate an annotation author or prove that an external storage service implemented the claimed generation transition.

## Compatibility description

### Active VM identity

The runtime root is the per-sandbox host directory. When machine-state persistence is configured, the binding also has a private `Identity` directory below its managed storage root. One identity provider selects the files used by VZ configuration, compatibility fingerprints, checkpoint capture, and restore:

| File | Persistent binding | Legacy binding |
| --- | --- | --- |
| `HardwareModel.bin` | Runtime root | Runtime root |
| `MachineIdentifier.bin` | Persistent `Identity` | Runtime root |
| `AuxiliaryStorage` | Persistent `Identity` | Runtime root |
| `macos-guest-network-lease.json` | Runtime root | Runtime root |

A new persistent binding inherits an existing valid runtime-root machine identifier and auxiliary storage together. Templates without a machine identifier receive a new unique identifier and a private auxiliary-storage copy. Once a persistent identifier exists, a changed runtime-root identifier does not replace it. An invalid persistent identifier, or auxiliary storage left without its identifier outside an explicit restore, is rejected instead of regenerating identity.

Each checkpoint contains an immutable identity bundle. Its hardware-model and machine-identifier digests must match the saved compatibility description. Restore validates the selected request, host and configuration before publishing identity files, and rejects mismatched existing hardware or machine identifiers. Auxiliary storage is restored from the verified checkpoint after those checks. All destination files are checked before any replacement, then staged on their destination filesystems and synchronized. A retry can complete an interrupted materialization before a VM is constructed; a failed restore never enters cold boot.

Identity directories require trusted ownership and reject arbitrary symbolic links. Identity files must be regular, singly linked, owned by the runtime user, and not writable by other users. Published identity files use mode `0600`. Bundle integrity alone does not establish warm-restore success: the VM and workload adoption checks remain required.

### Saved compatibility fields

The compatibility schema contains:

- compatibility schema and runtime protocol versions;
- exact host macOS build;
- Mac model and IOPlatform hardware UUID;
- SHA-256 fingerprints of `VZMacHardwareModel` and `VZMacMachineIdentifier` data;
- effective CPU count, memory size, boot loader, network backend, ordered block devices, directory-share count, graphics and virtio-socket presence;
- a SHA-256 fingerprint of critical runtime configuration, including block devices, mounts, GUI mode, and guest-agent port.
- the positive storage generation of the writable external disk used when the state was saved, when external generation tracking is configured.

Restore performs a conservative exact comparison before invoking Virtualization.framework. A different IOPlatform UUID returns `differentPhysicalHost`; a host update returns `hostBuildMismatch`; hardware, machine identifier, or configuration changes return their corresponding mismatch codes. Machine state is never presented as portable across physical Macs. Virtualization.framework additionally enforces its host-bound encryption and saved-state format checks.

For CRI-managed external disks, the saved manifest's storage generation must equal the annotation's selected saved `generation`. The annotation's `storageGeneration` instead identifies the newly cloned writable disk used by the resumed VM, so it is deliberately excluded from ordinary current-versus-saved configuration comparison. Retrying a save for an existing state id is accepted only when its manifest has the same storage generation as the current writable disk. Legacy local-disk states that omit generation tracking remain compatible only with requests that also omit it.

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
- `machineStateInUse`
- `machineStateAlreadyExists`
- `machineStateStorageGenerationMismatch`
- `unsafeMachineStatePath`
- `machineStateIncompatible`
- `machineStateRestoreRequired`
- `identityBundleMismatch`
- `activeIdentityMismatch`
- `activeIdentityInvalid`
- `unsafeIdentityBundlePath`
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

On a joined Kubernetes node, `scripts/macos-cri-machine-state-integration.sh` validates Pod recreation and durable workload adoption. It starts at storage generation 1, exercises pause/resume, then pauses and saves without resuming. The foreground guest process keeps a random boot token and monotonic counter only in memory and emits token, PID, and counter samples to stdout. The test never writes this continuity state to the VM filesystem. After the original Pod is removed, the test creates a new Pod UID with the selected state generation 1 and writable generation 2. Success requires a `Ready` and `Running` Pod, a CRI container id, an independent first-exec readiness probe, and log-stream samples that retain the token and PID while the counter advances. Reading continuity only from the replacement Pod's live log stream prevents a disk-carried token from satisfying the restore check. For full storage validation, provide the script's restore-preparation helper so the stable NBD socket selects a fenced writable clone before the replacement Pod starts. The explicit in-place mode reuses the quiesced disk and validates only the runtime restore path.

The CRI integration uses one configured deadline for each sidecar operation and for final cleanup. A transport timeout does not cancel a submitted VM operation. The test reconnects, reads `vm.capabilities`, and, for save or delete, reads `vm.compatibilityDescription` before it retries or proceeds. If the result remains unresolved at the deadline, the test retains the Pod and durable binding for reconciliation instead of starting destructive cleanup.

Final success also requires a cleanup helper. The script first deletes each run-owned Pod synchronously and reads back that its recorded UID is absent, then waits for both the lease and control socket to disappear. It passes a private JSON request containing the exact run identities and an idempotency key to the helper twice. Each invocation must synchronously remove and read back all matching CRI objects, leases, control sockets, machine-state data, and test-owned snapshots, clones, and exports. The helper must not unlink a pre-existing NBD entry point; it only removes a binding owned by the request key. Both receipts must echo the request's SHA-256 digest and report every resource category absent. A cleanup failure overrides a successful test result, while an unresolved sidecar operation prevents cleanup from advancing.

Run `python3 scripts/macos-cri-machine-state-integration-self-test.py` without a cluster to exercise manifest escaping, protocol-version negotiation, lost-response reconciliation, indeterminate deadlines, cleanup receipts, and exit-status precedence.
