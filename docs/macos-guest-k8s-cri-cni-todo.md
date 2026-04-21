# macOS Guest Kubernetes CRI/CNI TODO

Progress tracker for the current bounded CRI/CNI/NetworkPolicy delivery.

Related docs:

- [`macos-guest-k8s-cri-cni-implementation-plan.md`](./macos-guest-k8s-cri-cni-implementation-plan.md)
- [`macos-guest-k8s-cri-cni-roadmap.md`](./macos-guest-k8s-cri-cni-roadmap.md)
- [`macos-guest-core-design.md`](./macos-guest-core-design.md)
- [`macos-guest-networking-design.md`](./macos-guest-networking-design.md)
- [`macos-guest-networkpolicy-design.md`](./macos-guest-networkpolicy-design.md)
- [`macos-guest-workload-image-design.md`](./macos-guest-workload-image-design.md)

## 1. Implementation Capabilities

Configuration:

- [ ] Decide kube-proxy launch settings for single-node Service reachability.

CRI server:

- [x] Execute CRI metadata reconcile plans against core snapshots on shim
  startup.

RuntimeService:

- [x] Enrich `PodSandboxStatus` and `ListPodSandbox` with core sandbox
  snapshots and CNI network state.
- [ ] Support CRI container mounts for macOS guest workloads.
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
- [ ] Implement disconnect and stream timeout cleanup.

NetworkPolicy controller:

- [ ] Load kubeconfig and connect to the Kubernetes API.
- [ ] Watch `Pods`, `Namespaces`, and `NetworkPolicies`.
- [ ] Wire Kubernetes watch events into the local endpoint index for Pods
  scheduled to this node.
- [ ] Feed CRI sandbox metadata and CNI Pod IP state into the endpoint index.
- [x] Apply compiled policy with `ContainerKit.applySandboxPolicy`.
- [x] Remove compiled policy with `ContainerKit.removeSandboxPolicy` when Pods
  or policies are deleted.
- [ ] Load applied policy state and execute reconcile plans after Pod,
  Namespace, NetworkPolicy, shim, controller, kubelet, or apiserver restart.
- [ ] Emit logs and Kubernetes events for unsupported policy fields.

Tests:

- [ ] Add integration validation for local `crictl` lifecycle.
- [ ] Add integration validation for local kubelet static Pod lifecycle.
- [ ] Add integration validation for `kubectl logs`.
- [ ] Add integration validation for `kubectl exec`.
- [ ] Add integration validation for `kubectl port-forward`.
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

## 2. Acceptance Criteria

- [ ] `container-cri-shim-macos --config <path>` starts and listens on the
  configured Unix socket.
- [ ] `container-cni-macvmnet` handles `VERSION`, `STATUS`, `ADD`, `CHECK`,
  `DEL`, and `GC`.
- [ ] `container-k8s-networkpolicy-macos --config <path>` connects to the
  Kubernetes API and reconciles local sandbox policies.
- [ ] `crictl version` succeeds.
- [ ] `crictl info` succeeds.
- [ ] `crictl pull` can resolve a configured macOS workload image.
- [ ] `crictl runp` creates and starts one macOS VM-backed Pod sandbox.
- [ ] `crictl create` creates one workload in that sandbox.
- [ ] `crictl start` starts the workload.
- [ ] `crictl ps` lists the workload.
- [ ] `crictl inspect` reports stable sandbox and workload state.
- [ ] `crictl execsync` works.
- [ ] `crictl logs` or kubelet log-file inspection shows workload logs.
- [ ] `crictl stop/rm/stopp/rmp` cleans up workload, sandbox, and CNI state.
- [ ] Local kubelet can start a static Pod with one macOS workload container.
- [ ] Exec probe works.
- [ ] HTTP probe works.
- [ ] TCP probe works.
- [ ] `kubectl logs` works for the static Pod.
- [ ] `kubectl exec` works for the static Pod.
- [ ] `kubectl port-forward` works for the static Pod.
- [ ] Single-node Service reachability through kube-proxy works.
- [ ] Ingress `NetworkPolicy` allows selected traffic.
- [ ] Ingress `NetworkPolicy` denies unselected traffic.
- [ ] Egress `NetworkPolicy` allows selected Pod or IPv4 CIDR traffic.
- [ ] Egress `NetworkPolicy` denies traffic outside selected peers.
- [ ] Deleting the static Pod cleans up workload, sandbox, network lease, stream
  sessions, log mux state, and policy state.
- [ ] Restarting the NetworkPolicy controller reconciles the expected policy
  generation.
