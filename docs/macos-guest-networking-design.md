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
- writes guest-supported DNS settings (`nameservers`, `domain`, and `searchDomains`)
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
  - limited to guest-visible resolver state
  - excludes generic resolver `options`

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
  - `--dns`
  - `--dns-domain`
  - `--dns-search`
- `--publish <spec>`
  - enables host port forwarding on the host-visible `vmnetShared` runtime path
  - currently supports IPv4 host bindings only
  - if no explicit `--network` is provided, the runtime uses the builtin `default` network

The darwin path does not support:

- `--dns-option`
- `--publish-socket`
- multi-network semantics in the first iteration

`PortForward` remains a separate runtime capability.

`container build --platform darwin/arm64` stays on `virtualizationNAT`. `vmnetShared` is reserved for sandbox runtime paths that need stable host-visible network state.

## 7. Native Attachment and Host Gateway Readiness

The network helper reserves a logical vmnet network. The sidecar imports its serialized reference with `vmnet_network_create_with_serialization`, creates a `VZVmnetNetworkDeviceAttachment`, and retains the imported reference and allocation session for the VM's lifetime. Reserving a network or importing its reference does not establish that its first VM interface has started.

VM startup and network attachment startup have separate failure signals. The sidecar records `virtualMachine(_:networkDevice:attachmentWasDisconnectedWithError:)` callbacks, checks runtime attachments before and after host gateway activation, and checks them again before completing cold bootstrap. A disconnected attachment fails startup or restore with `networkAttachmentDisconnected`. Response metadata contains the device index when available, the native error domain and code, and the immediate underlying error domain and code. Bounded `details` preserve the error chain without serializing arbitrary error user information. A later gateway timeout does not replace an earlier native attachment error. Errors observed during normal VM execution are logged; the callback does not change the topology or reconnect devices automatically.

For a host-only network with an explicit IPv6 subnet, the host gateway readiness check still requires the expected IPv4 gateway on exactly one bridge and the non-tentative IPv6 gateway with the exact prefix on that bridge. Its bounded timeout includes `lastObservation=bridgeMissing` when the IPv4 bridge was absent on the last check, or `lastObservation=ipv6GatewayPending` when the bridge existed but IPv6 was not ready. Address conflicts remain immediate errors. These observations distinguish interface creation from subsequent IPv6 gateway convergence; neither observation is evidence of guest process readiness or machine-state restoration.

Apple documents both [network serialization](https://developer.apple.com/documentation/vmnet/vmnet_network_create_with_serialization(_:_:)) and the [same-process restriction for native attachments](https://developer.apple.com/documentation/virtualization/vzvmnetnetworkdeviceattachment/init(network:)). Successful deserialization and VM startup alone do not establish that a particular host OS build supports the complete imported-reference topology. Real-host verification must additionally observe the native attachment, the expected host bridge and both gateways, and guest connectivity. Unit tests exercise error propagation and readiness transitions without creating a host network.
