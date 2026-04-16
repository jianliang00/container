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

    @Option(name: .shortAndLong, help: "Path to the CRI shim JSON config file")
    var config: String

    func run() async throws {
        let configURL = URL(fileURLWithPath: config)
        let shimConfig = try CRIShimConfig.load(from: configURL)
        try shimConfig.validate()

        throw CRIShimStartupError.unimplemented(
            "configuration validated for \(shimConfig.normalizedRuntimeEndpoint ?? "<unknown>"); CRI server startup is not implemented yet because generated CRI protobuf and gRPC bindings have not been added"
        )
    }
}

enum CRIShimStartupError: Error, CustomStringConvertible {
    case unimplemented(String)

    var description: String {
        switch self {
        case .unimplemented(let message):
            return message
        }
    }
}
