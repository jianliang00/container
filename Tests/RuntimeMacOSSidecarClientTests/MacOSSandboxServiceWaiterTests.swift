#if os(macOS)
import ContainerResource
import Containerization
import ContainerizationError
import Foundation
import Logging
import Testing

@testable import container_runtime_macos

struct MacOSSandboxServiceWaiterTests {
    @Test
    func waitForMissingProcessThrowsNotFound() async throws {
        let tempRoot = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let service = makeSandboxService(root: tempRoot)

        do {
            _ = try await service.testingWaitForProcess("missing-process")
            Issue.record("expected wait on unknown process to fail")
        } catch let error as ContainerizationError {
            #expect(error.code == .notFound)
        }
    }

    @Test
    func closeAllSessionsResumesOutstandingWaiters() async throws {
        let tempRoot = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let service = makeSandboxService(root: tempRoot)
        await service.testingAddSession(id: "exec-1", config: baseProcessConfiguration())

        let waitTask = Task {
            try await service.testingWaitForProcess("exec-1")
        }
        try await waitUntilWaiterRegistered(service: service, id: "exec-1")

        await service.testingCloseAllSessions()

        let status = try await waitTask.value
        #expect(status.exitCode == 255)
        #expect(await service.testingWaiterCount(for: "exec-1") == 0)
    }

    @Test
    func timedWaitClearsRegisteredWaiter() async throws {
        let tempRoot = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let service = makeSandboxService(root: tempRoot)
        await service.testingAddSession(id: "exec-timeout", config: baseProcessConfiguration())

        do {
            _ = try await service.testingWaitForProcess("exec-timeout", timeout: 1)
            Issue.record("expected timed wait to throw timeout")
        } catch let error as ContainerizationError {
            #expect(error.code == .timeout)
        }

        #expect(await service.testingWaiterCount(for: "exec-timeout") == 0)
    }
}

private func makeSandboxService(root: URL) -> MacOSSandboxService {
    return MacOSSandboxService(
        root: root,
        connection: nil,
        log: Logger(label: "MacOSSandboxServiceWaiterTests")
    )
}

private func makeTemporaryRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
}

private func baseProcessConfiguration() -> ProcessConfiguration {
    ProcessConfiguration(
        executable: "/bin/sh",
        arguments: [],
        environment: [],
        workingDirectory: "/",
        terminal: false,
        user: .id(uid: 0, gid: 0)
    )
}

private func waitUntilWaiterRegistered(
    service: MacOSSandboxService,
    id: String,
    attempts: Int = 100
) async throws {
    for _ in 0..<attempts {
        if await service.testingWaiterCount(for: id) > 0 {
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }

    Issue.record("timed out waiting for waiter registration on \(id)")
}
#endif
