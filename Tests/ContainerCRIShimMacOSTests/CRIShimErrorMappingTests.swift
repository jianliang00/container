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

import Foundation
import Testing

@testable import ContainerCRIShimMacOS

struct CRIShimErrorMappingTests {
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
}
