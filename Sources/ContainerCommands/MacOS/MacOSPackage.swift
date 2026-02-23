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
import ContainerAPIClient
import Foundation

extension Application {
    public struct MacOSPackage: AsyncLoggableCommand {
        public init() {}

        public static let configuration = CommandConfiguration(
            commandName: "package",
            abstract: "Package a macOS image directory as an OCI layout tar"
        )

        @Option(
            name: .shortAndLong,
            help: "Path to an image directory containing Disk.img/AuxiliaryStorage/HardwareModel.bin",
            completion: .directory,
            transform: { str in
                URL(fileURLWithPath: str, relativeTo: .currentDirectory()).absoluteURL
            }
        )
        var input: URL

        @Option(
            name: .shortAndLong,
            help: "Output OCI layout tar path",
            completion: .file(),
            transform: { str in
                URL(fileURLWithPath: str, relativeTo: .currentDirectory()).absoluteURL
            }
        )
        var output: URL

        @Option(name: .long, help: "Optional OCI ref name annotation for index.json")
        var reference: String?

        @OptionGroup
        public var logOptions: Flags.Logging

        public func run() async throws {
            try MacOSImagePackager.package(
                imageDirectory: input,
                outputTar: output,
                reference: reference
            )
            print(output.path)
        }
    }
}
