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

enum MacOSGuestNetworkReadiness {
    static func inventorySummary(from output: String) -> String {
        interfaces(from: output).map { "\($0.name)=\($0.mac)" }.joined(separator: ",")
    }

    static func wait(
        expectedMACAddresses: [String],
        timeoutSeconds: TimeInterval = 30,
        pollIntervalSeconds: TimeInterval = 1,
        observe: @escaping @Sendable (_ remainingSeconds: TimeInterval) async throws -> String,
        onNotReady: @escaping @Sendable (_ attempt: Int, _ inventory: String) -> Void = { _, _ in }
    ) async throws {
        guard !expectedMACAddresses.isEmpty else { return }
        let expected = Set(expectedMACAddresses.map { $0.lowercased() })
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(timeoutSeconds))
        var lastInventory = "unavailable"
        var attempt = 0
        while true {
            try Task.checkCancellation()
            let now = clock.now
            guard now < deadline else { break }
            let remaining = now.duration(to: deadline).components
            let remainingSeconds = Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18
            let output = try await observe(min(10, remainingSeconds))
            try Task.checkCancellation()
            guard clock.now < deadline else { break }
            let observed = interfaces(from: output)
            if expected.isSubset(of: Set(observed.map(\.mac))) { return }
            lastInventory = observed.map { "\($0.name)=\($0.mac)" }.joined(separator: ",")
            attempt += 1
            onNotReady(attempt, lastInventory)
            if pollIntervalSeconds > 0 {
                try await clock.sleep(until: min(deadline, clock.now.advanced(by: .seconds(pollIntervalSeconds))))
            }
        }
        throw ContainerizationError(
            .timeout,
            message: "guest network interfaces did not become ready: requested=\(expectedMACAddresses.joined(separator: ",")), observed=\(lastInventory)"
        )
    }

    private static func interfaces(from output: String) -> [(name: String, mac: String)] {
        var currentInterface: String?
        var result: [(name: String, mac: String)] = []
        for rawLine in output.prefix(16 * 1024).split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if !rawLine.hasPrefix("\t") && !rawLine.hasPrefix(" ") && line.contains(": flags=") {
                currentInterface = String(line.split(separator: ":", maxSplits: 1)[0])
            } else if let currentInterface, line.hasPrefix("ether "),
                let mac = line.split(whereSeparator: \.isWhitespace).dropFirst().first
            {
                result.append((currentInterface, mac.lowercased()))
            }
        }
        return result
    }
}
