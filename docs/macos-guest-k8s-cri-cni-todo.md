# macOS Guest Kubernetes CRI/CNI TODO

Progress tracker for the current bounded CRI/CNI/NetworkPolicy delivery.

Related docs:

- [`macos-guest-k8s-cri-cni-implementation-plan.md`](./macos-guest-k8s-cri-cni-implementation-plan.md)
- [`macos-guest-k8s-cri-cni-roadmap.md`](./macos-guest-k8s-cri-cni-roadmap.md)
- [`macos-guest-core-design.md`](./macos-guest-core-design.md)
- [`macos-guest-networking-design.md`](./macos-guest-networking-design.md)
- [`macos-guest-networkpolicy-design.md`](./macos-guest-networkpolicy-design.md)
- [`macos-guest-production-release-strategy.md`](./macos-guest-production-release-strategy.md)
- [`macos-guest-workload-image-design.md`](./macos-guest-workload-image-design.md)

## 1. Implementation Capabilities

Configuration:

- [x] Decide kube-proxy launch settings for single-node Service reachability.

kube-proxy macOS:

- [x] Add PF-backed `container-kube-proxy-macos` executable skeleton.
- [x] Compile IPv4 ClusterIP Service and EndpointSlice snapshots into local PF
  redirect rules.
- [x] Load bearer-token kubeconfig and relist Services and EndpointSlices.
- [x] Apply generated rules through a dedicated PF anchor.
- [x] Add launchd installer and uninstaller scripts with dry-run support.
- [x] Check PF enabled state before applying or starting the PF-backed daemon.
- [ ] Add event-driven Kubernetes watch support in addition to periodic relist.
- [ ] Extend support beyond single-node IPv4 ClusterIP TCP/UDP.

CRI server:

- [x] Execute CRI metadata reconcile plans against core snapshots on shim
  startup.

RuntimeService:

- [x] Enrich `PodSandboxStatus` and `ListPodSandbox` with core sandbox
  snapshots and CNI network state.
- [x] Persist CRI container mounts in macOS workload configuration.
- [x] Defer sandbox VM boot until the first `StartContainer` so workload
  mounts can be included in the boot-time `virtiofs` share set.
- [x] Merge sandbox and workload mounts before VM boot and reject conflicting
  hostPath or guest-path mappings deterministically.
- [x] Reject late workload mounts that were not already included in the
  sandbox VM boot-time mount set.
- [x] Prepare guest symlink mappings for each workload's configured mounts.
- [x] Implement `ReopenContainerLog`.
- [x] Implement `Exec` through a loopback streaming server.
- [x] Implement `PortForward` through a loopback streaming server.

Logs and exec streaming:

- [x] Implement CRI log adapter from workload stdout/stderr to kubelet log path.
- [x] Start and stop per-container log mux tasks with workload lifecycle.
- [x] Implement log rotation reopen behavior.
- [x] Add loopback-only streaming HTTP server.
- [x] Add short-lived stream token model.
- [x] Bridge streaming exec to `ContainerClient.streamExec`.
- [x] Bridge streaming port-forward to `ContainerKit.streamPortForward`.
- [x] Implement TTY resize handling where core exposes it.
- [x] Implement disconnect and stream timeout cleanup.

NetworkPolicy controller:

- [ ] Load kubeconfig and connect to the Kubernetes API.
- [ ] Watch `Pods`, `Namespaces`, and `NetworkPolicies`.
- [ ] Wire Kubernetes watch events into the local endpoint index for Pods
  scheduled to this node.
- [x] Project CRI sandbox metadata and core/CNI Pod IP state into
  NetworkPolicy endpoint-index events.
- [ ] Wire projected CRI/CNI endpoint events into the long-running
  NetworkPolicy controller.
- [x] Apply compiled policy with `ContainerKit.applySandboxPolicy`.
- [x] Remove compiled policy with `ContainerKit.removeSandboxPolicy` when Pods
  or policies are deleted.
- [x] Persist applied policy state and execute reconcile plans from restored
  controller state.
- [ ] Rebuild watch snapshots and reconcile after Pod, Namespace,
  NetworkPolicy, shim, kubelet, or apiserver restart.
- [ ] Emit logs and Kubernetes events for unsupported policy fields.

Tests:

- [x] Add integration validation for local `crictl` lifecycle.
- [x] Add integration validation for local kubelet static Pod lifecycle.
- [x] Add integration validation for API-backed Pod `kubectl logs`.
- [x] Add integration validation for API-backed Pod `kubectl exec`.
- [x] Add integration validation for API-backed Pod `kubectl port-forward`.
- [x] Add integration validation for static Pod mirror `kubectl logs`,
  `kubectl exec`, and `kubectl port-forward`.
- [ ] Add integration validation for single-node Service reachability through
  kube-proxy.
- [ ] Add integration validation for node-local ingress and egress
  `NetworkPolicy` allow/deny cases.
- [ ] Add cleanup validation for workload, sandbox, CNI lease, log mux, stream
  session, and policy state.

Operator docs:

- [ ] Document local `crictl` commands.
- [ ] Document local kubelet launch command.
- [ ] Document RuntimeClass, `kubernetes.io/os=darwin`, node label, taint,
  toleration, and static Pod examples.
- [ ] Document kube-proxy setup for single-node Service reachability.
- [ ] Document sample CNI config installation.
- [ ] Document NetworkPolicy controller config and supported policy subset.
- [ ] Document deterministic unsupported behavior for removed features.

## 2. Production Mac Worker Node Readiness

Production scope:

- [x] Keep the Kubernetes control plane on Linux and treat macOS as a worker
  node pool only.
- [x] Confirm the supported Kubernetes version, fork branch, rebase cadence, and
  rollback policy for the macOS kubelet fork: production baseline is Kubernetes
  `v1.27.2`; the fork branch is `macos-node/v1.27.2`.
- [ ] Confirm the macOS workload scheduling contract: RuntimeClass,
  `kubernetes.io/os=darwin`, a dedicated macOS node label, taint/toleration, and
  admission rules that keep ordinary Pods off macOS nodes.
- [ ] Confirm the Pod OS contract for macOS workloads. The current operating
  assumption is that macOS Pods do not set `.spec.os.name`, and scheduling is
  controlled by node labels, RuntimeClass, and admission policy.
- [ ] Define the supported workload surface for the first production rollout:
  static Pods, API-backed Pods, probes, logs, exec, port-forward, mounts,
  Service, and NetworkPolicy support level.

macOS kubelet fork:

- [x] Create `macos-node/v1.27.2` from upstream Kubernetes tag `v1.27.2` and
  port the current Darwin kubelet patches onto that branch.
- [x] Fix Darwin failures in `go test ./pkg/kubelet/kuberuntime` and
  `go test ./pkg/kubelet`.
- [x] Replace fake or synthetic cAdvisor stats with real macOS node/root stats,
  and keep Pod or workload stats owned by CRI stats calls.
- [x] Define and test the Darwin CRI sandbox contract instead of relying on a
  PodSandboxConfig with neither Linux nor Windows platform fields.
- [x] Remove global kubelet log-directory mutation. The Darwin kubelet fork
  keeps the standard kubelet log paths (`/var/log/pods` and
  `/var/log/containers`); production installers must create those directories
  instead of relying on kubelet construction to rewrite package globals.
- [ ] Define the Darwin mount and hostutil support matrix, including explicit
  unsupported behavior for Linux mount propagation semantics.

Node components and dataplane:

- [ ] Finish CNI 1.1.0 command acceptance for `VERSION`, `STATUS`, `ADD`,
  `CHECK`, `DEL`, and `GC`, including idempotent cleanup and restart recovery.
- [ ] Validate `container-kube-proxy-macos` with a real API server and
  single-node IPv4 ClusterIP TCP/UDP Service traffic.
- [ ] Decide whether NetworkPolicy is required for the first production rollout.
  If required, finish Kubernetes API watches and ingress/egress e2e validation;
  if not required, document NetworkPolicy as unsupported for the rollout.
- [ ] Decide the kube-proxy scope beyond the first rollout: watch-based updates,
  multi-node routing, NodePort, LoadBalancer, session affinity, and dual-stack.

Installation and operations:

- [x] Define initial production artifact naming and rollback policy in
  `docs/macos-guest-production-release-strategy.md`.
- [ ] Build a root-owned installer package for `container`, the CRI shim, CNI
  plugin, kube-proxy, optional NetworkPolicy controller, kubelet fork,
  kubeconfigs, RBAC manifests, CNI config, and launchd plists.
- [ ] Add preflight checks for macOS version, virtualization support, PF state,
  required privileges, disk space, network reachability, certificates, and
  existing conflicting launchd or PF configuration.
- [ ] Add uninstall, upgrade, rollback, and node drain procedures that preserve
  user data and restore PF configuration safely.
- [ ] Add operator health checks for launchd services, kubelet Node readiness,
  CRI socket readiness, CNI lease state, kube-proxy PF anchor state, and policy
  reconciliation state.
- [ ] Add production logging and metrics for kubelet fork health, CRI/CNI
  lifecycle, stream sessions, kube-proxy reconciliation, policy reconciliation,
  and cleanup failures.
- [ ] Define code signing, notarization, SBOM, image signing, registry, and
  release artifact provenance requirements.

Production validation:

- [ ] Run API-backed Pod and static Pod lifecycle e2e across create, start,
  stop, delete, restart, and node reboot.
- [ ] Run logs, exec, port-forward, exec/http/tcp probe, mount, and cleanup e2e
  under concurrent workload churn.
- [ ] Run CNI crash/restart recovery, duplicate `DEL`, stale lease cleanup, and
  daemon restart recovery tests.
- [ ] Run Service reachability, optional NetworkPolicy allow/deny, kubelet
  restart, CRI shim restart, kube-proxy restart, API server restart, and host
  reboot tests.
- [ ] Run at least one multi-day soak test with repeated Pod create/delete,
  stream sessions, Service traffic, and cleanup verification.

## 3. Acceptance Criteria

- [x] `container-cri-shim-macos --config <path>` starts and listens on the
  configured Unix socket.
- [ ] `container-cni-macvmnet` handles `VERSION`, `STATUS`, `ADD`, `CHECK`,
  `DEL`, and `GC`.
- [ ] `container-k8s-networkpolicy-macos --config <path>` connects to the
  Kubernetes API and reconciles local sandbox policies.
- [x] `crictl version` succeeds.
- [x] `crictl info` succeeds.
- [ ] `crictl pull` can resolve a configured macOS workload image.
- [x] `crictl runp` creates and starts one macOS VM-backed Pod sandbox.
- [x] `crictl create` creates one workload in that sandbox.
- [x] `crictl start` starts the workload.
- [x] `crictl ps` lists the workload.
- [x] `crictl inspect` reports stable sandbox and workload state.
- [x] `crictl execsync` works.
- [x] `crictl logs` or kubelet log-file inspection shows workload logs.
- [ ] `crictl stop/rm/stopp/rmp` cleans up workload, sandbox, and CNI state.
- [x] Local kubelet can start a static Pod with one macOS workload container.
- [x] Exec probe works.
- [x] HTTP probe works.
- [x] TCP probe works.
- [x] `kubectl logs` works for an API-backed Pod.
- [x] `kubectl exec` works for an API-backed Pod.
- [x] `kubectl port-forward` works for an API-backed Pod.
- [x] `kubectl logs` works for the static Pod mirror path.
- [x] `kubectl exec` works for the static Pod mirror path.
- [x] `kubectl port-forward` works for the static Pod mirror path.
- [ ] Single-node Service reachability through kube-proxy works.
- [ ] Ingress `NetworkPolicy` allows selected traffic.
- [ ] Ingress `NetworkPolicy` denies unselected traffic.
- [ ] Egress `NetworkPolicy` allows selected Pod or IPv4 CIDR traffic.
- [ ] Egress `NetworkPolicy` denies traffic outside selected peers.
- [x] Deleting an API-backed Pod cleans up workload and sandbox runtime
  objects.
- [ ] Deleting the static Pod cleans up workload, sandbox, network lease, stream
  sessions, log mux state, and policy state.
- [ ] Restarting the NetworkPolicy controller reconciles the expected policy
  generation.
