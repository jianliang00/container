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

@testable import container_macos_guest_agent

struct GuestNetworkConfiguratorTests {
    @Test
    func parsesIfconfigOutputByMACAddress() throws {
        let output = """
            en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
            \toptions=6463<RXCSUM,TXCSUM,TSO4,TSO6,CHANNEL_IO,PARTIAL_CSUM,ZEROINVERT_CSUM>
            \tether 02:42:ac:11:00:02
            \tinet6 fe80::1%en0 prefixlen 64 secured scopeid 0x4
            bridge100: flags=41<UP,RUNNING> mtu 1500
            \tether 12:34:56:78:9a:bc
            """

        let mapping = try GuestNetworkConfigurator.parseInterfaceNamesByMAC(from: output)

        #expect(mapping["02:42:ac:11:00:02"] == "en0")
        #expect(mapping["12:34:56:78:9a:bc"] == "bridge100")
    }

    @Test
    func parsesNetworkServiceOrderByDevice() throws {
        let output = """
            An asterisk (*) denotes that a network service is disabled.
            (1) Wi-Fi
            (Hardware Port: Wi-Fi, Device: en0)

            (2) USB LAN
            (Hardware Port: USB 10/100/1000 LAN, Device: en7)
            """

        let mapping = try GuestNetworkConfigurator.parseNetworkServicesByDevice(from: output)

        #expect(mapping["en0"] == "Wi-Fi")
        #expect(mapping["en7"] == "USB LAN")
    }

    @Test
    func appliesDomainAsFirstSearchDomainAndWarnsAboutUnsupportedOptions() throws {
        let request = MacOSGuestNetworkConfigurationRequest(
            interfaces: [
                .init(
                    networkID: "default",
                    hostname: "guest-1",
                    macAddress: "02:42:ac:11:00:02",
                    ipv4Address: "192.168.64.2",
                    ipv4PrefixLength: 24,
                    ipv4Gateway: "192.168.64.1"
                )
            ],
            dns: .init(
                nameservers: ["192.168.64.1"],
                domain: "cluster.local",
                searchDomains: ["svc.cluster.local"],
                options: ["ndots:5"]
            )
        )

        let recorder = CommandRecorder()
        let configurator = GuestNetworkConfigurator { executable, arguments in
            recorder.record(executable: executable, arguments: arguments)
            switch (executable, arguments) {
            case ("/sbin/ifconfig", ["-a"]):
                return .init(
                    stdout: """
                        en0: flags=8863<UP,BROADCAST,RUNNING> mtu 1500
                        \tether 02:42:ac:11:00:02
                        """,
                    stderr: "",
                    exitCode: 0
                )
            case ("/usr/sbin/networksetup", ["-listnetworkserviceorder"]):
                return .init(
                    stdout: """
                        (1) Ethernet
                        (Hardware Port: Ethernet, Device: en0)
                        """,
                    stderr: "",
                    exitCode: 0
                )
            default:
                return .init(stdout: "", stderr: "", exitCode: 0)
            }
        }

        let result = try configurator.apply(request)

        #expect(result.dnsApplied)
        #expect(result.warnings == ["dns options are not yet applied inside the macOS guest"])
        let commands = recorder.commands()
        #expect(commands.contains { $0.executable == "/usr/sbin/networksetup" && $0.arguments == ["-setsearchdomains", "Ethernet", "cluster.local", "svc.cluster.local"] })
    }
}

extension GuestNetworkConfiguratorTests {
    private final class CommandRecorder: @unchecked Sendable {
        struct Command: Equatable {
            let executable: String
            let arguments: [String]
        }

        private let lock = NSLock()
        private var stored: [Command] = []

        func record(executable: String, arguments: [String]) {
            lock.lock()
            defer { lock.unlock() }
            stored.append(.init(executable: executable, arguments: arguments))
        }

        func commands() -> [Command] {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
    }
}
#endif
