# macOS Guest Networking Design

This document records the current networking boundary for the macOS guest runtime in `container core`.

## Goals

- remove the hard-coded `VZNATNetworkDeviceAttachment` assumption from the sidecar
- establish a stable backend selection point for future `vmnetShared` work
- keep the current `container run --os darwin` path on the compatibility backend until the new data plane exists

## Current Backend Model

The macOS sidecar now resolves networking through `ContainerConfiguration.macosGuest.networkBackend`.

Supported values:

- `virtualizationNAT`
  - compatibility backend
  - implemented with `VZNATNetworkDeviceAttachment`
  - remains the default for backward compatibility
- `vmnetShared`
  - implemented with `VZVmnetNetworkDeviceAttachment`
  - selected explicitly in config
  - allocates endpoint identity through `container-network-vmnet`
  - deserializes the vmnet network reference inside the sidecar process before attaching it to the VM
  - pushes static guest networking to a dedicated guest-agent network configurator during bootstrap
  - reports network ID, IP, gateway, MAC, and projected DNS back through sandbox snapshots on the host

## Why This Boundary Exists

This keeps backend selection inside the macOS runtime layer, where VM network devices are actually created, while avoiding Kubernetes- or CNI-specific concepts in `container core`.

The design intent is:

- `container core` owns backend selection, VM attachment, and network state plumbing
- external integrations decide when to request `vmnetShared`
- the CLI does not grow kubelet- or CNI-specific network controls in this phase
- internal callers can still provide `ContainerConfiguration.networks` and `ContainerConfiguration.dns` on the darwin path

## Configuration Shape

The backend is carried in `macosGuest`:

```json
{
  "macosGuest": {
    "snapshotEnabled": false,
    "guiEnabled": false,
    "agentPort": 27000,
    "networkBackend": "virtualizationNAT"
  }
}
```

If `networkBackend` is absent, decoding defaults to `virtualizationNAT` so older bundles remain compatible.

When `vmnetShared` is selected and no explicit `ContainerConfiguration.networks` are supplied, the runtime falls back to the builtin `default` network.

## Current Limitations

- the current `vmnetShared` path still depends on host-side allocation from `container-network-vmnet`
- guest-side static IPv4, route, and DNS bootstrap now run through a dedicated guest-agent network configurator
- DNS `options` are not yet applied inside the guest; the configurator returns a warning instead
- the current backend integration is still the serialization-based PoC; long-term ownership and recovery semantics still need to be frozen

## Build And Base Image Boundary

Base-image bootstrap and `container build --platform darwin/arm64` should stay on the compatibility backend:

- `virtualizationNAT` remains the expected backend for image preparation, agent installation, and Dockerfile build stages
- `vmnetShared` is reserved for the runtime path that needs stable host-visible network state
- do not switch build-stage VMs to `vmnetShared` yet, because those workflows may need networking before the guest has installed or started the agent-side control path

## Next Steps

The next implementation steps should be:

1. freeze restart and recovery semantics for sidecar-owned vs helper-owned vmnet resources
2. add a standalone network control API for prepare, inspect, and release flows
3. validate cross-sandbox and external connectivity end-to-end
