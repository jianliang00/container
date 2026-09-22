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

import ContainerizationError
import Foundation
import GRPC
import Testing

@testable import ContainerCRIShimMacOS

struct CRIShimErrorMappingTests {
    @Test
    func runtimeAbsenceRequiresStructuredCauseAndPreservesOtherFailures() {
        let missing = ContainerizationError(.notFound, message: "sandbox is absent")
        let wrapped = ContainerizationError(.internalError, message: "failed to delete container", cause: missing)
        #expect(criRuntimeObjectIsNotFound(missing))
        #expect(criRuntimeObjectIsNotFound(wrapped))
        #expect(criRuntimeObjectIsNotFound(ContainerizationError(.internalError, message: "request failed", cause: wrapped)))
        let failures: [any Error] = [
            POSIXError(.ENOENT), POSIXError(.EACCES), POSIXError(.ECONNREFUSED),
            ContainerizationError(.timeout, message: "transport timed out", cause: missing),
            ContainerizationError(.internalError, message: "notFound: text is not a typed cause"),
            ContainerizationError(.internalError, message: "permission denied", cause: POSIXError(.EACCES)),
            NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES), userInfo: [NSUnderlyingErrorKey: missing]),
        ]
        for error in failures { #expect(!criRuntimeObjectIsNotFound(error)) }
        // The generic status mapper remains unchanged; only cleanup uses the
        // causal runtime-absence classifier.
        #expect(CRIShimErrorMapper.disposition(for: wrapped).kind == .internalError)
    }

    @Test
    func mapsUnsupportedInvalidArgumentNotFoundAndInternalErrors() {
        #expect(CRIShimErrorMapper.disposition(for: CRIShimError.unsupported("unsupported")).kind == .unsupported)
        #expect(CRIShimErrorMapper.disposition(for: CRIShimError.invalidArgument("invalid")).kind == .invalidArgument)
        #expect(CRIShimErrorMapper.disposition(for: CRIShimMetadataStoreError.notFound(kind: .sandbox, id: "sandbox-1")).kind == .notFound)
        #expect(CRIShimErrorMapper.disposition(for: CRIShimMetadataStoreError.alreadyExists(kind: .container, id: "container-1")).kind == .invalidArgument)
        #expect(CRIShimErrorMapper.disposition(for: CRIShimMetadataStoreError.internalError("boom")).kind == .internalError)
        #expect(CRIShimErrorMapper.disposition(for: RuntimeHandlerResolutionError.unknownRuntimeHandler("missing")).kind == .notFound)
        #expect(CRIShimErrorMapper.disposition(for: CRIShimServerFactoryError.missingRuntimeEndpoint).kind == .invalidArgument)
        #expect(CRIShimErrorMapper.disposition(for: NSError(domain: "test", code: 1)).kind == .internalError)
    }

    @Test
    func exposesDescriptiveMessages() {
        let disposition = CRIShimErrorMapper.disposition(for: CRIShimError.notFound("sandbox missing"))
        #expect(disposition.message == "sandbox missing")
    }

    @Test
    func mapsErrorsToGRPCStatusCodes() {
        #expect(CRIShimGRPCStatusMapper.status(for: CRIShimError.unsupported("unsupported")).code == .unimplemented)
        #expect(CRIShimGRPCStatusMapper.status(for: CRIShimError.invalidArgument("invalid")).code == .invalidArgument)
        #expect(CRIShimGRPCStatusMapper.status(for: CRIShimError.notFound("missing")).code == .notFound)
        #expect(CRIShimGRPCStatusMapper.status(for: CRIShimError.unavailable("fenced")).code == .unavailable)
        #expect(CRIShimGRPCStatusMapper.status(for: CRIShimError.internalError("boom")).code == .internalError)

        let passthrough = GRPCStatus(code: .failedPrecondition, message: "already mapped")
        let mapped = CRIShimGRPCStatusMapper.status(for: passthrough)
        #expect(mapped.code == .failedPrecondition)
        #expect(mapped.message == "already mapped")
    }

    @Test
    func unsupportedOperationsMapThroughStructuredErrorModel() {
        let runtimeStatus = CRIShimGRPCStatusMapper.status(for: CRIShimGRPCStatusMapper.unsupportedError(.runPodSandbox))
        #expect(runtimeStatus.code == .unimplemented)
        #expect(runtimeStatus.message?.contains("RunPodSandbox") == true)

        let imageStatus = CRIShimGRPCStatusMapper.status(for: CRIShimGRPCStatusMapper.unsupportedError(.pullImage))
        #expect(imageStatus.code == .unimplemented)
        #expect(imageStatus.message?.contains("PullImage") == true)
    }
}
