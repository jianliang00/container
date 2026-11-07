# Guest filesystem synchronization

`fs.sync` requests a guest-wide `sync()` through the macOS guest agent. It is an
explicit operation; VM pause, snapshot, startup and shutdown behavior are not
changed automatically.

## Capability and messages

The guest ready frame advertises `filesystemSyncV1`. The sidecar checks this
capability before sending a request. Older guests receive no unknown command;
the caller receives `unsupportedGuestCapability`.

The sidecar control request uses method `fs.sync` and the existing base64 `data`
field containing this JSON payload:

```json
{"requestID":"operation-123","timeoutSeconds":30}
```

The payload ID must match the outer control request ID. IDs are nonempty and
limited to 128 UTF-8 bytes; the finite timeout range is 0.01–120 seconds.

The sidecar sends a `filesystemSync` frame with the same ID and payload. The
guest replies with `filesystemSyncResult`; its frame ID and decoded payload
`requestID` must both match. The result acknowledges that `sync()` returned.
It does not assert that applications stopped writing, that a filesystem was
frozen, or that all devices provide power-loss durability.

## Concurrency, retry and timeout

One shared guest admission lock permits at most one sync call across all
connections. Concurrent requests, including duplicate IDs, receive EBUSY. The
host reports `operationInProgress` and must not treat it as successful sync.
Completed IDs are not cached: repeating an ID performs another sync, covering
writes that may have occurred after the first response.

Connection, ready handshake, request and result share one timeout budget. Only
the initial ready handshake may reconnect. The host never replays a dispatched
sync automatically. On timeout or cancellation, it closes the socket and reports
failure; a kernel sync already in progress may still finish. Other requests stay
busy until that call returns. No thread is killed or replaced to force completion.

A caller must await a matching successful response before taking any dependent
action. A response is not an atomic sync-and-pause transaction. Snapshot callers
must separately coordinate writers, VM lifecycle and disk sealing, and validate
their crash-consistency contract.

## Validation

Unit and socket-pair tests cover capability negotiation, mismatched IDs,
malformed replies, errors, uncertain completion, concurrent rejection, repeat
requests and admission release after failure. These tests inject the sync action
rather than flushing the developer machine's filesystem.

The native overlay diagnostic supports `pause-wal-rpc` and
`raw-pause-wal-rpc`. They keep a committed SQLite WAL open, invoke the RPC on a
separate vsock connection, pause and copy the private fixture, then advance the
source. Read the copied database with `read-wal` or `raw-read-wal`. A guest agent
with the capability must be installed only in the dedicated test image.
