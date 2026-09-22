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
import Testing

@testable import RuntimeMacOSSidecarShared

struct MacOSManagedPathTests {
    @Test(arguments: ["/etc", "/tmp", "/var"])
    func verifiedAliasesHaveOneStablePhysicalSpelling(alias: String) throws {
        let suffix = "/container-path-test/nbd.sock"
        #expect(MacOSManagedPath.canonicalPath(alias + suffix) == "/private" + alias + suffix)
        #expect(MacOSManagedPath.canonicalPath("/private" + alias + suffix) == "/private" + alias + suffix)
        #expect(MacOSManagedPath.canonicalPath(alias + "/../escape") == nil)
        #expect(MacOSManagedPath.canonicalPath(alias + "//socket") == nil)
        #expect(MacOSManagedPath.canonicalPath(alias + "/socket\0ignored") == nil)
    }

    @Test
    func aliasTrustRequiresExactOwnerTypeAndLiteralTarget() {
        for alias in ["/etc", "/tmp", "/var"] {
            #expect(MacOSManagedPath.isTrustedSystemAlias(path: alias, ownerID: 0, mode: mode_t(S_IFLNK), target: "private" + alias))
            #expect(!MacOSManagedPath.isTrustedSystemAlias(path: alias, ownerID: 501, mode: mode_t(S_IFLNK), target: "private" + alias))
            #expect(!MacOSManagedPath.isTrustedSystemAlias(path: alias, ownerID: 0, mode: mode_t(S_IFDIR), target: "private" + alias))
            #expect(!MacOSManagedPath.isTrustedSystemAlias(path: alias, ownerID: 0, mode: mode_t(S_IFLNK), target: "/private/other"))
        }
        #expect(!MacOSManagedPath.isTrustedSystemAlias(path: "/other", ownerID: 0, mode: mode_t(S_IFLNK), target: "/private/other"))
    }

    @Test
    func writableSystemParentExceptionsDoNotExtendToDescendantsOrOtherOwners() {
        #expect(MacOSManagedPath.hasTrustedParentWritePermissions(path: "/private/var/run", ownerID: 0, groupID: 1, mode: 0o775))
        for path in ["/private/var/run/container", "/private/var/runnable", "/private/var/lib"] {
            #expect(!MacOSManagedPath.hasTrustedParentWritePermissions(path: path, ownerID: 0, groupID: 1, mode: 0o775))
        }
        for mode in [mode_t(0o777), mode_t(0o1775), mode_t(0o2775)] {
            #expect(!MacOSManagedPath.hasTrustedParentWritePermissions(path: "/private/var/run", ownerID: 0, groupID: 1, mode: mode))
        }
        #expect(!MacOSManagedPath.hasTrustedParentWritePermissions(path: "/private/var/run", ownerID: 501, groupID: 1, mode: 0o775))
        #expect(!MacOSManagedPath.hasTrustedParentWritePermissions(path: "/private/tmp", ownerID: 0, groupID: 0, mode: 0o777))
    }
}
