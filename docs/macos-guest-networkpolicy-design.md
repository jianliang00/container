# macOS Guest NetworkPolicy and CLI Compatibility Design

This document is for developers maintaining and extending `container`. It focuses on three questions:

- why the current macOS guest design cannot yet support Kubernetes `NetworkPolicy`
- where policy enforcement should live if support is added later
- how that path should stay compatible with the existing `container run --os darwin` model

## 1. Executive Summary

The recommendations are:

- the current macOS guest implementation cannot yet support Kubernetes `NetworkPolicy`
- even after Pod networking exists, the primary enforcement point should not live inside the guest
- the recommended model is:
  - `1 PodSandbox = 1 macOS VM`
  - `Pod network = VM network`
  - `NetworkPolicy` is compiled by an external Kubernetes integration layer
  - the host is responsible for primary policy enforcement
  - the guest is responsible only for network configuration and optional defense-in-depth hardening
- `container run --os darwin` can remain the entry point for local single-VM execution
- Kubernetes and `NetworkPolicy` should not be expressed through the `container run` CLI; they should integrate through an external `CRI shim + CNI plugin`

## 2. Current Implementation State

### 2.1 Existing Capabilities

The current macOS guest runtime already provides:

- VM lifecycle management
- in-guest process execution
- stdio forwarding
- a vsock control channel
- guest file injection

These capabilities are enough to serve as a PodSandbox control-plane foundation, but they are not yet a Kubernetes-ready network data plane.

### 2.2 Critical Gaps

The current implementation still has the following limitations:

- the macOS guest NIC still uses `VZNATNetworkDeviceAttachment`
- `--network`, `--publish`, and `--publish-socket` are all disabled for `--os darwin`
- `SandboxSnapshot.networks` and `ContainerSnapshot.networks` are empty in the externally reported runtime state
- the guest still has no independent network manager
- there is no `Network Control API`
- there is no CRI shim or CNI plugin

As a result, the prerequisites for `NetworkPolicy` do not exist yet:

- stable Pod IPs
- same-node Pod connectivity
- host-observable network state
- an orchestratable policy enforcement point

## 3. Why the Current Design Cannot Support NetworkPolicy

`NetworkPolicy` is not a feature that appears once a VM gets an IP address. It requires at least:

- a stable, reportable network identity for each Pod
- a control plane that can resolve selectors into concrete endpoints
- a data plane that can enforce L3/L4 ingress and egress rules
- a status plane that can report current networking and policy application state

The current macOS guest path is still in the fixed-NAT stage, so it does not meet those requirements.

More importantly, the current implementation does not yet have an appropriate policy enforcement boundary:

- inside the guest: the isolation boundary is too weak, and rules can theoretically be modified or bypassed once the guest is compromised
- in the CLI: the model is too weak to represent Kubernetes selectors, namespaces, and policy semantics
- inside the current core: no stable network control API has been exposed yet

So at the current stage, `NetworkPolicy` can only be discussed as a design topic, not as a deliverable feature commitment.

## 4. Recommended Overall Model

### 4.1 Base Model

The design should fix the following model:

- `1 PodSandbox = 1 macOS VM`
- `Pod network = VM network`
- multiple containers inside a Pod map to multiple workload processes or services inside that VM

This means:

- the enforcement boundary is the VM, not an individual process inside the guest
- `NetworkPolicy` should be designed around the VM network boundary

### 4.2 Layering Rules

The following layering should be preserved:

- `container core`
  - owns VM lifecycle, network attachment, guest-side network configuration, network state reporting, and internal control APIs
  - does not understand Pod labels, namespace selectors, or `NetworkPolicy` objects
- Kubernetes integration
  - watches Kubernetes objects
  - compiles `NetworkPolicy` into endpoint-level ACLs
  - calls core through `Runtime Control API` and `Network Control API`

The purpose of this boundary is to avoid embedding Kubernetes semantics directly into `container core`.

## 5. Primary Enforcement Should Live on the Host

### 5.1 Why Not Inside the Guest

The primary `NetworkPolicy` enforcement point should not be inside the guest, for several reasons:

- a root process inside the guest could theoretically modify or bypass the rules
- keeping policy state per VM would increase the complexity of consistency, cleanup, and recovery
- selector resolution naturally belongs to the cluster control plane, not inside each guest

The guest is better suited for:

- static IP, prefix, gateway, and DNS configuration
- interface matching and state reporting
- optional defense-in-depth hardening

### 5.2 Why the Host Is the Right Primary Enforcement Point

The host is the more appropriate primary enforcement point because:

- the VM is the real isolation boundary
- the host knows endpoint identity such as Pod IP, MAC, and network ID
- the host is a better place to apply, remove, recover, and observe policy consistently
- the host-side data plane is a better fit for integration with external CNI and CRI layers

Recommended model:

- `NetworkPolicy` is compiled into endpoint ACLs by the external integration layer
- the host performs actual ingress and egress enforcement
- the guest handles only network setup and optional hardening

## 6. Recommended Data-Plane and Control-Plane Split

### 6.1 Guest Responsibilities

Add a dedicated network manager inside the guest with a narrow scope:

- identify the target NIC by MAC
- configure IPv4, prefix, and gateway
- write DNS, `searchDomains`, and `domain`
- return the applied interface name and current IP

Do not implement this as "run a few shell commands through the generic exec path", because that leads to:

- untraceable state
- fragile error handling
- poor repeatability across reboot and restart

### 6.2 Core Responsibilities

`container core` needs to add:

- a network attachment abstraction
- a `vmnet` integration path
- Pod network state reporting
- a standalone `Network Control API`

Suggested API direction:

- `PrepareSandboxNetwork(sandboxID, networkRequest)`
- `InspectSandboxNetwork(sandboxID)`
- `ReleaseSandboxNetwork(sandboxID)`
- `ApplySandboxPolicy(sandboxID, generation, ingressACL, egressACL)`
- `RemoveSandboxPolicy(sandboxID)`

The first three are the network foundation. The last two are later extensions for policy enforcement.

### 6.3 Kubernetes Integration Responsibilities

The Kubernetes integration layer should:

- watch `Pods`, `Namespaces`, and `NetworkPolicies`
- resolve label and namespace selectors
- compile policy into endpoint-level L3/L4 ACLs
- push the result into core through `Network Control API`

In other words:

- selector resolution happens outside core
- data-plane enforcement happens on the host
- core only understands "which peers and ports are allowed for this sandbox"

## 7. Minimal Viable Policy Model

The first implementation should stay minimal: node-local, IPv4, and L3/L4 only.

### 7.1 Endpoint Identity

At minimum, the following fields are needed:

- `sandboxID`
- `networkID`
- `podIP`
- `podMAC`
- `gateway`
- `dns`
- `generation`

### 7.2 Policy Semantics

The implementation should follow the basic Kubernetes `NetworkPolicy` semantics:

- Pods not selected by any policy remain allow-all by default
- Pods selected by an ingress policy become ingress default-deny, then add explicit allow rules
- Pods selected by an egress policy become egress default-deny, then add explicit allow rules

Recommended first-phase scope:

- IPv4 only
- same-node Pod-to-Pod communication
- basic Pod-to-external-network egress
- TCP and UDP port-level rules

Do not try to cover these in the first phase:

- multi-node overlay networking
- IPv6
- full `ipBlock` edge semantics
- bandwidth control
- eBPF, iptables, or tc compatibility layers

## 8. Compatibility Strategy with `container run`

### 8.1 What Can Stay Compatible

The current `container run --os darwin` path can remain the local execution entry point, especially for:

- `container run --os darwin <image> [cmd]`
- `-it`
- `--env`
- `--cpus`
- `--memory`
- other process- and resource-oriented local flags

Those capabilities are still appropriate for:

- local single-VM execution
- development and debugging
- non-Kubernetes scenarios

### 8.2 What Should Not Continue Through `container run`

The following should not be expressed directly through the `container run` CLI:

- `NetworkPolicy`
- Kubernetes Pod or Namespace selectors
- CNI `ADD/DEL/CHECK`
- CRI `RunPodSandbox` or `CreateContainer`

The reason is straightforward:

- the CLI is not a good representation for Kubernetes object models
- these capabilities naturally belong to an external `CRI shim + CNI plugin`
- forcing them into CLI flags would couple core to Kubernetes semantics

### 8.3 What Could Be Exposed Gradually in the CLI

Once the macOS guest network foundation exists, some existing CLI semantics could be restored gradually:

- `--network <id>[,mac=...]`
- basic DNS parameters

But that should follow one rule:

- the CLI expresses only network parameters needed for local container or VM execution
- Kubernetes-specific objects remain in the external integration layer

## 9. Recommended Execution Order

Suggested order:

1. validate the `vmnet` attachment ownership PoC
2. introduce a configurable network backend for the macOS runtime
3. land a dedicated guest network manager
4. establish stable Pod IPs, DNS, same-node connectivity, and state reporting
5. freeze the `Network Control API` boundary
6. build the external CNI plugin MVP
7. add node-local host-side policy enforcement
8. then add egress policy, recovery behavior, observability, and debugging support

`NetworkPolicy` should not move ahead of "stable Pod networking + queryable network state + external CNI integration".

## 10. Risks and Open Questions

Several key risks still need validation:

- whether `VZVmnetNetworkDeviceAttachment` is compatible with the current sidecar and network-helper split
- whether network creation and VM attachment satisfy the SDK ownership requirements
- which host-side data-plane mechanism will be stable and maintainable
- how to keep policy updates, VM restarts, and failure recovery idempotent and consistent

Without clear answers to those questions, pushing directly into `NetworkPolicy` implementation will only create rework.

## 11. Final Recommendation

The entire recommendation can be summarized in one sentence:

Do not design `NetworkPolicy` as "install a firewall inside the macOS guest". Instead, first make Pod networking a host-controlled `vmnet` data plane, then let the external Kubernetes integration layer compile policy into host-side ACLs, while the guest handles only network setup and optional hardening.

Under that model:

- the current `container run --os darwin` path can stay intact
- `container core` keeps its standalone-project position
- Kubernetes features arrive through an external integration layer
- `NetworkPolicy` gets a stable, maintainable, and recoverable implementation path
