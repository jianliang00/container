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
- `container-kube-proxy-macos-<container-version>`

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
- `container-kube-proxy-macos`
- `container-macos-kubeadm`
- optional `container-k8s-networkpolicy-macos` binary, not enabled by default
- forked `kubelet`
- kubelet, CRI, CNI, and kube-proxy config templates
- launchd plists for kubelet, CRI shim, and kube-proxy

The installer package name is:

- `container-macos-node-<container-version>-k8s-v1.27.2.pkg`

The package stages files under system paths such as `/usr/local/bin`,
`/opt/cni/bin`, `/etc/kubernetes`, `/etc/cni/net.d`,
`/Library/LaunchDaemons`, `/var/lib/kubelet`, `/var/log/pods`, and
`/var/log/containers`.

The package does not include cluster credentials or certificates, does not load
launchd services, and does not enable PF. Operators must install
load the macOS sandbox image, validate PF policy, and run the packaged
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

That manifest creates the `kube-system/kube-proxy-macos` ServiceAccount, binds
it to `system:node-proxier`, and allows kubeadm bootstrap tokens in
`system:bootstrappers:kubeadm:default-node-token` to read the kubelet config
ConfigMap and request a bounded kube-proxy ServiceAccount token during join.

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
available. In full mode it also requests a kube-proxy ServiceAccount token. It
writes the CA certificate, kubelet bootstrap kubeconfig, kubelet configuration,
CRI configuration, launchd plists, and the matching RuntimeClass manifest. Full
mode additionally writes CNI and kube-proxy configuration, then starts
`container system`, `container-cri-shim-macos`, `container-kube-proxy-macos`,
and kubelet in dependency order. Compat mode starts `container system`, the CRI
shim, and kubelet, and intentionally does not configure CNI or kube-proxy.
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
Pods select it with `spec.runtimeClassName`.

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
node-specific Kubernetes configuration, the CRI socket, and launchd jobs for
the CRI shim, kube-proxy, and kubelet.

Operators can reset node-local Kubernetes configuration with:

```sh
sudo container-macos-kubeadm reset --force
```

`reset` stops kubelet, kube-proxy when present, and the CRI shim, flushes the
kube-proxy PF anchor when present, and removes kubeadm-generated kubelet, CRI,
CNI, kube-proxy, CA, and launchd configuration. Compat-mode nodes do not create
CNI or kube-proxy runtime configuration, so reset only removes the files and
services that exist on the host. It preserves the installed binaries and
package payload. Use `--dry-run` to inspect the exact plan without changing the
host. Use `--purge-state` only when intentionally removing kubelet, CRI/CNI
state, and node logs:

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
| `kubelet` | `com.apple.container.kubelet` | `/var/log/kubelet.log` |
| `container-cri-shim-macos` | `com.apple.container.cri-shim-macos` | `/var/log/container-cri-shim-macos.log` |
| `container-kube-proxy-macos` | `com.apple.container.kube-proxy-macos` | `/var/log/container-kube-proxy-macos.log` |

Use the kubelet log for node registration, pod lifecycle, probe, CRI, and log
streaming failures. Use the CRI shim log for runtime, image, sandbox, container,
exec, attach, and port-forward requests. Use the kube-proxy log for Service and
EndpointSlice watch state, generated PF rules, and PF apply failures. Compat
mode does not start kube-proxy, so the kube-proxy launchd job and log are
expected to be absent on compat-mode nodes.

The Darwin kubelet fork also uses the standard kubelet CRI log layout:

- Pod log root: `/var/log/pods`
- Container log symlinks: `/var/log/containers`

The installer owns creating these directories with root ownership and stable
permissions before kubelet starts. Kubelet construction must not rewrite log
directory package globals from `--root-dir`, because that leaks between repeated
kubelet instances and tests.

Common node-local troubleshooting commands:

```sh
sudo tail -n 200 /var/log/kubelet.log
sudo tail -n 200 /var/log/container-cri-shim-macos.log
sudo tail -n 200 /var/log/container-kube-proxy-macos.log
sudo launchctl print system/com.apple.container.kubelet
sudo launchctl print system/com.apple.container.cri-shim-macos
sudo launchctl print system/com.apple.container.kube-proxy-macos
```

`container-macos-kubeadm reset --force --purge-state` removes these process
logs, `/var/log/pods`, and `/var/log/containers` together with the kubelet and
CRI/CNI state directories.

## Rollback Policy

Rollback is node-local and must not require control-plane changes:

1. `cordon` and drain the macOS node when possible.
2. Stop launchd services for kubelet, CRI shim, CNI helper services,
   kube-proxy, and NetworkPolicy controller.
3. Restore the previous signed package or previous binary set.
4. Restore previous kubelet, CRI, CNI, kube-proxy, and NetworkPolicy config.
5. Validate PF config before reloading it on full-mode nodes.
6. Start launchd services.
7. Confirm CRI readiness and Node readiness before uncordoning. On full-mode
   nodes, also confirm CNI readiness and kube-proxy PF anchor state.

Rollback artifacts must remain available for every production rollout.
