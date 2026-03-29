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

import ContainerKit
import ContainerPlugin
import Foundation

struct ContainerKitServicesDependencies: Sendable {
    let createDirectory: @Sendable (URL) throws -> Void
    let writeData: @Sendable (Data, URL) throws -> Void
    let registerService: @Sendable (String) throws -> Void
    let deregisterService: @Sendable (String) throws -> Void
    let enumerateServices: @Sendable () throws -> [String]
    let isServiceRegistered: @Sendable (String) throws -> Bool
    let domainString: @Sendable () throws -> String
    let healthCheck: @Sendable (Duration?) async throws -> SystemHealth
    let listContainers: @Sendable () async throws -> [ContainerSnapshot]
    let stopContainer: @Sendable (String, ContainerStopOptions) async throws -> Void
    let sleep: @Sendable (Duration) async throws -> Void
    let runLaunchctl: @Sendable ([String]) throws -> (status: Int32, output: String)
}

extension ContainerKitServicesDependencies {
    static func live() -> Self {
        let kit = ContainerKit()

        return Self(
            createDirectory: { url in
                try FileManager.default.createDirectory(
                    at: url,
                    withIntermediateDirectories: true
                )
            },
            writeData: { data, url in
                try data.write(to: url)
            },
            registerService: { plistPath in
                try ServiceManager.register(plistPath: plistPath)
            },
            deregisterService: { fullServiceLabel in
                try ServiceManager.deregister(fullServiceLabel: fullServiceLabel)
            },
            enumerateServices: {
                try ServiceManager.enumerate()
            },
            isServiceRegistered: { label in
                try ServiceManager.isRegistered(fullServiceLabel: label)
            },
            domainString: {
                try ServiceManager.getDomainString()
            },
            healthCheck: { timeout in
                try await kit.health(timeout: timeout)
            },
            listContainers: {
                try await kit.listContainers()
            },
            stopContainer: { id, options in
                try await kit.stopContainer(id: id, options: options)
            },
            sleep: { duration in
                try await Task.sleep(for: duration)
            },
            runLaunchctl: { args in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
                process.arguments = args

                let outputPipe = Pipe()
                process.standardOutput = outputPipe
                process.standardError = outputPipe

                try process.run()
                let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()

                return (
                    status: process.terminationStatus,
                    output: String(data: outputData, encoding: .utf8) ?? ""
                )
            }
        )
    }
}
