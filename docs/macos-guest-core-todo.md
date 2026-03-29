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
  - [x] keep `--publish` and `--publish-socket` out of scope

### Exit Criteria

- [ ] Single-NIC, single-network, IPv4-first sandbox startup is reliable.
- [x] External and same-node connectivity work with real reported network state.
- [ ] Network lifecycle can be prepared, inspected, released, and recovered without manual cleanup.
- [ ] The darwin `--network` flow is a thin wrapper over the internal network control path.

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
- [ ] Stopping a sandbox consistently stops and cleans up all attached workloads.
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
- [ ] Split macOS build into explicit `sandbox build` and `workload build` modes.
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
- [ ] Add focused coverage for the mixed sandbox/workload flow.
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

- [ ] Publish the runtime control API.
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
  - [ ] `StreamAttach`
  - [x] `StreamPortForward`
- [x] Make inspect operations return stable snapshots.
- [x] Publish logging and event interfaces.
  - per-workload stdout and stderr
  - sandbox event log
  - log path or log-reading APIs
- [x] Implement `PortForward` over the sidecar or vsock path.
- [x] Keep CLI parsing, on-disk layout, and sidecar protocol details out of the control API.
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
