# macOS process output under backpressure

The guest-agent, sidecar, and runtime isolate process output from slow sockets,
log files, and attachments. Output can be truncated under sustained congestion;
process pipes continue draining and terminal records have a reserved queue slot.
File-transfer acknowledgements and payloads do not use the lossy output queues.

## Limits

| Component | Bound and overflow behavior |
| --- | --- |
| Guest-agent output | 4 MiB and 1,024 queued records per process; discard new output until a truncation marker can be delivered |
| Sidecar event forwarding | Same bounds per process; a dedicated thread continues reading the guest stream while event delivery is slow |
| Runtime event consumption | Same bounds per process; bounded wakeups and a reserved exit record replace unbounded event buffering |
| Runtime log files | 4 MiB and 1,024 records per stdout/stderr writer; filesystem writes run outside the runtime actor |
| Socket frame delivery | Five seconds, including serialization-lock acquisition; blocking writes use a socket send timeout and preserve partial-frame offsets |
| Pipe drain after process exit | One second, covering descendants that keep stdout/stderr open |
| Queue drain after exit | Two seconds per queue, followed by a truncation marker and the retained terminal record |
| Runtime log completion | Wait up to two seconds in total before publishing process completion; the actor remains available during the wait |

Queue limits count output bytes before JSON/base64 encoding and exclude one
in-flight record and the truncation/terminal records. Output gaps are reported
with a `container: ... output truncated` marker. Regular-file kernel I/O cannot
always be interrupted, but it never runs on the runtime actor or vsock reader.

A socket write failure shuts down the connection. This prevents an incomplete
JSON frame from being followed by another frame and wakes its reader. Transport
failure follows the existing stream-failure/cleanup path; delivery of the real
exit code requires a functioning connection.

Virtualization.framework vsock descriptors remain in blocking mode because
duplicated descriptors share file status flags. Bounded writes use
`SO_SNDTIMEO`, fixed-size chunks, and the overall frame deadline.

## Deployment and validation

Update both the image's `container-macos-guest-agent` and the host's
`container-runtime-macos` / `container-runtime-macos-sidecar`. The framing and
event schema are unchanged; updating only the host leaves guest pipe handling
unchanged. Validate on an isolated node before rollout.

The local regression suites exercise real pipes and Unix sockets: unread output,
signal handling during backpressure, inherited output descriptors, queue
overflow, incomplete-frame timeouts, slow control clients, and slow log sinks.

```sh
swift test --filter 'MacOSGuestAgentTests|RuntimeMacOSSidecarSharedTests|RuntimeMacOSSidecarTests|RuntimeMacOSSidecarClientTests'
make fmt
make check
```

Real Virtualization.framework/vsock validation is separate. A passing Unix-socket
regression does not establish the cause of a guest that stops producing data
while its host continues reading.
