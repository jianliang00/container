# macOS Guest Production Release Strategy

This document captures the first production rollout decision for a Kubernetes
cluster with a Linux control plane and macOS worker nodes.

## Kubernetes Baseline

- Production Kubernetes baseline: `v1.27.2`.
- macOS worker-node fork branch: `macos-node/v1.27.2`.
- The Linux control plane stays on a standard Kubernetes deployment.
- macOS-specific kubelet changes are maintained only in the fork branch and are
  treated as node-side platform patches.
- The current experimental Kubernetes fork `master` is not the production
  baseline until the Darwin patches are ported onto `v1.27.2`.

## Branch Policy

The Kubernetes fork should use these branches:

- `master`: mirror of the fork's default branch; not used directly for
  production Mac node releases.
- `macos-node/v1.27.2`: production Mac node branch based on upstream tag
  `v1.27.2`.
- `macos-node/v1.27.2-dev`: optional integration branch for unvalidated Darwin
  kubelet changes before promotion.

Production fixes land in `macos-node/v1.27.2` only after the Mac node validation
suite passes. Experimental work stays out of the production branch.

## Rebase And Patch Cadence

For the first rollout, do not rebase continuously. Use this cadence instead:

1. Port the current Darwin kubelet patches onto upstream `v1.27.2`.
2. Run the Mac node validation suite.
3. Tag a production candidate.
4. Apply only critical fixes to `macos-node/v1.27.2`.
5. Re-evaluate the Kubernetes baseline as a separate upgrade project.

Patch releases should use new container and kubelet artifact tags rather than
mutating an existing production tag.

## Artifact Naming

Use explicit artifact names that include both the container release and the
Kubernetes baseline:

- `container-macos-node-<container-version>-k8s-v1.27.2.pkg`
- `kubelet-darwin-arm64-k8s-v1.27.2-<patch-version>`
- `container-cri-shim-macos-<container-version>`
- `container-cni-macvmnet-<container-version>`
- `container-vmnet-recovery-macos-<container-version>`
- `container-flannel-vxlan-macos-<container-version>`
- `container-kube-proxy-macos-<container-version>`
- `container-macos-node-status-<container-version>`

Release metadata must record:

- Kubernetes baseline tag.
- Kubernetes fork commit.
- container repo commit.
- macOS version and architecture validated.
- workload image baseline.
- CNI config version.

The Darwin kubelet artifact must be built with `CGO_ENABLED=1` because the
node stats path reads Mach host counters through cgo. A `CGO_ENABLED=0` Darwin
build is not a production artifact.

## Kubelet Release Artifact

The Kubernetes fork is responsible for producing the node-side kubelet artifact,
not the container repo. The fork branch `macos-node/v1.27.2` publishes a GitHub
Release artifact named:

- `kubelet-darwin-arm64-k8s-v1.27.2-<patch-version>.tar.gz`

That artifact contains:

- `bin/kubelet`
- `SHA256SUMS`
- `manifest.json`
- `LICENSES/kubernetes-LICENSE`

The release workflow must build on a native macOS arm64 runner with
`CGO_ENABLED=1`, run the Darwin kubelet package tests, and publish the tarball
plus a `.sha256` checksum. Release metadata records the fork commit, Kubernetes
baseline, build date, architecture, and cgo state.

Kubelet release tags are immutable. If a bad kubelet build is found, publish a
new `<patch-version>` and roll nodes forward or back by installing the matching
macOS node package.

## macOS Node Installer

The container repo owns the full macOS node installer package. The installer
takes the kubelet tarball from the Kubernetes fork as an input and embeds it
alongside the container node components:

- `container` and core runtime helpers
- `container-cri-shim-macos`
- `container-cni-macvmnet`
- `container-vmnet-recovery-macos`
- `container-flannel-vxlan-macos`
- `container-kube-proxy-macos`
- `container-macos-node-status`
- `container-macos-kubeadm`
- optional `container-k8s-networkpolicy-macos` binary, not enabled by default
- forked `kubelet`
- inert kubelet, CRI, CNI, Flannel, and kube-proxy config templates
- inert launchd templates for the CRI shim, Flannel, kubelet, kube-proxy, and
  VMNet recovery; kubeadm also renders the container-system bootstrap job

The installer package name is:

- `container-macos-node-<container-version>-k8s-v1.27.2.pkg`

The package stages binaries and inert assets only under `/usr/local/bin`,
`/usr/local/libexec/container`, `/usr/local/share/container-macos-node`, and
`/opt/cni/bin`. It does not write active `/etc/kubernetes`, `/etc/cni/net.d`,
`/Library/LaunchDaemons`, `/var/lib`, or `/var/log` paths. Kubeadm creates those
active paths from the installed templates during join.

The package does not include cluster credentials or certificates, does not load
launchd services, and does not enable PF. Operators must install or load the
macOS sandbox image, validate PF policy, and run the packaged
bootstrap helper to discover cluster settings, write node-local credentials and
configuration, start the core container services through `container system
start`, and then explicitly start the Kubernetes node services.

Before joining the first macOS node, apply the cluster prep manifest from an
admin workstation. In the source tree it lives at
`packaging/macos-node/manifests/macos-node-bootstrap-rbac.yaml`; in an installed
node package it is also staged at
`/usr/local/share/container-macos-node/manifests/macos-node-bootstrap-rbac.yaml`.

```sh
kubectl apply -f packaging/macos-node/manifests/macos-node-bootstrap-rbac.yaml
```

That manifest creates the `kube-system/kube-proxy-macos` and
`kube-system/flannel-macos` ServiceAccounts, grants their bounded proxy and
read-only Flannel permissions, and allows kubeadm bootstrap tokens in
`system:bootstrappers:kubeadm:default-node-token` to read the kubelet config
ConfigMap and request their short-lived ServiceAccount tokens during join.

The supported deployment path is to install the package and then run the
packaged bootstrap helper with kubeadm-compatible join arguments. Select one
network mode for each node before joining it:

- `full` is the default mode. It requires macOS 26 or newer, configures the
  vmnet-backed CNI path, starts kube-proxy, and registers the node for the
  `macos` RuntimeClass.
- `compat` is for older macOS hosts. It configures the CRI shim to use
  Virtualization.framework NAT, skips Pod CNI configuration, skips kube-proxy,
  and registers the node for the `macos-compat` RuntimeClass. Compat-mode Pods
  have NAT egress, but they do not have a real Pod IP, ClusterIP Service
  semantics, NetworkPolicy, or inbound Service reachability.

Full-mode join:

```sh
sudo container-macos-kubeadm join 10.0.0.10:6443 \
  --token abcdef.0123456789abcdef \
  --discovery-token-ca-cert-hash sha256:<hash> \
  --node-name macos-node-1 \
  --network-mode full
```

Compat-mode join:

```sh
sudo container-macos-kubeadm join 10.0.0.10:6443 \
  --token abcdef.0123456789abcdef \
  --discovery-token-ca-cert-hash sha256:<hash> \
  --node-name macos-node-1 \
  --network-mode compat
```

`container-macos-kubeadm join` reads the public `kube-public/cluster-info`
ConfigMap, validates the discovered CA with `--discovery-token-ca-cert-hash`,
then uses the bootstrap token to read the kubelet config ConfigMap when
available. In full mode it also requests kube-proxy and Flannel ServiceAccount
tokens. It writes the CA certificate, kubelet bootstrap kubeconfig, kubelet
configuration, CRI configuration, launchd plists, and the matching RuntimeClass
manifest. Full mode additionally writes CNI, Flannel, and kube-proxy
configuration, then starts `container system`, `container-cri-shim-macos`,
Flannel, kubelet, and kube-proxy in dependency order. It writes and starts VMNet
recovery only when join includes `--vmnet-disconnect-recovery reboot-node`;
recovery is disabled by default. Compat mode starts `container system`, the CRI
shim, and kubelet, and intentionally does not configure Flannel, recovery, CNI,
or kube-proxy.
Token-bearing kubeconfig contents are never expanded in logs. Operators can
pass `--dry-run` to inspect the full plan without writing files, contacting the
API server, or starting services, and `--skip-start` to render files without
loading launchd jobs.

Apply the RuntimeClass manifests that should be exposed to workloads from an
admin workstation. The built-in default manifests are available from the source
tree:

```sh
kubectl apply -f packaging/macos-node/manifests/runtimeclass-macos.yaml
kubectl apply -f packaging/macos-node/manifests/runtimeclass-macos-compat.yaml
```

Installed packages also stage generated manifests under
`/usr/local/share/container-macos-node/manifests/` on each macOS node. Copy the
matching `runtimeclass-*.yaml` files to an admin workstation before applying
them when the source tree is not available there or when `--runtime-class`
generated additional RuntimeClasses.

Use only `runtimeclass-macos.yaml` for a cluster that exposes full-mode macOS
nodes only. Use only `runtimeclass-macos-compat.yaml` for a cluster that
exposes older compat-mode macOS nodes only. Apply both manifests only when the
cluster deliberately supports both scheduling targets.

Expose additional macOS sandbox images with repeated
`container-macos-kubeadm join --runtime-class <name>=<sandbox-image>` options.
Each additional RuntimeClass uses the joined node's selected network mode, and
Pods select it with `spec.runtimeClassName`. The join command writes generated
RuntimeClass manifests under
`/usr/local/share/container-macos-node/manifests/`; copy the matching
`runtimeclass-<name>.yaml` files to an admin workstation and apply them before
scheduling Pods that reference the new RuntimeClasses.

Example compat-mode node exposing two macOS base images:

```sh
sudo container-macos-kubeadm join 10.0.0.10:6443 \
  --token abcdef.0123456789abcdef \
  --discovery-token-ca-cert-hash sha256:<hash> \
  --node-name macos-node-1 \
  --network-mode compat \
  --runtime-class macos-15-2=ghcr.io/jianliang00/macos-base:15.2 \
  --runtime-class macos-15-4=ghcr.io/jianliang00/macos-base:15.4
```

Example Pod selecting one of those RuntimeClasses:

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

For compat-mode release validation, run macOS Pods sequentially on each host
unless that host has been validated for multiple active macOS VMs. Set
`automountServiceAccountToken: false` for validation Pods that do not need
Kubernetes API credentials.

Full-mode nodes advertise:

```text
kubernetes.io/os=darwin
node.kubernetes.io/macos=true
node.kubernetes.io/macos-network=full
```

Full-mode nodes also carry:

```text
node.kubernetes.io/macos=true:NoSchedule
```

Compat-mode nodes advertise:

```text
kubernetes.io/os=darwin
node.kubernetes.io/macos=true
node.kubernetes.io/macos-network=compat
```

Compat-mode nodes also carry:

```text
node.kubernetes.io/macos=true:NoSchedule
node.kubernetes.io/macos-network=compat:NoSchedule
```

Operators can inspect a node with:

```sh
sudo container-macos-kubeadm status
```

`status` is read-only. It reports the presence of packaged binaries,
node-specific Kubernetes configuration, the CRI socket, component status
files, and launchd jobs for the bootstrap helper, CRI shim, Flannel, kubelet,
kube-proxy, and VMNet recovery when it is enabled.

Operators can reset node-local Kubernetes configuration with:

```sh
sudo container-macos-kubeadm reset --force
```

`reset` stops VMNet recovery, kube-proxy, kubelet, Flannel, the CRI shim, and
the container-system bootstrap when present. Full mode withdraws the Flannel
tunnels, routes, forwarding ownership and kube-proxy PF anchors before removing
the owned Pod network and kubeadm-generated configuration. Compat-mode nodes do
not create Flannel, recovery, CNI, or kube-proxy runtime configuration, so reset
only removes the files and services that exist on the host. It preserves the
installed binaries and package payload. Use `--dry-run` to inspect the exact
plan without changing the host. Use `--purge-state` only when intentionally
removing kubelet, CRI/CNI/Flannel/recovery state, and node logs:

```sh
sudo container-macos-kubeadm reset --force --purge-state
```

Local validation can build the package with:

```sh
scripts/macos-node-installer/build.sh \
  --kubelet-artifact /path/to/kubelet-darwin-arm64-k8s-v1.27.2-1.tar.gz \
  --node-name macos-node-1
```

Unsigned packages are acceptable for local validation only. Production packages
must be code signed, product signed, notarized if distributed outside controlled
infrastructure, and accompanied by checksums, SBOM, and provenance metadata.

## Runtime And Sandbox Pairing

A production candidate is an immutable pair, not only a node package. Release
metadata must bind all of the following:

- the signed node package name, version, checksum, and container commit
- the immutable sandbox image digest
- the guest-agent checksum embedded in the package
- the checksum of the guest agent installed in the sandbox image
- the guest capabilities required by the release, including `tcpConnectV1`
- the workload image digest used by the canary

The package and sandbox guest-agent checksums must match before scheduling a
canary. A mutable image tag, a matching version string without a matching
checksum, or an unverified capability set is not sufficient. PortForward must
fail closed when the sandbox does not advertise the required TCP capability.

Rollback restores the previous signed package and its matching immutable
sandbox image as one unit. Keep both artifacts available until the replacement
has passed node reboot, Pod recreation, exec, PortForward, dual-stack Service,
and cleanup gates.

Production macOS node packages are published by GitHub Actions, not by a local
developer machine. The release workflow is `.github/workflows/macos-node-release.yml`.
It runs on a macOS runner, downloads the kubelet tarball from the Kubernetes
fork release, imports Developer ID signing material into an ephemeral runner
keychain, builds the package, verifies the package payload, submits the package
to Apple notarization, staples the ticket, writes a `.sha256` checksum, uploads
workflow artifacts, and creates or updates the GitHub Release.

The workflow is intentionally separate from the normal container installer
release because the macOS node package embeds a forked kubelet artifact and has
a different artifact name and release cadence. It can be triggered by:

- Manually dispatching `container project - macOS node release` with a
  `release_tag`, kubelet artifact URL, and default node name.
- Pushing a tag that matches `container-macos-node-*`.

The container repository must have these GitHub Actions secrets configured:

- `APPLE_DEVELOPER_ID_APPLICATION_CERTIFICATE_P12_BASE64`
- `APPLE_DEVELOPER_ID_APPLICATION_CERTIFICATE_PASSWORD`
- `APPLE_DEVELOPER_ID_APPLICATION_IDENTITY`
- `APPLE_DEVELOPER_ID_INSTALLER_CERTIFICATE_P12_BASE64`
- `APPLE_DEVELOPER_ID_INSTALLER_CERTIFICATE_PASSWORD`
- `APPLE_DEVELOPER_ID_INSTALLER_IDENTITY`
- `APP_STORE_CONNECT_API_PRIVATE_KEY_BASE64`
- `APP_STORE_CONNECT_API_KEY_ID`
- `APP_STORE_CONNECT_API_ISSUER_ID`

The `.p12` certificates and App Store Connect `.p8` key are stored as base64
encoded secret values. The workflow must never write decoded signing material
outside `RUNNER_TEMP`, and it must rely on GitHub's release artifacts rather
than locally built packages for distribution.

## Log Directories

The macOS node package writes each launchd-managed process to a stable log
path:

| Process | launchd label | stdout/stderr log |
| --- | --- | --- |
| `container-system` bootstrap | `com.apple.container.macos-node-bootstrap` | `/var/log/container-macos-node-bootstrap.log` |
| `kubelet` | `com.apple.container.kubelet` | `/var/log/kubelet.log` |
| `container-cri-shim-macos` | `com.apple.container.cri-shim-macos` | `/var/log/container-cri-shim-macos.log` |
| `container-vmnet-recovery-macos` | `com.apple.container.vmnet-recovery-macos` | `/var/log/container-vmnet-recovery-macos.log` |
| `container-flannel-vxlan-macos` | `com.apple.container.flannel-vxlan-macos` | `/var/log/container-flannel-vxlan-macos.log` |
| `container-kube-proxy-macos` | `com.apple.container.kube-proxy-macos` | `/var/log/container-kube-proxy-macos.log` |

Use the kubelet log for node registration, pod lifecycle, probe, CRI, and log
streaming failures. Use the CRI shim log for runtime, image, sandbox, container,
exec, attach, and port-forward requests. Use the Flannel log for PodCIDR,
peer, route, tunnel, and ownership reconciliation. Use the recovery log for
fence, reboot budget, boot-session validation, and admission state. Use the
kube-proxy log for Service and EndpointSlice watch state, generated PF rules,
and PF apply failures. Compat mode does not start Flannel, recovery, or
kube-proxy, so those launchd jobs and logs are expected to be absent.

The Darwin kubelet fork also uses the standard kubelet CRI log layout:

- Pod log root: `/var/log/pods`
- Container log symlinks: `/var/log/containers`

The installer owns creating these directories with root ownership and stable
permissions before kubelet starts. Kubelet construction must not rewrite log
directory package globals from `--root-dir`, because that leaks between repeated
kubelet instances and tests.

Common node-local troubleshooting commands:

```sh
sudo tail -n 200 /var/log/container-macos-node-bootstrap.log
sudo tail -n 200 /var/log/kubelet.log
sudo tail -n 200 /var/log/container-cri-shim-macos.log
sudo tail -n 200 /var/log/container-flannel-vxlan-macos.log
sudo tail -n 200 /var/log/container-vmnet-recovery-macos.log
sudo tail -n 200 /var/log/container-kube-proxy-macos.log
sudo launchctl print system/com.apple.container.macos-node-bootstrap
sudo launchctl print system/com.apple.container.kubelet
sudo launchctl print system/com.apple.container.cri-shim-macos
sudo launchctl print system/com.apple.container.flannel-vxlan-macos
sudo launchctl print system/com.apple.container.vmnet-recovery-macos
sudo launchctl print system/com.apple.container.kube-proxy-macos
```

`container-macos-kubeadm reset --force --purge-state` removes these process
logs, `/var/log/pods`, and `/var/log/containers` together with the kubelet and
CRI/CNI, Flannel, kube-proxy, and VMNet recovery state directories.

## Rollback Policy

Rollback is node-local and must not require control-plane changes:

1. `cordon` and drain the macOS node when possible.
2. Stop launchd services for VMNet recovery when enabled, kube-proxy, kubelet,
   Flannel, CRI shim, container-system bootstrap, CNI helpers, and NetworkPolicy
   controller.
3. Restore the previous signed package from the recorded rollback unit.
4. Restore the matching sandbox image digest and verify its guest-agent
   checksum and capabilities.
5. Restore previous kubelet, CRI, CNI, Flannel, kube-proxy, VMNet recovery,
   and NetworkPolicy config.
6. Validate PF config before reloading it on full-mode nodes.
7. Start launchd services.
8. Confirm CRI readiness and Node readiness before uncordoning. On full-mode
   nodes, also confirm CNI and Flannel readiness, kube-proxy PF anchor state,
   VMNet recovery health when enabled, and a successful
   `container-macos-node-status` run.

Rollback artifacts must remain available for every production rollout.
