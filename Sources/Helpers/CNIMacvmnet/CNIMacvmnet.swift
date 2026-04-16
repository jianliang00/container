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

import ContainerCNIMacvmnet
import Darwin
import Foundation

@main
struct CNIMacvmnet {
    static func main() {
        do {
            try run()
        } catch {
            writeError(error)
            exit(EXIT_FAILURE)
        }
    }

    private static func run() throws {
        let environment = ProcessInfo.processInfo.environment
        let command = try CNIEnvironment.parse(environment).command

        if command == .version {
            try writeJSON(CNIVersionResult())
            return
        }

        let stdin = FileHandle.standardInput.readDataToEndOfFile()
        let request = try CNIRequest.parse(environment: environment, stdin: stdin)

        switch request.environment.command {
        case .status:
            throw CNIError.backendUnavailable("STATUS is not ready: container network API health checks are not implemented")
        case .add, .check, .delete, .garbageCollect:
            let plan = MacvmnetOperationPlan(request: request)
            throw CNIError.backendUnavailable("\(plan.command.rawValue) is not wired to container network APIs yet")
        case .version:
            try writeJSON(CNIVersionResult())
        }
    }

    private static func writeJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(0x0a)
        FileHandle.standardOutput.write(data)
    }

    private static func writeError(_ error: Error) {
        let response = CNIErrorResponse(error: error)
        do {
            try writeJSON(response)
        } catch {
            let fallback = #"{"cniVersion":"\#(CNISpec.version)","code":100,"msg":"failed to encode CNI error response"}"#
            FileHandle.standardOutput.write(Data((fallback + "\n").utf8))
        }
    }
}
