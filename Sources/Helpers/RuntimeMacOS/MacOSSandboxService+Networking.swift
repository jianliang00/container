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

import ContainerNetworkServiceClient
import ContainerResource
import Foundation

extension MacOSSandboxService {
    func currentGuestNetworkAttachments() async -> [Attachment] {
        guard
            let configuration,
            configuration.macosGuest?.networkBackend == .vmnetShared
        else {
            return []
        }

        var attachments: [Attachment] = []
        for request in configuration.macOSGuestNetworkRequests() {
            let client = NetworkClient(id: request.network)
            do {
                guard let attachment = try await client.lookup(hostname: request.hostname) else {
                    continue
                }
                attachments.append(attachment)
            } catch {
                writeContainerLog(
                    Data(
                        ("failed to lookup guest network attachment network=\(request.network) hostname=\(request.hostname): \(error)\n").utf8
                    )
                )
            }
        }
        return configuration.macOSGuestReportedNetworkAttachments(attachments)
    }

    func releaseGuestNetworkAllocationsIfNeeded() async {
        guard
            let configuration,
            configuration.macosGuest?.networkBackend == .vmnetShared
        else {
            return
        }

        for request in configuration.macOSGuestNetworkRequests() {
            let client = NetworkClient(id: request.network)
            do {
                try await client.deallocate(hostname: request.hostname)
                writeContainerLog(
                    Data(
                        ("released guest network allocation network=\(request.network) hostname=\(request.hostname)\n").utf8
                    )
                )
            } catch {
                writeContainerLog(
                    Data(
                        ("failed to release guest network allocation network=\(request.network) hostname=\(request.hostname): \(error)\n").utf8
                    )
                )
            }
        }
    }
}
