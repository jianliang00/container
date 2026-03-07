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

public enum ZstdTool {
    public static let overrideEnvironmentKey = "CONTAINER_ZSTD_BIN"

    static let fallbackExecutablePaths = [
        "/opt/homebrew/bin/zstd",
        "/usr/local/bin/zstd",
        "/usr/bin/zstd",
    ]

    public static func executableURL(
        env: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> URL {
        try resolveExecutableURL(env: env) { path in
            FileManager.default.isExecutableFile(atPath: path)
        }
    }

    static func resolveExecutableURL(
        env: [String: String],
        isExecutable: (String) -> Bool
    ) throws -> URL {
        if let override = env[overrideEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
            guard isExecutable(override) else {
                throw NSError(
                    domain: "container.macos.zstd",
                    code: 127,
                    userInfo: [NSLocalizedDescriptionKey: "zstd not found at \(overrideEnvironmentKey)=\(override)"]
                )
            }
            return URL(fileURLWithPath: override)
        }

        var candidates: [String] = []
        if let pathValue = env["PATH"], !pathValue.isEmpty {
            candidates.append(
                contentsOf: pathValue
                    .split(separator: ":")
                    .map(String.init)
                    .filter { !$0.isEmpty }
                    .map { URL(fileURLWithPath: $0).appendingPathComponent("zstd").path }
            )
        }
        candidates.append(contentsOf: fallbackExecutablePaths)

        var seen = Set<String>()
        for candidate in candidates where seen.insert(candidate).inserted {
            if isExecutable(candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }

        let searched = seen.sorted().joined(separator: ", ")
        throw NSError(
            domain: "container.macos.zstd",
            code: 127,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "zstd not found; install zstd or set \(overrideEnvironmentKey) to an absolute path (searched: \(searched))"
            ]
        )
    }
}
