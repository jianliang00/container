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

@testable import ContainerCRI
@testable import ContainerCRIShimMacOS

struct CRIShimRuntimeServerTests {
    @Test
    func runnerCreatesServerAndRunsItAfterValidation() async throws {
        let config = try JSONDecoder().decode(CRIShimConfig.self, from: Data(validConfigJSON.utf8))
        let factory = RecordingServerFactory()
        let runner = CRIShimRunner(config: config, serverFactory: factory)

        try await runner.run()

        #expect(factory.makeServerCallCount == 1)
        #expect(factory.receivedRuntimeEndpoint == "/var/run/container-cri-macos.sock")
        #expect(factory.server.runCallCount == 1)
    }

    @Test
    func unixDomainSocketListenerStartsAndStopsCleanly() async throws {
        let socketPath = "/tmp/cri-shim-\(UUID().uuidString.prefix(8)).sock"
        let listener = try CRIShimUnixDomainSocketListener(socketPath: socketPath)

        try await listener.start()

        #expect(FileManager.default.fileExists(atPath: socketPath))

        await listener.stop()

        #expect(!FileManager.default.fileExists(atPath: socketPath))
    }

    @Test
    func runtimeOperationSurfaceHasDeterministicUnsupportedMessages() {
        for operation in CRIRuntimeOperationSurface.all {
            let disposition = DeterministicUnsupportedCRIRuntimeService().disposition(for: operation)
            #expect(disposition.kind == .unsupported)
            #expect(!disposition.detail.isEmpty)
        }
        #expect(CRIRuntimeOperationSurface.all.contains(.version))
        #expect(CRIRuntimeOperationSurface.all.contains(.status))
        #expect(CRIRuntimeOperationSurface.all.contains(.runPodSandbox))
        #expect(CRIRuntimeOperationSurface.all.contains(.stopPodSandbox))
        #expect(CRIRuntimeOperationSurface.all.contains(.portForward))
    }
}

private final class RecordingServerFactory: CRIShimServerFactory, @unchecked Sendable {
    private(set) var makeServerCallCount = 0
    private(set) var receivedRuntimeEndpoint: String?
    private(set) var server = RecordingServer()

    func makeServer(config: CRIShimConfig) throws -> any CRIShimServerLifecycle {
        makeServerCallCount += 1
        receivedRuntimeEndpoint = config.normalizedRuntimeEndpoint
        return server
    }
}

private final class RecordingServer: CRIShimServerLifecycle, @unchecked Sendable {
    private(set) var runCallCount = 0
    private(set) var stopCallCount = 0

    func run() async throws {
        runCallCount += 1
    }

    func stop() async {
        stopCallCount += 1
    }
}

private let validConfigJSON = """
    {
      "runtimeEndpoint": "/var/run/container-cri-macos.sock",
      "streaming": {
        "address": "127.0.0.1",
        "port": 0
      },
      "cni": {
        "binDir": "/opt/cni/bin",
        "confDir": "/etc/cni/net.d",
        "plugin": "macvmnet"
      },
      "defaults": {
        "sandboxImage": "localhost/macos-sandbox:latest",
        "workloadPlatform": {
          "os": "darwin",
          "architecture": "arm64"
        },
        "network": "default",
        "networkBackend": "vmnetShared",
        "guiEnabled": false
      },
      "runtimeHandlers": {
        "macos": {
          "sandboxImage": "localhost/macos-sandbox:latest",
          "network": "default",
          "networkBackend": "vmnetShared",
          "guiEnabled": false
        }
      },
      "networkPolicy": {
        "enabled": true,
        "kubeconfig": "/etc/kubernetes/kubelet.conf",
        "nodeName": "macos-node-1",
        "resyncSeconds": 30
      },
      "kubeProxy": {
        "enabled": true,
        "configPath": "/etc/kubernetes/kube-proxy.conf"
      }
    }
    """
