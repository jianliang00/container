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
  --node-name macos-node-1
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
