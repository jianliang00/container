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

#if os(macOS)
import ContainerXPC
import ContainerizationError
import Testing

struct XPCMessageErrorTests {
    @Test func preservesContainerizationErrorCauseChain() throws {
        let message = XPCMessage(route: "test")
        message.set(
            error: ContainerizationError(
                .internalError,
                message: "outer failure",
                cause: ContainerizationError(.notFound, message: "inner missing")
            )
        )

        do {
            try message.error()
            Issue.record("expected ContainerizationError")
        } catch let error as ContainerizationError {
            #expect(error.code == .internalError)
            #expect(error.message == "outer failure")

            let cause = try #require(error.cause as? ContainerizationError)
            #expect(cause.code == .notFound)
            #expect(cause.message == "inner missing")
        }
    }
}
#endif
