# macOS Node Installer Packaging

This directory contains the package inputs for the experimental macOS
Kubernetes worker-node installer.

The installer embeds a Darwin arm64 kubelet artifact built from the Kubernetes
fork branch `macos-node/v1.27.2` and stages the container node-side components
needed by the first rollout:

- `container` and core container runtime helpers
- `container-cri-shim-macos`
- `container-vmnet-recovery-macos`
- `container-cni-macvmnet`
- `container-flannel-vxlan-macos`
- `container-kube-proxy-macos`
- `container-macos-node-status`
- `container-macos-kubeadm`
- forked `kubelet`
- kubelet, CRI, CNI, Flannel VXLAN, and kube-proxy config templates
- launchd plists for container-system bootstrap, kubelet, CRI shim, vmnet recovery, Flannel VXLAN, and kube-proxy

The package does not include cluster credentials, write active Kubernetes
configuration under `/etc`, install launchd jobs, or enable PF. Its inert
configuration examples are stored under
`/usr/local/share/container-macos-node/templates`. Operators should use
`container-macos-kubeadm join` after installing the package to install
kubeconfigs, render node-specific configuration, and start the local services.
Core container services are still started through the normal `container system
start` path. Join also installs a one-shot system launchd job that re-enters the
configured container service user's launchd domain and runs that command after
each host boot. The job exits after a successful start and retries only after a
failure. `container-macos-kubeadm join` starts the core services and CRI shim
first, then starts the Flannel VXLAN daemon so it can wait for kubelet to publish
the assigned PodCIDR without creating a startup dependency cycle.

Installing a newer package does not rewrite active files under
`/Library/LaunchDaemons`; rerun the node's current join command during the
drained maintenance window to render and load the bootstrap job, explicitly
passing the original `--container-service-user`. Join rejects a different UID
while existing node configuration remains, preventing a second container core
from being started in another user domain. Before
downgrading to a package that predates the bootstrap job, use the current
version's `container-macos-kubeadm reset --force` or explicitly boot out
`system/com.apple.container.macos-node-bootstrap` and remove its plist. An older
binary does not provide the private bootstrap entry point.

Before joining the first macOS node, apply
`packaging/macos-node/manifests/macos-node-bootstrap-rbac.yaml` to the Linux
control plane from an admin workstation. The same manifest is also staged in
installed packages under
`/usr/local/share/container-macos-node/manifests/macos-node-bootstrap-rbac.yaml`.
Apply the current manifest before removing the legacy kube-proxy binding so the
ServiceAccount keeps uninterrupted API access:

```sh
kubectl apply -f packaging/macos-node/manifests/macos-node-bootstrap-rbac.yaml
kubectl delete clusterrolebinding container:kube-proxy-macos --ignore-not-found
```

It creates the `kube-proxy-macos` and `flannel-macos` ServiceAccounts and
allows kubeadm bootstrap tokens to request their tokens. The Flannel account
is read-only: it reads the cluster Flannel configuration and Node objects. The
Flannel daemon publishes and removes only its local Node's VXLAN annotations
with the kubelet client certificate from `/etc/kubernetes/kubelet.conf`.
Clusters must enable the Node authorizer and NodeRestriction admission plugin
so this node identity cannot modify another Node. Join stores each node-side
ServiceAccount token in a root-only file under
`/var/lib/container/kubernetes-credentials`. Initial and renewed tokens request
a 24-hour lifetime, and the Flannel and kube-proxy clients renew them through
the TokenRequest API shortly before expiry. Namespace-scoped Roles allow each
account to renew only its own token. If a node remains disconnected from the
API server until its current token has expired, rerun join with a valid
bootstrap token to restore its credentials.

The join command follows the Linux kubeadm shape:

```sh
sudo container-macos-kubeadm join 10.0.0.10:6443 \
  --token abcdef.0123456789abcdef \
  --discovery-token-ca-cert-hash sha256:<hash> \
  --node-name macos-node-1 \
  --network-mode full
```

The API server endpoint supplied to join and the server returned by
`kube-public/cluster-info` must both use HTTPS. Discovery rejects either
endpoint before sending bootstrap or ServiceAccount credentials.

Choose the network mode for the node before joining it:

- `--network-mode full` is the default. It requires macOS 26 or newer. Kubelet
  publishes the Node's assigned PodCIDR to the CRI shim; the Flannel daemon
  then creates the dedicated `kubernetes-pod` host-only vmnet network with
  that CIDR and joins the cluster's IPv4 VXLAN fabric. With
  `--enable-dual-stack`, Flannel waits for the control plane to allocate one
  IPv4 and one IPv6 PodCIDR before reconciling the host-only network and VXLAN
  for both families. CNI guest setup and the independent kube-proxy controller
  consume the same dual-family contract. Full-mode Pods use the `macos`
  RuntimeClass and get the normal macOS node labels:
  `node.kubernetes.io/macos=true` and
  `node.kubernetes.io/macos-network=full`. Full-mode nodes also carry the taint
  `node.kubernetes.io/macos=true:NoSchedule`.
- `--network-mode compat` is for older macOS hosts. It uses
  Virtualization.framework NAT, skips Pod CNI setup, does not start
  kube-proxy, and writes a `macos-compat` RuntimeClass manifest. Compat-mode
  Pods use NAT egress only: they do not get a real Pod IP, ClusterIP Service
  semantics, NetworkPolicy, or inbound Service reachability. Compat nodes get
  `node.kubernetes.io/macos=true`,
  `node.kubernetes.io/macos-network=compat`, and the taints
  `node.kubernetes.io/macos=true:NoSchedule` and
  `node.kubernetes.io/macos-network=compat:NoSchedule`.

The network mode is guarded while a Node object with the same name exists.
After CA-pinned discovery, join uses a short-lived `flannel-macos` credential
with read-only Node access to read that Node. A new node name can join directly.
An existing full-mode Node must already have the `full` network label and macOS
taint, without the compat taint. An existing compat-mode Node must already have
the `compat` network label and both managed taints. Join rejects missing or
conflicting metadata before changing local files or services. To change modes,
cordon and drain the Node from the control plane, then delete it or explicitly
update its macOS network label and managed taints before rerunning join. A dry
run makes no Kubernetes API requests and therefore does not validate metadata
on an existing Node.

Treat a full-mode join as a node maintenance operation. Cordon and drain the
Node before rerunning join, even when its PodCIDR is unchanged, because join
restarts kubelet, CRI, Flannel, and kube-proxy. When the PodCIDR is unchanged,
the owned `kubernetes-pod` network and its allocation state are retained. If
the Node object was deleted or its PodCIDR changed, drain and remove all
workloads, run `container-macos-kubeadm reset --force`, and then join again so
the host-only network is recreated from the newly assigned PodCIDR. Reset and
mode changes fail before stopping services when any container configuration or
live sandbox attachment still refers to the owned Pod network. Network
ownership is checked again immediately before deletion, after the VXLAN data
plane has been withdrawn.

Join renders the complete desired node configuration. Rerunning it on a node
with explicit network settings must repeat those settings; join does not merge
generated files from an earlier run. A dual-stack node can pin both kubelet
InternalIP addresses, the Flannel ConfigMap, and the underlay interface:

```sh
sudo container-macos-kubeadm join 10.0.0.10:6443 \
  --token abcdef.0123456789abcdef \
  --discovery-token-ca-cert-hash sha256:<hash> \
  --node-name macos-node-1 \
  --network-mode full \
  --enable-dual-stack \
  --vmnet-disconnect-recovery reboot-node \
  --node-ip 10.0.1.21 \
  --node-ip fd00:10:0:1::21 \
  --flannel-config-map-namespace kube-flannel \
  --flannel-config-map-name kube-flannel-cfg-macos \
  --flannel-underlay-interface en0
```

When `--node-ip` is specified for dual stack, pass the IPv4 address first and
the IPv6 address second. Omitting all `--node-ip` options preserves kubelet's
automatic address selection. Omitting `--flannel-underlay-interface` preserves
Flannel's automatic interface selection.

`--vmnet-disconnect-recovery reboot-node` is required only for node pools that
enable automatic recovery from a vmnet helper disconnect. It is disabled by
default; when omitted, kubeadm does not install or start the root recovery
coordinator and status collection does not expect its snapshot.

Dual stack is disabled unless `--enable-dual-stack` is present. Keep a newly
enabled node cordoned until same-node and cross-node traffic, Linux interop,
both ClusterIP families, EndpointSlice updates, DNS, external IPv6, MTU, and a
host reboot have passed for the exact release pair. Windows VXLAN IPv6 is not
supported; Mac↔Windows IPv4 remains a separate gate before enabling mixed-OS
backends.

To expose more than one macOS sandbox image on the same node, repeat
`--runtime-class <name>=<sandbox-image>` during join. Each additional
RuntimeClass uses the selected node network mode.

```sh
sudo container-macos-kubeadm join 10.0.0.10:6443 \
  --token abcdef.0123456789abcdef \
  --discovery-token-ca-cert-hash sha256:<hash> \
  --node-name macos-node-1 \
  --network-mode compat \
  --runtime-class macos-15-2=ghcr.io/jianliang00/macos-base:15.2 \
  --runtime-class macos-15-4=ghcr.io/jianliang00/macos-base:15.4
```

The generated CRI shim configuration registers one runtime handler per
RuntimeClass. Each additional profile also renders a
`runtimeclass-<name>.yaml` manifest under the package manifest directory. Pods
select the desired sandbox image with `spec.runtimeClassName`, for example
`macos-15-2`.

Pin every production sandbox image by digest. Release metadata and rollback
assets must bind the node package checksum, sandbox digest, package guest-agent
checksum, sandbox guest-agent checksum, and required capabilities. PortForward
requires `tcpConnectV1` and fails closed when the guest agent does not advertise
it. Restore the package and its matching sandbox image together during
rollback.

Use `--gui-runtime-class <name>=<sandbox-image>` instead of `--runtime-class`
for an additional handler that presents the sandbox GUI. GUI enablement is an
explicit per-handler property; RuntimeClass names do not change it implicitly.

After joining a node, apply the RuntimeClass manifests that should be exposed
to the cluster from an admin workstation. The built-in default manifests are
available from the source tree:

```sh
kubectl apply -f packaging/macos-node/manifests/runtimeclass-macos.yaml
kubectl apply -f packaging/macos-node/manifests/runtimeclass-macos-compat.yaml
```

Installed packages also stage generated manifests under
`/usr/local/share/container-macos-node/manifests/` on each macOS node. Copy the
matching `runtimeclass-*.yaml` files to an admin workstation before applying
them when the source tree is not available there or when `--runtime-class`
generated additional RuntimeClasses.

For a node joined with `--runtime-class macos-15-2=...`, apply the generated
manifest after copying it from the node:

```sh
kubectl apply -f runtimeclass-macos-15-2.yaml
```

Apply only the manifest that matches the node mode when a cluster exposes a
single macOS scheduling surface. Apply both manifests when the cluster
intentionally supports both macOS 26+ full-mode nodes and older compat-mode
nodes.

Example compat validation workload:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: macos-compat-check
spec:
  runtimeClassName: macos-compat
  automountServiceAccountToken: false
  restartPolicy: Never
  containers:
    - name: main
      image: ghcr.io/jianliang00/macos-base-workload:15.2
      command: ["/bin/sh", "-lc"]
      args: ["sw_vers && echo macos-compat-ok && sleep 3600"]
```

Example workload selecting an administrator-defined RuntimeClass:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: macos-15-2-check
spec:
  runtimeClassName: macos-15-2
  automountServiceAccountToken: false
  restartPolicy: Never
  containers:
    - name: main
      image: ghcr.io/jianliang00/macos-base-workload:15.2
      command: ["/bin/sh", "-lc"]
      args: ["sw_vers && echo macos-15-2-ok && sleep 3600"]
```

The CRI shim also accepts a Pod annotation override for the sandbox image:

```yaml
metadata:
  annotations:
    container-macos.io/sandbox-image: ghcr.io/jianliang00/macos-base:15.2
```

Clusters that expose this annotation should enforce an admission policy for
accepted sandbox images and callers. For basic compat-mode validation, run one
macOS Pod at a time on a host. Set `automountServiceAccountToken: false` for
validation Pods that do not need Kubernetes API credentials.

Machine-state persistence is opt-in per Pod sandbox through the versioned
`io.container.runtime.macos.machine-state.v1/` annotation namespace. The node
configuration controls all host paths; Pods cannot supply a state directory or
control socket path. A cold-startable sandbox uses:

```yaml
metadata:
  annotations:
    io.container.runtime.macos.machine-state.v1/enabled: "true"
    io.container.runtime.macos.machine-state.v1/persistence-id: example-vm
    io.container.runtime.macos.machine-state.v1/block-devices: >-
      [{"identifier":"root","unixSocket":"/var/run/container/nbd/example-vm.sock","readOnly":false,"timeoutSeconds":30}]
```

The first block device is the root device and must have identifier `root`.
Every configured device is a local Unix-socket NBD attachment with full disk
synchronization. Socket paths must be absolute, canonical, reachable, and below
a root listed in `machineState.nbdSocketAllowedRoots`. Unknown JSON fields,
duplicate identifiers, unavailable sockets, symbolic links, and paths outside
the allowlist are rejected before the sandbox is created.

The runtime derives the persistent state directory as
`<storageRoot>/<persistence-id>` and the discoverable sidecar socket as
`<controlSocketRoot>/<persistence-id>.sock`. Only one active sandbox may hold a
persistence ID. Machine states and VM identity remain in the state directory
after CRI sandbox removal; the volatile control socket does not.

`restore-state-id` is recognized by the v1 annotation decoder but CRI restore is
currently rejected with `criWorkloadAdoptionUnavailable`. Restoring only the VM
would leave the old guest process tied to a closed sidecar stream, while a new
CRI `CreateContainer`/`StartContainer` would launch a duplicate process with a
new container ID. The runtime therefore does not publish a warm-restore success
signal and does not fall back to a cold start. A future CRI restore protocol must
atomically adopt guest process identity, host workload metadata, logs, exec
sessions, and exit events before this annotation can succeed.

For enabled cold-started sandboxes, verbose CRI `PodSandboxStatus` includes a
`machineState` JSON entry with schema version, runtime protocol version,
`persistenceID`, and `restore.supported=false` plus the same structured reason
code. No `restored=true` signal exists in this release.

For example, the following additional annotation is deliberately rejected by
this release rather than reported as a warm restore:

```yaml
metadata:
  annotations:
    io.container.runtime.macos.machine-state.v1/restore-state-id: checkpoint-1
```

Direct runtime protocol v2 VM restore remains available outside CRI. It restores
before a VM cold start, leaves the VM paused, and requires an explicit resume.
Saved state is bound to the physical Mac, macOS build, VM hardware model,
machine identifier, VM configuration, and runtime protocol version. It must not
be moved to another physical Mac. This VM-level result is not a Kubernetes
workload restore result.

On a joined macOS node with a bootable root disk exported over a local NBD Unix
socket, run the real kubelet integration entry from the source checkout as the
container service user or root:

```sh
sudo env \
  MACOS_CRI_MACHINE_STATE_NODE=macos-node-1 \
  MACOS_CRI_MACHINE_STATE_IMAGE=ghcr.io/example/macos-workload@sha256:<digest> \
  MACOS_CRI_MACHINE_STATE_NBD_SOCKET=/var/run/container/nbd/integration.sock \
  scripts/macos-cri-machine-state-integration.sh
```

The check verifies protocol v2 capability, pause, save, and resume calls through
short-lived control clients without disrupting runtime exec, logs, or process
progress. It then deletes the Pod, creates a Pod with a new UID and the restore
annotation, and requires rejection before a CRI container ID is created.

Use `container-macos-kubeadm status` to inspect installed files, generated
configuration, the CRI socket, and launchd state. Use
`container-macos-kubeadm reset --force` to stop node services and remove
generated node configuration and the owned host-only Pod network while
preserving installed binaries. The reset command refuses to continue while a
container or sandbox still refers to that network. Add `--purge-state` only
when kubelet, CRI/CNI state, and node logs should also be removed.

In full mode, run `sudo container-macos-node-status` from the host monitoring
agent to export Prometheus text on standard output. The command does not open a
listener or modify the data plane. It reads only the three fixed root-owned
component status files, validates their schema, node and network identity, and
freshness, and emits bounded labels without raw errors, addresses, interface
names, or process identifiers. A missing, invalid, mismatched, or expired file
marks only that component's status source down. Alert separately on
`expected == 1 && status_up == 0`, on sustained Flannel or VMNet recovery
`expected == 1 && status_up == 1 && ready == 0`, and on a kube-proxy `failed`
state. Kube-proxy
`waitingForPodIngressRoute` is normal while the node has no local Pod; alert on
that state only when a local Pod should already have materialized its bridge
route. Dual-stack pools must also require the IPv6 family to have `enabled ==
1` and `ready/applied == 1`. Treat a non-zero collector exit or absent
`container_macos_kubernetes_collector_up` as a
collector failure; configuration errors occur before component metrics can be
emitted.

After a host reboot, expect the VM sandbox and workload container to be
recreated. Verify the Pod UID, Pod IPs, container attempt, EndpointSlices, and
Service traffic before uncordoning. The IPv4 allocation can remain stable while
the IPv6 interface identifier changes with the recreated VM MAC.

Runtime logs are written to stable host paths:

- container system boot bootstrap: `/var/log/container-macos-node-bootstrap.log`
- `kubelet`: `/var/log/kubelet.log`
- `container-cri-shim-macos`: `/var/log/container-cri-shim-macos.log`
- `container-vmnet-recovery-macos`: `/var/log/container-vmnet-recovery-macos.log`
- `container-flannel-vxlan-macos`: `/var/log/container-flannel-vxlan-macos.log`
- `container-kube-proxy-macos`: `/var/log/container-kube-proxy-macos.log`
- Pod log root: `/var/log/pods`
- Container log symlinks: `/var/log/containers`

When `vmnetDisconnectRecovery` is `reboot-node`, the root coordinator owns
`/var/lib/container/vmnet-recovery/state.json`. A non-root container service
user receives read-only access to that state and can only create
`/var/lib/container/vmnet-recovery/requests/fence.json`; it cannot rewrite the
reboot budget or delete a pending request.

For process state, inspect the matching launchd labels:

```sh
sudo launchctl print system/com.apple.container.kubelet
sudo launchctl print system/com.apple.container.macos-node-bootstrap
sudo launchctl print system/com.apple.container.cri-shim-macos
sudo launchctl print system/com.apple.container.vmnet-recovery-macos
sudo launchctl print system/com.apple.container.flannel-vxlan-macos
sudo launchctl print system/com.apple.container.kube-proxy-macos
```

Build an unsigned package:

```sh
scripts/macos-node-installer/build.sh \
  --kubelet-artifact /path/to/kubelet-darwin-arm64-k8s-v1.27.2-1.tar.gz \
  --node-name macos-node-1
```

Set `PKG_SIGN_IDENTITY` to sign the resulting pkg with `productsign`. Set
`CODESIGN_IDENTITY` to control code signing for staged executables; the default
is ad-hoc signing.
