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

public struct MacvmnetOperationPlan: Equatable {
    public var command: CNICommand
    public var networkName: String
    public var containerID: String?
    public var interfaceName: String?
    public var sandbox: CNISandboxURI?
    public var previousResult: CNIResult?
    public var validAttachments: Set<MacvmnetAttachmentIdentity>

    public init(request: CNIRequest) {
        command = request.environment.command
        networkName = request.config.networkName
        containerID = request.environment.containerID
        interfaceName = request.environment.ifName
        sandbox = request.sandbox
        previousResult = request.config.prevResult
        validAttachments = request.validAttachments
    }

    public var attachmentIdentity: MacvmnetAttachmentIdentity? {
        guard let containerID, let interfaceName else {
            return nil
        }
        return MacvmnetAttachmentIdentity(containerID: containerID, ifName: interfaceName)
    }
}
