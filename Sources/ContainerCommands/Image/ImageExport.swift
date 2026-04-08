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
import ContainerizationOCI
import Foundation

extension Application {
    public struct ImageExport: AsyncLoggableCommand {
        public init() {}

        public static let configuration = CommandConfiguration(
            commandName: "export",
            abstract: "Export a macOS sandbox image as a runnable VM directory"
        )

        @Option(
            name: .shortAndLong,
            help: "Output directory for Disk.img/AuxiliaryStorage/HardwareModel.bin",
            completion: .directory,
            transform: { str in
                URL(fileURLWithPath: str, relativeTo: .currentDirectory()).absoluteURL
            }
        )
        var output: URL

        @Option(
            help: "Platform to export (format: os/arch[/variant], default: darwin/arm64)"
        )
        var platform: String?

        @Flag(name: .long, help: "Overwrite the output directory if it already exists")
        var overwrite = false

        @OptionGroup
        public var logOptions: Flags.Logging

        @Argument(help: "Image reference to export")
        var reference: String

        public func run() async throws {
            let exportPlatform: Platform
            if let platform {
                exportPlatform = try Platform(from: platform)
            } else {
                exportPlatform = Platform(arch: "arm64", os: "darwin")
            }
            let image = try await ClientImage.get(reference: reference)
            try await image.exportMacOSImageDirectory(
                to: output,
                platform: exportPlatform,
                overwriteExisting: overwrite
            )
            print(output.standardizedFileURL.path)
        }
    }
}
