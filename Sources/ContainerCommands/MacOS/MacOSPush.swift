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
import TerminalProgress

extension Application {
    public struct MacOSPush: AsyncLoggableCommand {
        public init() {}

        public static let configuration = CommandConfiguration(
            commandName: "push",
            abstract: "Package a macOS template and push it as an OCI image"
        )

        @Option(
            name: .shortAndLong,
            help: "Path to a template directory containing Disk.img/AuxiliaryStorage/HardwareModel.bin",
            completion: .directory,
            transform: { str in
                URL(fileURLWithPath: str, relativeTo: .currentDirectory()).absoluteURL
            }
        )
        var input: URL

        @Option(name: .shortAndLong, help: "Destination image reference")
        var reference: String

        @OptionGroup
        var registry: Flags.Registry

        @OptionGroup
        var progressFlags: Flags.Progress

        @OptionGroup
        public var logOptions: Flags.Logging

        public func run() async throws {
            let tempTar = FileManager.default.temporaryDirectory.appendingPathComponent("macos-template-\(UUID().uuidString).tar")
            defer {
                try? FileManager.default.removeItem(at: tempTar)
            }

            try MacOSTemplatePackager.package(templateDirectory: input, outputTar: tempTar, reference: reference)
            let loadResult = try await ClientImage.load(from: tempTar.path, force: false)
            guard let loaded = loadResult.images.first else {
                throw ValidationError("failed to load packaged macOS template image")
            }

            let tagged = try await loaded.tag(new: reference)
            let scheme = try RequestScheme(registry.scheme)
            let platform = try Platform(from: "darwin/arm64")

            var progressConfig: ProgressConfig
            switch self.progressFlags.progress {
            case .none: progressConfig = try ProgressConfig(disableProgressUpdates: true)
            case .ansi:
                progressConfig = try ProgressConfig(
                    description: "Pushing image \(tagged.reference)",
                    itemsName: "blobs",
                    showItems: true,
                    showSpeed: false,
                    ignoreSmallSize: true
                )
            }

            let progress = ProgressBar(config: progressConfig)
            defer {
                progress.finish()
            }
            progress.start()
            try await tagged.push(platform: platform, scheme: scheme, progressUpdate: progress.handler)
            progress.finish()

            print(reference)
        }
    }
}
