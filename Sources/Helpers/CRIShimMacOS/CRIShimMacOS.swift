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

import ArgumentParser
import ContainerCRIShimMacOS
import Foundation

@main
struct CRIShimMacOS: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "container-cri-shim-macos",
        abstract: "Kubernetes CRI shim for macOS guest containers"
    )

    @Option(name: .shortAndLong, help: "Path to the CRI shim JSON config file. Uses the default search path when omitted.")
    var config: String?

    func run() async throws {
        let shimConfig =
            if let config {
                try CRIShimConfig.load(from: URL(fileURLWithPath: config))
            } else {
                try CRIShimConfig.loadFromSearchPath().config
            }
        let runner = CRIShimRunner(config: shimConfig, serverFactory: DefaultCRIShimServerFactory())
        try await runner.run()
    }
}
