# Reserved vmnet daemon lifetime

The macOS 26 reserved network backend binds its native reservation to the
InternetSharing process incarnation that created it. A helper-generated network
instance ID alone is not evidence that the system daemon still recognizes the
reservation after a crash.

## Lifetime checks

The backend reads kernel process metadata with `sysctl` and checks the executable
path with `proc_pidpath`. The identity contains PID and the kernel process start
timestamp, including microseconds. Only the root-owned
`/usr/libexec/InternetSharing` executable is accepted. Missing, ambiguous,
inaccessible or incomplete observations fail closed. No privileged process
inspection entitlement or private NetworkSharing RPC is used.

Reservation creation is bracketed by checks against one existing daemon
identity. If the daemon is initially absent, one unpublished startup reservation
may launch it on demand. That reservation is released before the final create,
which is checked against the now-known identity. This is a bounded startup step,
not a retry or replacement of an active network.

Status reads, native-reference export, and activation validate the identity.
Export checks again after serialization; activation checks again after waiting
for the gateway. Cached service activation also rechecks network status. Once
validation fails, the helper returns no running status and rejects exports and
activation permanently for that instance. A later process with the same PID
cannot revive it. Existing references and allocation owners are retained until
normal stop or session cleanup; the helper does not automatically recreate a
network, discard active VM ownership, restart a service, or reboot the host.

An allocation whose reference export fails rolls back its newly allocated,
unowned address. An existing session's address is preserved. Rollback uses the
same per-hostname release coordination as session cleanup and reports cleanup
failure rather than silently discarding it.

## Recovery and limitations

The existing recovery coordinator receives a failed status probe instead of a
cached healthy generation. Its configured failure threshold and recovery policy
remain unchanged. In `reboot-node` mode, reaching that threshold can request a
host reboot. Deploy and fault-test this change only in a drained, isolated
maintenance window with that policy explicitly accounted for.

Process continuity is a conservative invalidation signal, not a positive native
reservation liveness or connectivity proof. It does not detect a native client
connection failure that leaves the same daemon process alive. A daemon can also
exit immediately after a successful check; activation and workload-readiness
gates remain necessary. Kernel or daemon implementation changes that prevent
identity inspection block admission rather than falling back to cached status.

Offline tests cover incarnation changes, PID reuse, missing identity, inspection
failure, bounded on-demand startup, cleanup, sticky invalidation, cached
activation rejection, and address ownership. Deployment acceptance additionally
requires a dedicated temporary network on the target OS: verify ordinary
allocation first, then verify fail-closed behavior across an authorized daemon
failure, recovery policy behavior, and full guest network readiness. Unit tests
and the standalone attachment probe do not replace that acceptance.
