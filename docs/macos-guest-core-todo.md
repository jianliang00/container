# macOS Guest Core TODO

Implementation plan for macOS guest support in `container core`.

Related design docs:

- [`macos-guest-core-design.md`](./macos-guest-core-design.md)
- [`macos-guest-workload-image-design.md`](./macos-guest-workload-image-design.md)
- [`macos-guest-dockerfile-build-design.md`](./macos-guest-dockerfile-build-design.md)
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
- [x] Replace serialized `vmnet` handoff with persisted sandbox network leases.
  - [x] persist backend, `networkID`, MAC, IPv4/prefix, gateway, and DNS projection
  - [x] pass attachment specifications into sidecar bootstrap
  - [x] create `VZVmnetNetworkDeviceAttachment` inside the sidecar from persisted lease-backed attachment state
- [x] Expose the network control API.
  - `PrepareSandboxNetwork`
  - `InspectSandboxNetwork`
  - `ReleaseSandboxNetwork`
- [x] Add restart recovery and explicit network cleanup.
  - [x] recover sidecar attachment state from the persisted lease
  - [x] recover helper runtime inspect and cleanup state from the persisted lease
  - [x] recover apiserver runtime state from persisted lease plus sandbox snapshot
  - [x] make cleanup explicit through `ReleaseSandboxNetwork`
- [x] Finish network correctness work.
  - [x] reconcile guest-visible resolver state with host-side DNS projection
  - [x] validate same-node and external connectivity end to end
- [x] Re-enable limited darwin CLI networking.
  - [x] support only `--network <id>[,mac=...]`
  - [x] support only basic DNS parameters backed by `ContainerConfiguration.dns`
  - [x] support `--publish` on the host-visible single-network path
  - [x] keep `--publish-socket` out of scope

### Exit Criteria

- [x] Single-NIC, single-network, IPv4-first sandbox startup is reliable.
- [x] External and same-node connectivity work with real reported network state.
- [x] Network lifecycle can be prepared, inspected, released, and recovered without manual cleanup.
- [x] The darwin `--network` flow is a thin wrapper over the internal network control path.

## 2. P2: Sandbox and Workload Runtime

### TODO

- [x] Add first-class sandbox and workload resources.
  - [x] `SandboxConfiguration`
  - [x] `SandboxSnapshot`
  - [x] `WorkloadConfiguration`
  - [x] `WorkloadSnapshot`
- [x] Split sandbox lifecycle from workload lifecycle.
  - [x] `CreateSandbox`
  - [x] `StartSandbox`
  - [x] `CreateWorkload`
  - [x] `StartWorkload`
  - [x] stopping a sandbox stops all bound workloads
- [x] Run multiple workloads inside one sandbox.
  - reuse the multi-session base in `MacOSSandboxService`
  - [x] add workload-to-session mapping
  - [x] add wait, cleanup, and error propagation
  - [x] add regression coverage for independent workload state and cleanup
- [x] Add sandbox-scoped state and filesystem primitives.
  - [x] sandbox metadata and directory layout
  - [x] temporary directories
  - [x] host path mappings
  - [x] generic read-only file injection
- [x] Make workload state independently queryable.
  - [x] status
  - [x] exit code
  - [x] log path

### Exit Criteria

- [x] Two workloads can run reliably inside the same sandbox.
- [x] Stopping a sandbox consistently stops and cleans up all attached workloads.
- [x] Workload state is queryable independently from sandbox state.

## 3. P3: Workload Image, Injection, and Build Split

### Delivery Notes

- Reuse the existing `WorkloadConfiguration` / `WorkloadSnapshot` persistence path
  instead of introducing a parallel workload state model.
- Reuse the existing sidecar `fs.begin` / `fs.chunk` / `fs.end` transfer path for
  workload payload injection instead of inventing a new guest transport.
- Keep the current whole-disk packager and `MacOSBuildEngine` as the `sandbox build`
  path, then add `workload build` as an additive mode with an explicit payload
  boundary.

### TODO

- [x] Lock the image-role contract and reject role mismatches early.
  - [x] add explicit annotations:
    - `org.apple.container.macos.image.role=sandbox`
    - `org.apple.container.macos.image.role=workload`
    - `org.apple.container.macos.workload.format=v1`
  - [x] keep current VM bundle validation only for `sandbox image`
  - [x] add workload-image validation for ordinary filesystem layers plus OCI config
  - [x] fail fast when:
    - [x] a `workload image` is used to boot a sandbox
    - [x] a `sandbox image` is used as a workload payload
- [x] Extend the workload resource model to support image-backed workloads.
  - [x] extend `WorkloadConfiguration` to persist:
    - workload image reference
    - resolved workload image digest
    - guest payload path
    - guest metadata path
    - injection state
  - [x] make `CreateWorkload` reference a workload image plus runtime overrides, not
    only a raw process definition
  - [x] keep `InspectWorkload` stable across restart recovery by rebuilding state from
    persisted workload configuration
- [x] Define the workload OCI artifact format on top of standard image primitives.
  - [x] use ordinary OCI filesystem payload layers for workload contents
  - [x] source default startup metadata from OCI image config:
    - `entrypoint`
    - `cmd`
    - environment
    - user
    - working directory
  - [x] persist guest `meta.json` with:
    - workload image digest
    - effective process metadata
    - creation timestamp
  - [x] add a dedicated host-side workload packager, for example
    `MacOSWorkloadPackager`, that walks a payload root and emits OCI output
- [x] Implement host unpack, guest injection, and cleanup semantics.
  - [x] unpack workload layers on the host into a cache keyed by workload image digest
  - [x] inject each workload into:
    - `/var/lib/container/workloads/<id>/rootfs`
    - `/var/lib/container/workloads/<id>/meta.json`
  - [x] start workloads from persisted image metadata plus runtime overrides by
    reusing the existing process-start path
  - [x] separate cleanup responsibilities:
    - [x] remove the guest instance directory when one workload is removed
    - [x] remove all guest workload directories when the sandbox is stopped
    - [x] keep host unpack cache separate from guest instance lifetime
  - [x] cover restart points before and after injection so recovery can determine
    whether reinjection is needed
- [x] Split macOS build into explicit `sandbox build` and `workload build` modes.
  - [x] keep the current whole-disk commit flow as `sandbox build`
  - [x] add explicit `payloadRoot`, recommended as
    `/var/lib/container/build/payload`
  - [x] route `COPY` and `ADD(local)` into `payloadRoot`
  - [x] track `WORKDIR` relative to `payloadRoot`
  - [x] persist `ENV`, `USER`, `CMD`, and `ENTRYPOINT` into workload image config
  - [x] keep `RUN` executing in the build sandbox so it can use machine-global tools
  - [x] narrow `RUN` semantics to "only writes under `payloadRoot` are committed"
  - [x] add explicit build-sandbox selection, such as
    `--build-sandbox-image <sandbox-ref>`
  - [x] reject or clearly document unsupported workload-build cases:
    - guest-global installers whose writes must become workload payload
    - `pkg`-driven system installs captured as workload payload
    - whole-guest diff capture
  - [x] stabilize the real-guest `RUN` path in workload-build mode
- [x] Add focused coverage for the mixed sandbox/workload flow.
  - [x] one sandbox image can host multiple workload images
  - [x] workload images can be packed, pushed, pulled, validated, unpacked, and injected
  - [x] workload-start defaults come from OCI config and can be overridden at runtime
  - [x] workload builds use machine-global tools from the sandbox image without
    copying those tools into the workload image
  - [x] workload builds never depend on whole-guest diff detection

### Exit Criteria

- [x] Runtime rejects sandbox/workload role mismatches before VM boot or payload
  injection begins.
- [x] One sandbox image can host multiple workload images with stable injection,
  startup, restart recovery, and cleanup.
- [x] Workload images can be packed, pushed, pulled, validated, unpacked, and started
  from OCI config defaults plus runtime overrides.
- [x] `workload build` commits only `payloadRoot`, while `sandbox build` remains the
  only path that commits machine-global guest state.

## 4. P4: Core Control Surface

### TODO

- [x] Publish the runtime control API.
  - [x] `CreateSandbox`
  - [x] `StartSandbox`
  - [x] `StopSandbox`
  - [x] `RemoveSandbox`
  - [x] `CreateWorkload`
  - [x] `StartWorkload`
  - [x] `StopWorkload`
  - [x] `RemoveWorkload`
  - [x] `InspectSandbox`
  - [x] `InspectWorkload`
  - [x] `ExecSync`
  - [x] `StreamExec`
  - [x] `StreamAttach`
  - [x] `StreamPortForward`
- [x] Make inspect operations return stable snapshots.
- [x] Publish logging and event interfaces.
  - per-workload stdout and stderr
  - sandbox event log
  - log path or log-reading APIs
- [x] Implement `PortForward` over the sidecar or vsock path.
- [x] Keep CLI parsing, on-disk layout, and sidecar protocol details out of the control API.
- [x] Add state transition, idempotency, recovery, and error propagation tests.

### Exit Criteria

- [x] External integrations can use only the control APIs and do not need to call the CLI or read internal state files.
- [x] `exec`, `attach`, `logs`, and `port-forward` have stable core-side contracts.

## 5. P5: L4 Network Policy and Audit

### TODO

- [x] Add sandbox-scoped L4 policy resource types.
  - [x] policy generation
  - [x] ingress ACL
  - [x] egress ACL
  - [x] IPv4 CIDR and single-host endpoints
  - [x] TCP and UDP protocols
  - [x] single ports and port ranges
  - [x] allow and deny actions
  - [x] default action
  - [x] audit mode
- [x] Persist applied policy state with sandbox network state.
  - [x] sandbox ID
  - [x] network ID
  - [x] IPv4 address
  - [x] MAC address
  - [x] policy generation
  - [x] rendered host rule identifiers
  - [x] last apply result
- [x] Add network policy control APIs.
  - [x] `ApplySandboxPolicy(sandboxID, generation, ingressACL, egressACL)`
  - [x] `RemoveSandboxPolicy(sandboxID)`
  - [x] `InspectSandboxPolicy(sandboxID)`
- [x] Add XPC client and server routes for policy control.
  - [x] `SandboxRoutes.applyNetworkPolicy`
  - [x] `SandboxRoutes.removeNetworkPolicy`
  - [x] `SandboxRoutes.inspectNetworkPolicy`
  - [x] `SandboxClient.applySandboxPolicy`
  - [x] `SandboxClient.removeSandboxPolicy`
  - [x] `SandboxClient.inspectSandboxPolicy`
- [x] Add API service wrappers for external integrations.
  - [x] `ClientNetwork.applySandboxPolicy`
  - [x] `ClientNetwork.removeSandboxPolicy`
  - [x] `ClientNetwork.inspectSandboxPolicy`
  - [x] `ContainerKit.applySandboxPolicy`
  - [x] `ContainerKit.removeSandboxPolicy`
  - [x] `ContainerKit.inspectSandboxPolicy`
- [x] Add policy preflight validation.
  - [x] accept policies for `vmnetShared` sandbox leases
  - [x] return unsupported errors for `virtualizationNAT`
  - [x] return invalid-state errors for missing leases
  - [x] return invalid-argument errors for non-IPv4 endpoints
  - [x] reject stale generations
- [x] Add a host packet policy controller.
  - [x] render ingress rules by sandbox IPv4 and MAC
  - [x] render egress rules by sandbox IPv4 and MAC
  - [x] render TCP and UDP port rules
  - [x] apply rules idempotently by sandbox ID and generation
  - [x] replace rules atomically for a new generation
  - [x] remove rules during policy removal
  - [x] remove rules during network release and sandbox shutdown
  - [x] expose apply, replace, remove, and status operations
- [x] Add published-port policy enforcement.
  - [x] evaluate inbound TCP connections before backend connect
  - [x] evaluate inbound UDP datagrams before backend write
  - [x] map published host ports to guest ports during policy evaluation
  - [x] close denied TCP connections
  - [x] drop denied UDP datagrams
  - [x] emit audit events for allowed and denied published-port traffic
- [x] Add structured network audit events.
  - [x] timestamp
  - [x] sandbox ID
  - [x] network ID
  - [x] policy generation
  - [x] direction
  - [x] protocol
  - [x] source IP
  - [x] source port
  - [x] destination IP
  - [x] destination port
  - [x] action
  - [x] rule ID
  - [x] enforcement source
- [ ] Add an audit event sink.
  - [x] append audit events to the sandbox event log
  - [x] expose audit event paths in sandbox inspect output
  - [ ] rotate audit logs with existing sandbox log retention behavior
  - [x] include policy generation in inspect snapshots
- [ ] Add host packet audit ingestion.
  - [ ] collect allowed and denied ingress events from host rules
  - [ ] collect allowed and denied egress events from host rules
  - [ ] normalize host rule events into the structured audit schema
  - [ ] attach sandbox identity from persisted policy state
- [ ] Add recovery behavior.
  - [x] reload persisted policy state during helper restart
  - [ ] reapply host rules after helper restart
  - [ ] reconcile missing host rules with persisted generations
  - [ ] remove orphaned host rules for deleted sandboxes
- [ ] Add unit coverage.
  - [x] policy model encoding and decoding
  - [ ] ACL validation
  - [x] generation conflict handling
  - [x] host rule rendering
  - [x] published-port TCP allow, deny, and audit
  - [x] published-port UDP allow, deny, and audit
  - [x] policy persistence and recovery
  - [x] policy removal cleanup
- [ ] Add integration coverage.
  - [ ] same-node sandbox ingress allow and deny
  - [ ] external egress allow and deny
  - [ ] published TCP port allow and deny
  - [ ] published UDP port allow and deny
  - [ ] audit events for each enforced path
  - [ ] policy reapply after helper restart
  - [ ] rule cleanup after sandbox removal

### Exit Criteria

- [ ] A `vmnetShared` sandbox accepts, replaces, inspects, and removes L4 policy by generation.
- [ ] Host-side rules enforce IPv4 ingress and egress ACLs for TCP and UDP at the sandbox boundary.
- [ ] Published TCP and UDP ports apply the same policy decision model as host packet rules.
- [ ] Allowed and denied L4 traffic emits structured audit events with sandbox identity and policy generation.
- [ ] Policy state and host rules recover across helper restart.
- [ ] Network release and sandbox removal clean up persisted policy state, host rules, and audit handles.

## 6. Later Enhancements

- [ ] `HostPort`
- [ ] multiple network attachments
- [ ] IPv6
- [ ] crash recovery beyond the initial restart and cleanup guarantees above
- [ ] metrics, tracing, and health checking
- [ ] APFS snapshots
- [ ] `chroot` or jail-style isolation
- [ ] stronger in-guest seatbelt or fine-grained isolation
