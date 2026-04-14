//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the container project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//   https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

import ContainerKit
import Foundation
import Testing

@testable import ContainerKitServices

struct ContainerKitServicesLifecycleTests {
    @Test
    func startRegistersServiceAndPingsHealth() async throws {
        let installation = try makeInstallation()
        let createdDirectories = LockedBox<[URL]>([])
        let writtenFiles = LockedBox<[URL]>([])
        let registeredPaths = LockedBox<[String]>([])
        let healthTimeouts = LockedBox<[Duration?]>([])

        let expectedServiceDirectory = installation.appRoot
            .appendingPathComponent("apiserver", isDirectory: true)
        let expectedPlistURL = expectedServiceDirectory.appendingPathComponent("apiserver.plist")

        let services = ContainerKitServices(
            appRoot: installation.appRoot,
            installation: installation.containerInstallation,
            dependencies: makeDependencies(
                createDirectory: { url in
                    createdDirectories.withValue { $0.append(url) }
                },
                writeData: { _, url in
                    writtenFiles.withValue { $0.append(url) }
                },
                registerService: { path in
                    registeredPaths.withValue { $0.append(path) }
                },
                healthCheck: { timeout in
                    healthTimeouts.withValue { $0.append(timeout) }
                    return makeSystemHealth(
                        appRoot: installation.appRoot,
                        installRoot: installation.installRoot
                    )
                }
            )
        )

        try await services.start(timeout: .seconds(7))

        #expect(createdDirectories.snapshot() == [expectedServiceDirectory])
        #expect(writtenFiles.snapshot() == [expectedPlistURL])
        #expect(registeredPaths.snapshot() == [expectedPlistURL.path(percentEncoded: false)])
        #expect(healthTimeouts.snapshot() == [.seconds(7)])
    }

    @Test
    func ensureRunningDoesNotPrepareDefaultKernel() async throws {
        let installation = try makeInstallation()
        let defaultKernelChecks = LockedBox(0)
        let kernelInstallCalls = LockedBox(0)

        let services = ContainerKitServices(
            appRoot: installation.appRoot,
            installation: installation.containerInstallation,
            dependencies: makeDependencies(
                healthCheck: { _ in
                    makeSystemHealth(
                        appRoot: installation.appRoot,
                        installRoot: installation.installRoot
                    )
                },
                defaultKernelExists: {
                    defaultKernelChecks.withValue { $0 += 1 }
                    return false
                },
                installRecommendedKernel: {
                    kernelInstallCalls.withValue { $0 += 1 }
                }
            )
        )

        try await services.ensureRunning(timeout: .seconds(7))

        #expect(defaultKernelChecks.snapshot() == 0)
        #expect(kernelInstallCalls.snapshot() == 0)
    }

    @Test
    func ensureDefaultKernelInstalledInstallsRecommendedKernelWhenMissing() async throws {
        let installation = try makeInstallation()
        let registeredPaths = LockedBox<[String]>([])
        let defaultKernelChecks = LockedBox(0)
        let kernelInstallCalls = LockedBox(0)

        let services = ContainerKitServices(
            appRoot: installation.appRoot,
            installation: installation.containerInstallation,
            dependencies: makeDependencies(
                registerService: { path in
                    registeredPaths.withValue { $0.append(path) }
                },
                isServiceRegistered: { _ in true },
                healthCheck: { _ in
                    makeSystemHealth(
                        appRoot: installation.appRoot,
                        installRoot: installation.installRoot
                    )
                },
                defaultKernelExists: {
                    defaultKernelChecks.withValue { $0 += 1 }
                    return false
                },
                installRecommendedKernel: {
                    kernelInstallCalls.withValue { $0 += 1 }
                }
            )
        )

        try await services.ensureDefaultKernelInstalled(timeout: .seconds(7))

        #expect(registeredPaths.snapshot().isEmpty)
        #expect(defaultKernelChecks.snapshot() == 1)
        #expect(kernelInstallCalls.snapshot() == 1)
    }

    @Test
    func startWrapsHealthFailureWithDiagnostics() async throws {
        let installation = try makeInstallation()
        let services = ContainerKitServices(
            appRoot: installation.appRoot,
            installation: installation.containerInstallation,
            dependencies: makeDependencies(
                isServiceRegistered: { label in
                    #expect(label == ContainerKitServices.apiServerServiceLabel)
                    return true
                },
                healthCheck: { _ in
                    throw TestError(message: "simulated health failure")
                },
                runLaunchctl: { args in
                    if args == ["print", "gui/501/\(ContainerKitServices.apiServerServiceLabel)"] {
                        return (0, "state = failed")
                    }
                    return (1, "")
                }
            )
        )

        do {
            try await services.start(timeout: Duration.seconds(3))
            Issue.record("expected start to fail when the health check fails")
        } catch let error as NSError {
            #expect(error.localizedDescription.contains("failed to get a response from apiserver"))
            #expect(error.localizedDescription.contains("apiserver launchd diagnostics:"))
            #expect(error.localizedDescription.contains("state = failed"))
        }
    }

    @Test
    func stopDeregistersApiserverEvenWhenUnhealthy() async throws {
        let installation = try makeInstallation()
        let deregisteredLabels = LockedBox<[String]>([])
        let stoppedContainers = LockedBox<[String]>([])

        let services = ContainerKitServices(
            appRoot: installation.appRoot,
            installation: installation.containerInstallation,
            dependencies: makeDependencies(
                deregisterService: { label in
                    deregisteredLabels.withValue { $0.append(label) }
                },
                enumerateServices: {
                    [
                        ContainerKitServices.apiServerServiceLabel,
                        "com.apple.container.network",
                        "com.apple.container.sandbox",
                    ]
                },
                isServiceRegistered: { _ in true },
                healthCheck: { _ in
                    throw TestError(message: "apiserver is unresponsive")
                },
                stopContainer: { id, _ in
                    stoppedContainers.withValue { $0.append(id) }
                }
            )
        )

        try await services.stop()

        #expect(
            deregisteredLabels.snapshot() == [
                "gui/501/com.apple.container.apiserver",
                "gui/501/com.apple.container.network",
                "gui/501/com.apple.container.sandbox",
            ]
        )
        #expect(stoppedContainers.snapshot().isEmpty)
    }

    @Test
    func ensureRunningRestartsRegisteredButUnhealthyService() async throws {
        let installation = try makeInstallation()
        let healthResults = LockedBox<[HealthResult]>([
            .failure(TestError(message: "status sees unhealthy service")),
            .success(
                makeSystemHealth(
                    appRoot: installation.appRoot,
                    installRoot: installation.installRoot
                )),
            .success(
                makeSystemHealth(
                    appRoot: installation.appRoot,
                    installRoot: installation.installRoot
                )),
        ])
        let deregisteredLabels = LockedBox<[String]>([])
        let registeredPaths = LockedBox<[String]>([])

        let expectedPlistPath = installation.appRoot
            .appending(path: "apiserver")
            .appending(path: "apiserver.plist")
            .path(percentEncoded: false)

        let services = ContainerKitServices(
            appRoot: installation.appRoot,
            installation: installation.containerInstallation,
            dependencies: makeDependencies(
                registerService: { path in
                    registeredPaths.withValue { $0.append(path) }
                },
                deregisterService: { label in
                    deregisteredLabels.withValue { $0.append(label) }
                },
                enumerateServices: {
                    [ContainerKitServices.apiServerServiceLabel]
                },
                isServiceRegistered: { _ in true },
                healthCheck: { _ in
                    let result = healthResults.withValue { values -> HealthResult in
                        values.removeFirst()
                    }
                    switch result {
                    case .success(let health):
                        return health
                    case .failure(let error):
                        throw error
                    }
                }
            )
        )

        try await services.ensureRunning(timeout: Duration.seconds(3))

        #expect(deregisteredLabels.snapshot() == ["gui/501/com.apple.container.apiserver"])
        #expect(registeredPaths.snapshot() == [expectedPlistPath])
        #expect(healthResults.snapshot().isEmpty)
    }

    @Test
    func ensureDefaultKernelInstalledSkipsInstallWhenDefaultKernelExists() async throws {
        let installation = try makeInstallation()
        let registeredPaths = LockedBox<[String]>([])
        let defaultKernelChecks = LockedBox(0)
        let kernelInstallCalls = LockedBox(0)

        let services = ContainerKitServices(
            appRoot: installation.appRoot,
            installation: installation.containerInstallation,
            dependencies: makeDependencies(
                registerService: { path in
                    registeredPaths.withValue { $0.append(path) }
                },
                isServiceRegistered: { _ in true },
                healthCheck: { _ in
                    makeSystemHealth(
                        appRoot: installation.appRoot,
                        installRoot: installation.installRoot
                    )
                },
                defaultKernelExists: {
                    defaultKernelChecks.withValue { $0 += 1 }
                    return true
                },
                installRecommendedKernel: {
                    kernelInstallCalls.withValue { $0 += 1 }
                }
            )
        )

        try await services.ensureDefaultKernelInstalled(timeout: Duration.seconds(3))

        #expect(registeredPaths.snapshot().isEmpty)
        #expect(defaultKernelChecks.snapshot() == 1)
        #expect(kernelInstallCalls.snapshot() == 0)
    }

    @Test
    func ensureRunningReplacesMismatchedServiceWithoutStoppingItsContainers() async throws {
        let installation = try makeInstallation()
        let healthResults = LockedBox<[HealthResult]>([
            .success(
                makeSystemHealth(
                    appRoot: URL(filePath: "/tmp/other-container-app"),
                    installRoot: URL(filePath: "/tmp/other-container-install")
                )),
            .success(
                makeSystemHealth(
                    appRoot: installation.appRoot,
                    installRoot: installation.installRoot
                )),
            .success(
                makeSystemHealth(
                    appRoot: installation.appRoot,
                    installRoot: installation.installRoot
                )),
        ])
        let deregisteredLabels = LockedBox<[String]>([])
        let registeredPaths = LockedBox<[String]>([])
        let stoppedContainers = LockedBox<[String]>([])

        let expectedPlistPath = installation.appRoot
            .appending(path: "apiserver")
            .appending(path: "apiserver.plist")
            .path(percentEncoded: false)

        let services = ContainerKitServices(
            appRoot: installation.appRoot,
            installation: installation.containerInstallation,
            dependencies: makeDependencies(
                registerService: { path in
                    registeredPaths.withValue { $0.append(path) }
                },
                deregisterService: { label in
                    deregisteredLabels.withValue { $0.append(label) }
                },
                enumerateServices: {
                    [ContainerKitServices.apiServerServiceLabel]
                },
                isServiceRegistered: { _ in true },
                healthCheck: { _ in
                    let result = healthResults.withValue { values -> HealthResult in
                        values.removeFirst()
                    }
                    switch result {
                    case .success(let health):
                        return health
                    case .failure(let error):
                        throw error
                    }
                },
                stopContainer: { id, _ in
                    stoppedContainers.withValue { $0.append(id) }
                }
            )
        )

        try await services.ensureRunning(timeout: Duration.seconds(3))

        #expect(deregisteredLabels.snapshot() == ["gui/501/com.apple.container.apiserver"])
        #expect(registeredPaths.snapshot() == [expectedPlistPath])
        #expect(stoppedContainers.snapshot().isEmpty)
        #expect(healthResults.snapshot().isEmpty)
    }
}

private struct InstallationFixture {
    let appRoot: URL
    let installRoot: URL
    let executableURL: URL

    var containerInstallation: ContainerInstallation {
        ContainerInstallation(
            installRoot: installRoot,
            apiServerExecutableURL: executableURL
        )
    }
}

private enum HealthResult: Sendable {
    case success(SystemHealth)
    case failure(TestError)
}

private struct TestError: Error, LocalizedError, Sendable {
    let message: String

    var errorDescription: String? {
        message
    }
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func withValue<T>(_ body: (inout Value) -> T) -> T {
        lock.lock()
        defer {
            lock.unlock()
        }
        return body(&value)
    }

    func snapshot() -> Value {
        withValue { $0 }
    }
}

private func makeInstallation() throws -> InstallationFixture {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let installRoot = root.appendingPathComponent("install", isDirectory: true)
    let appRoot = root.appendingPathComponent("app", isDirectory: true)
    let executableURL = installRoot.appendingPathComponent("bin/container-apiserver")

    try FileManager.default.createDirectory(
        at: executableURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    FileManager.default.createFile(atPath: executableURL.path, contents: Data())

    return InstallationFixture(
        appRoot: appRoot,
        installRoot: installRoot,
        executableURL: executableURL
    )
}

private func makeDependencies(
    createDirectory: @escaping @Sendable (URL) throws -> Void = { _ in },
    writeData: @escaping @Sendable (Data, URL) throws -> Void = { _, _ in },
    registerService: @escaping @Sendable (String) throws -> Void = { _ in },
    deregisterService: @escaping @Sendable (String) throws -> Void = { _ in },
    enumerateServices: @escaping @Sendable () throws -> [String] = { [] },
    isServiceRegistered: @escaping @Sendable (String) throws -> Bool = { _ in false },
    domainString: @escaping @Sendable () throws -> String = { "gui/501" },
    healthCheck: @escaping @Sendable (Duration?) async throws -> SystemHealth = { _ in
        makeSystemHealth()
    },
    defaultKernelExists: @escaping @Sendable () async throws -> Bool = { true },
    installRecommendedKernel: @escaping @Sendable () async throws -> Void = {},
    listContainers: @escaping @Sendable () async throws -> [ContainerSnapshot] = { [] },
    stopContainer: @escaping @Sendable (String, ContainerStopOptions) async throws -> Void = { _, _ in },
    sleep: @escaping @Sendable (Duration) async throws -> Void = { _ in },
    runLaunchctl: @escaping @Sendable ([String]) throws -> (status: Int32, output: String) = { _ in
        (1, "")
    }
) -> ContainerKitServicesDependencies {
    ContainerKitServicesDependencies(
        createDirectory: createDirectory,
        writeData: writeData,
        registerService: registerService,
        deregisterService: deregisterService,
        enumerateServices: enumerateServices,
        isServiceRegistered: isServiceRegistered,
        domainString: domainString,
        healthCheck: healthCheck,
        defaultKernelExists: defaultKernelExists,
        installRecommendedKernel: installRecommendedKernel,
        listContainers: listContainers,
        stopContainer: stopContainer,
        sleep: sleep,
        runLaunchctl: runLaunchctl
    )
}

private func makeSystemHealth(
    appRoot: URL = URL(filePath: "/tmp/container-app"),
    installRoot: URL = URL(filePath: "/tmp/container-install")
) -> SystemHealth {
    struct Payload: Codable {
        let appRoot: URL
        let installRoot: URL
        let apiServerVersion: String
        let apiServerCommit: String
        let apiServerBuild: String
        let apiServerAppName: String
    }

    let payload = Payload(
        appRoot: appRoot,
        installRoot: installRoot,
        apiServerVersion: "0.0.0",
        apiServerCommit: "deadbeef",
        apiServerBuild: "debug",
        apiServerAppName: "container"
    )
    let data = try! JSONEncoder().encode(payload)
    return try! JSONDecoder().decode(SystemHealth.self, from: data)
}
