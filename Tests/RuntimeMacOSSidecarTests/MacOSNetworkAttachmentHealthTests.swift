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
import Foundation
import RuntimeMacOSSidecarShared
import Testing

@testable import container_runtime_macos_sidecar

struct MacOSNetworkAttachmentHealthTests {
    @Test func healthyAndEmptyNetworkConfigurationsPass() throws {
        let health = MacOSNetworkAttachmentHealth()
        try health.validate(connectedAttachments: [], expectedCount: 0)
        try health.validate(connectedAttachments: [true, true], expectedCount: 2)
    }

    @Test func missingAttachmentAndWrongDeviceCountFailClosed() throws {
        let health = MacOSNetworkAttachmentHealth()
        for (attachments, expectedCount, metadata) in [
            ([true, false], 2, ["networkDeviceIndex": "1"]),
            ([true], 2, ["expectedNetworkDeviceCount": "2", "observedNetworkDeviceCount": "1"]),
            ([true, true], 1, ["expectedNetworkDeviceCount": "1", "observedNetworkDeviceCount": "2"]),
        ] {
            do {
                try health.validate(connectedAttachments: attachments, expectedCount: expectedCount)
                Issue.record("disconnected device was accepted")
            } catch let error as SidecarRPCError {
                #expect(error.code == "networkAttachmentDisconnected")
                #expect(error.metadata == metadata)
            }
        }
    }

    @Test func nativeFailurePreservesDomainCodeAndUnderlyingCauseInProtocolResponse() throws {
        let health = MacOSNetworkAttachmentHealth()
        let cause = NSError(domain: "TestVMNet", code: 42, userInfo: [NSLocalizedDescriptionKey: "interface refused"])
        let native = NSError(
            domain: "TestVirtualization", code: 7,
            userInfo: [NSLocalizedDescriptionKey: "attachment failed", NSUnderlyingErrorKey: cause]
        )
        let failure = health.recordDisconnection(deviceIndex: 0, error: native)
        let response = MacOSSidecarResponse.failure(
            requestID: "bootstrap", code: failure.code, message: failure.message,
            details: failure.details, metadata: failure.metadata
        )
        let encoded = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(MacOSSidecarResponse.self, from: encoded)
        #expect(decoded.requestID == "bootstrap")
        #expect(decoded.error?.code == "networkAttachmentDisconnected")
        #expect(
            decoded.error?.metadata == [
                "networkDeviceIndex": "0", "errorDomain": "TestVirtualization", "errorCode": "7",
                "underlyingErrorDomain": "TestVMNet", "underlyingErrorCode": "42",
            ])
        #expect(decoded.error?.details == "TestVirtualization(7): attachment failed <- TestVMNet(42): interface refused")
    }

    @Test func nativeFailureWinsOverLaterTimeoutAndRemainsBoundToOneVM() throws {
        let health = MacOSNetworkAttachmentHealth()
        let timeout = NSError(domain: "TestGatewayTimeout", code: 1)
        #expect(health.failureOr(timeout) as NSError === timeout)
        health.recordDisconnection(deviceIndex: 0, error: NSError(domain: "TestFirstFailure", code: 2))
        health.recordDisconnection(deviceIndex: 1, error: NSError(domain: "TestLaterFailure", code: 3))
        let failure = try #require(health.failureOr(timeout) as? SidecarRPCError)
        #expect(failure.metadata?["errorDomain"] == "TestFirstFailure")
        #expect(failure.metadata?["networkDeviceIndex"] == "0")
        #expect(throws: SidecarRPCError.self) {
            try health.validate(connectedAttachments: [true, true], expectedCount: 2)
        }
        try MacOSNetworkAttachmentHealth().validate(connectedAttachments: [true], expectedCount: 1)
    }

    @Test func diagnosticsAreBoundedAndDoNotSerializeUserInfo() throws {
        var error = NSError(domain: "TestRoot", code: 0)
        for index in 1...12 {
            error = NSError(
                domain: "TestError", code: index,
                userInfo: [
                    NSLocalizedDescriptionKey: String(repeating: "x", count: 2_000),
                    NSUnderlyingErrorKey: error,
                    "unrelated": "not-for-diagnostics",
                ]
            )
        }
        let failure = MacOSNetworkAttachmentHealth().recordDisconnection(deviceIndex: nil, error: error)
        let details = try #require(failure.details)
        #expect(details.components(separatedBy: " <- ").count == 8)
        #expect(details.count < 5_000)
        #expect(!details.contains("not-for-diagnostics"))
        #expect(failure.metadata?["networkDeviceIndex"] == nil)
    }

    @Test func concurrentCallbacksAndActivationInspectionRetainFirstFailure() async throws {
        let health = MacOSNetworkAttachmentHealth()
        health.recordDisconnection(deviceIndex: 0, error: NSError(domain: "TestOriginal", code: 1))
        await withTaskGroup(of: Void.self) { group in
            for index in 1...32 {
                group.addTask {
                    health.recordDisconnection(deviceIndex: index, error: NSError(domain: "TestSubsequent", code: index))
                    #expect(throws: SidecarRPCError.self) {
                        try health.validate(connectedAttachments: [true], expectedCount: 1)
                    }
                }
            }
        }
        let failure = try #require(health.failureOr(NSError(domain: "TestTimeout", code: 0)) as? SidecarRPCError)
        #expect(failure.metadata?["errorDomain"] == "TestOriginal")
        #expect(failure.metadata?["errorCode"] == "1")
    }
}
#endif
