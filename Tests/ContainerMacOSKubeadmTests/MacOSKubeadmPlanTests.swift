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

    private func makeOptions(startServices: Bool) throws -> MacOSKubeadmJoinOptions {
        try MacOSKubeadmJoinOptions(
            apiServer: #require(URL(string: "https://127.0.0.1:6443")),
            nodeName: "macos-ci-1",
            bootstrapToken: "abcdef.0123456789abcdef",
            kubeProxyToken: "proxy-token",
            caCertificatePath: "/tmp/ca.crt",
            clusterDNS: "10.96.0.53",
            sandboxImage: "localhost/macos-sandbox:test",
            installRoot: "/tmp/macos-node",
            startServices: startServices,
            dryRun: true
        )
    }
}
