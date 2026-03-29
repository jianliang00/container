# SwiftPM Embedding Design: `ContainerKit`

> [!IMPORTANT]
> This file contains documentation for the CURRENT BRANCH. To find documentation for official releases, find the target release on the [Release Page](https://github.com/apple/container/releases) and click the tag corresponding to your release version.
>
> Example: [release 0.4.1 tag](https://github.com/apple/container/tree/0.4.1)

This document describes a concrete, minimal plan for exposing `container` to other Swift projects through Swift Package Manager, using a new facade library product named `ContainerKit` and an optional service bootstrap product named `ContainerKitServices`.

The intent is not to redesign the existing architecture. The intent is to provide one stable, easy-to-adopt import surface for common client use cases while preserving the current helper, XPC, and resource model underneath.

## 1. Summary

Today, this repository already ships many SwiftPM library products, including `ContainerAPIClient`, `ContainerResource`, `ContainerPlugin`, and `ContainerXPC`. That is technically sufficient for advanced consumers, but it is not a good default integration story for another app or CLI:

- consumers must know which low-level module boundaries matter
- the CLI-oriented modules are easy to pick by mistake
- the runtime dependency on launchd/XPC services is not obvious from the package entry point

The proposal is to add two library products:

- `ContainerKit`
- `ContainerKitServices`

`ContainerKit` is a thin facade over:

- `ContainerAPIClient`
- `ContainerResource`

It gives external consumers one import for the common operations that already exist in the codebase:

- health checking
- container lifecycle operations
- image lookup and pull
- volume operations
- network operations
- disk usage queries

`ContainerKitServices` is an optional host-management layer for consumers that want this package to start or stop the local `container` services on their behalf.

The two products have different responsibilities:

- `ContainerKit`: client facade for talking to already-installed, already-running services
- `ContainerKitServices`: explicit launchd/bootstrap support for starting, stopping, and checking those services

This keeps the default integration path simple without forcing all embedders to accept host-mutation behavior.

## 2. Goals

- Make this repository consumable as a source dependency through SwiftPM with one obvious product for external apps.
- Keep the implementation thin by delegating to existing public APIs rather than creating a parallel client stack.
- Keep the public API focused on the highest-value operations that most host apps need first.
- Preserve existing runtime behavior, service topology, XPC routes, and resource models.
- Avoid forcing external consumers to import `ContainerCommands`, `ArgumentParser`, or service-management code for routine use.
- Make service installation and startup an explicit opt-in capability rather than implicit behavior hidden in the main client facade.

## 3. Non-Goals

- No `XCFramework` or binary distribution work in this phase.
- No attempt to embed or auto-install the helper executables from inside the library.
- No automatic `launchctl bootstrap` or service registration in `ContainerKit`.
- No new wrapper model hierarchy that duplicates `ContainerResource`.
- No protocol-heavy abstraction layer created only for unit-test mocking.
- No attempt to cover every public API already present in `ContainerAPIClient`.
- No implicit service startup on first API use.
- No interactive prompts inside library APIs.

## 4. Consumer Experience

### 4.1 SwiftPM dependency

Until `ContainerKit` ships in a tagged release, consumers should use a branch or revision dependency during development. After release, the recommended form should be a tagged semantic version.

The intended integration path for another Swift project is:

```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MyApp",
    platforms: [
        .macOS("15")
    ],
    dependencies: [
        .package(url: "https://github.com/apple/container.git", branch: "main")
    ],
    targets: [
        .executableTarget(
            name: "MyApp",
            dependencies: [
                .product(name: "ContainerKit", package: "container")
            ]
        )
    ]
)
```

This keeps the default external integration path explicit:

- source distribution through SwiftPM
- macOS-only
- one product import for common use cases

Consumers that also want explicit service lifecycle control can add:

```swift
.product(name: "ContainerKitServices", package: "container")
```

### 4.2 Basic usage

The expected consumer code should look like this:

```swift
import ContainerKit

let kit = ContainerKit()

let health = try await kit.health()
print("container services reachable at \(health.installRoot.path)")

let containers = try await kit.listContainers()
print("found \(containers.count) containers")
```

For create/run-style flows, consumers should be able to write:

```swift
import ContainerKit

let image = try await ContainerKit().pullImage(reference: "docker.io/library/alpine:latest")

let process = ProcessConfiguration(
    executable: "/bin/sh",
    arguments: ["-lc", "echo hello"],
    environment: []
)

let config = ContainerConfiguration(
    id: "demo",
    image: image.description,
    process: process
)

let kit = ContainerKit()
try await kit.createContainer(configuration: config)
```

This is intentionally close to the current codebase. The facade should reduce import and discovery cost, not hide how the system works.

## 5. Proposed Package Shape

### 5.1 Products and targets

Add two new products and targets in `Package.swift`:

```swift
.library(name: "ContainerKit", targets: ["ContainerKit"])
.library(name: "ContainerKitServices", targets: ["ContainerKitServices"])
```

```swift
.target(
    name: "ContainerKit",
    dependencies: [
        "ContainerAPIClient",
        "ContainerResource",
    ]
)
```

```swift
.target(
    name: "ContainerKitServices",
    dependencies: [
        "ContainerKit",
        "ContainerPlugin",
    ]
)
```

`ContainerKit` should not depend on:

- `ContainerCommands`
- `ArgumentParser`
- `ContainerPlugin`
- `ContainerXPC`

directly.

Those remain implementation details behind `ContainerAPIClient` and existing runtime services.

`ContainerKitServices` may depend on host-management modules because that is its explicit job. It should still avoid `ContainerCommands` and `ArgumentParser`; library startup and shutdown should be implemented directly from reusable lower-level APIs.

### 5.2 File layout

Keep the target small and boring:

- `Sources/ContainerKit/ContainerKit.swift`
- `Sources/ContainerKit/ContainerKit+Aliases.swift`
- `Sources/ContainerKit/ContainerKit+Containers.swift`
- `Sources/ContainerKit/ContainerKit+Images.swift`
- `Sources/ContainerKit/ContainerKit+Volumes.swift`
- `Sources/ContainerKit/ContainerKit+Networks.swift`
- `Sources/ContainerKit/ContainerKit+System.swift`

This keeps each file focused by resource area without introducing extra types or submodules.

For the optional service layer:

- `Sources/ContainerKitServices/ContainerKitServices.swift`
- `Sources/ContainerKitServices/ContainerKitServices+Start.swift`
- `Sources/ContainerKitServices/ContainerKitServices+Stop.swift`
- `Sources/ContainerKitServices/ContainerKitServices+Status.swift`

That keeps all launchd/bootstrap behavior isolated from the main facade.

## 6. Public API Shape

### 6.1 Top-level type

Use one root client type:

```swift
public struct ContainerKit: Sendable {
    public init()
}
```

Internally it owns:

- one stored `ContainerClient` for container lifecycle calls

and delegates to existing static clients for other resources:

- `ClientHealthCheck`
- `ClientImage`
- `ClientVolume`
- `ClientNetwork`
- `ClientDiskUsage`

This matches the current implementation model and avoids new infrastructure.

### 6.2 Public type aliases

To keep the consumer import surface simple without copying existing model definitions, `ContainerKit` should re-expose the most common resource types using top-level `typealias` declarations:

```swift
public typealias ContainerConfiguration = ContainerResource.ContainerConfiguration
public typealias ContainerCreateOptions = ContainerResource.ContainerCreateOptions
public typealias ContainerListFilters = ContainerResource.ContainerListFilters
public typealias ContainerSnapshot = ContainerResource.ContainerSnapshot
public typealias ContainerStopOptions = ContainerResource.ContainerStopOptions
public typealias DiskUsageStats = ContainerAPIClient.DiskUsageStats
public typealias Image = ContainerAPIClient.ClientImage
public typealias NetworkConfiguration = ContainerResource.NetworkConfiguration
public typealias NetworkState = ContainerResource.NetworkState
public typealias ProcessConfiguration = ContainerResource.ProcessConfiguration
public typealias SystemHealth = ContainerAPIClient.SystemHealth
public typealias Volume = ContainerResource.Volume
```

This is intentionally a small list. Add aliases only for the types used directly by the facade or by the first-layer consumer examples.

### 6.3 Initial method set

Keep v1 to the common operations already supported by stable public APIs:

```swift
public extension ContainerKit {
    func health(timeout: Duration? = .seconds(5)) async throws -> SystemHealth
    func diskUsage() async throws -> DiskUsageStats

    func listContainers(filters: ContainerListFilters = .all) async throws -> [ContainerSnapshot]
    func getContainer(id: String) async throws -> ContainerSnapshot
    func createContainer(
        configuration: ContainerConfiguration,
        options: ContainerCreateOptions = .default
    ) async throws
    func stopContainer(
        id: String,
        options: ContainerStopOptions = .default
    ) async throws
    func deleteContainer(id: String, force: Bool = false) async throws
    func containerDiskUsage(id: String) async throws -> UInt64

    func listImages() async throws -> [Image]
    func getImage(reference: String) async throws -> Image
    func pullImage(reference: String) async throws -> Image
    func deleteImage(reference: String, garbageCollect: Bool = false) async throws

    func listVolumes() async throws -> [Volume]
    func createVolume(
        name: String,
        driver: String = "local",
        driverOptions: [String: String] = [:],
        labels: [String: String] = [:]
    ) async throws -> Volume
    func inspectVolume(_ name: String) async throws -> Volume
    func deleteVolume(name: String) async throws
    func volumeDiskUsage(name: String) async throws -> UInt64

    func listNetworks() async throws -> [NetworkState]
    func getNetwork(id: String) async throws -> NetworkState
    func createNetwork(configuration: NetworkConfiguration) async throws -> NetworkState
    func deleteNetwork(id: String) async throws
}
```

Deliberately out of scope for v1:

- custom progress abstractions
- kernel install and system bootstrap helpers
- DNS and packet filter helpers
- process bootstrap and interactive stdio orchestration
- plugin/service registration entry points

Those remain available to advanced consumers through existing lower-level modules if needed.

### 6.4 Optional service bootstrap API

Service lifecycle control should live in a separate top-level type:

```swift
public struct ContainerInstallation: Sendable {
    public let installRoot: URL
    public let apiServerExecutableURL: URL
}

public struct ContainerKitServices: Sendable {
    public init(
        appRoot: URL = ApplicationRoot.defaultURL,
        installation: ContainerInstallation
    )
}
```

Its initial method set should stay small and explicit:

```swift
public extension ContainerKitServices {
    func start(timeout: Duration = .seconds(10)) async throws
    func stop() async throws
    func status() async throws -> ServiceStatus
    func ensureRunning(timeout: Duration = .seconds(10)) async throws
}
```

`ServiceStatus` should be a small value type, for example:

```swift
public struct ServiceStatus: Sendable {
    public let isRegistered: Bool
    public let health: SystemHealth?
}
```

Phase 1 of `ContainerKitServices` should support only:

- writing and registering the API server plist
- verifying health after startup
- best-effort stop and deregistration
- launchd registration and health reporting
- explicit startup of an already-installed runtime

Phase 1 should not attempt:

- default kernel installation
- base image installation
- interactive confirmation
- plugin installation workflows
- helper download, embedding, or auto-install flows

Those tasks are deployment and provisioning concerns and should only be added later if a real embedding use case requires them.

## 7. Internal Architecture

### 7.1 Delegation model

The implementation should be straightforward:

- `health()` -> `ClientHealthCheck.ping`
- `diskUsage()` -> `ClientDiskUsage.get`
- container methods -> stored `ContainerClient`
- image methods -> `ClientImage`
- volume methods -> `ClientVolume`
- network methods -> `ClientNetwork`

No new transport, caching, or synchronization layer should be introduced.

For the optional service layer:

- `start()` should reuse the same core launchd concepts currently used by `container system start`
- `stop()` should reuse the same shutdown approach as `container system stop`
- plist generation should use `LaunchPlist`
- launchd registration and deregistration should use `ServiceManager`
- helper discovery should be explicit through `ContainerInstallation`, not inferred from the embedding app's executable path

This keeps runtime behavior aligned with the CLI without making the library depend on the CLI command implementations.

### 7.2 Error model

Do not add a `ContainerKitError` in v1.

Return existing errors unchanged, primarily:

- `ContainerizationError`
- resource-specific errors already surfaced by current public APIs

This keeps behavior aligned with the existing modules and avoids one more translation layer to maintain.

### 7.3 Runtime contract

`ContainerKit` must document, clearly and early, that:

- it is a client library, not a self-contained runtime
- the `container` services and helpers must already be installed on the host
- the `container` services must already be running

The supported readiness check is:

- `try await ContainerKit().health()`

The facade should not try to auto-start or auto-register services. That behavior belongs to installation and operator workflows, not routine SDK calls.

`ContainerKitServices` is the explicit opt-in layer for consumers who do want programmatic startup and shutdown. Even there, startup must be initiated by a direct API call such as `start()` or `ensureRunning()`, never implicitly during `init` or on first client request.

`ContainerKitServices` must also not guess where helper executables live for external SwiftPM consumers. The embedding app, installer, or deployment tooling is responsible for providing that layout through `ContainerInstallation`.

## 8. Why This Boundary Is Reasonable

This boundary is intentionally narrow:

- `ContainerAPIClient` already defines the real client behavior
- `ContainerResource` already defines the data model
- `ContainerCommands` is CLI-specific and should stay out of the embedding path

`ContainerKit` therefore acts as:

- an import simplifier
- a small API curator
- a documentation anchor for embedders

It is not a second client implementation.

The service layer is also intentionally narrow:

- it owns host lifecycle concerns
- it does not become a replacement for the CLI
- it should expose only explicit, non-interactive lifecycle APIs
- it should not absorb unrelated provisioning features by default

## 9. Rollout Plan

### Phase 1: Introduce the facade target

Changes:

- add `ContainerKit` product and target to `Package.swift`
- add `Sources/ContainerKit/...`
- implement type aliases and the minimal method set above

Acceptance criteria:

- a consumer can depend on `.product(name: "ContainerKit", package: "container")`
- a consumer can `import ContainerKit`
- a consumer can compile calls to `health`, container list/create/delete, image list/pull/delete, volume list/create/delete, and network list/create/delete

### Phase 2: Introduce the optional service layer

Changes:

- add `ContainerKitServices` product and target
- implement explicit `start`, `stop`, `status`, and `ensureRunning`
- add `ContainerInstallation` so helper paths are provided explicitly by the embedding app or installer
- build those APIs directly on reusable launchd/bootstrap code, not on `ArgumentParser` commands

Acceptance criteria:

- a consumer can choose to add `.product(name: "ContainerKitServices", package: "container")`
- service startup remains opt-in and explicit
- `ContainerKit` remains free of host-management dependencies

### Phase 3: Add docs and examples

Changes:

- document the runtime preconditions and the split between client and service layers
- add a short code sample to `docs/how-to.md` or a dedicated example later if needed

Acceptance criteria:

- an external developer can discover the recommended import path without reading source files
- the docs make it explicit when services must already be running and when the optional service layer can start them

### Phase 4: Add minimal verification

Changes:

- add `Tests/ContainerKitTests`
- add `Tests/ContainerKitServicesTests`
- add compile-focused tests for aliases and facade call signatures
- add focused service lifecycle tests around plist generation, registration flow, and health checks
- reuse existing integration coverage for runtime semantics

Acceptance criteria:

- facade API regressions are caught by normal SwiftPM test runs
- no mock-only protocol layer is needed

## 10. Testing Strategy

The facade should be validated with the smallest useful test surface:

- compile and type-check tests for the public aliases
- simple facade tests where behavior is pure delegation and can be exercised without inventing a full fake transport
- service-layer tests focused on launchd input generation and explicit lifecycle calls
- existing integration and end-to-end tests remain the main validation for container runtime behavior

Do not create a parallel in-memory implementation of the container backend just to test the facade. The facade is intentionally too thin to justify that cost.

If packaging regressions become common, add one dedicated SwiftPM consumer smoke test later. That should be a follow-up, not part of the first implementation.

## 11. Migration and Compatibility

This plan is additive:

- existing library products remain unchanged
- existing internal code can continue using `ContainerAPIClient` and `ContainerResource` directly
- external consumers who need more control can still import lower-level modules explicitly
- external consumers who need service startup can opt into `ContainerKitServices` without forcing that dependency onto all consumers

`ContainerKit` becomes the recommended default, not the only supported path.

## 12. Concrete Implementation Notes

When implementing the facade:

- prefer direct delegation methods rather than helper objects or nested namespaces
- keep `ContainerKit` as a value type with minimal stored state
- store only the reusable `ContainerClient`
- avoid wrapping returned models unless a translation is strictly required
- keep advanced options in lower-level modules until a real consumer need proves they belong in the facade

When implementing the optional service layer:

- keep startup and shutdown APIs explicit
- do not call into `ArgumentParser` command implementations from library code
- do not preserve the CLI's interactive prompts
- split provisioning concerns, such as default kernel and base image installation, into a later phase
- keep the main `ContainerKit` target free of launchd/bootstrap concerns

That gives a practical first version with low maintenance cost, clear responsibilities, and a clean upgrade path.
