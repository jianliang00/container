# SwiftPM `ContainerKit` TODO

This document turns
[`docs/swiftpm-containerkit-design.md`](./swiftpm-containerkit-design.md)
into an executable checklist. It assumes the current tree does not yet contain
`ContainerKit` or `ContainerKitServices` targets.

## 1. Scope Guardrails

- [ ] Keep `ContainerKit` a thin facade over `ContainerAPIClient` and
      `ContainerResource`.
- [ ] Keep `ContainerKit` free of direct dependencies on
      `ContainerCommands`, `ArgumentParser`, `ContainerPlugin`, and
      `ContainerXPC`.
- [ ] Keep `ContainerKitServices` opt-in and explicit. It must never start
      services during `init` or on first client request.
- [ ] Reuse existing public model and error types. Do not add
      `ContainerKitError` or duplicate `ContainerResource` models in v1.
- [ ] Keep provisioning out of scope for the first cut:
      kernel installation, base image installation, interactive prompts,
      plugin installation workflows, and any auto-bootstrap behavior.

## 2. Phase 1: Add the `ContainerKit` Facade Target

### TODO

- [ ] Add `.library(name: "ContainerKit", targets: ["ContainerKit"])` to
      `Package.swift`.
- [ ] Add a new target in `Package.swift` with only:
      `ContainerAPIClient` and `ContainerResource` as dependencies.
- [ ] Create the initial target layout:
      - `Sources/ContainerKit/ContainerKit.swift`
      - `Sources/ContainerKit/ContainerKit+Aliases.swift`
      - `Sources/ContainerKit/ContainerKit+Containers.swift`
      - `Sources/ContainerKit/ContainerKit+Images.swift`
      - `Sources/ContainerKit/ContainerKit+Volumes.swift`
      - `Sources/ContainerKit/ContainerKit+Networks.swift`
      - `Sources/ContainerKit/ContainerKit+System.swift`
- [ ] Add the root type:
      `public struct ContainerKit: Sendable { public init() }`
- [ ] Store only one reusable `ContainerClient` instance on `ContainerKit`.
- [ ] Add a top-level doc comment that states the runtime contract clearly:
      services must already be installed and already running.

### Public Alias Checklist

- [ ] Re-export the first-layer consumer types with top-level aliases:
      - `ContainerConfiguration`
      - `ContainerCreateOptions`
      - `ContainerListFilters`
      - `ContainerSnapshot`
      - `ContainerStopOptions`
      - `DiskUsageStats`
      - `Image`
      - `NetworkConfiguration`
      - `NetworkState`
      - `ProcessConfiguration`
      - `SystemHealth`
      - `Volume`
- [ ] Keep the alias list intentionally small. Only add aliases that are used
      by the facade methods or by the recommended consumer examples.
- [ ] Do not wrap or translate models unless the lower-level API forces it.

### System and Container Methods

- [ ] Implement `health(timeout:)` as a direct call to
      `ClientHealthCheck.ping`.
- [ ] Implement `diskUsage()` as a direct call to `ClientDiskUsage.get`.
- [ ] Implement `listContainers(filters:)` via `ContainerClient.list`.
- [ ] Implement `getContainer(id:)` via `ContainerClient.get`.
- [ ] Implement `createContainer(configuration:options:)` via
      `ContainerClient.create`.
- [ ] Implement `stopContainer(id:options:)` via `ContainerClient.stop`.
- [ ] Implement `deleteContainer(id:force:)` via `ContainerClient.delete`.
- [ ] Implement `containerDiskUsage(id:)` via `ContainerClient.diskUsage`.

### Image, Volume, and Network Methods

- [ ] Implement image methods as direct delegation to `ClientImage`:
      - `listImages()`
      - `getImage(reference:)`
      - `pullImage(reference:)`
      - `deleteImage(reference:garbageCollect:)`
- [ ] Implement volume methods as direct delegation to `ClientVolume`:
      - `listVolumes()`
      - `createVolume(name:driver:driverOptions:labels:)`
      - `inspectVolume(_:)`
      - `deleteVolume(name:)`
      - `volumeDiskUsage(name:)`
- [ ] Decide and document the public argument label for volume driver options.
      The design uses `driverOptions`, while the current lower-level API uses
      `driverOpts`. The facade should expose one stable spelling.
- [ ] Implement network methods as direct delegation to `ClientNetwork`:
      - `listNetworks()`
      - `getNetwork(id:)`
      - `createNetwork(configuration:)`
      - `deleteNetwork(id:)`
- [ ] Keep all facade methods as thin forwarding wrappers. No caching, retry,
      transport abstraction, or protocol-heavy test seam should be added.

### Exit Criteria

- [ ] A consumer can depend on
      `.product(name: "ContainerKit", package: "container")`.
- [ ] A consumer can `import ContainerKit` without importing lower-level
      modules for the common flows.
- [ ] A consumer can compile the documented calls for:
      health, disk usage, container list/create/stop/delete,
      image list/pull/delete, volume list/create/delete, and
      network list/create/delete.
- [ ] The `ContainerKit` target still has no host-management or launchd
      dependencies.

## 3. Phase 2: Add the Optional `ContainerKitServices` Layer

### TODO

- [ ] Add `.library(name: "ContainerKitServices", targets: ["ContainerKitServices"])`
      to `Package.swift`.
- [ ] Add a new target in `Package.swift` with dependencies on:
      `ContainerKit` and `ContainerPlugin`.
- [ ] Create the initial target layout:
      - `Sources/ContainerKitServices/ContainerKitServices.swift`
      - `Sources/ContainerKitServices/ContainerKitServices+Start.swift`
      - `Sources/ContainerKitServices/ContainerKitServices+Stop.swift`
      - `Sources/ContainerKitServices/ContainerKitServices+Status.swift`
- [ ] Add the root type:
      `public struct ContainerKitServices: Sendable`
- [ ] Add the explicit installation description:
      `public struct ContainerInstallation { let installRoot: URL; let apiServerExecutableURL: URL }`
- [ ] Add the initializer:
      `init(appRoot: URL = ApplicationRoot.defaultURL, installation: ContainerInstallation)`
- [ ] Add the public `ServiceStatus` value type:
      - `isRegistered: Bool`
      - `health: SystemHealth?`

### Start Flow

- [ ] Implement `start(timeout:)` without calling `ArgumentParser` command
      implementations.
- [ ] Do not infer the `container-apiserver` executable path from the
      embedding app. Require it through `ContainerInstallation`.
- [ ] Build the launchd environment with `ApplicationRoot` and `InstallRoot`.
- [ ] Generate the plist with `LaunchPlist`.
- [ ] Write the plist into the app root service directory
      (matching the current `system start` layout).
- [ ] Register the service with `ServiceManager.register`.
- [ ] Verify readiness with `ClientHealthCheck.ping`.
- [ ] Preserve useful diagnostics for launchd registration and failed health
      checks, but keep the API non-interactive.

### Stop and Status Flow

- [ ] Implement `status()` using `ServiceManager.isRegistered` plus an
      optional health ping.
- [ ] Implement `ensureRunning(timeout:)` to call `start()` only when the
      service is absent or unhealthy.
- [ ] Implement `stop()` with the same core behavior as the CLI path:
      - best-effort stop of running containers
      - short wait for container shutdown
      - deregister the API server service
      - best-effort deregistration of related services under the same prefix
- [ ] Keep `stop()` best-effort and explicit. Do not add interactive prompts or
      hidden cleanup beyond service lifecycle.

### Refactoring Support Work

- [ ] Identify any logic in the current CLI-only files that must move into a
      reusable library location:
      - `Sources/ContainerCommands/System/SystemStart.swift`
      - `Sources/ContainerCommands/System/SystemStop.swift`
      - `Sources/ContainerCommands/System/SystemStatus.swift`
- [ ] If code extraction is needed, move only non-CLI lifecycle helpers into a
      reusable place. Do not make `ContainerKitServices` depend on
      `ContainerCommands`.
- [ ] Keep `ContainerKit` itself free of launchd/bootstrap concerns after the
      refactor.

### Exit Criteria

- [ ] A consumer can optionally add
      `.product(name: "ContainerKitServices", package: "container")`.
- [ ] Service lifecycle remains explicit and opt-in.
- [ ] `ContainerKitServices` can start, stop, check, and ensure API service
      readiness without importing CLI command types.
- [ ] `ContainerKitServices` requires explicit helper installation inputs
      instead of assuming CLI-style colocated binaries.
- [ ] Phase 1 exclusions remain out of scope:
      kernel installation, base image installation, plugin installation, and
      interactive confirmation.

## 4. Phase 3: Documentation and Consumer Guidance

### TODO

- [ ] Add a short SwiftPM dependency example that uses `ContainerKit`.
- [ ] Add a short usage example for `health()` and at least one resource area
      such as containers or images.
- [ ] Document the runtime preconditions explicitly:
      `ContainerKit` talks to already-installed, already-running services.
- [ ] Document when `ContainerKitServices` should be used instead:
      explicit host lifecycle control by the embedding app.
- [ ] Add the above guidance to `docs/how-to.md` or to a dedicated embedding
      example if that becomes clearer.

### Exit Criteria

- [ ] An external Swift developer can find the recommended product import path
      without reading source files.
- [ ] The docs explain the difference between the facade and the service layer.
- [ ] The docs make the runtime contract explicit before the first code sample.

## 5. Phase 4: Minimal Verification

### TODO

- [ ] Add `Tests/ContainerKitTests` and wire a new test target in `Package.swift`.
- [ ] Add `Tests/ContainerKitServicesTests` and wire a new test target in
      `Package.swift`.
- [ ] Add compile-focused tests for the public aliases.
- [ ] Add compile-focused tests for the intended facade call signatures.
- [ ] Add focused tests for service-layer behavior:
      - plist generation
      - registration and deregistration flow
      - health check success and failure handling
- [ ] Reuse existing integration coverage for runtime semantics instead of
      creating a fake in-memory backend.
- [ ] Only add a dedicated SwiftPM consumer smoke test if packaging regressions
      actually become a recurring problem.

### Exit Criteria

- [ ] Normal SwiftPM test runs catch facade API regressions.
- [ ] The new targets do not require a mock-only protocol abstraction layer.
- [ ] Service-layer coverage is focused on lifecycle inputs and outputs, not on
      recreating the runtime.

## 6. Existing Code to Reuse

- `Sources/Services/ContainerAPIService/Client/ClientHealthCheck.swift`
- `Sources/Services/ContainerAPIService/Client/ClientDiskUsage.swift`
- `Sources/Services/ContainerAPIService/Client/ContainerClient.swift`
- `Sources/Services/ContainerAPIService/Client/ClientImage.swift`
- `Sources/Services/ContainerAPIService/Client/ClientVolume.swift`
- `Sources/Services/ContainerAPIService/Client/ClientNetwork.swift`
- `Sources/ContainerPlugin/ApplicationRoot.swift`
- `Sources/ContainerPlugin/InstallRoot.swift`
- `Sources/ContainerPlugin/LaunchPlist.swift`
- `Sources/ContainerPlugin/ServiceManager.swift`
- `Sources/ContainerCommands/System/SystemStart.swift`
- `Sources/ContainerCommands/System/SystemStop.swift`
- `Sources/ContainerCommands/System/SystemStatus.swift`

## 7. Explicitly Out of Scope for the First Cut

- [ ] `XCFramework` or binary distribution work
- [ ] helper embedding or helper auto-install flows
- [ ] automatic launchd bootstrap inside `ContainerKit`
- [ ] custom progress abstractions
- [ ] DNS, packet filter, kernel, or provisioning helper APIs
- [ ] interactive stdio orchestration and other advanced CLI flows
- [ ] broad facade coverage for every API currently exposed by
      `ContainerAPIClient`
