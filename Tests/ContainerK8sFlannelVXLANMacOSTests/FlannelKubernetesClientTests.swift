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

import Foundation
import Testing

@testable import ContainerK8sFlannelVXLANMacOS

struct FlannelKubernetesClientTests {
    @Test
    func usesNodeClientCertificateOnlyForOwnNodeAnnotationWrites() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("flannel-node-writer-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let certificateAuthority = Data("node-ca".utf8)
        let clientCertificate = Data("node-client-certificate".utf8)
        let clientKey = Data("node-client-key".utf8)
        let kubeconfigURL = directory.appendingPathComponent("kubelet.conf")
        let kubeconfig = """
            apiVersion: v1
            clusters:
            - cluster:
                certificate-authority-data: \(certificateAuthority.base64EncodedString())
                server: https://cluster.example:6443
              name: cluster
            contexts:
            - context:
                cluster: cluster
                user: kubelet
              name: kubelet
            current-context: kubelet
            users:
            - name: kubelet
              user:
                client-certificate-data: \(clientCertificate.base64EncodedString())
                client-key-data: \(clientKey.base64EncodedString())
                token: must-not-authorize-node-writes
            """
        try kubeconfig.write(to: kubeconfigURL, atomically: true, encoding: .utf8)
        let transport = RecordingNodeAnnotationTransport()
        let client = try FlannelKubernetesClient(
            readConfig: .init(server: URL(string: "https://cluster.example:6443")!, bearerToken: "read-only-token"),
            nodeKubeconfigPath: kubeconfigURL.path,
            nodeName: "mac-a",
            nodeTransport: transport
        )

        let patchedNode = try await client.patchOwnNodeAnnotations(
            FlannelNodeAnnotationPatch(values: ["flannel.alpha.coreos.com/backend-type": "vxlan"])
        )
        let request = try #require(await transport.onlyRequest())
        let root = try #require(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        let metadata = try #require(root["metadata"] as? [String: Any])
        let annotations = try #require(metadata["annotations"] as? [String: Any])

        #expect(patchedNode.metadata.name == "mac-a")
        #expect(request.url.absoluteString == "https://cluster.example:6443/api/v1/nodes/mac-a/status")
        #expect(request.certificateAuthorityDER == certificateAuthority)
        #expect(request.clientCertificate == clientCertificate)
        #expect(request.clientKey == clientKey)
        #expect(annotations["flannel.alpha.coreos.com/backend-type"] as? String == "vxlan")
    }

    @Test
    func rejectsHTTPReadKubeconfigBeforeUsingServiceAccountToken() throws {
        #expect(
            throws: FlannelVXLANError.invalidConfiguration(
                "read kubeconfig Kubernetes API server must use HTTPS"
            )
        ) {
            try FlannelKubernetesClient(
                readConfig: .init(server: URL(string: "http://cluster.example:6443")!, bearerToken: "secret"),
                nodeKubeconfigPath: "/etc/kubernetes/kubelet.conf",
                nodeName: "mac-a"
            )
        }
    }

    @Test
    func rendersFlannelLeaseAsNodeAnnotationMergePatch() throws {
        let patch = try FlannelKubernetesClient.leaseAnnotationPatch(
            annotationPrefix: "network.example.com/flannel",
            publicIP: "192.0.2.9",
            vni: 4096,
            vtepMAC: "02-AA-BB-CC-DD-EE"
        )
        let data = try FlannelKubernetesClient.annotationMergePatchData(patch)
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let metadata = try #require(root["metadata"] as? [String: Any])
        let annotations = try #require(metadata["annotations"] as? [String: Any])

        #expect(annotations["network.example.com/flannel-kube-subnet-manager"] as? String == "true")
        #expect(annotations["network.example.com/flannel-backend-type"] as? String == "vxlan")
        #expect(annotations["network.example.com/flannel-public-ip"] as? String == "192.0.2.9")

        let backendDataString = try #require(annotations["network.example.com/flannel-backend-data"] as? String)
        let backendData = try JSONDecoder().decode(FlannelBackendLeaseData.self, from: Data(backendDataString.utf8))
        #expect(backendData.vni == 4096)
        #expect(backendData.vtepMAC == "02:aa:bb:cc:dd:ee")
    }

    @Test
    func rendersAnnotationRemovalAsJSONNull() throws {
        let patch = FlannelNodeAnnotationPatch(
            values: ["flannel.alpha.coreos.com/backend-type": "vxlan"],
            removals: ["flannel.alpha.coreos.com/backend-data"]
        )

        let data = try FlannelKubernetesClient.annotationMergePatchData(patch)
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let metadata = try #require(root["metadata"] as? [String: Any])
        let annotations = try #require(metadata["annotations"] as? [String: Any])

        #expect(annotations["flannel.alpha.coreos.com/backend-type"] as? String == "vxlan")
        #expect(annotations["flannel.alpha.coreos.com/backend-data"] is NSNull)
    }

    @Test
    func preventsAmbiguousAnnotationPatch() {
        let patch = FlannelNodeAnnotationPatch(values: ["example.com/key": "value"], removals: ["example.com/key"])

        #expect(
            throws: FlannelVXLANError.invalidConfiguration(
                "an annotation cannot be set and removed in one patch"
            )
        ) {
            try FlannelKubernetesClient.annotationMergePatchData(patch)
        }
    }

    @Test
    func matchesDefaultFlannelAnnotationNames() throws {
        let keys = try FlannelAnnotationKeys(prefix: "flannel.alpha.coreos.com")

        #expect(keys.prefix == "flannel.alpha.coreos.com/")
        #expect(keys.kubeSubnetManager == "flannel.alpha.coreos.com/kube-subnet-manager")
        #expect(keys.backendData == "flannel.alpha.coreos.com/backend-data")
        #expect(keys.backendType == "flannel.alpha.coreos.com/backend-type")
        #expect(keys.publicIP == "flannel.alpha.coreos.com/public-ip")
    }
}

private actor RecordingNodeAnnotationTransport: FlannelNodeAnnotationTransport {
    private var requests: [FlannelNodePatchRequest] = []

    func patch(_ request: FlannelNodePatchRequest) async throws -> Data {
        requests.append(request)
        return try JSONEncoder().encode(
            FlannelNode(
                metadata: FlannelObjectMeta(name: "mac-a"),
                spec: FlannelNodeSpec(podCIDR: "10.250.22.0/24")
            ))
    }

    func onlyRequest() -> FlannelNodePatchRequest? {
        requests.count == 1 ? requests[0] : nil
    }
}
