# macOS Guest Networking Design

Network model for macOS guest sandboxes in `container core`.

## 1. Backend

The runtime selects the backend through `ContainerConfiguration.macosGuest.networkBackend`.

Supported values:

- `virtualizationNAT`
  - default backend
  - implemented with `VZNATNetworkDeviceAttachment`
  - used for backward compatibility and darwin image-build workflows
- `vmnetShared`
  - runtime backend for host-visible sandbox networking
  - implemented with `VZVmnetNetworkDeviceAttachment`

If `networkBackend` is absent, it defaults to `virtualizationNAT`.

If `vmnetShared` is selected and no explicit `ContainerConfiguration.networks` are provided, the runtime uses the builtin `default` network.

## 2. Guest Bring-Up

Guest networking is applied by a dedicated guest network manager. It:

- matches the NIC by MAC
- configures IPv4, prefix, and gateway
- writes DNS settings
- returns the applied interface name and current IP

Network setup does not run through the generic exec path.

## 3. Lease Model

Network state is owned by host control-plane code in helper or apiserver-managed components.

The persisted lease stores:

- `networkID`
- backend
- MAC
- IPv4 and prefix
- gateway
- DNS projection

The sidecar reads that lease and creates VM-local `VZ*NetworkDeviceAttachment` instances during bootstrap or recovery.

The guest network manager applies the same lease inside the guest.

The sidecar is not durable network state. Do not use serialized `vmnet` attachment objects as the long-term data model.

Host-visible sandbox snapshots report at least:

- IP
- gateway
- DNS
- MAC
- network ID

## 4. Network Control API

- `PrepareSandboxNetwork`
- `InspectSandboxNetwork`
- `ReleaseSandboxNetwork`

`PrepareSandboxNetwork` allocates or restores the persisted lease and returns the attachment specification plus host-visible network state.

`InspectSandboxNetwork` reads the persisted lease and current reported state.

`ReleaseSandboxNetwork` removes the lease and related host-side allocations.

## 5. Recovery

- sidecar restart recreates local attachments from the persisted lease
- helper or apiserver restart rebuilds runtime state from the persisted lease and sandbox snapshot
- cleanup happens through `ReleaseSandboxNetwork`, not through sidecar teardown

## 6. CLI and Build Boundary

The darwin CLI network surface is:

- `--network <id>[,mac=...]`
- basic DNS parameters backed by `ContainerConfiguration.dns`

The darwin path does not support:

- `--publish`
- `--publish-socket`
- multi-network semantics in the first iteration

`PortForward` remains a separate runtime capability.

`container build --platform darwin/arm64` stays on `virtualizationNAT`. `vmnetShared` is reserved for sandbox runtime paths that need stable host-visible network state.
