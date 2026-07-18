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
import ContainerRuntimeClient
import ContainerXPC
import Foundation
import Logging

extension RuntimeMacOSHelper {
    struct Start: AsyncParsableCommand {
        static let label = "com.apple.container.runtime.container-runtime-macos"

        static let configuration = CommandConfiguration(
            commandName: "start",
            abstract: "Start helper for a macOS guest container"
        )

        @Flag(name: .long, help: "Enable debug logging")
        var debug = false

        @Option(name: .shortAndLong, help: "Sandbox UUID")
        var uuid: String

        @Option(name: .shortAndLong, help: "Root directory for the sandbox")
        var root: String

        var machServiceLabel: String {
            "\(Self.label).\(uuid)"
        }

        func run() async throws {
            let commandName = Self._commandName
            let log = RuntimeMacOSHelper.setupLogger(debug: debug, metadata: ["uuid": "\(uuid)"])

            log.info("starting \(commandName)")
            defer {
                log.info("stopping \(commandName)")
            }

            do {
                try adjustLimits()
                signal(SIGPIPE, SIG_IGN)

                nonisolated(unsafe) let anonymousConnection = xpc_connection_create(nil, nil)
                let service = MacOSSandboxService(
                    root: .init(fileURLWithPath: root),
                    log: log
                )

                let endpointServer = XPCServer(
                    identifier: machServiceLabel,
                    routes: [
                        RuntimeRoutes.createEndpoint.rawValue: XPCServer.route { message in
                            let endpoint = xpc_endpoint_create(anonymousConnection)
                            let reply = message.reply()
                            reply.set(key: RuntimeKeys.runtimeServiceEndpoint.rawValue, value: endpoint)
                            return reply
                        }
                    ],
                    log: log
                )

                let mainServer = XPCServer(
                    connection: anonymousConnection,
                    routes: [
                        RuntimeRoutes.createSandbox.rawValue: XPCServer.route(service.createSandbox),
                        RuntimeRoutes.startSandbox.rawValue: XPCServer.route(service.startSandbox),
                        RuntimeRoutes.showGUI.rawValue: XPCServer.route(service.showGUI),
                        RuntimeRoutes.bootstrap.rawValue: XPCServer.route(service.bootstrap),
                        RuntimeRoutes.createWorkload.rawValue: XPCServer.route(service.createWorkload),
                        RuntimeRoutes.startWorkload.rawValue: XPCServer.route(service.startWorkload),
                        RuntimeRoutes.attachWorkload.rawValue: XPCServer.route(service.attachWorkload),
                        RuntimeRoutes.detachWorkloadAttachment.rawValue: XPCServer.route(service.detachWorkloadAttachment),
                        RuntimeRoutes.stopWorkload.rawValue: XPCServer.route(service.stopWorkload),
                        RuntimeRoutes.removeWorkload.rawValue: XPCServer.route(service.removeWorkload),
                        RuntimeRoutes.createProcess.rawValue: XPCServer.route(service.createProcess),
                        RuntimeRoutes.state.rawValue: XPCServer.route(service.state),
                        RuntimeRoutes.inspectWorkload.rawValue: XPCServer.route(service.inspectWorkload),
                        RuntimeRoutes.stop.rawValue: XPCServer.route(service.stop),
                        RuntimeRoutes.kill.rawValue: XPCServer.route(service.kill),
                        RuntimeRoutes.resize.rawValue: XPCServer.route(service.resize),
                        RuntimeRoutes.wait.rawValue: XPCServer.route(service.wait),
                        RuntimeRoutes.start.rawValue: XPCServer.route(service.startProcess),
                        RuntimeRoutes.dial.rawValue: XPCServer.route(service.dial),
                        RuntimeRoutes.fsBegin.rawValue: XPCServer.route(service.fsBegin),
                        RuntimeRoutes.fsChunk.rawValue: XPCServer.route(service.fsChunk),
                        RuntimeRoutes.fsEnd.rawValue: XPCServer.route(service.fsEnd),
                        RuntimeRoutes.fsReadBegin.rawValue: XPCServer.route(service.fsReadBegin),
                        RuntimeRoutes.fsReadChunk.rawValue: XPCServer.route(service.fsReadChunk),
                        RuntimeRoutes.fsReadEnd.rawValue: XPCServer.route(service.fsReadEnd),
                        RuntimeRoutes.fsListDir.rawValue: XPCServer.route(service.fsListDir),
                        RuntimeRoutes.prepareNetwork.rawValue: XPCServer.route(service.prepareSandboxNetwork),
                        RuntimeRoutes.inspectNetwork.rawValue: XPCServer.route(service.inspectSandboxNetwork),
                        RuntimeRoutes.releaseNetwork.rawValue: XPCServer.route(service.releaseSandboxNetwork),
                        RuntimeRoutes.applyNetworkPolicy.rawValue: XPCServer.route(service.applySandboxPolicy),
                        RuntimeRoutes.removeNetworkPolicy.rawValue: XPCServer.route(service.removeSandboxPolicy),
                        RuntimeRoutes.inspectNetworkPolicy.rawValue: XPCServer.route(service.inspectSandboxPolicy),
                        RuntimeRoutes.shutdown.rawValue: XPCServer.route(service.shutdown),
                        RuntimeRoutes.statistics.rawValue: XPCServer.route(service.statistics),
                    ],
                    log: log
                )

                log.info("starting XPC server")
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        try await endpointServer.listen()
                    }
                    group.addTask {
                        try await mainServer.listen()
                    }
                    defer { group.cancelAll() }
                    _ = try await group.next()
                }
            } catch {
                log.error("\(commandName) failed", metadata: ["error": "\(error)"])
                RuntimeMacOSHelper.Start.exit(withError: error)
            }
        }

        private func adjustLimits() throws {
            var limits = rlimit()
            guard getrlimit(RLIMIT_NOFILE, &limits) == 0 else {
                throw POSIXError(.init(rawValue: errno)!)
            }
            limits.rlim_cur = 65536
            limits.rlim_max = 65536
            guard setrlimit(RLIMIT_NOFILE, &limits) == 0 else {
                throw POSIXError(.init(rawValue: errno)!)
            }
        }
    }
}
