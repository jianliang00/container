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

import ContainerKit
import ContainerPlugin
import Foundation

/// Explicit description of an already-installed container runtime layout.
public struct ContainerInstallation: Sendable, Equatable {
    public let installRoot: URL
    public let apiServerExecutableURL: URL

    public init(installRoot: URL, apiServerExecutableURL: URL) {
        self.installRoot = installRoot
        self.apiServerExecutableURL = apiServerExecutableURL
    }
}

/// Lifecycle state of the API service.
public struct ServiceStatus: Sendable {
    public let isRegistered: Bool
    public let health: SystemHealth?

    public init(isRegistered: Bool, health: SystemHealth?) {
        self.isRegistered = isRegistered
        self.health = health
    }
}

public struct ContainerKitServices: Sendable {
    static let apiServerServiceLabel = "com.apple.container.apiserver"
    static let launchctlPrintLineLimit = 30
    static let stopTimeoutSeconds: Int32 = 5
    static let shutdownTimeoutSeconds = 20

    let appRoot: URL
    let installation: ContainerInstallation
    let dependencies: ContainerKitServicesDependencies

    public init(
        appRoot: URL = ApplicationRoot.defaultURL,
        installation: ContainerInstallation
    ) {
        self.init(
            appRoot: appRoot,
            installation: installation,
            dependencies: .live()
        )
    }

    init(
        appRoot: URL = ApplicationRoot.defaultURL,
        installation: ContainerInstallation,
        dependencies: ContainerKitServicesDependencies
    ) {
        self.appRoot = appRoot
        self.installation = installation
        self.dependencies = dependencies
    }
}

struct APIServerRegistrationPlan: Sendable {
    let plistURL: URL
    let plistData: Data
    let arguments: [String]
    let environment: [String: String]
}
