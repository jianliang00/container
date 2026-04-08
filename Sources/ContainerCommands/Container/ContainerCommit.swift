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
import TerminalProgress

extension Application {
    public struct ContainerCommit: AsyncLoggableCommand {
        public init() {}

        public static let configuration = CommandConfiguration(
            commandName: "commit",
            abstract: "Commit a macOS guest container into a local sandbox image"
        )

        @Flag(name: .long, help: "Leave a running source container stopped after commit")
        var leaveStopped = false

        @OptionGroup
        public var logOptions: Flags.Logging

        @Argument(help: "Container ID")
        var containerID: String

        @Argument(help: "Target image reference")
        var targetReference: String

        public func run() async throws {
            let progressConfig = try ProgressConfig(description: "Committing container")
            let progress = ProgressBar(config: progressConfig)
            defer {
                progress.finish()
            }
            progress.start()

            try await MacOSContainerCommitter.commit(
                containerID: containerID,
                targetReference: targetReference,
                leaveStopped: leaveStopped,
                progress: { message in
                    progress.set(description: message)
                },
                detail: { message in
                    progress.set(subDescription: message)
                }
            )

            progress.finish()
            print(targetReference)
        }
    }
}
