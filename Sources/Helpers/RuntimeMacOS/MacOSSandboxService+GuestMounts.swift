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

import ContainerResource
import Containerization
import ContainerizationError
import Darwin
import Foundation

extension MacOSSandboxService {
    func prepareGuestMountsIfNeeded(containerConfig: ContainerConfiguration) async throws {
        guard !guestMountsPrepared else {
            return
        }

        let shares: [MacOSGuestMountMapping.HostPathShare]
        do {
            shares = try MacOSGuestMountMapping.hostPathShares(from: containerConfig.mounts)
        } catch let error as MacOSGuestMountMapping.Error {
            throw ContainerizationError(.invalidArgument, message: error.localizedDescription)
        }

        guard !shares.isEmpty else {
            guestMountsPrepared = true
            return
        }

        let processID = "mount-setup-\(UUID().uuidString)"
        var session = try makeSession(
            processID: processID,
            config: ProcessConfiguration(
                executable: "/bin/sh",
                arguments: ["-ceu", Self.guestMountBootstrapScript(shares: shares)],
                environment: [],
                workingDirectory: "/",
                terminal: false,
                user: .id(uid: 0, gid: 0)
            ),
            stdio: [nil, nil, nil],
            includeInSnapshots: false
        )

        writeContainerLog(
            Data(
                ("preparing macOS guest mounts: " + shares.map { "\($0.source)->\($0.guestPath) [real=\($0.guestRealPath)]" }.joined(separator: ", ") + "\n").utf8
            )
        )

        sessions[processID] = session
        defer {
            cleanupBootstrapSession(processID: processID)
        }

        do {
            try await startSessionViaSidecarProcessStream(&session, containerConfig: containerConfig)
            let status = try await waitForProcess(processID, timeout: 30)
            guard status.exitCode == 0 else {
                let detail =
                    sessions[processID]?.lastAgentError ?? sessions[processID]?.lastStderr ?? "bootstrap script exited with status \(status.exitCode)"
                throw ContainerizationError(
                    .internalError,
                    message: """
                        failed to prepare macOS guest volume mappings: \(detail)
                        check container log: \(root.appendingPathComponent("stdio.log").path)
                        """
                )
            }
            guestMountsPrepared = true
        } catch {
            guestMountsPrepared = false
            try? sendSignalToProcess(processID: processID, signal: SIGKILL)
            throw error
        }
    }

    private func cleanupBootstrapSession(processID: String) {
        guard let session = sessions.removeValue(forKey: processID) else {
            return
        }
        closeSessionResources(session)
    }

    private static func guestMountBootstrapScript(shares: [MacOSGuestMountMapping.HostPathShare]) -> String {
        var lines = [
            "set -euo pipefail",
            "",
            "wait_for_shared_path() {",
            "  real_path=$1",
            "  attempts=${2:-15}",
            "",
            "  while [ \"$attempts\" -gt 0 ]; do",
            "    if [ -d \"$real_path\" ]; then",
            "      return 0",
            "    fi",
            "    sleep 1",
            "    attempts=$((attempts - 1))",
            "  done",
            "",
            "  return 1",
            "}",
            "",
            "ensure_link() {",
            "  real_path=$1",
            "  guest_path=$2",
            "  parent_path=$(dirname \"$guest_path\")",
            "",
            "  if ! wait_for_shared_path \"$real_path\"; then",
            "    echo \"shared path is not available in guest after waiting: $real_path\" >&2",
            "    exit 1",
            "  fi",
            "",
            "  if [ -L \"$guest_path\" ]; then",
            "    existing_target=$(readlink \"$guest_path\")",
            "    if [ \"$existing_target\" = \"$real_path\" ]; then",
            "      return 0",
            "    fi",
            "    echo \"guest path already points elsewhere: $guest_path -> $existing_target\" >&2",
            "    exit 1",
            "  fi",
            "",
            "  if [ ! -e \"$guest_path\" ]; then",
            "    mkdir -p \"$parent_path\"",
            "    ln -s \"$real_path\" \"$guest_path\"",
            "    return 0",
            "  fi",
            "",
            "  if [ -d \"$guest_path\" ]; then",
            "    if [ -n \"$(ls -A \"$guest_path\")\" ]; then",
            "      echo \"guest path exists and is not empty: $guest_path\" >&2",
            "      exit 1",
            "    fi",
            "    rmdir \"$guest_path\"",
            "    mkdir -p \"$parent_path\"",
            "    ln -s \"$real_path\" \"$guest_path\"",
            "    return 0",
            "  fi",
            "",
            "  echo \"guest path already exists and cannot be replaced safely: $guest_path\" >&2",
            "  exit 1",
            "}",
            "",
        ]

        for share in shares {
            lines.append("ensure_link \(shQuote(share.guestRealPath)) \(shQuote(share.guestPath))")
        }

        return lines.joined(separator: "\n")
    }
}

private func shQuote(_ value: String) -> String {
    if value.isEmpty {
        return "''"
    }
    return "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
}

#if DEBUG
extension MacOSSandboxService {
    static func testingGuestMountBootstrapScript(shares: [MacOSGuestMountMapping.HostPathShare]) -> String {
        guestMountBootstrapScript(shares: shares)
    }
}
#endif
