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

#if os(macOS)
import ContainerizationError
import ContainerResource
import Darwin
import Foundation
import Logging
import Testing

@testable import RuntimeMacOSSidecarShared
@testable import container_runtime_macos

@Suite(.serialized)
struct MacOSSidecarClientTests {
    @Test
    func restoreStartupUsesRestoreThenResumeWithoutColdBootstrap() async throws {
        let socketPath = try makeTemporarySocketPath()
        let server = try FakeUnixSidecarTestServer(socketPath: socketPath)
        defer { server.stop() }

        server.start { clientFD in
            let capabilities = try readRequest(from: clientFD)
            #expect(capabilities.method == .vmCapabilities)
            try writeResponse(
                .success(
                    requestID: capabilities.requestID,
                    data: try JSONEncoder().encode(
                        MacOSSidecarCapabilities(
                            lifecycleState: .created,
                            machineState: .init(supported: true),
                            methods: []
                        )
                    ),
                    protocolVersion: 2
                ),
                to: clientFD
            )
            let restore = try readRequest(from: clientFD)
            #expect(restore.method == .vmRestoreMachineState)
            #expect(restore.protocolVersion == 2)
            #expect(restore.machineState?.stateID == "state-a")
            try writeResponse(
                .success(
                    requestID: restore.requestID,
                    data: try JSONEncoder().encode(
                        MacOSMachineStateOperationResult(lifecycleState: .paused, stateID: "state-a")
                    ),
                    protocolVersion: 2
                ),
                to: clientFD
            )

            let resume = try readRequest(from: clientFD)
            #expect(resume.method == .vmResume)
            #expect(resume.protocolVersion == 2)
            try writeResponse(
                .success(
                    requestID: resume.requestID,
                    data: try JSONEncoder().encode(
                        MacOSMachineStateOperationResult(lifecycleState: .running, stateID: "state-a")
                    ),
                    protocolVersion: 2
                ),
                to: clientFD
            )
        }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("restore-start-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let service = MacOSSandboxService(root: root, log: Logger(label: "MacOSSidecarClientTests"))
        let client = MacOSSidecarClient(socketPath: socketPath, log: Logger(label: "MacOSSidecarClientTests"))
        defer { client.closeControlConnection() }

        try await service.initializeVirtualMachineViaSidecar(
            client: client,
            config: try makeSidecarStartupConfiguration(restoreStateID: "state-a"),
            presentGUI: false,
            socketConnectRetries: 3
        )
        try server.waitForCompletion()
    }

    @Test
    func failedRestoreDoesNotFallBackToColdBootstrap() async throws {
        let socketPath = try makeTemporarySocketPath()
        let server = try FakeUnixSidecarTestServer(socketPath: socketPath)
        defer { server.stop() }

        server.start { clientFD in
            let capabilities = try readRequest(from: clientFD)
            #expect(capabilities.method == .vmCapabilities)
            try writeResponse(
                .success(
                    requestID: capabilities.requestID,
                    data: try JSONEncoder().encode(
                        MacOSSidecarCapabilities(
                            lifecycleState: .created,
                            machineState: .init(supported: true),
                            methods: []
                        )
                    ),
                    protocolVersion: 2
                ),
                to: clientFD
            )
            let restore = try readRequest(from: clientFD)
            #expect(restore.method == .vmRestoreMachineState)
            try writeResponse(
                .failure(
                    requestID: restore.requestID,
                    code: "machineStateIncompatible",
                    message: "saved state is incompatible",
                    protocolVersion: 2
                ),
                to: clientFD
            )
            usleep(150_000)
            var byte = UInt8.zero
            let count = Darwin.recv(clientFD, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
            #expect(count == -1)
            #expect(errno == EAGAIN || errno == EWOULDBLOCK)
        }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("restore-failure-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let service = MacOSSandboxService(root: root, log: Logger(label: "MacOSSidecarClientTests"))
        let client = MacOSSidecarClient(socketPath: socketPath, log: Logger(label: "MacOSSidecarClientTests"))
        defer { client.closeControlConnection() }

        await #expect(throws: ContainerizationError.self) {
            try await service.initializeVirtualMachineViaSidecar(
                client: client,
                config: makeSidecarStartupConfiguration(restoreStateID: "state-a"),
                presentGUI: false,
                socketConnectRetries: 3
            )
        }
        try server.waitForCompletion()
    }

    @Test
    func explicitRestoreInternalErrorIsNotRetriedAsTransportLoss() async throws {
        let socketPath = try makeTemporarySocketPath()
        let server = try FakeUnixSidecarTestServer(socketPath: socketPath)
        defer { server.stop() }
        let methods = LockedValue<[MacOSSidecarMethod]>([])

        server.start { clientFD in
            let capabilities = try readRequest(from: clientFD)
            methods.withLock { $0.append(capabilities.method) }
            try writeCapabilities(state: .created, requestID: capabilities.requestID, to: clientFD)

            let restore = try readRequest(from: clientFD)
            methods.withLock { $0.append(restore.method) }
            try writeResponse(
                .failure(
                    requestID: restore.requestID,
                    code: "internalError",
                    message: "Virtualization restore failed",
                    protocolVersion: 2
                ),
                to: clientFD
            )
            usleep(100_000)
            var byte = UInt8.zero
            let count = Darwin.recv(clientFD, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
            #expect(count == -1)
            #expect(errno == EAGAIN || errno == EWOULDBLOCK)
        }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("restore-internal-error-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let service = MacOSSandboxService(root: root, log: Logger(label: "MacOSSidecarClientTests"))
        let client = MacOSSidecarClient(
            socketPath: socketPath,
            log: Logger(label: "MacOSSidecarClientTests"),
            requestTimeoutSeconds: 0.05
        )
        defer { client.closeControlConnection() }

        do {
            try await service.initializeVirtualMachineViaSidecar(
                client: client,
                config: makeSidecarStartupConfiguration(restoreStateID: "state-a"),
                presentGUI: false,
                socketConnectRetries: 1,
                operationTimeoutSeconds: 0.05,
                reconciliationTimeoutSeconds: 0.1,
                reconciliationPollMicroseconds: 10_000
            )
            Issue.record("explicit sidecar restore failure was treated as an unknown transport outcome")
        } catch let error as ContainerizationError {
            #expect(error.code == .internalError)
            #expect(error.message.contains("Virtualization restore failed"))
        }

        try server.waitForCompletion()
        #expect(methods.withLock { $0 } == [.vmCapabilities, .vmRestoreMachineState])
    }

    @Test
    func persistenceLeaseSerializesRecreatedSandboxes() async throws {
        let root = URL(fileURLWithPath: "/tmp/ms-lease-\(UUID().uuidString)", isDirectory: true)
        let storage = root.appendingPathComponent("state", isDirectory: true)
        let control = root.appendingPathComponent("control", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: control, withIntermediateDirectories: true)
        let config = try makeSidecarStartupConfiguration(
            restoreStateID: nil,
            storageDirectory: storage.path,
            controlSocketPath: control.appendingPathComponent("pod-a.sock").path
        )
        let first = MacOSSandboxService(
            root: root.appendingPathComponent("sandbox-a"),
            log: Logger(label: "MacOSSidecarClientTests")
        )
        let recreated = MacOSSandboxService(
            root: root.appendingPathComponent("sandbox-b"),
            log: Logger(label: "MacOSSidecarClientTests")
        )

        try await first.validateMachineStateRuntimeConfiguration(config)
        try await first.acquireMachineStateLeaseIfNeeded(config)
        await #expect(throws: ContainerizationError.self) {
            try await recreated.acquireMachineStateLeaseIfNeeded(config)
        }
        await first.releaseMachineStateLeaseIfPresent()
        try await recreated.acquireMachineStateLeaseIfNeeded(config)
        await recreated.releaseMachineStateLeaseIfPresent()
    }

    @Test
    func pendingRequestEOFReconnectsEventsAndPreservesPersistentRuntime() async throws {
        let root = URL(fileURLWithPath: "/tmp/ms-control-recovery-\(UUID().uuidString)", isDirectory: true)
        let sandboxRoot = root.appendingPathComponent("sandbox", isDirectory: true)
        let storage = root.appendingPathComponent("state", isDirectory: true)
        let control = root.appendingPathComponent("control", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: sandboxRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: control, withIntermediateDirectories: true)
        let socketPath = control.appendingPathComponent("sidecar.sock").path
        let eventAcknowledged = LockedValue(false)
        let releaseRecoveredConnection = DispatchSemaphore(value: 0)
        let server = try FakeConcurrentUnixSidecarTestServer(socketPath: socketPath)
        defer { server.stop() }
        server.start(connectionCount: 2) { index, clientFD in
            try acknowledgeEventSubscription(from: clientFD)
            if index == 0 {
                let signal = try readRequest(from: clientFD)
                #expect(signal.method == .processSignal)
                _ = Darwin.shutdown(clientFD, SHUT_RDWR)
                return
            }

            let capabilities = try readRequest(from: clientFD)
            #expect(capabilities.method == .vmCapabilities)
            try writeCapabilities(state: .running, requestID: capabilities.requestID, to: clientFD)
            try writeEvent(
                .init(
                    event: .processStdout,
                    processID: "durable-session",
                    data: Data("after-reconnect\n".utf8),
                    sequence: 1,
                    subscriptionID: "test-subscription"
                ),
                to: clientFD
            )
            let acknowledgement = try readRequest(from: clientFD)
            #expect(acknowledgement.method == .eventsAcknowledge)
            #expect(acknowledgement.eventAcknowledgement?.processID == "durable-session")
            #expect(acknowledgement.eventAcknowledgement?.sequence == 1)
            try writeResponse(.success(requestID: acknowledgement.requestID), to: clientFD)
            eventAcknowledged.withLock { $0 = true }
            _ = releaseRecoveredConnection.wait(timeout: .now() + 2)
        }
        let config = try makeSidecarStartupConfiguration(
            restoreStateID: nil,
            storageDirectory: storage.path,
            controlSocketPath: socketPath
        )
        let service = MacOSSandboxService(
            root: sandboxRoot,
            log: Logger(label: "MacOSSidecarClientTests")
        )

        try await service.testingPrepareSandbox(config, state: "running")
        try await service.acquireMachineStateLeaseIfNeeded(config)
        await service.testingAddSession(
            id: "durable-session",
            config: config.initProcess,
            started: true
        )
        await service.testingInstallSidecarClient(socketPath: socketPath)

        await #expect(throws: ContainerizationError.self) {
            try await service.testingSignalWorkload("durable-session", signal: SIGUSR1)
        }
        for _ in 0..<200 where !eventAcknowledged.withLock({ $0 }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(eventAcknowledged.withLock { $0 })

        #expect(await service.testingHasSidecarHandle())
        #expect(await service.testingMachineStateLeaseIsHeld())
        let session = try await service.testingInspectWorkload("durable-session")
        #expect(session.status == .running)
        #expect(session.exitCode == nil)
        let stdout = try String(contentsOfFile: try #require(session.stdoutLogPath), encoding: .utf8)
        #expect(stdout == "after-reconnect\n")
        await service.testingRemoveSidecarClient()
        await service.releaseMachineStateLeaseIfPresent()
        releaseRecoveredConnection.signal()
        try server.waitForCompletion()
    }

    @Test
    func persistenceIDKeepsSidecarIdentityStableAcrossSandboxIDs() async throws {
        var firstConfig = try makeSidecarStartupConfiguration(restoreStateID: nil)
        firstConfig.id = "sandbox-a"
        var recreatedConfig = firstConfig
        recreatedConfig.id = "sandbox-b"
        let service = MacOSSandboxService(
            root: FileManager.default.temporaryDirectory.appendingPathComponent("stable-sidecar-identity"),
            log: Logger(label: "MacOSSidecarClientTests")
        )
        let firstSocket = await service.sidecarSocketPath(config: firstConfig)
        let recreatedSocket = await service.sidecarSocketPath(config: recreatedConfig)
        let firstLabel = await service.sidecarLaunchLabel(config: firstConfig)
        let recreatedLabel = await service.sidecarLaunchLabel(config: recreatedConfig)

        #expect(firstSocket == recreatedSocket)
        #expect(firstLabel == recreatedLabel)
    }

    @Test
    func machineStateMethodsUseVersionTwoAndDecodeStructuredResults() throws {
        let socketPath = try makeTemporarySocketPath()
        let server = try FakeUnixSidecarTestServer(socketPath: socketPath)
        defer { server.stop() }

        server.start { clientFD in
            let capabilitiesRequest = try readRequest(from: clientFD)
            #expect(capabilitiesRequest.method == .vmCapabilities)
            #expect(capabilitiesRequest.protocolVersion == 2)
            let capabilities = MacOSSidecarCapabilities(
                lifecycleState: .running,
                machineState: .init(supported: true),
                methods: [MacOSSidecarMethod.vmPause.rawValue]
            )
            try writeResponse(
                .success(
                    requestID: capabilitiesRequest.requestID,
                    data: try JSONEncoder().encode(capabilities),
                    protocolVersion: 2
                ),
                to: clientFD
            )

            let pauseRequest = try readRequest(from: clientFD)
            #expect(pauseRequest.method == .vmPause)
            #expect(pauseRequest.protocolVersion == 2)
            #expect(pauseRequest.machineState?.timeoutSeconds == 12)
            try writeResponse(
                .success(
                    requestID: pauseRequest.requestID,
                    data: try JSONEncoder().encode(MacOSMachineStateOperationResult(lifecycleState: .paused)),
                    protocolVersion: 2
                ),
                to: clientFD
            )

            let saveRequest = try readRequest(from: clientFD)
            #expect(saveRequest.method == .vmSaveMachineState)
            #expect(saveRequest.machineState?.stateID == "state-1")
            try writeResponse(
                .success(
                    requestID: saveRequest.requestID,
                    data: try JSONEncoder().encode(
                        MacOSMachineStateOperationResult(lifecycleState: .paused, stateID: "state-1")
                    ),
                    protocolVersion: 2
                ),
                to: clientFD
            )

            let restoreRequest = try readRequest(from: clientFD)
            #expect(restoreRequest.method == .vmRestoreMachineState)
            #expect(restoreRequest.protocolVersion == 2)
            try writeResponse(
                .failure(
                    requestID: restoreRequest.requestID,
                    code: "machineStateNotFound",
                    message: "machine state missing does not exist",
                    protocolVersion: 2
                ),
                to: clientFD
            )

            let deleteRequest = try readRequest(from: clientFD)
            #expect(deleteRequest.method == .vmDeleteMachineState)
            #expect(deleteRequest.protocolVersion == 2)
            #expect(deleteRequest.machineState?.stateID == "state-1")
            try writeResponse(
                .success(
                    requestID: deleteRequest.requestID,
                    data: try JSONEncoder().encode(
                        MacOSMachineStateDeleteResult(stateID: "state-1", deleted: true)
                    ),
                    protocolVersion: 2
                ),
                to: clientFD
            )
        }

        let client = MacOSSidecarClient(socketPath: socketPath, log: Logger(label: "MacOSSidecarClientTests"))
        defer { client.closeControlConnection() }
        #expect(try client.capabilities().machineState.supported)
        #expect(try client.pauseVM(timeoutSeconds: 12).lifecycleState == .paused)
        #expect(try client.saveMachineState(stateID: "state-1", timeoutSeconds: 12).stateID == "state-1")
        do {
            _ = try client.restoreMachineState(stateID: "missing", timeoutSeconds: 12)
            Issue.record("expected missing machine state to be reported")
        } catch let error as ContainerizationError {
            #expect(error.code == .notFound)
            #expect(error.message.contains("machineStateNotFound"))
        }
        #expect(try client.deleteMachineState(stateID: "state-1") == .init(stateID: "state-1", deleted: true))
        try server.waitForCompletion()
    }

    @Test
    func restoreAndResumeResponseLossReconcilesOnNewConnections() async throws {
        let socketPath = try makeTemporarySocketPath()
        let server = try FakeConcurrentUnixSidecarTestServer(socketPath: socketPath)
        defer { server.stop() }
        let methods = LockedValue<[MacOSSidecarMethod]>([])

        server.start(connectionCount: 3) { index, clientFD in
            func nextRequest() throws -> MacOSSidecarRequest {
                let request = try readRequest(from: clientFD)
                methods.withLock { $0.append(request.method) }
                return request
            }

            switch index {
            case 0:
                let capabilities = try nextRequest()
                #expect(capabilities.method == .vmCapabilities)
                try writeCapabilities(state: .created, requestID: capabilities.requestID, to: clientFD)

                let restore = try nextRequest()
                #expect(restore.method == .vmRestoreMachineState)
                #expect(restore.machineState?.stateID == "state-reconcile")
                usleep(150_000)
            case 1:
                let restoring = try nextRequest()
                #expect(restoring.method == .vmCapabilities)
                try writeCapabilities(state: .restoring, requestID: restoring.requestID, to: clientFD)

                let paused = try nextRequest()
                #expect(paused.method == .vmCapabilities)
                try writeCapabilities(state: .paused, requestID: paused.requestID, to: clientFD)

                let restoreReadback = try nextRequest()
                #expect(restoreReadback.method == .vmRestoreMachineState)
                try writeResponse(
                    .success(
                        requestID: restoreReadback.requestID,
                        data: try JSONEncoder().encode(
                            MacOSMachineStateOperationResult(lifecycleState: .paused, stateID: "state-reconcile")
                        ),
                        protocolVersion: 2
                    ),
                    to: clientFD
                )

                let resume = try nextRequest()
                #expect(resume.method == .vmResume)
                usleep(150_000)
            default:
                let resuming = try nextRequest()
                #expect(resuming.method == .vmCapabilities)
                try writeCapabilities(state: .resuming, requestID: resuming.requestID, to: clientFD)

                let running = try nextRequest()
                #expect(running.method == .vmCapabilities)
                try writeCapabilities(state: .running, requestID: running.requestID, to: clientFD)

                let resumeReadback = try nextRequest()
                #expect(resumeReadback.method == .vmResume)
                try writeResponse(
                    .success(
                        requestID: resumeReadback.requestID,
                        data: try JSONEncoder().encode(
                            MacOSMachineStateOperationResult(lifecycleState: .running, stateID: "state-reconcile")
                        ),
                        protocolVersion: 2
                    ),
                    to: clientFD
                )
            }
        }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("restore-reconcile-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let service = MacOSSandboxService(root: root, log: Logger(label: "MacOSSidecarClientTests"))
        let client = MacOSSidecarClient(
            socketPath: socketPath,
            log: Logger(label: "MacOSSidecarClientTests"),
            requestTimeoutSeconds: 0.05
        )
        defer { client.closeControlConnection() }

        try await service.initializeVirtualMachineViaSidecar(
            client: client,
            config: makeSidecarStartupConfiguration(restoreStateID: "state-reconcile"),
            presentGUI: false,
            socketConnectRetries: 3,
            operationTimeoutSeconds: 0.05,
            reconciliationTimeoutSeconds: 2,
            reconciliationPollMicroseconds: 10_000
        )
        try server.waitForCompletion(timeout: 3)
        #expect(!methods.withLock { $0 }.contains(.vmBootstrapStart))
        #expect(!methods.withLock { $0 }.contains(.vmStop))
    }

    @Test
    func bootstrapAndProcessEventsFlowOverPersistentControlConnection() throws {
        let socketPath = try makeTemporarySocketPath()
        let server = try FakeUnixSidecarTestServer(socketPath: socketPath)
        defer { server.stop() }

        let events = LockedValue<[MacOSSidecarEvent]>([])
        let eventSemaphore = DispatchSemaphore(value: 0)

        server.start { clientFD in
            try acknowledgeEventSubscription(from: clientFD)
            let bootstrap = try readRequest(from: clientFD)
            #expect(bootstrap.method == .vmBootstrapStart)
            try writeResponse(.success(requestID: bootstrap.requestID), to: clientFD)

            let start = try readRequest(from: clientFD)
            #expect(start.method == .processStart)
            #expect(start.processID == "proc-1")
            #expect(start.port == 27000)
            #expect(start.exec?.executable == "/bin/echo")
            #expect(start.exec?.user == "nobody")
            #expect(start.exec?.supplementalGroups == [20])
            try writeResponse(.success(requestID: start.requestID), to: clientFD)

            try writeEvent(.init(event: .processStdout, processID: "proc-1", data: Data("hello\n".utf8)), to: clientFD)
            try writeEvent(.init(event: .processExit, processID: "proc-1", exitCode: 0), to: clientFD)
        }

        let client = MacOSSidecarClient(socketPath: socketPath, log: Logger(label: "MacOSSidecarClientTests"))
        defer { client.closeControlConnection() }
        client.setEventHandler { event in
            events.withLock { $0.append(event) }
            eventSemaphore.signal()
        }

        let descriptors = try client._testControlConnectionDescriptors()
        #expect(descriptors.owner >= 0)
        #expect(descriptors.reader >= 0)
        #expect(descriptors.owner != descriptors.reader)

        try client.bootstrapStart(socketConnectRetries: 3)
        try client.processStart(
            port: 27000,
            processID: "proc-1",
            request: .init(
                executable: "/bin/echo",
                arguments: ["hello"],
                user: "nobody",
                supplementalGroups: [20]
            )
        )

        #expect(eventSemaphore.wait(timeout: .now() + 2) == .success)
        #expect(eventSemaphore.wait(timeout: .now() + 2) == .success)

        let received = events.withLock { $0 }
        #expect(received.contains(where: { $0.event == .processStdout && $0.data == Data("hello\n".utf8) }))
        #expect(received.contains(where: { $0.event == .processExit && $0.exitCode == 0 }))

        try server.waitForCompletion()
    }

    @Test
    func reconnectResubscribesBeforeSendingControlRequests() throws {
        let socketPath = try makeTemporarySocketPath()
        let firstServer = try FakeUnixSidecarTestServer(socketPath: socketPath)
        defer { firstServer.stop() }

        firstServer.start { clientFD in
            try acknowledgeEventSubscription(from: clientFD)
            let bootstrap = try readRequest(from: clientFD)
            #expect(bootstrap.method == .vmBootstrapStart)
            try writeResponse(.success(requestID: bootstrap.requestID), to: clientFD)
            _ = Darwin.shutdown(clientFD, SHUT_RDWR)
        }

        let eventSemaphore = DispatchSemaphore(value: 0)
        let disconnectSemaphore = DispatchSemaphore(value: 0)
        let receivedEvent = LockedValue<MacOSSidecarEvent?>(nil)
        let client = MacOSSidecarClient(socketPath: socketPath, log: Logger(label: "MacOSSidecarClientTests"))
        defer { client.closeControlConnection() }
        client.setEventHandler { event in
            receivedEvent.withLock { $0 = event }
            eventSemaphore.signal()
        }
        client.setDisconnectHandler { _ in
            disconnectSemaphore.signal()
        }

        try client.bootstrapStart(socketConnectRetries: 3)
        #expect(disconnectSemaphore.wait(timeout: .now() + 2) == .success)
        try firstServer.waitForCompletion()
        firstServer.stop()

        let secondServer = try FakeUnixSidecarTestServer(socketPath: socketPath)
        defer { secondServer.stop() }
        secondServer.start { clientFD in
            try acknowledgeEventSubscription(from: clientFD)
            let start = try readRequest(from: clientFD)
            #expect(start.method == .processStart)
            #expect(start.processID == "proc-reconnected")
            try writeResponse(.success(requestID: start.requestID), to: clientFD)
            try writeEvent(.init(event: .processExit, processID: "proc-reconnected", exitCode: 0), to: clientFD)
        }

        try client.processStart(
            port: 27000,
            processID: "proc-reconnected",
            request: .init(executable: "/bin/true")
        )
        #expect(eventSemaphore.wait(timeout: .now() + 2) == .success)
        #expect(receivedEvent.withLock { $0?.processID == "proc-reconnected" })
        #expect(receivedEvent.withLock { $0?.exitCode == 0 })
        try secondServer.waitForCompletion()
    }

    @Test
    func eventSubscriptionFallsBackToLegacySidecarWithoutLosingEvents() throws {
        let socketPath = try makeTemporarySocketPath()
        let server = try FakeUnixSidecarTestServer(socketPath: socketPath)
        defer { server.stop() }

        let events = LockedValue<[MacOSSidecarEvent]>([])
        let eventSemaphore = DispatchSemaphore(value: 0)
        server.start { clientFD in
            let subscription = try readRequest(from: clientFD)
            #expect(subscription.method == .eventsSubscribe)
            #expect(subscription.protocolVersion == MacOSSidecarProtocolVersion.durableEventAcknowledgement)
            try writeResponse(
                .failure(
                    requestID: subscription.requestID,
                    code: "unknownMethod",
                    message: "unknown sidecar control method events.subscribe"
                ),
                to: clientFD
            )

            let versionTwoSubscription = try readRequest(from: clientFD)
            #expect(versionTwoSubscription.method == .eventsSubscribe)
            #expect(versionTwoSubscription.protocolVersion == MacOSSidecarProtocolVersion.machineState)
            try writeResponse(
                .failure(
                    requestID: versionTwoSubscription.requestID,
                    code: "unknownMethod",
                    message: "unknown sidecar control method events.subscribe"
                ),
                to: clientFD
            )

            let bootstrap = try readRequest(from: clientFD)
            #expect(bootstrap.method == .vmBootstrapStart)
            try writeResponse(.success(requestID: bootstrap.requestID), to: clientFD)
            try writeEvent(.init(event: .processExit, processID: "legacy-process", exitCode: 0), to: clientFD)
        }

        let client = MacOSSidecarClient(socketPath: socketPath, log: Logger(label: "MacOSSidecarClientTests"))
        defer { client.closeControlConnection() }
        client.setEventHandler { event in
            events.withLock { $0.append(event) }
            eventSemaphore.signal()
        }

        try client.bootstrapStart(socketConnectRetries: 3)
        #expect(eventSemaphore.wait(timeout: .now() + 2) == .success)
        #expect(events.withLock { $0 }.contains(where: { $0.processID == "legacy-process" && $0.exitCode == 0 }))
        try server.waitForCompletion()
    }

    @Test
    func connectVsockReceivesTransferredFileDescriptor() throws {
        let socketPath = try makeTemporarySocketPath()
        let server = try FakeUnixSidecarTestServer(socketPath: socketPath)
        defer { server.stop() }

        server.start { clientFD in
            let request = try readRequest(from: clientFD)
            #expect(request.method == .vmConnectVsock)
            #expect(request.port == 27000)

            var pipeFDs = [Int32](repeating: -1, count: 2)
            #expect(Darwin.pipe(&pipeFDs) == 0)
            let readFD = pipeFDs[0]
            let writeFD = pipeFDs[1]
            defer {
                closeIfValid(readFD)
                closeIfValid(writeFD)
            }

            try MacOSSidecarSocketIO.sendFileDescriptorMarker(socketFD: clientFD, descriptorFD: readFD)
            try writeResponse(.success(requestID: request.requestID, fdAttached: true), to: clientFD)

            try writeAll(Data("vsock-fd".utf8), fd: writeFD)
        }

        let client = MacOSSidecarClient(socketPath: socketPath, log: Logger(label: "MacOSSidecarClientTests"))
        let fd = try client.connectVsock(port: 27000)
        defer { closeIfValid(fd) }

        let data = try MacOSSidecarSocketIO.readExact(fd: fd, count: 8)
        #expect(String(data: data, encoding: .utf8) == "vsock-fd")

        try server.waitForCompletion()
    }

    @Test
    func matchesOutOfOrderResponsesByRequestID() throws {
        let socketPath = try makeTemporarySocketPath()
        let server = try FakeUnixSidecarTestServer(socketPath: socketPath)
        defer { server.stop() }

        server.start { clientFD in
            let bootstrap = try readRequest(from: clientFD)
            #expect(bootstrap.method == .vmBootstrapStart)
            try writeResponse(.success(requestID: bootstrap.requestID), to: clientFD)

            let req1 = try readRequest(from: clientFD)
            let req2 = try readRequest(from: clientFD)
            #expect(Set([req1.method, req2.method]) == Set([.processClose, .processSignal]))

            // Intentionally reverse response order to validate requestID correlation.
            try writeResponse(.success(requestID: req2.requestID), to: clientFD)
            try writeResponse(.success(requestID: req1.requestID), to: clientFD)
        }

        let client = MacOSSidecarClient(socketPath: socketPath, log: Logger(label: "MacOSSidecarClientTests"))
        defer { client.closeControlConnection() }
        try client.bootstrapStart(socketConnectRetries: 3)

        let result1 = LockedValue<Error?>(nil)
        let result2 = LockedValue<Error?>(nil)
        let done1 = DispatchSemaphore(value: 0)
        let done2 = DispatchSemaphore(value: 0)

        Thread.detachNewThread {
            defer { done1.signal() }
            do {
                try client.processClose(processID: "proc-close")
            } catch {
                result1.withLock { $0 = error }
            }
        }
        Thread.detachNewThread {
            defer { done2.signal() }
            do {
                try client.processSignal(processID: "proc-signal", signal: 15)
            } catch {
                result2.withLock { $0 = error }
            }
        }

        #expect(done1.wait(timeout: .now() + 2) == .success)
        #expect(done2.wait(timeout: .now() + 2) == .success)
        #expect(result1.withLock { $0 == nil })
        #expect(result2.withLock { $0 == nil })

        try server.waitForCompletion()
    }

    @Test
    func durableProcessDeleteCarriesStableExecutionIDAndPort() throws {
        let socketPath = try makeTemporarySocketPath()
        let server = try FakeUnixSidecarTestServer(socketPath: socketPath)
        defer { server.stop() }

        server.start { clientFD in
            let bootstrap = try readRequest(from: clientFD)
            #expect(bootstrap.method == .vmBootstrapStart)
            try writeResponse(.success(requestID: bootstrap.requestID), to: clientFD)

            let delete = try readRequest(from: clientFD)
            #expect(delete.method == .processDelete)
            #expect(delete.protocolVersion == MacOSSidecarProtocolVersion.durableProcessIdentity)
            #expect(delete.port == 27_001)
            #expect(delete.processID == "sandbox:container:builder")
            #expect(delete.durableProcessDeleteIdentity?.executionID == "sandbox:container:builder")
            #expect(
                delete.durableProcessDeleteIdentity?.trustedLaunchFingerprint
                    == "sha256:\(String(repeating: "a", count: 64))"
            )
            #expect(
                delete.durableProcessDeleteIdentity?.incarnation
                    == "sha256:\(String(repeating: "b", count: 64))"
            )
            #expect(delete.durableProcessDeleteIdentity?.storageGeneration == 9)
            try writeResponse(.success(requestID: delete.requestID), to: clientFD)
        }

        let client = MacOSSidecarClient(socketPath: socketPath, log: Logger(label: "MacOSSidecarClientTests"))
        defer { client.closeControlConnection() }
        try client.bootstrapStart(socketConnectRetries: 3)
        try client.processDelete(
            port: 27_001,
            identity: .init(
                executionID: "sandbox:container:builder",
                trustedLaunchFingerprint: "sha256:\(String(repeating: "a", count: 64))",
                incarnation: "sha256:\(String(repeating: "b", count: 64))",
                storageGeneration: 9
            )
        )

        try server.waitForCompletion()
    }

    @Test
    func durableProcessDeleteRetriesAfterResponseLoss() throws {
        let socketPath = try makeTemporarySocketPath()
        let server = try FakeConcurrentUnixSidecarTestServer(socketPath: socketPath)
        defer { server.stop() }
        let received = LockedValue<[MacOSSidecarDurableProcessDeleteIdentity]>([])

        server.start(connectionCount: 2) { index, clientFD in
            let request = try readRequest(from: clientFD)
            #expect(request.method == .processDelete)
            received.withLock {
                if let identity = request.durableProcessDeleteIdentity {
                    $0.append(identity)
                }
            }
            if index == 0 {
                // Simulate a sidecar restart after the guest committed delete
                // but before the control response was written.
                return
            }
            try writeResponse(.success(requestID: request.requestID), to: clientFD)
        }

        let identity = MacOSSidecarDurableProcessDeleteIdentity(
            executionID: "sandbox:container:lost-delete-ack",
            trustedLaunchFingerprint: "sha256:\(String(repeating: "b", count: 64))",
            incarnation: "sha256:\(String(repeating: "c", count: 64))",
            storageGeneration: 11
        )
        let client = MacOSSidecarClient(
            socketPath: socketPath,
            log: Logger(label: "MacOSSidecarClientTests"),
            requestTimeoutSeconds: 1
        )
        defer { client.closeControlConnection() }
        try client.processDelete(port: 27_001, identity: identity)

        try server.waitForCompletion()
        #expect(received.withLock { $0 } == [identity, identity])
    }

    @Test
    func durableProcessStartTimeoutReconnectsAndInspectsBeforeRetryingStart() throws {
        let socketPath = try makeTemporarySocketPath()
        let server = try FakeConcurrentUnixSidecarTestServer(socketPath: socketPath)
        defer { server.stop() }
        let receivedMethods = LockedValue<[MacOSSidecarMethod]>([])
        let releaseInspectionConnection = DispatchSemaphore(value: 0)

        server.start(connectionCount: 2) { index, clientFD in
            let request = try readRequest(from: clientFD)
            receivedMethods.withLock { $0.append(request.method) }
            if index == 0 {
                #expect(request.method == .processStart)
                #expect(request.processID == "durable-process")
                usleep(300_000)
                return
            }

            #expect(request.method == .processInspect)
            #expect(request.processID == "durable-process")
            #expect(request.port == 27_001)
            #expect(request.exec?.durableExecutionID == "sandbox:container:builder")
            let status = MacOSGuestProcessStatusPayload(
                executionID: "sandbox:container:builder",
                disposition: .inspected,
                state: .running,
                launchFingerprint: "guest-launch-fingerprint",
                processIdentifier: 909,
                exitCode: nil,
                cursor: 8,
                oldestAvailableSequence: 1,
                replayTruncated: false
            )
            try writeResponse(
                .success(requestID: request.requestID, data: try JSONEncoder().encode(status)),
                to: clientFD
            )
            _ = releaseInspectionConnection.wait(timeout: .now() + 2)
        }

        let disconnectCount = LockedValue(0)
        let client = MacOSSidecarClient(
            socketPath: socketPath,
            log: Logger(label: "MacOSSidecarClientTests"),
            requestTimeoutSeconds: 0.1
        )
        defer { client.closeControlConnection() }
        client.setDisconnectHandler { _ in
            disconnectCount.withLock { $0 += 1 }
        }

        try client.processStart(
            port: 27_001,
            processID: "durable-process",
            request: .init(
                executable: "/bin/sleep",
                arguments: ["60"],
                durableExecutionID: "sandbox:container:builder",
                replayCursor: 7
            )
        )

        #expect(receivedMethods.withLock { $0 } == [.processStart, .processInspect])
        #expect(disconnectCount.withLock { $0 } == 0)
        releaseInspectionConnection.signal()
        client.closeControlConnection()
        try server.waitForCompletion()
    }

    @Test
    func durableProcessStartTimeoutRejectsExitedInspection() throws {
        let socketPath = try makeTemporarySocketPath()
        let server = try FakeConcurrentUnixSidecarTestServer(socketPath: socketPath)
        defer { server.stop() }
        let receivedMethods = LockedValue<[MacOSSidecarMethod]>([])

        server.start(connectionCount: 2) { index, clientFD in
            let request = try readRequest(from: clientFD)
            receivedMethods.withLock { $0.append(request.method) }
            if index == 0 {
                #expect(request.method == .processStart)
                usleep(300_000)
                return
            }

            #expect(request.method == .processInspect)
            let status = MacOSGuestProcessStatusPayload(
                executionID: "sandbox:container:exited",
                disposition: .inspected,
                state: .exited,
                launchFingerprint: "guest-launch-fingerprint",
                processIdentifier: 910,
                exitCode: 0,
                cursor: 9,
                oldestAvailableSequence: 1,
                replayTruncated: false
            )
            try writeResponse(
                .success(requestID: request.requestID, data: try JSONEncoder().encode(status)),
                to: clientFD
            )
        }

        let client = MacOSSidecarClient(
            socketPath: socketPath,
            log: Logger(label: "MacOSSidecarClientTests"),
            requestTimeoutSeconds: 0.1
        )
        defer { client.closeControlConnection() }

        do {
            try client.processStart(
                port: 27_001,
                processID: "durable-exited-process",
                request: .init(
                    executable: "/bin/true",
                    durableExecutionID: "sandbox:container:exited",
                    replayCursor: 8
                )
            )
            Issue.record("exited durable process inspection was accepted as a successful start")
        } catch let error as ContainerizationError {
            #expect(error.code == .invalidState)
        }

        try server.waitForCompletion()
        #expect(receivedMethods.withLock { $0 } == [.processStart, .processInspect])
    }

    @Test
    func filesystemRequestsUseDedicatedPayloads() throws {
        let socketPath = try makeTemporarySocketPath()
        let server = try FakeUnixSidecarTestServer(socketPath: socketPath)
        defer { server.stop() }

        server.start { clientFD in
            let bootstrap = try readRequest(from: clientFD)
            #expect(bootstrap.method == .vmBootstrapStart)
            try writeResponse(.success(requestID: bootstrap.requestID), to: clientFD)

            let begin = try readRequest(from: clientFD)
            #expect(begin.method == .fsBegin)
            #expect(begin.port == 27000)
            #expect(begin.fsBegin?.txID == "tx-1")
            #expect(begin.fsBegin?.path == "/tmp/build-context.txt")
            #expect(begin.fsBegin?.digest == "sha256:abc")
            #expect(begin.fsBegin?.inlineData == Data("abc".utf8))
            try writeResponse(.success(requestID: begin.requestID), to: clientFD)

            let chunk = try readRequest(from: clientFD)
            #expect(chunk.method == .fsChunk)
            #expect(chunk.fsChunk?.txID == "tx-1")
            #expect(chunk.fsChunk?.offset == 3)
            #expect(chunk.fsChunk?.data == Data("def".utf8))
            try writeResponse(.success(requestID: chunk.requestID), to: clientFD)

            let end = try readRequest(from: clientFD)
            #expect(end.method == .fsEnd)
            #expect(end.fsEnd?.txID == "tx-1")
            #expect(end.fsEnd?.action == .commit)
            #expect(end.fsEnd?.digest == "sha256:test")
            try writeResponse(.success(requestID: end.requestID), to: clientFD)
        }

        let client = MacOSSidecarClient(socketPath: socketPath, log: Logger(label: "MacOSSidecarClientTests"))
        defer { client.closeControlConnection() }

        try client.bootstrapStart(socketConnectRetries: 3)
        try client.fsBegin(
            port: 27000,
            request: .init(
                txID: "tx-1",
                op: .writeFile,
                path: "/tmp/build-context.txt",
                digest: "sha256:abc",
                inlineData: Data("abc".utf8)
            )
        )
        try client.fsChunk(request: .init(txID: "tx-1", offset: 3, data: Data("def".utf8)))
        try client.fsEnd(request: .init(txID: "tx-1", action: .commit, digest: "sha256:test"))

        try server.waitForCompletion()
    }

    @Test
    func sidecarFailureMapsKnownErrorCodeToContainerizationError() throws {
        let socketPath = try makeTemporarySocketPath()
        let server = try FakeUnixSidecarTestServer(socketPath: socketPath)
        defer { server.stop() }

        server.start { clientFD in
            let bootstrap = try readRequest(from: clientFD)
            #expect(bootstrap.method == .vmBootstrapStart)
            try writeResponse(.success(requestID: bootstrap.requestID), to: clientFD)

            let close = try readRequest(from: clientFD)
            #expect(close.method == .processClose)
            try writeResponse(
                .failure(
                    requestID: close.requestID,
                    code: "notFound",
                    message: "filesystem transaction tx-404 not found in sidecar",
                    details: "tx_id=tx-404"
                ),
                to: clientFD
            )
        }

        let client = MacOSSidecarClient(socketPath: socketPath, log: Logger(label: "MacOSSidecarClientTests"))
        defer { client.closeControlConnection() }
        try client.bootstrapStart(socketConnectRetries: 3)

        do {
            try client.processClose(processID: "proc-missing")
            Issue.record("expected sidecar processClose to surface a notFound error")
        } catch let error as ContainerizationError {
            #expect(error.code == .notFound)
            #expect(error.message.contains("filesystem transaction tx-404 not found in sidecar"))
            #expect(error.message.contains("tx_id=tx-404"))
        }

        try server.waitForCompletion()
    }

    @Test
    func pendingRequestFailsWhenSidecarClosesControlConnection() throws {
        let socketPath = try makeTemporarySocketPath()
        let server = try FakeUnixSidecarTestServer(socketPath: socketPath)
        defer { server.stop() }

        server.start { clientFD in
            let bootstrap = try readRequest(from: clientFD)
            #expect(bootstrap.method == .vmBootstrapStart)
            try writeResponse(.success(requestID: bootstrap.requestID), to: clientFD)

            let begin = try readRequest(from: clientFD)
            #expect(begin.method == .fsBegin)
            _ = Darwin.shutdown(clientFD, SHUT_RDWR)
        }

        let client = MacOSSidecarClient(socketPath: socketPath, log: Logger(label: "MacOSSidecarClientTests"))
        defer { client.closeControlConnection() }
        let disconnectCount = LockedValue(0)
        let disconnect = DispatchSemaphore(value: 0)
        client.setDisconnectHandler { _ in
            disconnectCount.withLock { $0 += 1 }
            disconnect.signal()
        }
        try client.bootstrapStart(socketConnectRetries: 3)

        do {
            try client.fsBegin(
                port: 27000,
                request: .init(
                    txID: "tx-eof",
                    op: .writeFile,
                    path: "/tmp/eof.txt",
                    inlineData: Data("payload".utf8),
                    autoCommit: true
                )
            )
            Issue.record("expected fsBegin to fail when the sidecar closes the control socket")
        } catch let error as ContainerizationError {
            #expect(error.code == .internalError)
            #expect(error.message.contains("sidecar control connection closed"))
        }

        try server.waitForCompletion()
        #expect(disconnect.wait(timeout: .now() + 2) == .success)
        #expect(disconnectCount.withLock { $0 } == 1)
    }

    @Test
    func pendingRequestTimesOutWhenSidecarStopsResponding() throws {
        let socketPath = try makeTemporarySocketPath()
        let server = try FakeUnixSidecarTestServer(socketPath: socketPath)
        defer { server.stop() }

        server.start { clientFD in
            let bootstrap = try readRequest(from: clientFD)
            #expect(bootstrap.method == .vmBootstrapStart)
            try writeResponse(.success(requestID: bootstrap.requestID), to: clientFD)

            let begin = try readRequest(from: clientFD)
            #expect(begin.method == .fsBegin)
            usleep(300_000)
        }

        let client = MacOSSidecarClient(
            socketPath: socketPath,
            log: Logger(label: "MacOSSidecarClientTests"),
            requestTimeoutSeconds: 0.1
        )
        defer { client.closeControlConnection() }
        let disconnectCount = LockedValue(0)
        client.setDisconnectHandler { _ in
            disconnectCount.withLock { $0 += 1 }
        }
        try client.bootstrapStart(socketConnectRetries: 3)

        do {
            try client.fsBegin(
                port: 27000,
                request: .init(
                    txID: "tx-timeout",
                    op: .writeFile,
                    path: "/tmp/timeout.txt",
                    inlineData: Data("payload".utf8),
                    autoCommit: true
                )
            )
            Issue.record("expected fsBegin to time out when the sidecar stops responding")
        } catch let error as ContainerizationError {
            #expect(error.code == .timeout)
            #expect(error.message.contains("fs.begin"))
        }

        try server.waitForCompletion()
        #expect(disconnectCount.withLock { $0 } == 0)
    }

    @Test
    func bootstrapStartUsesDedicatedTimeoutBudget() throws {
        let socketPath = try makeTemporarySocketPath()
        let server = try FakeUnixSidecarTestServer(socketPath: socketPath)
        defer { server.stop() }

        server.start { clientFD in
            let bootstrap = try readRequest(from: clientFD)
            #expect(bootstrap.method == .vmBootstrapStart)
            usleep(250_000)
            try writeResponse(.success(requestID: bootstrap.requestID), to: clientFD)

            let begin = try readRequest(from: clientFD)
            #expect(begin.method == .fsBegin)
            usleep(250_000)
        }

        let client = MacOSSidecarClient(
            socketPath: socketPath,
            log: Logger(label: "MacOSSidecarClientTests"),
            requestTimeoutSeconds: 0.1,
            bootstrapStartTimeoutSeconds: 0.6
        )
        defer { client.closeControlConnection() }

        try client.bootstrapStart(socketConnectRetries: 3)

        do {
            try client.fsBegin(
                port: 27000,
                request: .init(
                    txID: "tx-bootstrap-timeout",
                    op: .writeFile,
                    path: "/tmp/bootstrap-timeout.txt",
                    inlineData: Data("payload".utf8),
                    autoCommit: true
                )
            )
            Issue.record("expected fsBegin to keep using the default request timeout")
        } catch let error as ContainerizationError {
            #expect(error.code == .timeout)
            #expect(error.message.contains("fs.begin"))
        }

        try server.waitForCompletion()
    }

    @Test
    func sidecarEventPumpPreservesEventOrder() async {
        let pump = SidecarEventPump()
        let recorder = EventRecorder()

        let consumer = Task {
            for await event in pump.stream {
                await recorder.record(event)
            }
        }

        pump.yield(.init(event: .processStdout, processID: "proc-1", data: Data("hello\n".utf8)))
        pump.yield(.init(event: .processExit, processID: "proc-1", exitCode: 0))
        pump.finish()
        await consumer.value

        let received = await recorder.events()
        #expect(received.map(\.event) == [.processStdout, .processExit])
        #expect(received.first?.data == Data("hello\n".utf8))
        #expect(received.last?.exitCode == 0)
    }
}

private func makeSidecarStartupConfiguration(
    restoreStateID: String?,
    storageDirectory: String = "/var/lib/container/machine-state/v1/pod-a",
    controlSocketPath: String = "/var/run/container/machine-state/v1/pod-a.sock"
) throws -> ContainerConfiguration {
    let image = try JSONDecoder().decode(
        ImageDescription.self,
        from: Data(
            #"{"reference":"example/macos:latest","descriptor":{"mediaType":"application/vnd.oci.image.index.v1+json","digest":"sha256:test","size":1}}"#.utf8
        )
    )
    var configuration = ContainerConfiguration(
        id: "sandbox-a",
        image: image,
        process: ProcessConfiguration(
            executable: "/bin/true",
            arguments: [],
            environment: [],
            workingDirectory: "/",
            terminal: false,
            user: .id(uid: 0, gid: 0)
        )
    )
    configuration.macosGuest = .init(
        snapshotEnabled: true,
        guiEnabled: false,
        agentPort: 27_000,
        blockDevices: [
            .init(identifier: "root", kind: .nbdUnixSocket, path: "/var/run/container/nbd/root.sock")
        ],
        machineState: .init(
            persistenceID: "pod-a",
            storageDirectory: storageDirectory,
            controlSocketPath: controlSocketPath,
            restoreStateID: restoreStateID
        )
    )
    return configuration
}

private actor EventRecorder {
    private var received: [MacOSSidecarEvent] = []

    func record(_ event: MacOSSidecarEvent) {
        received.append(event)
    }

    func events() -> [MacOSSidecarEvent] {
        received
    }
}

private final class FakeUnixSidecarTestServer: @unchecked Sendable {
    private let socketPath: String
    private let stateLock = NSLock()
    private var listenFD: Int32
    private let errorBox = LockedValue<Error?>(nil)
    private let done = DispatchSemaphore(value: 0)
    private let activeClientFD = LockedValue<Int32?>(nil)
    private let started = LockedValue<Bool>(false)

    init(socketPath: String) throws {
        self.socketPath = socketPath
        self.listenFD = try makeUnixListener(path: socketPath)
    }

    func start(_ handler: @Sendable @escaping (Int32) throws -> Void) {
        let wasStarted = started.withLock { value -> Bool in
            let old = value
            value = true
            return old
        }
        precondition(!wasStarted, "server can only be started once")

        Thread.detachNewThread { [self] in
            defer { done.signal() }
            do {
                let clientFD = Darwin.accept(listenFD, nil, nil)
                guard clientFD >= 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                activeClientFD.withLock { $0 = clientFD }
                defer {
                    let ownedClientFD = activeClientFD.withLock { fd -> Int32? in
                        guard fd == clientFD else {
                            return nil
                        }
                        fd = nil
                        return clientFD
                    }
                    closeIfValid(ownedClientFD)
                }
                try handler(clientFD)
            } catch {
                errorBox.withLock { $0 = error }
            }
        }
    }

    func waitForCompletion(timeout: TimeInterval = 2.0) throws {
        let result = done.wait(timeout: .now() + timeout)
        guard result == .success else {
            throw POSIXError(.ETIMEDOUT)
        }
        if let error = errorBox.withLock({ $0 }) {
            throw error
        }
    }

    func stop() {
        stateLock.lock()
        let listenFD = self.listenFD
        self.listenFD = -1
        stateLock.unlock()

        let clientFDToClose = activeClientFD.withLock { fd -> Int32? in
            let current = fd
            fd = nil
            return current
        }
        if let clientFDToClose, clientFDToClose >= 0 {
            _ = Darwin.shutdown(clientFDToClose, SHUT_RDWR)
            Darwin.close(clientFDToClose)
        }
        if listenFD >= 0 {
            _ = Darwin.shutdown(listenFD, SHUT_RDWR)
            Darwin.close(listenFD)
        }
        _ = unlink(socketPath)
    }
}

private final class FakeConcurrentUnixSidecarTestServer: @unchecked Sendable {
    private let socketPath: String
    private let stateLock = NSLock()
    private var listenFD: Int32
    private let activeClients = LockedValue<[UUID: Int32]>([:])
    private let errorBox = LockedValue<Error?>(nil)
    private let done = DispatchSemaphore(value: 0)
    private let started = LockedValue(false)

    init(socketPath: String) throws {
        self.socketPath = socketPath
        self.listenFD = try makeUnixListener(path: socketPath)
    }

    func start(
        connectionCount: Int,
        handler: @Sendable @escaping (Int, Int32) throws -> Void
    ) {
        let wasStarted = started.withLock { value -> Bool in
            let old = value
            value = true
            return old
        }
        precondition(!wasStarted, "server can only be started once")

        Thread.detachNewThread { [self] in
            let handlers = DispatchGroup()
            defer {
                handlers.wait()
                done.signal()
            }

            for index in 0..<connectionCount {
                let clientFD = Darwin.accept(listenFD, nil, nil)
                guard clientFD >= 0 else {
                    errorBox.withLock { value in
                        value = value ?? POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                    return
                }
                let token = UUID()
                activeClients.withLock { $0[token] = clientFD }
                handlers.enter()
                Thread.detachNewThread { [self] in
                    defer {
                        let ownedFD = activeClients.withLock { $0.removeValue(forKey: token) }
                        if let ownedFD {
                            closeIfValid(ownedFD)
                        }
                        handlers.leave()
                    }
                    do {
                        try handler(index, clientFD)
                    } catch {
                        errorBox.withLock { value in
                            value = value ?? error
                        }
                    }
                }
            }
        }
    }

    func waitForCompletion(timeout: TimeInterval = 2) throws {
        guard done.wait(timeout: .now() + timeout) == .success else {
            throw POSIXError(.ETIMEDOUT)
        }
        if let error = errorBox.withLock({ $0 }) {
            throw error
        }
    }

    func stop() {
        stateLock.lock()
        let listener = listenFD
        listenFD = -1
        stateLock.unlock()

        let clients = activeClients.withLock { values -> [Int32] in
            let result = Array(values.values)
            values.removeAll()
            return result
        }
        for fd in clients {
            _ = Darwin.shutdown(fd, SHUT_RDWR)
            closeIfValid(fd)
        }
        if listener >= 0 {
            _ = Darwin.shutdown(listener, SHUT_RDWR)
            closeIfValid(listener)
        }
        _ = unlink(socketPath)
    }
}

private final class LockedValue<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T

    init(_ value: T) {
        self.value = value
    }

    func withLock<R>(_ body: (inout T) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

private func readRequest(from fd: Int32) throws -> MacOSSidecarRequest {
    let envelope = try MacOSSidecarSocketIO.readJSONFrame(MacOSSidecarEnvelope.self, fd: fd)
    #expect(envelope.kind == .request)
    return try #require(envelope.request)
}

private func acknowledgeEventSubscription(from fd: Int32) throws {
    let request = try readRequest(from: fd)
    #expect(request.method == .eventsSubscribe)
    #expect(request.protocolVersion == MacOSSidecarProtocolVersion.durableEventAcknowledgement)
    try writeResponse(
        .success(
            requestID: request.requestID,
            data: try JSONEncoder().encode(
                MacOSSidecarEventSubscription(subscriptionID: "test-subscription")
            ),
            protocolVersion: MacOSSidecarProtocolVersion.durableEventAcknowledgement
        ),
        to: fd
    )
}

private func writeResponse(_ response: MacOSSidecarResponse, to fd: Int32) throws {
    try MacOSSidecarSocketIO.writeJSONFrame(MacOSSidecarEnvelope.response(response), fd: fd)
}

private func writeCapabilities(state: MacOSVMRuntimeState, requestID: String, to fd: Int32) throws {
    try writeResponse(
        .success(
            requestID: requestID,
            data: try JSONEncoder().encode(
                MacOSSidecarCapabilities(
                    lifecycleState: state,
                    machineState: .init(supported: true),
                    methods: []
                )
            ),
            protocolVersion: MacOSSidecarProtocolVersion.machineState
        ),
        to: fd
    )
}

private func writeEvent(_ event: MacOSSidecarEvent, to fd: Int32) throws {
    try MacOSSidecarSocketIO.writeJSONFrame(MacOSSidecarEnvelope.event(event), fd: fd)
}

private func makeTemporarySocketPath() throws -> String {
    let suffix = UUID().uuidString.prefix(8)
    return "/tmp/sidecar-client-\(suffix).sock"
}

private func makeUnixListener(path: String) throws -> Int32 {
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    let parent = URL(fileURLWithPath: path).deletingLastPathComponent()
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    _ = unlink(path)

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(path.utf8)
    let maxPathCount = MemoryLayout.size(ofValue: addr.sun_path)
    guard pathBytes.count < maxPathCount else {
        Darwin.close(fd)
        throw POSIXError(.ENAMETOOLONG)
    }

    withUnsafeMutableBytes(of: &addr.sun_path) { rawBuffer in
        rawBuffer.initializeMemory(as: CChar.self, repeating: 0)
        for (index, byte) in pathBytes.enumerated() {
            rawBuffer[index] = byte
        }
    }

    let addrLen = socklen_t(MemoryLayout<sa_family_t>.size + pathBytes.count + 1)
    let bindResult = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
            Darwin.bind(fd, sockaddrPtr, addrLen)
        }
    }
    guard bindResult == 0 else {
        let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        Darwin.close(fd)
        throw error
    }
    guard Darwin.listen(fd, 8) == 0 else {
        let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        Darwin.close(fd)
        throw error
    }
    return fd
}

private func writeAll(_ data: Data, fd: Int32) throws {
    try data.withUnsafeBytes { rawBuffer in
        guard let base = rawBuffer.baseAddress else { return }
        var offset = 0
        while offset < rawBuffer.count {
            let n = Darwin.write(fd, base.advanced(by: offset), rawBuffer.count - offset)
            if n > 0 {
                offset += n
                continue
            }
            if n == 0 {
                throw POSIXError(.EIO)
            }
            let code = errno
            if code == EINTR { continue }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }
}

private func closeIfValid(_ fd: Int32?) {
    guard let fd, fd >= 0 else { return }
    Darwin.close(fd)
}
#endif
