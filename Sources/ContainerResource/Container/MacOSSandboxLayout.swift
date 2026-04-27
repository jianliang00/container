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

/// Filesystem layout for a macOS guest sandbox bundle.
public struct MacOSSandboxLayout: Sendable, Equatable {
    public static let stateDirectoryName = "state"
    public static let stateSchemaVersion = 1

    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public var stateRootURL: URL {
        root
            .appendingPathComponent(Self.stateDirectoryName)
            .appendingPathComponent("v\(Self.stateSchemaVersion)")
    }

    public var runtimeConfigurationURL: URL {
        root.appendingPathComponent("runtime-configuration.json")
    }

    public var optionsURL: URL {
        root.appendingPathComponent("options.json")
    }

    public var containerConfigurationURL: URL {
        root.appendingPathComponent("config.json")
    }

    public var sandboxConfigurationURL: URL {
        stateRootURL.appendingPathComponent("sandbox.json")
    }

    public var diskImageURL: URL {
        root.appendingPathComponent("Disk.img")
    }

    public var auxiliaryStorageURL: URL {
        root.appendingPathComponent("AuxiliaryStorage")
    }

    public var hardwareModelURL: URL {
        root.appendingPathComponent("HardwareModel.bin")
    }

    public var stdioLogURL: URL {
        root.appendingPathComponent("stdio.log")
    }

    public var bootLogURL: URL {
        root.appendingPathComponent("vminitd.log")
    }

    public var guestAgentHostLogURL: URL {
        root.appendingPathComponent("guest-agent.log")
    }

    public var guestAgentHostStderrLogURL: URL {
        root.appendingPathComponent("guest-agent.stderr.log")
    }

    public var networkAuditLogURL: URL {
        root.appendingPathComponent("network-audit.log")
    }

    public var temporaryDirectoryURL: URL {
        stateRootURL.appendingPathComponent("tmp")
    }

    public var readonlyInjectionDirectoryURL: URL {
        stateRootURL.appendingPathComponent("readonly")
    }

    public var readonlyInjectionManifestURL: URL {
        readonlyInjectionDirectoryURL.appendingPathComponent("manifest.json")
    }

    public var workloadsDirectoryURL: URL {
        stateRootURL.appendingPathComponent("workloads")
    }

    public func workloadDirectoryURL(id: String) -> URL {
        workloadsDirectoryURL.appendingPathComponent(id)
    }

    public func workloadConfigurationURL(id: String) -> URL {
        workloadDirectoryURL(id: id).appendingPathComponent("config.json")
    }

    public func workloadReadonlyInjectionDirectoryURL(id: String) -> URL {
        workloadDirectoryURL(id: id).appendingPathComponent("readonly")
    }

    public func workloadReadonlyInjectionManifestURL(id: String) -> URL {
        workloadReadonlyInjectionDirectoryURL(id: id).appendingPathComponent("manifest.json")
    }

    public func workloadStdoutLogURL(id: String) -> URL {
        workloadDirectoryURL(id: id).appendingPathComponent("stdout.log")
    }

    public func workloadStderrLogURL(id: String) -> URL {
        workloadDirectoryURL(id: id).appendingPathComponent("stderr.log")
    }

    public func prepareBaseDirectories(fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: stateRootURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: temporaryDirectoryURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: readonlyInjectionDirectoryURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: workloadsDirectoryURL, withIntermediateDirectories: true)
    }
}
