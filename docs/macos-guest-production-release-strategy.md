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

Build the package with:

```sh
scripts/macos-node-installer/build.sh \
  --kubelet-artifact /path/to/kubelet-darwin-arm64-k8s-v1.27.2-1.tar.gz \
  --node-name macos-node-1
```

Unsigned packages are acceptable for local validation only. Production packages
must be code signed, product signed, notarized if distributed outside controlled
infrastructure, and accompanied by checksums, SBOM, and provenance metadata.

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
