# macOS Guest Core TODO

This document is distilled from [macos-guest-k8s-cri-cni-roadmap.md](./macos-guest-k8s-cri-cni-roadmap.md), but keeps only the work items that belong to `container core` in this repository.

The goal is not to implement Kubernetes integration directly in this repository. The goal is to make the macOS guest runtime, networking, image injection, and control APIs stable enough for future external integration layers to consume.

## 1. Scope Boundaries

### 1.1 In Scope for This Project

- macOS VM lifecycle
- sidecar, guest-agent, and guest network manager
- sandbox and workload resource model
- network attachment plus IP, MAC, and DNS state management
- file injection, workload payload injection, logs, exec, attach, and port-forward
- stable `Runtime Control API` and `Network Control API` for external integration layers

### 1.2 Out of Scope for This Project

- CRI protobuf definitions and gRPC server
- CNI config schema, CNI Result objects, and `ADD`/`DEL`/`CHECK` idempotency logic
- kubelet-specific state machines, `RuntimeClass`, and Pod UID or metadata assembly
- CNI binary install paths, kubelet config paths, and single-node kubelet integration
- Kubernetes compatibility testing and release cadence

### 1.3 Design Constraints

- `container core` must not depend back on Kubernetes types or semantics.
- Default installation artifacts must not include a CRI shim or CNI plugin.
- The CLI should not grow kubelet-specific commands; prefer internal control APIs instead.
- External object models should use neutral naming such as `Sandbox` and `Workload`. Mapping those objects to Kubernetes `PodSandbox` belongs in the integration layer.

## 2. Current Baseline

### Existing Capabilities

- `container run --os darwin` can already boot a macOS VM and execute guest processes.
- The helper + GUI sidecar + guest-agent architecture is in place and stable.
- The guest control path uses vsock and does not depend on guest IP networking.
- Guest file transfer already exists.
- `MacOSSandboxService` already supports multiple process sessions inside a single sandbox.

### Current Gaps

- The darwin runtime still uses NAT unconditionally, with `VZNATNetworkDeviceAttachment` hard-coded in the sidecar.
- `--network`, `--publish`, and `--publish-socket` are explicitly disabled on the darwin path.
- `snapshot.networks` remains empty after macOS runtime creation, so real network state is not reported back.
- The guest has no dedicated networking component.
- The resource model is still "one container equals one VM", not "one sandbox hosts multiple workloads".
- There is no dual `sandbox image` and `workload image` model yet.
- There is no stable runtime or network control API for external consumers.

## 3. P0: Freeze the Architecture and Build PoCs

### Required Work

- [ ] Validate ownership constraints between `VZVmnetNetworkDeviceAttachment` and the current helper and sidecar layering.
- [ ] Compare and freeze one of the following implementation paths:
  - the sidecar creates and attaches the vmnet network directly
  - a network helper creates the network and serializes it to the sidecar
  - network creation moves into the sidecar, while centralized IPAM and control-plane logic stay outside
- [ ] Build a guest-side static networking PoC and confirm that IPv4, prefix, gateway, and DNS can be configured reliably.
- [ ] Freeze the boundary between `sandbox image` and `workload image`.
- [ ] Freeze the internal `Sandbox` and `Workload` object model and lifecycle in core.
- [ ] Draft a minimal `Runtime Control API` and `Network Control API` without CRI- or CNI-specific types.

### Suggested Deliverables

- [ ] `docs/macos-runtime-control-api.md`
- [ ] `docs/macos-network-control-api.md`
- [ ] `docs/macos-guest-sandbox-runtime-design.md`
- [ ] `docs/macos-guest-networking-design.md`
- [ ] `docs/macos-guest-workload-image-design.md`

### Exit Criteria

- [ ] It is clear who creates, owns, and restores vmnet networks.
- [ ] A complete static guest networking flow can be applied reliably.
- [ ] VM base and workload payload are clearly separated.
- [ ] A neutral set of control API drafts can be handed to future integration layers.

## 4. P1: Network Foundation MVP

### Goal

Give the macOS sandbox stable, queryable, reclaimable network state without introducing Kubernetes or CNI details in this phase.

### TODO

- [ ] Introduce a `NetworkBackend` abstraction in the macOS runtime and replace hard-coded NAT in the sidecar.
- [ ] Support two backends in the first phase:
  - `virtualizationNAT` for the compatibility path
  - `vmnetShared` as the new network foundation MVP
- [ ] Restore internal network configuration input on the darwin path, at least for:
  - `ContainerConfiguration.networks`
  - `ContainerConfiguration.dns`
  - `SandboxSnapshot.networks`
- [ ] Include network configuration in sidecar bootstrap input.
- [ ] Introduce a dedicated `guest network manager` instead of embedding network setup into the generic exec path.
- [ ] Complete interface matching, IP/prefix/gateway configuration, DNS writes, and result reporting during sandbox startup.
- [ ] Persist and report network state on the host, including at least:
  - sandbox IP
  - gateway
  - DNS
  - MAC
  - network ID
- [ ] Provide a standalone `Network Control API` covering at least:
  - `PrepareSandboxNetwork`
  - `InspectSandboxNetwork`
  - `ReleaseSandboxNetwork`
- [ ] Define restart recovery and resource cleanup semantics for sidecar, apiserver, and helper restarts.

### Notes

- The first phase can expose only internal APIs. A general CLI `--network` flow for `run --os darwin` is not required immediately.
- The initial target is single-node, single-NIC, single-network, IPv4-first.

### Exit Criteria

- [ ] A new sandbox gets a stable IPv4 address after startup.
- [ ] The sandbox can access external networks.
- [ ] Two sandboxes on the same node can reach each other.
- [ ] State inspection returns real network information.

## 5. P2: Sandbox and Workload Runtime Model

### Goal

Refactor the current "container equals VM" implementation into a neutral runtime model with one sandbox VM and multiple workloads.

### TODO

- [ ] Add internal resource types:
  - `SandboxConfiguration`
  - `SandboxSnapshot`
  - `WorkloadConfiguration`
  - `WorkloadSnapshot`
- [ ] Separate VM lifecycle from workload lifecycle.
- [ ] Reuse the existing multi-session base in `MacOSSandboxService`, and add:
  - sandbox-level namespaces
  - workload ID to session ID mapping
  - wait, cleanup, and error propagation
- [ ] Support multiple independent workloads inside one sandbox.
- [ ] Add sandbox-level metadata, directory layout, and cleanup flow.
- [ ] Add sandbox-level volume and file injection primitives:
  - temporary directories
  - host path mappings
  - generic read-only file injection
- [ ] Stop and clean up all workloads when the sandbox stops.
- [ ] Make workload state, exit code, and log path independently queryable.
- [ ] Remove assumptions in code and logs that "container" always implies exactly one VM.

### Boundary Notes

- This phase implements a neutral runtime model. It should not hard-code CRI method names such as `RunPodSandbox` or `CreateContainer`.
- The integration layer can map Kubernetes objects onto the core `Sandbox` and `Workload` abstractions.

### Exit Criteria

- [ ] Two workloads can run reliably inside the same sandbox.
- [ ] Stopping a sandbox consistently cleans up all attached workloads.
- [ ] Workload state can be queried independently.

## 6. P3: Workload Image and Injection Model

### Goal

Define how workloads run inside an already started macOS sandbox, including the image model and guest-side file layout.

### TODO

- [ ] Keep the existing darwin base image as the `sandbox image`, responsible only for booting the VM.
- [ ] Define a `workload image` or artifact format that describes at least:
  - file tree payload
  - `entrypoint` and `cmd`
  - default environment variables
  - user
  - working directory
- [ ] Define the guest-side workload directory layout, for example:
  - `/var/lib/container/workloads/<id>/rootfs`
  - `/var/lib/container/workloads/<id>/meta.json`
- [ ] Reuse the existing file transfer path for workload payload injection.
- [ ] Define layout and cleanup semantics when multiple workloads share the same sandbox image.
- [ ] Clarify how builder and image store will later distinguish sandbox images from workload images, without introducing CRI `ImageService` in this phase.

### Deferred Items

- APFS snapshots
- `chroot` or jail-style isolation
- stronger in-guest seatbelt or fine-grained isolation

### Exit Criteria

- [ ] One sandbox image can host multiple workload images.
- [ ] The injection, startup, and cleanup flow for workloads is stable and reproducible.

## 7. P4: Core Control Surface and API Consolidation

### Goal

Turn existing execution, logging, and stream capabilities into stable core control interfaces that future external adapters can reuse.

### TODO

- [ ] Provide a stable `Runtime Control API` with at least:
  - `CreateSandbox`
  - `StartSandbox`
  - `StopSandbox`
  - `RemoveSandbox`
  - `CreateWorkload`
  - `StartWorkload`
  - `StopWorkload`
  - `RemoveWorkload`
  - `InspectSandbox`
  - `InspectWorkload`
  - `ExecSync`
  - `StreamExec`
  - `StreamAttach`
  - `StreamPortForward`
- [ ] Expose stable logging interfaces:
  - separate stdout and stderr logs per workload
  - sandbox-level event log
  - log path or log-reading interfaces
- [ ] Make `PortForward` a core capability, preferably reusing the sidecar or vsock channel instead of depending on `HostPort`.
- [ ] Decouple the API from CLI argument parsing, on-disk state layout, and private sidecar protocol details.
- [ ] Add tests for state transitions, idempotency, failure recovery, and error propagation.

### Exit Criteria

- [ ] External integration layers can rely only on control APIs and do not need to call the CLI or read internal state files.
- [ ] `exec`, `attach`, `logs`, and `port-forward` all have stable core-side contracts.

## 8. Later Enhancements (Not Blocking the MVP)

- [ ] crash recovery and state restoration
- [ ] metrics, tracing, and health checking
- [ ] `HostPort`
- [ ] multiple network attachments
- [ ] IPv6
- [ ] stronger in-guest isolation

## 9. Recommended Execution Order

1. Complete P0 to freeze ownership, networking, image model, and control API boundaries.
2. Complete P1 to establish the network foundation and state reporting.
3. Complete P2 to split sandbox and workload resource models.
4. Complete P3 to stabilize the workload image and injection path.
5. Complete P4 last to consolidate runtime and network control APIs into a stable external contract.

## 10. Contract Reminder for External Integration Layers

The following work is intentionally left to an external Kubernetes integration layer outside this repository:

- CRI runtime service and image service
- CNI plugin and IPAM idempotency logic
- kubelet integration, `RuntimeClass`, and Pod metadata translation
- Kubernetes semantic translation for `kubectl exec`, `kubectl logs`, and `kubectl port-forward`

This repository only needs to guarantee one thing: those external components can drive macOS sandboxes and workloads through stable core APIs, without reaching into `container` implementation details.
