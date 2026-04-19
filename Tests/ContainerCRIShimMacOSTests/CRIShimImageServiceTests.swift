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

@testable import ContainerCRI
@testable import ContainerCRIShimMacOS
@testable import ContainerResource

struct CRIShimImageServiceTests {
    @Test
    func mapsUsernamePasswordAuthConfigToBasicAuthentication() throws {
        var auth = Runtime_V1_AuthConfig()
        auth.username = "user"
        auth.password = "password"

        #expect(try CRIShimImagePullAuthentication.resolve(auth) == .basic(username: "user", password: "password"))
    }

    @Test
    func mapsDockerAuthFieldToBasicAuthentication() throws {
        var auth = Runtime_V1_AuthConfig()
        auth.auth = Data("docker-user:docker-password".utf8).base64EncodedString()

        #expect(try CRIShimImagePullAuthentication.resolve(auth) == .basic(username: "docker-user", password: "docker-password"))
    }

    @Test
    func mapsRegistryTokensToBearerAuthentication() throws {
        var registryTokenAuth = Runtime_V1_AuthConfig()
        registryTokenAuth.registryToken = "registry-token"
        #expect(try CRIShimImagePullAuthentication.resolve(registryTokenAuth) == .bearer(token: "registry-token"))

        var identityTokenAuth = Runtime_V1_AuthConfig()
        identityTokenAuth.identityToken = "identity-token"
        #expect(try CRIShimImagePullAuthentication.resolve(identityTokenAuth) == .bearer(token: "identity-token"))
    }

    @Test
    func rejectsMalformedAuthField() {
        var invalidBase64 = Runtime_V1_AuthConfig()
        invalidBase64.auth = "not base64"
        #expect {
            _ = try CRIShimImagePullAuthentication.resolve(invalidBase64)
        } throws: { error in
            error as? CRIShimError == .invalidArgument("image auth field is not valid base64")
        }

        var missingSeparator = Runtime_V1_AuthConfig()
        missingSeparator.auth = Data("missing-separator".utf8).base64EncodedString()
        #expect {
            _ = try CRIShimImagePullAuthentication.resolve(missingSeparator)
        } throws: { error in
            error as? CRIShimError == .invalidArgument("image auth field must decode to username:password")
        }
    }

    @Test
    func validatesExplicitMacOSImageRoles() throws {
        let sandboxImage = CRIShimImageRecord(
            reference: "localhost/macos-sandbox:latest",
            digest: "sha256:sandbox",
            size: 1024,
            annotations: MacOSImageContract.annotations(for: .sandbox)
        )
        try validateCRIShimImage(
            sandboxImage,
            expectedRole: .sandbox,
            requestedReference: sandboxImage.reference
        )

        let workloadImage = CRIShimImageRecord(
            reference: "localhost/macos-workload:latest",
            digest: "sha256:workload",
            size: 2048,
            annotations: MacOSImageContract.annotations(for: .workload)
        )
        try validateCRIShimImage(
            workloadImage,
            expectedRole: .workload,
            requestedReference: workloadImage.reference
        )

        #expect {
            try validateCRIShimImage(
                sandboxImage,
                expectedRole: .workload,
                requestedReference: sandboxImage.reference
            )
        } throws: { error in
            guard case .invalidArgument(let message) = error as? CRIShimError else {
                return false
            }
            return message.contains("expected a macOS workload image")
        }

        let unannotated = CRIShimImageRecord(
            reference: "localhost/unannotated:latest",
            digest: "sha256:unannotated",
            size: 1024
        )
        #expect {
            try validateCRIShimImage(
                unannotated,
                expectedRole: .sandbox,
                requestedReference: unannotated.reference
            )
        } throws: { error in
            guard case .invalidArgument(let message) = error as? CRIShimError else {
                return false
            }
            return message.contains("missing macOS image role annotation")
        }
    }
}
