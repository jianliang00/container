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
    public var runtimeName: String
    public var containerID: String?
    public var interfaceName: String?
    public var sandbox: CNISandboxURI?
    public var previousResult: CNIResult?
    public var attachmentOwner: MacvmnetAttachmentOwner?
    public var validAttachments: Set<MacvmnetAttachmentIdentity>
    public var dataDirectory: String

    public init(request: CNIRequest) {
        command = request.environment.command
        networkName = request.config.networkName
        runtimeName = request.config.runtimeName
        containerID = request.environment.containerID
        interfaceName = request.environment.ifName
        sandbox = request.sandbox
        previousResult = request.config.prevResult
        if let criSandboxID = request.environment.arguments["KROSS_CRI_SANDBOX_ID"],
            !criSandboxID.isEmpty
        {
            attachmentOwner = MacvmnetAttachmentOwner(
                criSandboxID: criSandboxID,
                restoreRequestID: request.environment.arguments["KROSS_RESTORE_REQUEST_ID"].flatMap {
                    $0.isEmpty ? nil : $0
                },
                podUID: request.environment.arguments["K8S_POD_UID"].flatMap {
                    $0.isEmpty ? nil : $0
                }
            )
        } else {
            attachmentOwner = nil
        }
        validAttachments = request.validAttachments
        dataDirectory =
            request.config.stringValue(for: "stateDir")
            ?? MacvmnetAttachmentLedgerDefaults.defaultRootURL.path
    }

    public var attachmentIdentity: MacvmnetAttachmentIdentity? {
        guard let containerID, let interfaceName else {
            return nil
        }
        return MacvmnetAttachmentIdentity(containerID: containerID, ifName: interfaceName)
    }
}
