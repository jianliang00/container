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

import ContainerMacOSKubeadm
import Foundation
import Testing

struct MacOSKubeadmPlanTests {
    @Test func joinPlanRendersExpectedNodeConfiguration() throws {
        let options = try makeOptions(startServices: false)
        let plan = try MacOSKubeadmPlanner.joinPlan(options: options)

        #expect(
            plan.steps.contains { step in
                guard case .writeFile(let path, let contents, 0o644, false) = step.action else {
                    return false
                }
                return path == "/tmp/macos-node/etc/kubernetes/pki/ca.crt"
                    && contents.contains("BEGIN CERTIFICATE")
            })

        #expect(
            plan.steps.contains { step in
                guard case .writeFile(let path, let contents, 0o644, false) = step.action else {
                    return false
                }
                return path == "/tmp/macos-node/etc/kubernetes/kube-proxy.conf"
                    && contents.contains(#""nodeName": "macos-ci-1""#)
            })

        #expect(
            plan.steps.contains { step in
                guard case .writeFile(let path, let contents, 0o644, false) = step.action else {
                    return false
                }
                return path == "/tmp/macos-node/Library/LaunchDaemons/com.apple.container.kubelet.plist"
                    && contents.contains("<string>macos-ci-1</string>")
                    && contents.contains("<string>localhost/macos-sandbox:test</string>")
            })

        #expect(
            plan.steps.contains { step in
                guard case .writeFile(let path, let contents, 0o644, false) = step.action else {
                    return false
                }
                return path == "/tmp/macos-node/etc/kubernetes/kubelet-config.yaml"
                    && contents.contains("clusterDNS:")
                    && contents.contains(#""10.96.0.53""#)
                    && contents.contains("enforceNodeAllocatable: []")
                    && contents.contains(#"memory.available: "0%""#)
                    && contents.contains(#""name": "default""#)
                    && !contents.contains("podLogsDir:")
                    && !contents.contains("failCgroupV1:")
            })
    }

    @Test func kubeconfigsAreMarkedSensitive() throws {
        let options = try makeOptions(startServices: false)
        let plan = try MacOSKubeadmPlanner.joinPlan(options: options)
        let kubeconfigSteps = plan.steps.filter { step in
            guard case .writeFile(let path, _, _, _) = step.action else {
                return false
            }
            return path.hasSuffix(".kubeconfig")
        }

        #expect(kubeconfigSteps.count == 2)
        for step in kubeconfigSteps {
            guard case .writeFile(_, let contents, 0o600, true) = step.action else {
                Issue.record("kubeconfig step should be mode 0600 and sensitive")
                continue
            }
            #expect(contents.contains("token:"))
            #expect(!step.action.safeDescription.contains("abcdef.0123456789abcdef"))
            #expect(!step.action.safeDescription.contains("proxy-token"))
        }
    }

    @Test func serviceStartPlanStartsCRIBeforeKubelet() throws {
        let options = try makeOptions(startServices: true)
        let plan = try MacOSKubeadmPlanner.joinPlan(options: options)
        let descriptions = plan.steps.map(\.message)

        let criIndex = try #require(descriptions.firstIndex(of: "start CRI shim launchd job"))
        let waitIndex = try #require(descriptions.firstIndex(of: "wait for CRI socket"))
        let kubeletIndex = try #require(descriptions.firstIndex(of: "start kubelet launchd job"))

        #expect(criIndex < waitIndex)
        #expect(waitIndex < kubeletIndex)
    }

    @Test func serviceStartPlanUsesRootUserBootstrapForContainerRuntime() throws {
        let options = try makeOptions(startServices: true)
        let plan = try MacOSKubeadmPlanner.joinPlan(options: options)

        #expect(
            plan.steps.contains { step in
                guard step.message == "start container core services",
                    case .runCommand(let arguments, false) = step.action
                else {
                    return false
                }
                return arguments == [
                    "/bin/launchctl",
                    "asuser",
                    "0",
                    "/usr/local/bin/container",
                    "system",
                    "start",
                ]
            })

        #expect(
            plan.steps.contains { step in
                guard step.message == "start CRI shim launchd job",
                    case .runCommand(let arguments, false) = step.action
                else {
                    return false
                }
                return arguments == [
                    "/bin/launchctl",
                    "bootstrap",
                    "system",
                    "/Library/LaunchDaemons/com.apple.container.cri-shim-macos.plist",
                ]
            })

        #expect(
            plan.steps.contains { step in
                guard step.message == "kickstart CRI shim launchd job",
                    case .runCommand(let arguments, false) = step.action
                else {
                    return false
                }
                return arguments == [
                    "/bin/launchctl",
                    "kickstart",
                    "-k",
                    "system/com.apple.container.cri-shim-macos",
                ]
            })

        #expect(
            plan.steps.contains { step in
                guard step.message == "write CRI shim launchd plist",
                    case .writeFile(_, let contents, 0o644, false) = step.action
                else {
                    return false
                }
                return contents.contains("<string>/bin/launchctl</string>")
                    && contents.contains("<string>asuser</string>")
                    && contents.contains("<string>0</string>")
                    && contents.contains("<string>/usr/local/bin/container-cri-shim-macos</string>")
            })
    }

    @Test func joinPlanRequiresDiscoveryHash() throws {
        var options = try makeOptions(startServices: false)
        options.discoveryTokenCACertHashes = []

        #expect(throws: MacOSKubeadmError.invalidInput("--discovery-token-ca-cert-hash is required")) {
            try MacOSKubeadmPlanner.joinPlan(options: options)
        }
    }

    @Test func resetRequiresForceUnlessDryRun() throws {
        #expect(throws: MacOSKubeadmError.invalidInput("reset requires --force unless --dry-run is set")) {
            try MacOSKubeadmPlanner.resetPlan(
                options: MacOSKubeadmResetOptions(
                    installRoot: "/",
                    dryRun: false
                )
            )
        }

        let dryRunPlan = try MacOSKubeadmPlanner.resetPlan(
            options: MacOSKubeadmResetOptions(
                installRoot: "/tmp/macos-node",
                dryRun: true
            )
        )
        #expect(!dryRunPlan.steps.isEmpty)
    }

    @Test func resetStopsServicesBeforeRemovingConfiguration() throws {
        let plan = try MacOSKubeadmPlanner.resetPlan(
            options: MacOSKubeadmResetOptions(
                installRoot: "/",
                force: true
            )
        )
        let descriptions = plan.steps.map(\.message)

        let stopKubeletIndex = try #require(descriptions.firstIndex(of: "stop kubelet launchd job if present"))
        let firstRemoveIndex = try #require(descriptions.firstIndex { $0.hasPrefix("remove ") })

        #expect(stopKubeletIndex < firstRemoveIndex)
    }

    @Test func resetPurgeStateRemovesRuntimeStateRecursively() throws {
        let plan = try MacOSKubeadmPlanner.resetPlan(
            options: MacOSKubeadmResetOptions(
                installRoot: "/tmp/macos-node",
                purgeState: true,
                dryRun: true
            )
        )

        #expect(
            plan.steps.contains { step in
                guard case .removePath(let path, let recursive, let bestEffort, let sensitive) = step.action else {
                    return false
                }
                return path == "/tmp/macos-node/var/lib/kubelet"
                    && recursive
                    && bestEffort
                    && !sensitive
            })
    }

    @Test func resetKubeconfigRemovalIsMarkedSensitive() throws {
        let plan = try MacOSKubeadmPlanner.resetPlan(
            options: MacOSKubeadmResetOptions(
                installRoot: "/tmp/macos-node",
                dryRun: true
            )
        )
        let kubeconfigSteps = plan.steps.filter { step in
            guard case .removePath(let path, _, _, _) = step.action else {
                return false
            }
            return path.hasSuffix(".kubeconfig")
        }

        #expect(kubeconfigSteps.count == 3)
        for step in kubeconfigSteps {
            guard case .removePath(_, let recursive, let bestEffort, let sensitive) = step.action,
                !recursive && bestEffort && sensitive
            else {
                Issue.record("kubeconfig removal should be best-effort and sensitive")
                continue
            }
            #expect(step.action.safeDescription.contains("sensitive"))
            #expect(!step.action.safeDescription.contains("token:"))
        }
    }

    private func makeOptions(startServices: Bool) throws -> MacOSKubeadmJoinOptions {
        try MacOSKubeadmJoinOptions(
            apiServer: #require(URL(string: "https://127.0.0.1:6443")),
            nodeName: "macos-ci-1",
            token: "abcdef.0123456789abcdef",
            discoveryTokenCACertHashes: [String(repeating: "a", count: 64)],
            certificateAuthorityPEM: """
                -----BEGIN CERTIFICATE-----
                dGVzdC1jYQ==
                -----END CERTIFICATE-----

                """,
            kubeProxyToken: "proxy-token",
            clusterDNS: "10.96.0.53",
            sandboxImage: "localhost/macos-sandbox:test",
            installRoot: "/tmp/macos-node",
            startServices: startServices,
            dryRun: true
        )
    }
}
