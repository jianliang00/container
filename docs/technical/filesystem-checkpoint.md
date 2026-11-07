# Guest filesystem checkpoint protocol

This optional sidecar protocol prepares a running macOS VM for a cold disk snapshot. It combines a guest-wide `sync()` acknowledgement with a VM pause and retains ownership while the caller seals disk files. It does not freeze applications or create an application-consistent checkpoint. Guest writers can modify pages between `sync()` and pause. The caller must still perform the storage-specific flush, seal and integrity checks; this protocol does not certify a disk snapshot by itself.

## Capability and requests

Discover `vm.prepareFilesystemCheckpoint` and `vm.finishFilesystemCheckpoint` in `vm.capabilities.methods`. Both requests require protocol version 6 and use the existing envelope's base64-encoded JSON `data` field. An older runtime rejects the unknown method; an older guest rejects the missing `filesystemSyncV1` capability. Callers must not fall back to separate sync/pause calls after a prepare failure.

Prepare payload:

```json
{"checkpointID":"unique-operation-id","timeoutSeconds":30}
```

The timeout covers the guest connection, handshake, sync request and acknowledgement. It does not impose a deadline on Virtualization.framework's pause callback. A client transport timeout is an unknown outcome, not cancellation. The successful response contains the same `checkpointID` and `lifecycleState: "paused"`.

Finish payload:

```json
{"checkpointID":"unique-operation-id","action":"resume"}
```

Use `resume` after a failed seal or to continue using the source VM. Use `stop` only after the caller has durably committed its snapshot. A successful finish releases ownership; a failed finish retains it for an explicit retry. The response includes the checkpoint ID and current lifecycle state. Neither action creates or deletes disk snapshots.

## Ownership and failure handling

1. Before prepare, complete active sidecar file transfers. An in-flight process start or another checkpoint rejects preparation without changing the VM.
2. Prepare reserves the lifecycle before sending guest I/O. New process starts, file-transfer sessions and ordinary VM lifecycle mutations are rejected throughout sync, pause and sealing. The session admission lock is released before waiting for the guest.
3. On success, seal and validate the disk while ownership remains held. This cold checkpoint is mutually exclusive with the durable machine-state checkpoint protocol; it cannot be used to save guest memory.
4. Retrying the current successful prepare returns the paused receipt without another sync. Retrying a failed prepare returns `checkpointUncertain`; it never replays an unacknowledged sync. A failure does not automatically resume or release the VM.
5. Only a matching finish may release ownership. A failed sync can be released with `resume`; this does not cancel a guest kernel sync that may still be running. A subsequent checkpoint requires a fresh ID.

Ownership is scoped to this sidecar process and VM instance, with no automatic expiry. The last completed finish is retained for retry, not as a permanent operation ledger. Callers must persist operation identity and outcome, never reuse IDs, and revalidate the VM instance after sidecar loss. A restarted sidecar cannot prove that an earlier checkpoint completed. This interface is not a disk archive, storage fencing, or recovery journal.

## Validation scope

Lifecycle tests cover exclusion during synchronization and sealing, duplicate prepare, wrong-owner finish, failed sync without replay, failed finish with retained ownership, invalid requests and process-start admission. Unix-socket tests cover version gating, failure retention, owner release and event-subscription independence. Guest sync transport tests separately cover missing capabilities, malformed or mismatched acknowledgements, busy and silent peers.

These tests do not establish native difference-layer sealing, TOS recovery, VM pause failure semantics, or end-to-end recovery latency. Those require isolated VM and PPE acceptance before this optional interface is used in a production snapshot flow.
