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

Protocol and generated code:

- [ ] Pin the CRI protobuf source to the selected Kubernetes `cri-api` tag.
- [ ] Add a regeneration command or script for CRI Swift protobuf and gRPC
  bindings.
- [ ] Document the CRI/CNI/Kubernetes references used by the implementation.

Configuration:

- [ ] Decide config file search order and default paths.
- [ ] Add sample kube-proxy config for single-node Service validation.
- [ ] Reject configs that enable Kubernetes integration without `vmnetShared`.
- [ ] Decide kube-proxy launch settings for single-node Service reachability.

CRI server:

- [ ] Start a Unix socket gRPC server from `container-cri-shim-macos`.
- [ ] Wire CRI request logging and structured error mapping into RPC handlers.
- [ ] Wire CRI sandbox metadata persistence into sandbox lifecycle RPCs.
- [ ] Wire CRI container metadata persistence into container lifecycle RPCs.
- [ ] Execute CRI metadata reconcile plans against core snapshots on shim
  startup.

RuntimeService:

- [ ] Implement `Version`.
- [ ] Implement `Status`.
- [ ] Implement `RuntimeConfig`.
- [ ] Implement `UpdateRuntimeConfig`.
- [ ] Implement `RunPodSandbox` with configured runtime handler and sandbox
  image.
- [ ] Invoke CNI `ADD` during `RunPodSandbox`.
- [ ] Start the macOS sandbox VM after successful CNI `ADD`.
- [ ] Implement `StopPodSandbox`.
- [ ] Invoke CNI `DEL` during sandbox stop and cleanup.
- [ ] Remove sandbox policy state during sandbox stop and cleanup.
- [ ] Implement `RemovePodSandbox`.
- [ ] Implement `PodSandboxStatus`.
- [ ] Implement `ListPodSandbox`.
- [ ] Implement `CreateContainer` for macOS workload images.
- [ ] Map CRI command, args, env, working directory, user, labels, annotations,
  mounts, and log path to workload metadata.
- [ ] Reject or clearly report unsupported Linux-only security context fields.
- [ ] Implement `StartContainer`.
- [ ] Implement `StopContainer`.
- [ ] Implement `RemoveContainer`.
- [ ] Implement `ContainerStatus`.
- [ ] Implement `ListContainers`.
- [ ] Implement `UpdateContainerResources` with deterministic unsupported/no-op
  behavior for Linux-only resource changes.
- [ ] Implement `UpdatePodSandboxResources` with deterministic unsupported/no-op
  behavior for Linux-only resource changes.
- [ ] Implement `ReopenContainerLog`.
- [ ] Implement `ExecSync`.
- [ ] Implement `Exec` through a loopback streaming server.
- [ ] Implement `PortForward` through a loopback streaming server.
- [ ] Return deterministic unsupported response for `Attach`.
- [ ] Implement minimal `ContainerStats`, `ListContainerStats`,
  `PodSandboxStats`, and `ListPodSandboxStats`.
- [ ] Implement deterministic handlers for `CheckpointContainer`,
  `GetContainerEvents`, `ListMetricDescriptors`, and `ListPodSandboxMetrics`.

ImageService:

- [ ] Implement `ListImages`.
- [ ] Implement `ImageStatus`.
- [ ] Implement `PullImage`.
- [ ] Implement `RemoveImage`.
- [ ] Implement minimal `ImageFsInfo`.
- [ ] Validate sandbox images before runtime handler use.
- [ ] Validate workload images before container start.
- [ ] Map CRI registry auth into existing image pull support.

CNI plugin:

- [ ] Wire CNI `ADD` to `PrepareSandboxNetwork`.
- [ ] Wire live CNI `CHECK` to `InspectSandboxNetwork` and guest interface
  validation.
- [ ] Wire CNI `DEL` to `ReleaseSandboxNetwork`.
- [ ] Connect CNI `GC` `cni.dev/valid-attachments` cleanup to the persistent
  attachment ledger.
- [ ] Persist CNI result metadata needed for cleanup.
- [ ] Make `ADD` idempotent for existing sandbox network leases.
- [ ] Make `DEL` tolerate already-released or missing leases.
- [ ] Return live CNI result data from sandbox network lease state.

Logs and exec streaming:

- [ ] Implement CRI log adapter from workload stdout/stderr to kubelet log path.
- [ ] Start and stop per-container log mux tasks with workload lifecycle.
- [ ] Implement log rotation reopen behavior.
- [ ] Add loopback-only streaming HTTP server.
- [ ] Add short-lived stream token model.
- [ ] Bridge streaming exec to `ContainerClient.streamExec`.
- [ ] Bridge streaming port-forward to `ContainerKit.streamPortForward`.
- [ ] Implement TTY resize handling where core exposes it.
- [ ] Implement disconnect and stream timeout cleanup.

NetworkPolicy controller:

- [ ] Load kubeconfig and connect to the Kubernetes API.
- [ ] Watch `Pods`, `Namespaces`, and `NetworkPolicies`.
- [ ] Wire Kubernetes watch events into the local endpoint index for Pods
  scheduled to this node.
- [ ] Feed CRI sandbox metadata and CNI Pod IP state into the endpoint index.
- [ ] Apply compiled policy with `ContainerKit.applySandboxPolicy`.
- [ ] Remove compiled policy with `ContainerKit.removeSandboxPolicy` when Pods
  or policies are deleted.
- [ ] Load applied policy state and execute reconcile plans after Pod,
  Namespace, NetworkPolicy, shim, controller, kubelet, or apiserver restart.
- [ ] Emit logs and Kubernetes events for unsupported policy fields.

Tests:

- [ ] Add unit tests for CRI-to-core mapping helpers.
- [ ] Add unit tests for CRI unsupported field handling.
- [ ] Add live-adapter unit tests for CNI sandbox network API wiring and
  cleanup behavior.
- [ ] Add unit tests for NetworkPolicy Kubernetes watch reconciliation.
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
