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
import ContainerK8sNetworkPolicyMacOS
import Foundation

@main
struct K8sNetworkPolicyMacOS: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "container-k8s-networkpolicy-macos",
        abstract: "Render a compiled endpoint policy snapshot into a sandbox policy JSON document."
    )

    @Option(
        name: [.customLong("input"), .short],
        help: "Path to a CompiledEndpointPolicy JSON snapshot. Reads stdin when omitted."
    )
    var input: String?

    @Flag(name: [.customLong("pretty"), .short], help: "Pretty-print the rendered JSON.")
    var pretty: Bool = false

    func run() throws {
        let data = try readInputData()
        let compiled = try JSONDecoder().decode(CompiledEndpointPolicy.self, from: data)
        let rendered = try compiled.renderedSandboxPolicy()

        let encoder = JSONEncoder()
        if pretty {
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        }
        let output = try encoder.encode(rendered)
        FileHandle.standardOutput.write(output)
        FileHandle.standardOutput.write(Data([0x0a]))
    }

    private func readInputData() throws -> Data {
        if let input {
            return try Data(contentsOf: URL(fileURLWithPath: input))
        }
        return FileHandle.standardInput.readDataToEndOfFile()
    }
}
