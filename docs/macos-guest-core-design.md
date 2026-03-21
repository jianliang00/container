# macOS Guest Core Design

Architecture for macOS guest support in `container core`.

## 1. Scope

`container core` provides:

- sandbox VM lifecycle
- workload lifecycle inside a running sandbox
- workload payload injection
- guest networking integration
- runtime and network control APIs

`container core` does not provide:

- CRI or CNI protocol types
- kubelet-facing object models
- Kubernetes `NetworkPolicy` translation
- darwin `HostPort`

Sandbox networking is defined in [`macos-guest-networking-design.md`](./macos-guest-networking-design.md). NetworkPolicy layering is defined in [`macos-guest-networkpolicy-design.md`](./macos-guest-networkpolicy-design.md).

## 2. Runtime Model

### 2.1 Sandbox

`Sandbox` is the VM boundary. It owns:

- VM lifecycle
- network lease
- sidecar lifecycle
- sandbox directories
- shared injected resources
- sandbox event log

### 2.2 Workload

`Workload` is a process payload running inside an existing sandbox. It owns:

- payload files
- `entrypoint`
- `cmd`
- environment
- user and working directory
- stdout and stderr logs
- exit status

### 2.3 Resource Types

Core resources are:

- `SandboxConfiguration`
- `SandboxSnapshot`
- `WorkloadConfiguration`
- `WorkloadSnapshot`

### 2.4 Lifecycle

1. `CreateSandbox`
2. `StartSandbox`
3. `CreateWorkload`
4. `StartWorkload`
5. `StopWorkload`
6. `RemoveWorkload`
7. `StopSandbox`
8. `RemoveSandbox`

Stopping a sandbox stops and cleans up all workloads bound to it.

`MacOSSandboxService` multi-session support remains the execution substrate. Session IDs stay internal and are mapped from workload IDs.

## 3. Image Model

### 3.1 Sandbox Image

`sandbox image` boots the VM and contains only guest base artifacts such as:

- `Disk.img`
- `AuxiliaryStorage`
- `HardwareModel`

### 3.2 Workload Image

`workload image` contains:

- payload file tree
- `entrypoint`
- `cmd`
- default environment variables
- user
- working directory

Image role is explicit metadata. Do not infer it from tag naming.

### 3.3 Guest Layout

Workloads are injected under:

- `/var/lib/container/workloads/<id>/rootfs`
- `/var/lib/container/workloads/<id>/meta.json`

The initial model is payload injection plus process launch. It does not include APFS snapshots, `chroot`, jail-style isolation, or in-guest seatbelt hardening.

## 4. Control Surface

### 4.1 Runtime Control API

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

### 4.2 Network Control API

- `PrepareSandboxNetwork`
- `InspectSandboxNetwork`
- `ReleaseSandboxNetwork`

Network control API semantics are defined in [`macos-guest-networking-design.md`](./macos-guest-networking-design.md).

### 4.3 API Rules

- `Inspect*` returns stable snapshots
- CLI parsing, sidecar protocol details, and on-disk layout stay private to core
- stdout and stderr remain separate per workload
- sandbox events remain separate from workload stdio
- `PortForward` runs over sidecar or vsock transport
