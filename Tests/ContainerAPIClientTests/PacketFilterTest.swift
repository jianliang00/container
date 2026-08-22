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

import ContainerizationError
import ContainerizationExtras
import DNSServer
import Dispatch
import Foundation
import SystemPackage
import Testing

@testable import ContainerAPIClient

struct PacketFilterTest {
    @Test
    func testRedirectRuleUpdate() async throws {
        let fm = FileManager.default
        let tempURL = try fm.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: .temporaryDirectory,
            create: true
        )
        let tempPath = FilePath(tempURL.path)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let configPath = tempPath.appending("pf.conf")

        let pf = PacketFilter(
            configPath: configPath,
            anchorsPath: tempPath,
            advisoryLockPath: tempPath.appending("pf.lock").string
        )
        let from1 = try! IPAddress("203.0.113.113")
        let domain1 = try! DNSName("aaa.com")
        let to = try! IPAddress("127.0.0.1")
        try pf.createRedirectRule(from: from1, to: to, domain: domain1)

        let anchorPath = tempPath.appending("com.apple.container")
        var actualAnchorText = try String(contentsOfFile: anchorPath.string, encoding: .utf8)
        var expectedAnchorTest = """
            rdr inet from any to \(from1) -> \(to) # \(domain1.pqdn)\n
            """

        #expect(actualAnchorText == expectedAnchorTest)

        let from2 = try! IPAddress("172.31.72.1")
        let domain2 = try! DNSName("bbb.com")
        try pf.createRedirectRule(from: from2, to: to, domain: domain2)

        actualAnchorText = try String(contentsOfFile: anchorPath.string, encoding: .utf8)
        expectedAnchorTest += """
            rdr inet from any to \(from2) -> \(to) # \(domain2.pqdn)\n
            """
        #expect(actualAnchorText == expectedAnchorTest)

        let actualConfigText = try String(contentsOfFile: configPath.string, encoding: .utf8)
        let expectedConfigText = try Regex(
            #"""
            scrub-anchor "([^"]+)"
            nat-anchor "([^"]+)"
            rdr-anchor "([^"]+)"
            dummynet-anchor "([^"]+)"
            anchor "([^"]+)"
            load anchor "([^"]+)" from "[^"]+"
            """#
        )

        #expect(actualConfigText.contains(expectedConfigText))

        try pf.removeRedirectRule(from: from1, to: to, domain: domain1)
        try pf.removeRedirectRule(from: from2, to: to, domain: domain2)

        #expect(!fm.fileExists(atPath: anchorPath.string))
        let configText = try String(contentsOfFile: configPath.string, encoding: .utf8)
        #expect(configText == "")
    }

    @Test
    func testPacketFilterReinitialize() async throws {
        let pf = PacketFilter()
        #expect(throws: ContainerizationError.self) {
            try pf.reinitialize()
        }
    }

    @Test
    func testDNSAnchorOwnershipDoesNotMatchKubeProxyAnchors() throws {
        let fm = FileManager.default
        let tempURL = try fm.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: .temporaryDirectory,
            create: true
        )
        defer { try? fm.removeItem(at: tempURL) }
        let tempPath = FilePath(tempURL.path)
        let configPath = tempPath.appending("pf.conf")
        let ipv4Anchor = "com.apple.container.kube-proxy"
        let ipv6Anchor = "\(ipv4Anchor).ipv6"
        let preservedDirectives = [
            "nat-anchor \"\(ipv4Anchor)\"",
            "rdr-anchor \"\(ipv4Anchor)\"",
            "load anchor \"\(ipv4Anchor)\" from \"\(tempPath.appending(ipv4Anchor).string)\"",
            "rdr-anchor \"\(ipv6Anchor)\"",
            "load anchor \"\(ipv6Anchor)\" from \"\(tempPath.appending(ipv6Anchor).string)\"",
        ]
        try (preservedDirectives + [""]).joined(separator: "\n").write(
            toFile: configPath.string,
            atomically: true,
            encoding: .utf8
        )

        let packetFilter = PacketFilter(
            configPath: configPath,
            anchorsPath: tempPath,
            advisoryLockPath: tempPath.appending("pf.lock").string
        )
        let from = try IPAddress("203.0.113.113")
        let to = try IPAddress("127.0.0.1")
        let domain = try DNSName("example.com")

        try packetFilter.createRedirectRule(from: from, to: to, domain: domain)

        let dnsAnchorPath = tempPath.appending(PacketFilter.anchor)
        let dnsDirectives = [
            "scrub-anchor \"\(PacketFilter.anchor)\"",
            "nat-anchor \"\(PacketFilter.anchor)\"",
            "rdr-anchor \"\(PacketFilter.anchor)\"",
            "dummynet-anchor \"\(PacketFilter.anchor)\"",
            "anchor \"\(PacketFilter.anchor)\"",
            "load anchor \"\(PacketFilter.anchor)\" from \"\(dnsAnchorPath.string)\"",
        ]
        var configLines = try String(contentsOfFile: configPath.string, encoding: .utf8)
            .components(separatedBy: .newlines)
        #expect(dnsDirectives.allSatisfy(configLines.contains))

        try packetFilter.removeRedirectRule(from: from, to: to, domain: domain)

        configLines = try String(contentsOfFile: configPath.string, encoding: .utf8)
            .components(separatedBy: .newlines)
        #expect(preservedDirectives.allSatisfy(configLines.contains))
        #expect(dnsDirectives.allSatisfy { !configLines.contains($0) })
    }

    @Test
    func testUsesSharedPFAdvisoryLockPath() {
        #expect(PacketFilter.advisoryLockPath == "/var/run/com.apple.container.pf.lock")
    }

    @Test
    func testRejectsCrossFamilyRedirect() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = FilePath(directory.path)
        let packetFilter = PacketFilter(
            configPath: path.appending("pf.conf"),
            anchorsPath: path,
            advisoryLockPath: path.appending("pf.lock").string
        )
        let ipv4 = try IPAddress("127.0.0.1")
        let ipv6 = try IPAddress("::1")
        let domain = try DNSName("example.com")

        #expect(throws: ContainerizationError.self) {
            try packetFilter.createRedirectRule(from: ipv6, to: ipv4, domain: domain)
        }
        #expect(throws: ContainerizationError.self) {
            try packetFilter.removeRedirectRule(from: ipv4, to: ipv6, domain: domain)
        }
    }

    @Test
    func testMutationLockSerializesPacketFilterInstances() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = FilePath(directory.path)
        let lockPath = path.appending("pf.lock").string
        let first = PacketFilter(configPath: path.appending("first.conf"), anchorsPath: path, advisoryLockPath: lockPath)
        let second = PacketFilter(configPath: path.appending("second.conf"), anchorsPath: path, advisoryLockPath: lockPath)
        let firstEntered = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let secondEntered = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let queue = DispatchQueue(label: "PacketFilterTest.mutation-lock", attributes: .concurrent)
        defer {
            releaseFirst.signal()
            queue.sync(flags: .barrier) {}
            try? FileManager.default.removeItem(at: directory)
        }

        queue.async {
            try! first.withMutationLock {
                firstEntered.signal()
                releaseFirst.wait()
            }
            finished.signal()
        }
        let firstResult = firstEntered.wait(timeout: .now() + 10)
        #expect(firstResult == .success)
        guard firstResult == .success else {
            releaseFirst.signal()
            return
        }

        queue.async {
            try! second.withMutationLock {
                _ = secondEntered.signal()
            }
            finished.signal()
        }
        #expect(secondEntered.wait(timeout: .now() + 0.1) == .timedOut)

        releaseFirst.signal()
        #expect(secondEntered.wait(timeout: .now() + 10) == .success)
        #expect(finished.wait(timeout: .now() + 10) == .success)
        #expect(finished.wait(timeout: .now() + 10) == .success)
    }
}
