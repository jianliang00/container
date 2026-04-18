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

import ContainerCRI
import GRPC
import Logging

public struct CRIShimGRPCHandlerLogger: Sendable {
    public var logger: Logger
    public var service: String

    public init(
        service: String,
        logger: Logger? = nil
    ) {
        self.service = service
        self.logger = logger ?? Logger(label: "com.apple.container.cri-shim.\(service)")
    }

    public static func runtimeService() -> CRIShimGRPCHandlerLogger {
        CRIShimGRPCHandlerLogger(service: "runtime")
    }

    public static func imageService() -> CRIShimGRPCHandlerLogger {
        CRIShimGRPCHandlerLogger(service: "image")
    }

    public func handle<Response>(
        operation: String,
        metadata: Logger.Metadata = [:],
        _ body: () async throws -> Response
    ) async throws -> Response {
        var started = metadata
        started["cri.service"] = "\(service)"
        started["cri.operation"] = "\(operation)"
        logger.debug("handling CRI RPC", metadata: started)

        do {
            let response = try await body()
            var completed = started
            completed["cri.status"] = "ok"
            logger.debug("handled CRI RPC", metadata: completed)
            return response
        } catch {
            let status = CRIShimGRPCStatusMapper.status(for: error)
            var failed = started
            failed["cri.status"] = "error"
            failed["grpc.code"] = "\(status.code)"
            if let message = status.message {
                failed["error.message"] = "\(message)"
            }
            logger.debug("failed CRI RPC", metadata: failed)
            throw status
        }
    }
}

func unsupportedRuntime<Response>(
    _ operation: CRIRuntimeOperation
) async throws -> Response {
    try await CRIShimGRPCHandlerLogger.runtimeService().handle(operation: operation.rawValue) {
        throw CRIShimGRPCStatusMapper.unsupportedError(operation)
    }
}

func unsupportedImage<Response>(
    _ operation: CRIImageOperation
) async throws -> Response {
    try await CRIShimGRPCHandlerLogger.imageService().handle(operation: operation.rawValue) {
        throw CRIShimGRPCStatusMapper.unsupportedError(operation)
    }
}
