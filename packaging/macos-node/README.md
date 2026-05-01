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

Use `container-macos-kubeadm status` to inspect installed files, generated
configuration, the CRI socket, and launchd state. Use
`container-macos-kubeadm reset --force` to stop node services and remove
generated node configuration while preserving installed binaries. Add
`--purge-state` only when kubelet, CRI/CNI state, and node logs should also be
removed.

Build an unsigned package:

```sh
scripts/macos-node-installer/build.sh \
  --kubelet-artifact /path/to/kubelet-darwin-arm64-k8s-v1.27.2-1.tar.gz \
  --node-name macos-node-1
```

Set `PKG_SIGN_IDENTITY` to sign the resulting pkg with `productsign`. Set
`CODESIGN_IDENTITY` to control code signing for staged executables; the default
is ad-hoc signing.
