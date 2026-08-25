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
import Darwin
import Foundation

@main
struct MacOSNodeStatus: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "container-macos-node-status",
        abstract: "Export validated macOS Kubernetes node status as Prometheus text."
    )

    func run() throws {
        guard geteuid() == 0 else {
            throw ValidationError("container-macos-node-status must run as root")
        }
        let nodeConfig = try MacOSNodeStatusConfigFile().load()
        let output = try MacOSNodeStatusCollector().render(config: nodeConfig)
        try FileHandle.standardOutput.write(contentsOf: Data(output.utf8))
    }
}
