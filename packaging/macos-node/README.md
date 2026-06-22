# macOS Node Installer Packaging

This directory contains the package inputs for the experimental macOS
Kubernetes worker-node installer.

The installer embeds a Darwin arm64 kubelet artifact built from the Kubernetes
fork branch `macos-node/v1.27.2` and stages the container node-side components
needed by the first rollout:

- `container` and core container runtime helpers
- `container-cri-shim-macos`
- `container-cni-macvmnet`
- `container-kube-proxy-macos`
- `container-macos-kubeadm`
- forked `kubelet`
- kubelet, CRI, CNI, and kube-proxy config templates
- launchd plists for kubelet, CRI shim, and kube-proxy

The package does not include cluster credentials, does not load launchd
services, and does not enable PF during package installation. Operators should
use `container-macos-kubeadm join` after installing the package to install
kubeconfigs, render node-specific configuration, and start the local services.
Core container services are still started through the normal `container system
start` path; `container-macos-kubeadm join` runs that command before starting
the Kubernetes launchd jobs.

Before joining the first macOS node, apply
`packaging/macos-node/manifests/macos-node-bootstrap-rbac.yaml` to the Linux
control plane from an admin workstation. The same manifest is also staged in
installed packages under
`/usr/local/share/container-macos-node/manifests/macos-node-bootstrap-rbac.yaml`.
It creates the `kube-proxy-macos` ServiceAccount and allows kubeadm bootstrap
tokens to request the kube-proxy token needed by the host launchd service.

The join command follows the Linux kubeadm shape:

```sh
sudo container-macos-kubeadm join 10.0.0.10:6443 \
  --token abcdef.0123456789abcdef \
  --discovery-token-ca-cert-hash sha256:<hash> \
  --node-name macos-node-1 \
  --network-mode full
```

Choose the network mode for the node before joining it:

- `--network-mode full` is the default. It requires macOS 26 or newer and uses
  the vmnet-backed CNI path with kube-proxy. Full-mode Pods use the `macos`
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
RuntimeClass. Pods select the desired sandbox image with
`spec.runtimeClassName`, for example `macos-15-2`.

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

Apply only the manifest that matches the node mode when a cluster exposes a
single macOS scheduling surface. Apply both manifests when the cluster
intentionally supports both macOS 26+ full-mode nodes and older compat-mode
nodes.

Example compat workload:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: macos-compat-smoke
spec:
  runtimeClassName: macos-compat
  restartPolicy: Never
  containers:
    - name: smoke
      image: ghcr.io/example/macos-workload:15.2
      command: ["/bin/sh", "-lc"]
      args: ["sw_vers && sleep 3600"]
```

Use `container-macos-kubeadm status` to inspect installed files, generated
configuration, the CRI socket, and launchd state. Use
`container-macos-kubeadm reset --force` to stop node services and remove
generated node configuration while preserving installed binaries. Add
`--purge-state` only when kubelet, CRI/CNI state, and node logs should also be
removed.

Runtime logs are written to stable host paths:

- `kubelet`: `/var/log/kubelet.log`
- `container-cri-shim-macos`: `/var/log/container-cri-shim-macos.log`
- `container-kube-proxy-macos`: `/var/log/container-kube-proxy-macos.log`
- Pod log root: `/var/log/pods`
- Container log symlinks: `/var/log/containers`

For process state, inspect the matching launchd labels:

```sh
sudo launchctl print system/com.apple.container.kubelet
sudo launchctl print system/com.apple.container.cri-shim-macos
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
