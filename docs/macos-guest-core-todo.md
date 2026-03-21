# macOS Guest Core TODO

Implementation plan for macOS guest support in `container core`.

Related design docs:

- [`macos-guest-core-design.md`](./macos-guest-core-design.md)
- [`macos-guest-networking-design.md`](./macos-guest-networking-design.md)
- [`macos-guest-networkpolicy-design.md`](./macos-guest-networkpolicy-design.md)

## 1. P1: Sandbox Networking

### TODO

- [x] Add darwin network backend selection.
  - `virtualizationNAT`
  - `vmnetShared`
- [x] Add guest network bring-up during sandbox startup.
  - guest network manager
  - interface matching
  - IPv4, prefix, gateway, and DNS setup
  - host-side state reporting for IP, gateway, DNS, MAC, and network ID
- [ ] Replace serialized `vmnet` handoff with persisted sandbox network leases.
  - persist backend, `networkID`, MAC, IPv4/prefix, gateway, and DNS projection
  - pass attachment specifications into sidecar bootstrap
  - create `VZVmnetNetworkDeviceAttachment` inside the sidecar from the persisted lease
- [ ] Expose the network control API.
  - `PrepareSandboxNetwork`
  - `InspectSandboxNetwork`
  - `ReleaseSandboxNetwork`
- [ ] Add restart recovery and explicit network cleanup.
  - recover sidecar attachment state from the persisted lease
  - recover helper or apiserver runtime state from persisted lease plus sandbox snapshot
  - make cleanup explicit through `ReleaseSandboxNetwork`
- [ ] Finish network correctness work.
  - reconcile guest-visible resolver state with host-side DNS projection
  - validate same-node and external connectivity end to end
- [ ] Re-enable limited darwin CLI networking.
  - support only `--network <id>[,mac=...]`
  - support only basic DNS parameters backed by `ContainerConfiguration.dns`
  - keep `--publish` and `--publish-socket` out of scope

### Exit Criteria

- [ ] Single-NIC, single-network, IPv4-first sandbox startup is reliable.
- [ ] External and same-node connectivity work with real reported network state.
- [ ] Network lifecycle can be prepared, inspected, released, and recovered without manual cleanup.
- [ ] The darwin `--network` flow is a thin wrapper over the internal network control path.

## 2. P2: Sandbox and Workload Runtime

### TODO

- [ ] Add first-class sandbox and workload resources.
  - `SandboxConfiguration`
  - `SandboxSnapshot`
  - `WorkloadConfiguration`
  - `WorkloadSnapshot`
- [ ] Split sandbox lifecycle from workload lifecycle.
  - `CreateSandbox`
  - `StartSandbox`
  - `CreateWorkload`
  - `StartWorkload`
  - stopping a sandbox stops all bound workloads
- [ ] Run multiple workloads inside one sandbox.
  - reuse the multi-session base in `MacOSSandboxService`
  - add workload-to-session mapping
  - add wait, cleanup, and error propagation
- [ ] Add sandbox-scoped state and filesystem primitives.
  - sandbox metadata and directory layout
  - temporary directories
  - host path mappings
  - generic read-only file injection
- [ ] Make workload state independently queryable.
  - status
  - exit code
  - log path

### Exit Criteria

- [ ] Two workloads can run reliably inside the same sandbox.
- [ ] Stopping a sandbox consistently stops and cleans up all attached workloads.
- [ ] Workload state is queryable independently from sandbox state.

## 3. P3: Workload Image and Injection

### TODO

- [ ] Add explicit image role metadata.
  - `sandbox image`
  - `workload image`
- [ ] Keep sandbox image and workload image responsibilities separate.
  - sandbox image boots the VM
  - workload image carries payload and execution metadata
- [ ] Define the workload artifact format.
  - file tree payload
  - `entrypoint`
  - `cmd`
  - default environment variables
  - user
  - working directory
- [ ] Implement guest-side workload layout and payload injection.
  - reuse the existing file transfer path
  - `/var/lib/container/workloads/<id>/rootfs`
  - `/var/lib/container/workloads/<id>/meta.json`
  - define sharing and cleanup semantics when multiple workloads use one sandbox image
- [ ] Distinguish sandbox images from workload images in builder and image store.

### Exit Criteria

- [ ] One sandbox image can host multiple workload images.
- [ ] Workload injection, startup, and cleanup are stable and reproducible.

## 4. P4: Core Control Surface

### TODO

- [ ] Publish the runtime control API.
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
- [ ] Make inspect operations return stable snapshots.
- [ ] Publish logging and event interfaces.
  - per-workload stdout and stderr
  - sandbox event log
  - log path or log-reading APIs
- [ ] Implement `PortForward` over the sidecar or vsock path.
- [ ] Keep CLI parsing, on-disk layout, and sidecar protocol details out of the control API.
- [ ] Add state transition, idempotency, recovery, and error propagation tests.

### Exit Criteria

- [ ] External integrations can use only the control APIs and do not need to call the CLI or read internal state files.
- [ ] `exec`, `attach`, `logs`, and `port-forward` have stable core-side contracts.

## 5. Later Enhancements

- [ ] `HostPort`
- [ ] multiple network attachments
- [ ] IPv6
- [ ] crash recovery beyond the initial restart and cleanup guarantees above
- [ ] metrics, tracing, and health checking
- [ ] APFS snapshots
- [ ] `chroot` or jail-style isolation
- [ ] stronger in-guest seatbelt or fine-grained isolation
