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

import Darwin
import Foundation
import Testing

@testable import ContainerK8sFlannelVXLANMacOS

struct FlannelDaemonLifecycleTests {
    @Test
    func failedWithdrawalStopsReconcileRetainsLifecycleAndCanBeRetried() async throws {
        let operations = LifecycleOperations(cleanupFailures: 1)
        let lifecycle = FlannelDaemonLifecycle(
            reconcile: {
                try await operations.reconcile()
            },
            cleanup: {
                try await operations.cleanup()
            }
        )
        await lifecycle.start()
        try await waitUntil { await operations.reconcileStarts == 1 }

        let first = await lifecycle.withdraw()
        #expect(!first.succeeded)
        #expect(await lifecycle.state == .withdrawn)
        #expect(await operations.reconcileCancellations == 1)
        #expect(await operations.cleanupCalls == 1)

        let second = await lifecycle.withdraw()
        #expect(second.succeeded)
        #expect(await lifecycle.state == .cleaned)
        #expect(await operations.reconcileStarts == 1)
        #expect(await operations.cleanupCalls == 2)
    }

    @Test
    func terminationRetriesCleanupWithoutRestartingReconcile() async throws {
        let operations = LifecycleOperations(cleanupFailures: 2)
        let lifecycle = FlannelDaemonLifecycle(
            reconcile: {
                try await operations.reconcile()
            },
            cleanup: {
                try await operations.cleanup()
            }
        )
        await lifecycle.start()
        try await waitUntil { await operations.reconcileStarts == 1 }

        await lifecycle.terminateWhenClean(retryDelay: .zero, onCleanupError: { _ in })

        #expect(await lifecycle.state == .cleaned)
        #expect(await operations.cleanupCalls == 3)
        #expect(await operations.reconcileCancellations == 1)
        #expect(await operations.reconcileStarts == 1)
    }

    @Test
    func rootOnlyControlSocketReturnsCleanupAcknowledgement() async throws {
        let socketPath = "/tmp/flannel-control-\(UUID().uuidString).sock"
        let outcomes = ControlOutcomes()
        let server = FlannelControlServer(socketPath: socketPath, requiredPeerUID: geteuid())
        try server.start {
            await outcomes.next()
        }
        defer { server.stop() }

        let attributes = try FileManager.default.attributesOfItem(atPath: socketPath)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)

        #expect(throws: FlannelVXLANError.self) {
            try FlannelControlClient.requestWithdrawal(
                socketPath: socketPath,
                requiredPeerUID: geteuid() &+ 1
            )
        }

        let first = try FlannelControlClient.requestWithdrawal(
            socketPath: socketPath,
            requiredPeerUID: geteuid()
        )
        #expect(!first.succeeded)
        #expect(first.message == "injected cleanup failure")
        let second = try FlannelControlClient.requestWithdrawal(
            socketPath: socketPath,
            requiredPeerUID: geteuid()
        )
        #expect(second.succeeded)
        #expect(second.message == "withdrawn")
        #expect(await outcomes.calls == 2)
    }

    @Test
    func controlSocketRoutesCheckPurgeWithoutBreakingWithdrawal() async throws {
        let socketPath = "/tmp/flannel-control-\(UUID().uuidString).sock"
        let handlers = ControlHandlers()
        let claim = try makePurgePreflightClaim()
        let server = FlannelControlServer(socketPath: socketPath, requiredPeerUID: geteuid())
        try server.start(
            withdrawalHandler: {
                await handlers.withdraw()
            },
            checkPurgeHandler: { requestedClaim in
                await handlers.checkPurge(claim: requestedClaim)
            }
        )
        defer { server.stop() }

        let preflight = try FlannelControlClient.requestPurgePreflight(
            claim: claim,
            socketPath: socketPath,
            requiredPeerUID: geteuid()
        )
        #expect(preflight == FlannelWithdrawalOutcome(succeeded: true, message: "owned=true network=test"))

        let withdrawal = try FlannelControlClient.requestWithdrawal(
            socketPath: socketPath,
            requiredPeerUID: geteuid()
        )
        #expect(withdrawal == FlannelWithdrawalOutcome(succeeded: true, message: "withdrawn"))
        #expect(await handlers.checkPurgeCalls == 1)
        #expect(await handlers.withdrawalCalls == 1)
        #expect(await handlers.lastPurgePreflightClaim == claim)
    }

    @Test
    func controlSocketRejectsUnsupportedActionExplicitly() async throws {
        let socketPath = "/tmp/flannel-control-\(UUID().uuidString).sock"
        let outcomes = ControlOutcomes()
        let server = FlannelControlServer(socketPath: socketPath, requiredPeerUID: geteuid())
        try server.start {
            await outcomes.next()
        }
        defer { server.stop() }

        let response = try FlannelControlClient.request(
            FlannelControlRequest(action: "future-action"),
            socketPath: socketPath,
            requiredPeerUID: geteuid()
        )
        #expect(!response.outcome.succeeded)
        #expect(response.failureKind == .unsupportedAction)
        #expect(response.outcome.message.contains("future-action"))
        #expect(await outcomes.calls == 0)
    }

    @Test
    func withdrawalOnlyServerExplicitlyRejectsCheckPurge() async throws {
        let socketPath = "/tmp/flannel-control-\(UUID().uuidString).sock"
        let outcomes = ControlOutcomes()
        let claim = try makePurgePreflightClaim()
        let server = FlannelControlServer(socketPath: socketPath, requiredPeerUID: geteuid())
        try server.start {
            await outcomes.next()
        }
        defer { server.stop() }

        #expect(throws: FlannelCheckPurgeControlError.self) {
            try FlannelControlClient.requestPurgePreflight(
                claim: claim,
                socketPath: socketPath,
                requiredPeerUID: geteuid()
            )
        }
        #expect(await outcomes.calls == 0)
    }

    @Test
    func checkPurgeResponseValidationSupportsLegacyFallbackAndRejectsMalformedSuccess() throws {
        let legacyUnsupported = FlannelControlResponse(
            outcome: FlannelWithdrawalOutcome(succeeded: false, message: "unsupported control request")
        )
        #expect(throws: FlannelCheckPurgeControlError.unsupportedAction("unsupported control request")) {
            try FlannelControlClient.purgePreflightOutcome(from: legacyUnsupported)
        }

        let malformedSuccess = FlannelControlResponse(
            outcome: FlannelWithdrawalOutcome(succeeded: true, message: "ok"),
            failureKind: .unsupportedAction
        )
        #expect(throws: FlannelCheckPurgeControlError.self) {
            try FlannelControlClient.purgePreflightOutcome(from: malformedSuccess)
        }

        #expect(
            FlannelCheckPurgeControlError.transport("unreachable").fallbackManifestPolicy
                == .requireExactManifest
        )
        #expect(
            FlannelCheckPurgeControlError.unsupportedAction("legacy").fallbackManifestPolicy
                == .allowMissingLegacyManifest
        )
        #expect(FlannelCheckPurgeControlError.authentication("uid").fallbackManifestPolicy == nil)
        #expect(FlannelCheckPurgeControlError.protocolViolation("invalid").fallbackManifestPolicy == nil)
    }

    @Test
    func checkPurgeOperationFailureRemainsACompletedSemanticResponse() async throws {
        let socketPath = "/tmp/flannel-control-\(UUID().uuidString).sock"
        let claim = try makePurgePreflightClaim()
        let server = FlannelControlServer(socketPath: socketPath, requiredPeerUID: geteuid())
        try server.start(
            withdrawalHandler: {
                FlannelWithdrawalOutcome(succeeded: true, message: "withdrawn")
            },
            checkPurgeHandler: { _ in
                FlannelWithdrawalOutcome(succeeded: false, message: "network still has attachments")
            }
        )
        defer { server.stop() }

        let response = try FlannelControlClient.requestPurgePreflight(
            claim: claim,
            socketPath: socketPath,
            requiredPeerUID: geteuid()
        )
        #expect(response == FlannelWithdrawalOutcome(succeeded: false, message: "network still has attachments"))
    }

    @Test
    func oversizedCheckPurgeResponseFailsAsAProtocolViolation() async throws {
        let socketPath = "/tmp/flannel-control-\(UUID().uuidString).sock"
        let claim = try makePurgePreflightClaim()
        let server = FlannelControlServer(socketPath: socketPath, requiredPeerUID: geteuid())
        try server.start(
            withdrawalHandler: {
                FlannelWithdrawalOutcome(succeeded: true, message: "withdrawn")
            },
            checkPurgeHandler: { _ in
                FlannelWithdrawalOutcome(
                    succeeded: false,
                    message: String(repeating: "attachment ", count: 600)
                )
            }
        )
        defer { server.stop() }

        #expect(throws: FlannelCheckPurgeControlError.protocolViolation("Flannel control frame exceeds 4096 bytes")) {
            try FlannelControlClient.requestPurgePreflight(
                claim: claim,
                socketPath: socketPath,
                requiredPeerUID: geteuid()
            )
        }
    }

    @Test
    func checkPurgeRequiresAValidCompactManifestClaim() async throws {
        let socketPath = "/tmp/flannel-control-\(UUID().uuidString).sock"
        let handlers = ControlHandlers()
        let server = FlannelControlServer(socketPath: socketPath, requiredPeerUID: geteuid())
        try server.start(
            withdrawalHandler: {
                await handlers.withdraw()
            },
            checkPurgeHandler: { requestedClaim in
                await handlers.checkPurge(claim: requestedClaim)
            }
        )
        defer { server.stop() }

        let missingClaim = try FlannelControlClient.request(
            FlannelControlRequest(action: FlannelControlRequest.checkPurgeAction),
            socketPath: socketPath,
            requiredPeerUID: geteuid()
        )
        #expect(!missingClaim.outcome.succeeded)
        #expect(missingClaim.failureKind == .operationFailed)
        #expect(missingClaim.outcome.message.contains("requires a purge preflight claim"))

        let invalidClaim = try FlannelControlClient.request(
            FlannelControlRequest(
                action: FlannelControlRequest.checkPurgeAction,
                purgePreflightClaim: FlannelPurgePreflightClaim(manifestSHA256: String(repeating: "g", count: 64))
            ),
            socketPath: socketPath,
            requiredPeerUID: geteuid()
        )
        #expect(!invalidClaim.outcome.succeeded)
        #expect(invalidClaim.failureKind == .operationFailed)
        #expect(invalidClaim.outcome.message.contains("invalid SHA-256 digest"))
        #expect(await handlers.checkPurgeCalls == 0)
    }

    @Test
    func compactManifestClaimIsStableAndWireCompatibleWithVersionOne() throws {
        let manifest = makePurgePreflightManifest()
        let claim = try FlannelPurgePreflightClaim(manifest: manifest)
        let duplicateClaim = try FlannelPurgePreflightClaim(manifest: manifest)
        #expect(claim == duplicateClaim)
        #expect(claim.manifestSHA256.count == 64)

        var changedManifest = manifest
        changedManifest.identity.nodeName = "different-node"
        #expect(try FlannelPurgePreflightClaim(manifest: changedManifest) != claim)

        let request = FlannelControlRequest(
            action: FlannelControlRequest.checkPurgeAction,
            purgePreflightClaim: claim
        )
        let encodedRequest = try JSONEncoder().encode(request)
        #expect(encodedRequest.count < 4_096)

        let legacyDecoded = try JSONDecoder().decode(LegacyControlRequest.self, from: encodedRequest)
        #expect(legacyDecoded.version == FlannelControlRequest.currentVersion)
        #expect(legacyDecoded.action == FlannelControlRequest.checkPurgeAction)

        let legacyRequest = LegacyControlRequest(
            version: FlannelControlRequest.currentVersion,
            action: FlannelControlRequest.withdrawAction
        )
        let newDecoded = try JSONDecoder().decode(
            FlannelControlRequest.self,
            from: JSONEncoder().encode(legacyRequest)
        )
        #expect(newDecoded.purgePreflightClaim == nil)
    }

    @Test
    func controlServerRejectsUnexpectedClientUIDBeforeDispatch() async throws {
        let socketPath = "/tmp/flannel-control-\(UUID().uuidString).sock"
        let outcomes = ControlOutcomes()
        let server = FlannelControlServer(socketPath: socketPath, requiredPeerUID: geteuid() &+ 1)
        try server.start {
            await outcomes.next()
        }
        defer { server.stop() }

        let response = try FlannelControlClient.requestWithdrawal(
            socketPath: socketPath,
            requiredPeerUID: geteuid()
        )
        #expect(!response.succeeded)
        #expect(response.message.contains("control request denied for uid"))
        #expect(await outcomes.calls == 0)
    }
}

private actor LifecycleOperations {
    private(set) var reconcileStarts = 0
    private(set) var reconcileCancellations = 0
    private(set) var cleanupCalls = 0
    private var cleanupFailures: Int

    init(cleanupFailures: Int) {
        self.cleanupFailures = cleanupFailures
    }

    func reconcile() async throws {
        reconcileStarts += 1
        do {
            while true {
                try await Task.sleep(for: .seconds(60))
            }
        } catch is CancellationError {
            reconcileCancellations += 1
            throw CancellationError()
        }
    }

    func cleanup() throws -> FlannelCleanupResult {
        cleanupCalls += 1
        if cleanupFailures > 0 {
            cleanupFailures -= 1
            throw FlannelVXLANError.runtime("injected cleanup failure")
        }
        return FlannelCleanupResult(
            removedRoutes: ["10.250.2.0/24"],
            stoppedTunnel: true,
            removedNodeAnnotations: true,
            nodeAnnotationAttempts: 1
        )
    }
}

private actor ControlOutcomes {
    private(set) var calls = 0

    func next() -> FlannelWithdrawalOutcome {
        calls += 1
        if calls == 1 {
            return FlannelWithdrawalOutcome(succeeded: false, message: "injected cleanup failure")
        }
        return FlannelWithdrawalOutcome(succeeded: true, message: "withdrawn")
    }
}

private actor ControlHandlers {
    private(set) var withdrawalCalls = 0
    private(set) var checkPurgeCalls = 0
    private(set) var lastPurgePreflightClaim: FlannelPurgePreflightClaim?

    func withdraw() -> FlannelWithdrawalOutcome {
        withdrawalCalls += 1
        return FlannelWithdrawalOutcome(succeeded: true, message: "withdrawn")
    }

    func checkPurge(claim: FlannelPurgePreflightClaim) -> FlannelWithdrawalOutcome {
        checkPurgeCalls += 1
        lastPurgePreflightClaim = claim
        return FlannelWithdrawalOutcome(succeeded: true, message: "owned=true network=test")
    }
}

private struct LegacyControlRequest: Codable {
    var version: Int
    var action: String
}

private func makePurgePreflightClaim() throws -> FlannelPurgePreflightClaim {
    try FlannelPurgePreflightClaim(manifest: makePurgePreflightManifest())
}

private func makePurgePreflightManifest() -> FlannelStateManifest {
    FlannelStateManifest(
        configPath: "/etc/kubernetes/flannel-vxlan-macos.conf",
        identity: FlannelStateManifestIdentity(
            nodeName: "test-node",
            networkName: "kubernetes-pod",
            networkPlugin: "hostOnly",
            networkVariant: "kubernetes",
            annotationPrefix: "flannel.alpha.coreos.com"
        ),
        statePaths: FlannelManagedStatePaths(
            dataplaneOwnership: "/var/lib/container/flannel-vxlan/ownership.json",
            networkOwnership: "/var/lib/container/flannel-vxlan/network-ownership.json",
            hostIPv6GatewayOwnership: "/var/lib/container/flannel-vxlan/host-ipv6-gateway-ownership.json",
            forwardingOwnership: "/var/lib/container/flannel-vxlan/forwarding-ownership.json",
            ready: "/var/lib/container/flannel-vxlan/ready.json"
        )
    )
}

private func waitUntil(
    attempts: Int = 100,
    condition: @escaping @Sendable () async -> Bool
) async throws {
    for _ in 0..<attempts {
        if await condition() {
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw FlannelVXLANError.runtime("condition was not satisfied")
}
