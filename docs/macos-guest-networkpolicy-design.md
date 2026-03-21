# macOS Guest NetworkPolicy Design

NetworkPolicy model for macOS guest sandboxes.

This design builds on [`macos-guest-networking-design.md`](./macos-guest-networking-design.md).

## 1. Policy Boundary

- `1 PodSandbox = 1 Sandbox = 1 macOS VM`
- Pod network identity is sandbox network identity
- `NetworkPolicy` applies at the sandbox or VM boundary, not at an in-guest process boundary

Multiple workloads in one sandbox share the same policy boundary.

## 2. Enforcement Model

Primary policy enforcement runs on the host.

The guest only applies the sandbox network configuration from [`macos-guest-networking-design.md`](./macos-guest-networking-design.md) and any optional defense-in-depth hardening.

## 3. Integration Boundary

`container core` owns:

- sandbox lifecycle
- sandbox networking
- network identity reporting
- runtime and network control APIs

The external Kubernetes integration layer owns:

- watching `Pods`, `Namespaces`, and `NetworkPolicies`
- resolving selectors
- compiling policy into endpoint ACLs
- calling core APIs

`container core` does not understand labels, namespace selectors, or Kubernetes `NetworkPolicy` objects.

## 4. API Shape

Network foundation:

- `PrepareSandboxNetwork`
- `InspectSandboxNetwork`
- `ReleaseSandboxNetwork`

Policy extension:

- `ApplySandboxPolicy(sandboxID, generation, ingressACL, egressACL)`
- `RemoveSandboxPolicy(sandboxID)`

Core only needs concrete endpoint and ACL data. Selector resolution stays outside core.

## 5. Endpoint Identity

Policy evaluation needs at least:

- `sandboxID`
- `networkID`
- IP
- MAC
- gateway
- DNS
- `generation`

## 6. Scope

The initial policy scope is:

- node-local
- IPv4
- L3/L4 ingress and egress
- TCP and UDP

Out of scope for the first phase:

- multi-node overlay networking
- IPv6
- full `ipBlock` edge semantics
- bandwidth control
- guest-side primary firewall enforcement

## 7. CLI Boundary

The local darwin CLI remains local-only.

Do not express these through `container run`:

- `NetworkPolicy`
- Kubernetes Pod or Namespace selectors
- CNI `ADD/DEL/CHECK`
- CRI sandbox or workload lifecycle

If the darwin CLI exposes network flags, it stays limited to local network parameters defined in [`macos-guest-networking-design.md`](./macos-guest-networking-design.md).
