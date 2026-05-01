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
`/etc/kubernetes/bootstrap-kubelet.kubeconfig`,
`/etc/kubernetes/kubelet.kubeconfig`, `/etc/kubernetes/kube-proxy.kubeconfig`,
and `/etc/kubernetes/pki/ca.crt`, load the macOS sandbox image, validate PF
policy, start the core container services through `container system start`, and
then explicitly start the Kubernetes node services.

The supported deployment path is to install the package and then run the
packaged bootstrap helper:

```sh
sudo container-macos-kubeadm join \
  --apiserver https://10.0.0.10:6443 \
  --bootstrap-token abcdef.0123456789abcdef \
  --kube-proxy-token <kube-proxy-bearer-token> \
  --ca-cert /path/to/ca.crt \
  --node-name macos-node-1 \
  --cluster-dns 10.96.0.10
```

`container-macos-kubeadm join` logs each deployment step, writes the CA
certificate, kubelet bootstrap kubeconfig, kube-proxy kubeconfig, kubelet
configuration, CRI/CNI/kube-proxy configuration, and launchd plists, then starts
`container system`, `container-cri-shim-macos`, `container-kube-proxy-macos`,
and kubelet in dependency order. Token-bearing kubeconfig contents are never
expanded in logs. Operators can pass `--dry-run` to inspect the full plan without
writing files or starting services, and `--skip-start` to render files without
loading launchd jobs.

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

`reset` stops kubelet, kube-proxy, and the CRI shim, flushes the kube-proxy PF
anchor, and removes kubeadm-generated kubelet, CRI, CNI, kube-proxy, CA, and
launchd configuration. It preserves the installed binaries and package payload.
Use `--dry-run` to inspect the exact plan without changing the host. Use
`--purge-state` only when intentionally removing kubelet, CRI/CNI state, and
node logs:

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

The Darwin kubelet fork uses the standard kubelet CRI log layout:

- `/var/log/pods`
- `/var/log/containers`

The installer owns creating these directories with root ownership and stable
permissions before kubelet starts. Kubelet construction must not rewrite log
directory package globals from `--root-dir`, because that leaks between repeated
kubelet instances and tests.

## Rollback Policy

Rollback is node-local and must not require control-plane changes:

1. `cordon` and drain the macOS node when possible.
2. Stop launchd services for kubelet, CRI shim, CNI helper services,
   kube-proxy, and NetworkPolicy controller.
3. Restore the previous signed package or previous binary set.
4. Restore previous kubelet, CRI, CNI, kube-proxy, and NetworkPolicy config.
5. Validate PF config before reloading it.
6. Start launchd services.
7. Confirm CRI readiness, CNI readiness, kube-proxy PF anchor state, and Node
   readiness before uncordoning.

Rollback artifacts must remain available for every production rollout.
