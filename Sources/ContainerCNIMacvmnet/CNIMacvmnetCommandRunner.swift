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

import Darwin
import Foundation

public struct CNIMacvmnetExecutionResult: Equatable {
    public var exitCode: Int32
    public var stdout: Data

    public init(exitCode: Int32, stdout: Data) {
        self.exitCode = exitCode
        self.stdout = stdout
    }
}

public struct CNIMacvmnetCommandRunner<Backend: MacvmnetBackend>: Sendable {
    public var handler: MacvmnetOperationHandler<Backend>

    public init(handler: MacvmnetOperationHandler<Backend>) {
        self.handler = handler
    }

    public init(backend: Backend) {
        self.init(handler: MacvmnetOperationHandler(backend: backend))
    }

    public func execute(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        stdin: Data
    ) async -> CNIMacvmnetExecutionResult {
        do {
            return try await executeThrowing(environment: environment, stdin: stdin)
        } catch {
            return CNIMacvmnetExecutionResult(
                exitCode: Int32(EXIT_FAILURE),
                stdout: Self.renderError(error)
            )
        }
    }

    public func executeThrowing(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        stdin: Data
    ) async throws -> CNIMacvmnetExecutionResult {
        let command = try CNIEnvironment.parse(environment).command

        if command == .version {
            return CNIMacvmnetExecutionResult(
                exitCode: EXIT_SUCCESS,
                stdout: try Self.renderJSON(CNIVersionResult())
            )
        }

        let request = try CNIRequest.parse(environment: environment, stdin: stdin)

        switch request.environment.command {
        case .status:
            _ = try await handler.handle(request)
            return CNIMacvmnetExecutionResult(exitCode: EXIT_SUCCESS, stdout: Data())
        case .add, .check, .delete, .garbageCollect:
            let output =
                if let result = try await handler.handle(request) {
                    try Self.renderJSON(result)
                } else {
                    Data()
                }
            return CNIMacvmnetExecutionResult(exitCode: EXIT_SUCCESS, stdout: output)
        case .version:
            return CNIMacvmnetExecutionResult(
                exitCode: EXIT_SUCCESS,
                stdout: try Self.renderJSON(CNIVersionResult())
            )
        }
    }

    public static func renderJSON<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(0x0a)
        return data
    }

    public static func renderError(_ error: Error) -> Data {
        let response = CNIErrorResponse(error: error)
        do {
            return try renderJSON(response)
        } catch {
            return Data(
                (#"{"cniVersion":"\#(CNISpec.version)","code":100,"msg":"failed to encode CNI error response"}"# + "\n").utf8
            )
        }
    }
}
