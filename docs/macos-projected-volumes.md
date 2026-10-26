# Kubernetes projected volumes in macOS guests

ConfigMap, Secret, projected, and downward API directory volumes use guest-local
storage. Kubelet publishes these volumes by replacing its `..data` symlink.
Virtualization.framework shared directories can retain the replaced inode, so
applications cannot reliably observe updates through virtiofs.

The runtime identifies read-only mounts under kubelet's `volumes` directory by
volume plugin name. It excludes these mounts from the VM's shared directories.
Ordinary hostPath mounts and single-file injections keep their existing behavior.
Kubernetes subPath mounts remain fixed to the selected file or directory.

Before starting workloads, the runtime reads the active generation on the host
and transfers the complete snapshot through guest-agent. It checks the source
link again after reading; a concurrent kubelet replacement causes a retry instead
of publishing an incomplete snapshot. Transfers use bounded chunks and SHA-256
verification. Configuration contents are not written to runtime logs.

Guest-agent writes a private staging directory, restores file ownership and
permission bits, and marks its files and directories immutable. It then atomically
replaces the link to the active directory. Application mount paths stay stable;
new keys, removed keys, nested paths, and executable scripts switch together.
A process that opens several files separately can cross a version boundary,
as with Kubernetes AtomicWriter. Applications requiring a consistent multi-file
read should resolve and hold one generation directory.

The runtime checks the host generation link every two seconds. Unchanged volumes
require no content reads or transfers. Changes during a transfer are coalesced
into the next reconciliation. Failed transfers retain the last complete guest
version and retry; a sidecar reconnect invalidates the runtime's remembered
versions. The update task stops with the sandbox. Guest-agent retains the current
and previous generation and removes older generations, clearing their immutable
flags during cleanup. Sandbox deletion removes its guest disk and projections.

The node package and sandbox must both advertise `projectedVolumeV1` and contain
the paired guest-agent binary. Upgrading only the node package is insufficient.
Existing VMs retain their original volume mappings until recreated.

Immutable flags prevent ordinary writes, including direct writes by root. A
privileged guest process can explicitly clear these flags; this mechanism is not
a security boundary against an administrator inside the VM. General virtiofs
cache coherence and writable hostPath update behavior are outside this mechanism.
