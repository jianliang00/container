# macOS Guest Kubernetes CRI/CNI Implementation Plan

Implementation plan for connecting the macOS guest runtime in `container` to
Kubernetes through CRI, CNI, and a bounded node-local `NetworkPolicy`
controller.

Related docs:

- [`macos-guest-k8s-cri-cni-roadmap.md`](./macos-guest-k8s-cri-cni-roadmap.md)
- [`macos-guest-k8s-cri-cni-todo.md`](./macos-guest-k8s-cri-cni-todo.md)
- [`macos-guest-core-design.md`](./macos-guest-core-design.md)
- [`macos-guest-networking-design.md`](./macos-guest-networking-design.md)
- [`macos-guest-networkpolicy-design.md`](./macos-guest-networkpolicy-design.md)
- [`macos-guest-workload-image-design.md`](./macos-guest-workload-image-design.md)

External references checked on 2026-04-16:

- Kubernetes CRI documentation:
  <https://kubernetes.io/docs/concepts/containers/cri/>
- Kubernetes CRI `runtime.v1` protobuf:
  <https://github.com/kubernetes/cri-api/blob/v0.35.3/pkg/apis/runtime/v1/api.proto>
- Kubernetes RuntimeClass documentation:
  <https://kubernetes.io/docs/concepts/containers/runtime-class/>
- CNI specification target version `1.1.0`:
  <https://github.com/containernetworking/cni/blob/main/SPEC.md>

## 1. Decision Summary

The current target is one complete, bounded local Kubernetes integration:

- kubelet runs directly on macOS; this plan assumes that local kubelet premise is
  satisfied and does not gate the adapter work on proving it
- kubelet talks to `container-cri-shim-macos` over a Unix socket
- the shim implements current Kubernetes CRI `runtime.v1`
- the shim invokes `container-cni-macvmnet` for Pod sandbox networking
- a companion `container-k8s-networkpolicy-macos` controller watches Kubernetes
  policy objects and applies node-local sandbox ACLs
- sandbox image, workload platform, runtime handlers, CNI paths, streaming
  settings, and policy-controller settings come from config
- Kubernetes object models and selector translation stay outside `container core`

This is an experimental single-node macOS worker path. It is not a claim that
macOS is a general production Kubernetes node OS.

## 2. Feasibility

The integration is feasible because `container core` already has the required
runtime primitives:

- Pod sandbox lifecycle maps to sandbox VM lifecycle
- Pod container lifecycle maps to workload lifecycle inside the sandbox VM
- sandbox VM images and workload images are separate artifacts
- `vmnetShared` provides stable host-visible sandbox networking
- sandbox network leases can be prepared, inspected, released, and recovered
- workload stdout and stderr log paths are available from snapshots
- `ExecSync` and streaming exec are available through core-side contracts
- sandbox network policy state can be applied, inspected, removed, rendered, and
  persisted through existing core APIs

With kubelet-on-macOS assumed, the main feasibility risk is Kubernetes
scheduling and support semantics, not the protocol bridge itself. Scheduling must
be explicit through labels, taints, tolerations, and `RuntimeClass`.

## 3. Current Delivery Scope

The current plan includes:

- one local macOS node
- kubelet on macOS
- one CRI Unix socket
- one CNI plugin
- one default `vmnetShared` network
- IPv4 Pod networking
- node identity and examples using `kubernetes.io/os=darwin`
- `darwin/arm64` workload images
- one Pod sandbox as one macOS VM
- each Pod container as one workload inside that VM
- kubelet-materialized volume paths
- CRI log adaptation for `kubectl logs`
- `ExecSync` for probes
- loopback CRI streaming for `kubectl exec`
- loopback CRI streaming for `kubectl port-forward`
- single-node Service reachability through kube-proxy
- deterministic CRI handlers for the full current `runtime.v1` RPC surface
- node-local, IPv4, L3/L4 `NetworkPolicy` enforcement for TCP and UDP

The current `NetworkPolicy` subset supports:

- watching `Pods`, `Namespaces`, and `NetworkPolicies`
- resolving `podSelector` and `namespaceSelector` for Pods assigned to this node
- resolving numeric TCP and UDP ports
- resolving IPv4 Pod endpoints and simple IPv4 `ipBlock.cidr` peers
- compiling ingress and egress rules into sandbox ACLs
- applying policies through `ApplySandboxPolicy`
- removing policies through `RemoveSandboxPolicy`
- reconciling policy generations after Pod, Namespace, or NetworkPolicy changes

## 4. Removed Scope

The following directions are removed from the current plan because they would
expand the delivery without being required for the first working macOS kubelet
integration:

- `kubectl attach`
- Kubernetes `HostPort`
- multiple CNI network attachments
- IPv6 Pod networking
- multi-node Pod routing and multi-node Service reachability
- overlay networking
- SCTP policy rules
- named-port `NetworkPolicy` resolution
- full Linux security compatibility hardening across cgroups, SELinux, AppArmor,
  seccomp, user namespaces, capabilities, and mount propagation

The CRI shim must still implement deterministic responses for removed CRI RPCs
or unsupported request fields so kubelet receives clear errors instead of
hanging or observing partial state.

## 5. Architecture

The implementation adds three external adapters:

- `container-cri-shim-macos`
- `container-cni-macvmnet`
- `container-k8s-networkpolicy-macos`

`container core` remains the owner of sandbox lifecycle, workload lifecycle,
network leases, image handling, logs, streaming primitives, and concrete sandbox
network policy state.

```text
kubelet
  -> unix:///var/run/container-cri-macos.sock
  -> container-cri-shim-macos
       -> ContainerAPIClient / ContainerKit
       -> container-apiserver
       -> container-runtime-macos

container-cri-shim-macos
  -> container-cni-macvmnet
       -> PrepareSandboxNetwork / InspectSandboxNetwork / ReleaseSandboxNetwork

container-k8s-networkpolicy-macos
  -> Kubernetes API watch
  -> local sandbox endpoint index
  -> ApplySandboxPolicy / RemoveSandboxPolicy
```

The CRI shim owns Kubernetes-facing runtime behavior:

- CRI RuntimeService
- CRI ImageService
- CRI metadata persistence
- CNI invocation
- CRI log path adaptation
- loopback exec and port-forward streaming URL server
- kubelet-facing error semantics

The CNI plugin owns network command translation:

- CNI `ADD` -> `PrepareSandboxNetwork`
- CNI `CHECK` -> `InspectSandboxNetwork`
- CNI `DEL` -> `ReleaseSandboxNetwork`
- CNI `STATUS` -> network service readiness check
- CNI `VERSION` -> CNI `1.1.0` version response
- CNI `GC` -> stale CNI result cache and lease reconciliation

kube-proxy owns Kubernetes Service translation for the current single-node
validation path. `container core` only exposes Pod IP reachability and does not
implement Kubernetes Service VIP or endpoint programming.

The policy controller owns Kubernetes policy translation:

- watch Kubernetes resources
- resolve selectors and endpoint identity
- compile policy into concrete ACLs
- apply, remove, and reconcile sandbox policies

## 6. Package Layout

Add Swift package targets:

- `ContainerCRI`
  - generated Kubernetes CRI protobuf and gRPC bindings
  - conversion helpers shared by the shim implementation
- `ContainerCRIShimMacOS`
  - CRI RuntimeService implementation
  - CRI ImageService implementation
  - shim config model
  - metadata store
  - CNI runner
  - log adapter
  - exec streaming server
- `container-cri-shim-macos`
  - executable entry point
  - argument parsing
  - config loading
  - Unix socket gRPC server startup
- `ContainerCNIMacvmnet`
  - CNI request parsing
  - CNI result encoding
  - network API calls
- `container-cni-macvmnet`
  - CNI executable entry point
- `ContainerK8sNetworkPolicyMacOS`
  - Kubernetes watch client
  - local endpoint index
  - selector resolver
  - policy compiler
  - reconciliation loop
- `container-k8s-networkpolicy-macos`
  - executable entry point
  - config loading
  - controller startup

Generated protobuf files should stay isolated from hand-written shim code so CRI
API changes are easy to regenerate and review.

The CRI protobuf source is pinned in `Protos/KubernetesCRI` from
`kubernetes/cri-api` tag `v0.35.3`. Regenerate the Swift bindings with
`make cri-protos`.

## 7. Configuration

The CRI shim and policy controller must be explicitly configured and fail fast
when required fields are missing.

The config owns:

- CRI Unix socket path
- CRI metadata state directory
- streaming listen address and port
- CNI binary and config paths
- default sandbox image
- default workload platform
- default network
- default macOS guest network backend
- runtime handler profiles
- GUI policy for kubelet-launched macOS guests
- per-runtime sandbox resources: vCPU count and memory bytes
- policy-controller kubeconfig path
- policy-controller node name
- policy-controller resync interval
- kube-proxy launch mode and config path for single-node Service validation

When `--config` is omitted, `container-cri-shim-macos` searches these paths in
order:

1. `/etc/container/container-cri-shim-macos-config.json`
2. `/etc/container-cri-shim-macos-config.json`
3. `~/.config/container/container-cri-shim-macos-config.json`

Any config that enables NetworkPolicy or kube-proxy must resolve every active
runtime profile to `networkBackend: "vmnetShared"`. `virtualizationNAT` remains
valid only for non-Kubernetes macOS guest usage because it does not provide the
stable host-visible sandbox networking required by CNI, NetworkPolicy, and
kube-proxy validation.

Recommended initial shape:

```json
{
  "runtimeEndpoint": "/var/run/container-cri-macos.sock",
  "stateDirectory": "/var/lib/container/cri-shim-macos",
  "streaming": {
    "address": "127.0.0.1",
    "port": 0
  },
  "cni": {
    "binDir": "/opt/cni/bin",
    "confDir": "/etc/cni/net.d",
    "plugin": "macvmnet"
  },
  "defaults": {
    "sandboxImage": "localhost/macos-sandbox:latest",
    "workloadPlatform": {
      "os": "darwin",
      "architecture": "arm64"
    },
    "network": "default",
    "networkBackend": "vmnetShared",
    "guiEnabled": false,
    "resources": {
      "cpus": 4,
      "memoryInBytes": 8589934592
    }
  },
  "runtimeHandlers": {
    "macos": {
      "sandboxImage": "localhost/macos-sandbox:latest",
      "network": "default",
      "networkBackend": "vmnetShared",
      "guiEnabled": false,
      "resources": {
        "cpus": 4,
        "memoryInBytes": 8589934592
      }
    }
  },
  "networkPolicy": {
    "enabled": true,
    "kubeconfig": "/etc/kubernetes/kubelet.conf",
    "nodeName": "macos-node-1",
    "resyncSeconds": 30
  },
  "kubeProxy": {
    "enabled": true,
    "configPath": "/etc/kubernetes/kube-proxy.conf"
  }
}
```

Image and handler selection rules:

1. If `RunPodSandboxRequest.runtime_handler` is set, it must match a configured
   runtime handler.
2. If the runtime handler is empty, use `defaults`.
3. Unknown runtime handlers fail `RunPodSandbox`.
4. Pod annotations may select configured profiles only when the shim config
   explicitly enables that policy.
5. The implementation does not allow arbitrary Pod annotations to inject sandbox
   image references.
6. `resources.cpus` and `resources.memoryInBytes` are resolved from the selected
   runtime handler over `defaults`; when omitted, the shim uses the macOS guest
   default of 4 vCPUs and 8 GiB memory.

## 8. RuntimeService Mapping

| CRI call | Current behavior |
| --- | --- |
| `Version` | Return shim, runtime, and CRI API versions |
| `Status` | Report runtime and network readiness |
| `RuntimeConfig` | Return static runtime config from shim config |
| `UpdateRuntimeConfig` | Accept kubelet updates that do not change macOS runtime behavior |
| `RunPodSandbox` | Persist CRI sandbox metadata, create sandbox, run CNI, start VM |
| `StopPodSandbox` | Stop workloads, stop VM, run CNI cleanup, remove policy |
| `RemovePodSandbox` | Remove sandbox metadata and core sandbox |
| `PodSandboxStatus` | Combine CRI metadata, sandbox snapshot, network state, policy state |
| `ListPodSandbox` | List persisted sandbox metadata and core snapshots |
| `CreateContainer` | Persist CRI container metadata and create workload |
| `StartContainer` | Start workload and log mux |
| `StopContainer` | Stop workload with timeout |
| `RemoveContainer` | Remove workload and CRI metadata |
| `ContainerStatus` | Return workload status and log path |
| `ListContainers` | List persisted container metadata and snapshots |
| `UpdateContainerResources` | Return deterministic unsupported/no-op response for Linux-only resource changes |
| `UpdatePodSandboxResources` | Return deterministic unsupported/no-op response for Linux-only resource changes |
| `ReopenContainerLog` | Recreate or reopen the CRI log destination |
| `ExecSync` | Run command and capture output |
| `Exec` | Create loopback streaming URL for `kubectl exec` |
| `Attach` | Return deterministic unsupported response |
| `PortForward` | Create loopback streaming URL for `kubectl port-forward` |
| `ContainerStats` | Return minimal available workload or sandbox stats |
| `ListContainerStats` | Aggregate available stats |
| `PodSandboxStats` | Return sandbox-level stats |
| `ListPodSandboxStats` | Aggregate sandbox-level stats |
| `CheckpointContainer` | Return deterministic unsupported response |
| `GetContainerEvents` | Return deterministic empty stream or unsupported response accepted by kubelet |
| `ListMetricDescriptors` | Return empty descriptors |
| `ListPodSandboxMetrics` | Return empty metrics |

`Status` must not report `RuntimeReady` or `NetworkReady` from configuration
alone. `RuntimeReady` is true only after the shim can reach the local container
services health endpoint. `NetworkReady` is true only after the configured
default network exists and is running. `RuntimeConfig` returns no Linux
`cgroupDriver` because the macOS shim is not a Linux runtime; kubelet
`UpdateRuntimeConfig` PodCIDR updates are accepted as no-ops because Pod IP
allocation comes from the configured vmnet network.

Unsupported Linux-specific request fields must fail before sandbox or workload
creation when accepting them would make Pod behavior misleading.

## 9. ImageService Mapping

| CRI call | Shim behavior |
| --- | --- |
| `ListImages` | Return local image summaries |
| `ImageStatus` | Resolve image by reference |
| `PullImage` | Pull configured platform and return image ref |
| `RemoveImage` | Remove local image reference |
| `ImageFsInfo` | Return image store disk usage where available |

Image policy:

- sandbox images must validate as macOS sandbox images before profile use
- workload images must validate as macOS workload images before container start
- default platform is configured, initially `darwin/arm64`
- registry auth from CRI is mapped to existing image pull support

## 10. CNI Design

The CNI plugin is a normal executable invoked by the CRI shim with standard CNI
environment variables and stdin JSON. The target CNI spec version is `1.1.0`.

Supported commands:

- `ADD`
- `CHECK`
- `DEL`
- `STATUS`
- `VERSION`
- `GC`

The plugin does not create or enter a Linux network namespace. The macOS VM is
the Pod network boundary. `CNI_NETNS` is accepted for compatibility but does not
drive Linux namespace behavior.

The plugin persists CNI result metadata in `stateDir`, defaulting to
`/var/lib/container/cni/macvmnet`. `GC` uses that ledger with
`cni.dev/valid-attachments` to release stale macvmnet attachments and delete
their cached CNI results.

The plugin connects to sandbox-scoped runtime services using `runtime`,
defaulting to `container-runtime-macos`. `ADD`, `CHECK`, `DEL`, and `GC` use
`SandboxClient` for `PrepareSandboxNetwork`, `InspectSandboxNetwork`, and
`ReleaseSandboxNetwork`; `STATUS` checks the local network service and selected
network readiness.

Non-netns CNI contract:

- `CNI_CONTAINERID` is the CRI PodSandbox ID.
- `CNI_NETNS` is a non-empty opaque VM isolation-domain reference owned by the
  shim, initially `macvmnet://sandbox/<sandboxID>`.
- `CNI_IFNAME` is the logical Pod interface name. The plugin persists it in the
  CNI result and compares it with the sandbox network state during `CHECK`.
- `ADD` validates that `CNI_CONTAINERID` and `CNI_NETNS` refer to the same
  sandbox before calling `PrepareSandboxNetwork`.
- `CHECK` requires the previous `ADD` result as `prevResult` and compares that
  result with the persisted lease and current `InspectSandboxNetwork` state.
- `DEL` tolerates a missing `CNI_NETNS`, missing lease, or already-released
  allocation.
- `STATUS` reports readiness of the local network service and default network.
- `GC` removes stale CNI result cache entries and releases leases not present in
  `cni.dev/valid-attachments`.

The CNI result includes:

- interface name from the CNI request
- Pod IPv4 address
- gateway
- default route
- DNS nameservers and search domains
- MAC address when available
- network ID

`ADD` must be idempotent for an existing sandbox network lease. `DEL` must
tolerate already-released or missing state where Kubernetes cleanup semantics
require it.

## 11. NetworkPolicy Design

The policy controller watches Kubernetes state and compiles policy for local
sandboxes only.

Inputs:

- Pods assigned to the configured node
- Namespaces and namespace labels
- NetworkPolicy objects
- CRI sandbox metadata
- CNI Pod IP and network identity

Compilation rules:

- policy selection uses Kubernetes `podSelector`
- peer selection supports `podSelector`, `namespaceSelector`, and simple IPv4
  `ipBlock.cidr`
- numeric TCP and UDP ports are translated to `SandboxNetworkPortRange`
- ingress peers become source ACL endpoints
- egress peers become destination ACL endpoints
- a selected Pod with ingress policies gets default-deny ingress plus compiled
  allow rules
- a selected Pod with egress policies gets default-deny egress plus compiled
  allow rules
- unselected Pods keep default allow behavior
- policy generation increases on every compiled change

Egress policy follows Kubernetes `NetworkPolicy` semantics: there is no implicit
allow rule for DNS, gateway, apiserver, or other Pod-network traffic. Workloads
that need DNS or API access must receive explicit egress allows. Host-side
runtime control traffic over the shim, sidecar, or vsock path is not Pod-network
traffic and is outside this policy boundary.

Apply and cleanup:

- apply with `ContainerKit.applySandboxPolicy`
- remove with `ContainerKit.removeSandboxPolicy`
- inspect with `ContainerKit.inspectSandboxPolicy`
- remove policy during `StopPodSandbox` and `RemovePodSandbox`
- reconcile after shim, controller, kubelet, or apiserver restart

Unsupported policy fields are surfaced through controller logs and Kubernetes
events. The controller must leave the previous successfully applied generation in
place when a new generation cannot be compiled.

## 12. Logs

Core stores workload stdout and stderr separately. Kubelet expects a single CRI
log file at:

- `PodSandboxConfig.log_directory`
- `ContainerConfig.log_path`

The shim bridges these models by writing CRI-formatted records to the kubelet
path while preserving native core logs.

Adapter flow:

1. `CreateContainer` records the target CRI log path.
2. `StartContainer` starts a log mux task.
3. The mux task tails workload stdout and stderr logs.
4. Each line is written to the CRI log path with stream identity.
5. `ReopenContainerLog` recreates or reopens the destination after rotation.

This is required for `kubectl logs`.

## 13. Streaming

The current streaming scope is `Exec` and `PortForward`.

The shim runs a loopback-only streaming server with:

- short-lived tokens
- per-session expiration
- stdin/stdout/stderr routing
- TTY support where available
- resize support where available
- cleanup on disconnect

Current mapping:

- `Exec` -> `ContainerClient.streamExec`
- `PortForward` -> `ContainerKit.streamPortForward`

The server binds to loopback because kubelet and the shim run on the same macOS
host in this plan.

## 14. Volumes

The current plan supports kubelet-materialized paths:

- `emptyDir`
- `hostPath`
- `ConfigMap`
- `Secret`
- `projected`

The shim maps CRI `ContainerConfig.mounts` into macOS guest `virtiofs`
filesystem entries. Kubernetes passes these mounts in `CreateContainer`, while
the macOS VM must receive its `virtiofs` directory-sharing devices before the
VM boots. Therefore the shim must not boot the sandbox VM in `RunPodSandbox`.

Required lifecycle:

1. `RunPodSandbox` creates the sandbox bundle, runs CNI, persists sandbox
   metadata, and leaves the VM ready but not booted.
2. `CreateContainer` validates CRI mounts, converts supported hostPath
   directory mounts into `Filesystem.virtiofs` entries, and persists them in the
   workload configuration.
3. The first `StartContainer` computes the sandbox VM mount set from sandbox
   mounts plus all created workload mounts, validates conflicts, updates the
   sandbox configuration before boot, and starts the VM.
4. Guest-side mount preparation projects each workload's configured guest paths
   through the existing `/Volumes/My Shared Files/<share>` automount symlink
   mapping.
5. If the VM is already booted, later workloads may only use mount mappings
   that were already part of the VM boot-time mount set. Any new hostPath or
   guest-path mapping returns a deterministic failed-precondition error.

Supported CRI mount subset:

- `host_path` must be an existing absolute host directory
- `container_path` must be an absolute guest path accepted by the macOS guest
  mount mapping rules
- `readonly` maps to a read-only `virtiofs` share
- mount propagation must be private
- image mounts, SELinux relabel, ID-mapped mounts, and recursive read-only
  mounts are rejected

Important limitation:

- the Pod sandbox is one macOS VM
- workloads share the VM boundary
- the plan does not provide Linux mount namespace semantics or strict
  per-workload mount isolation inside the Pod

## 15. Scheduling and Node Setup

Because this is an experimental macOS node path, workloads must opt in.

Recommended node setup:

- label: `apple.com/macos-container=true`
- label: `kubernetes.io/os=darwin`
- taint: `apple.com/macos-container=true:NoSchedule`
- `RuntimeClass` handler: `macos`
- Pod `nodeSelector` or RuntimeClass scheduling rules selecting the macOS node,
  including `kubernetes.io/os=darwin`
- matching toleration for the macOS node taint

Pod manifests should omit `.spec.os.name` unless the deployed Kubernetes API
server and kubelet explicitly admit `darwin` as a Pod OS value. The supported
selection signal for this adapter is the node label and scheduling metadata
above, not setting Pod OS to `linux` or `windows`.

Pods should use macOS workload images and should not assume Linux-only security,
namespace, filesystem, or cgroup behavior.

## 16. Validation Plan

`crictl` validation:

- `crictl version`
- `crictl info`
- `crictl pull`
- `crictl runp`
- `crictl create`
- `crictl start`
- `crictl ps`
- `crictl inspect`
- `crictl execsync`
- `crictl logs`
- `crictl stop`
- `crictl rm`
- `crictl stopp`
- `crictl rmp`

kubelet validation:

- local kubelet starts with `--container-runtime-endpoint`
- static Pod starts on the macOS node
- single-container Pod starts on the macOS node
- exec probe works
- HTTP probe works
- TCP probe works
- `kubectl logs` works
- `kubectl exec` works
- `kubectl port-forward` works
- kube-proxy provides single-node Service reachability
- Pod deletion cleans up workload, sandbox, network lease, and policy state

NetworkPolicy validation:

- default allow behavior works before policy selection
- ingress policy allows traffic from a selected Pod
- ingress policy denies traffic from an unselected Pod
- egress policy allows traffic to a selected Pod or IPv4 CIDR
- egress policy denies traffic outside allowed peers
- deleting a NetworkPolicy restores the expected policy state
- deleting a Pod removes its endpoint from compiled ACLs
- restarting the policy controller reconciles the same policy generation

## 17. Done Criteria

The current plan is done when:

- `container-cri-shim-macos --config <path>` listens on the configured Unix
  socket
- `container-cni-macvmnet` handles `ADD`, `CHECK`, `DEL`, `STATUS`, `VERSION`,
  and `GC`
- `container-k8s-networkpolicy-macos --config <path>` watches Kubernetes API
  state and reconciles local sandbox policies
- local `crictl` lifecycle validation passes
- local kubelet can run a static Pod backed by a configured macOS sandbox image
  and macOS workload image
- `kubectl logs` works
- `kubectl exec` works
- `kubectl port-forward` works
- exec, HTTP, and TCP probes work
- single-node Service reachability through kube-proxy works
- node-local IPv4 TCP/UDP `NetworkPolicy` allow and deny cases work
- Pod deletion cleans up workload, sandbox, CNI state, log tasks, stream
  sessions, and policy state

## 18. Implementation Rule

Keep the boundary explicit:

- Kubernetes integration code translates CRI, CNI, kubelet, and policy behavior.
- `container core` owns sandbox, workload, image, network, log, stream, and
  concrete policy primitives.
- The CRI shim persists Kubernetes metadata that core does not understand.
- The CNI plugin translates network lifecycle commands; it does not own durable
  runtime state beyond CNI result caching needed for cleanup.
- The policy controller translates Kubernetes selectors into concrete ACLs; it
  does not add Kubernetes object awareness to core.
