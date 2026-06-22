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

public enum MacOSKubeadmNetworkMode: String, CaseIterable, Sendable, Equatable {
    case full
    case compat

    public var usesPodNetworking: Bool {
        self == .full
    }

    public var runtimeHandler: String {
        switch self {
        case .full:
            return "macos"
        case .compat:
            return "macos-compat"
        }
    }

    public var runtimeClassName: String {
        runtimeHandler
    }

    public var networkBackend: String {
        switch self {
        case .full:
            return "vmnetShared"
        case .compat:
            return "virtualizationNAT"
        }
    }

    public var nodeNetworkLabelValue: String {
        rawValue
    }
}

public struct MacOSKubeadmRuntimeClassProfile: Sendable, Equatable {
    public var name: String
    public var handler: String
    public var sandboxImage: String
    public var networkMode: MacOSKubeadmNetworkMode

    public init(
        name: String,
        handler: String? = nil,
        sandboxImage: String,
        networkMode: MacOSKubeadmNetworkMode
    ) {
        self.name = name
        self.handler = handler ?? name
        self.sandboxImage = sandboxImage
        self.networkMode = networkMode
    }

    public var manifestFileName: String {
        "runtimeclass-\(name).yaml"
    }
}

public struct MacOSKubeadmJoinOptions: Sendable, Equatable {
    public var apiServer: URL
    public var nodeName: String
    public var token: String
    public var discoveryTokenCACertHashes: [String]
    public var certificateAuthorityPEM: String?
    public var kubeProxyToken: String?
    public var clusterName: String
    public var clusterDNS: String
    public var clusterDomain: String
    public var sandboxImage: String
    public var runtimeClasses: [MacOSKubeadmRuntimeClassProfile]
    public var networkMode: MacOSKubeadmNetworkMode
    public var containerServiceUserID: Int
    public var installRoot: String
    public var startServices: Bool
    public var dryRun: Bool
    public var debug: Bool

    public init(
        apiServer: URL,
        nodeName: String,
        token: String,
        discoveryTokenCACertHashes: [String],
        certificateAuthorityPEM: String? = nil,
        kubeProxyToken: String? = nil,
        clusterName: String = "kubernetes",
        clusterDNS: String = "10.96.0.10",
        clusterDomain: String = "cluster.local",
        sandboxImage: String = "localhost/macos-sandbox:latest",
        runtimeClasses: [MacOSKubeadmRuntimeClassProfile] = [],
        networkMode: MacOSKubeadmNetworkMode = .full,
        containerServiceUserID: Int = 0,
        installRoot: String = "/",
        startServices: Bool = true,
        dryRun: Bool = false,
        debug: Bool = false
    ) {
        self.apiServer = apiServer
        self.nodeName = nodeName
        self.token = token
        self.discoveryTokenCACertHashes = discoveryTokenCACertHashes
        self.certificateAuthorityPEM = certificateAuthorityPEM
        self.kubeProxyToken = kubeProxyToken
        self.clusterName = clusterName
        self.clusterDNS = clusterDNS
        self.clusterDomain = clusterDomain
        self.sandboxImage = sandboxImage
        self.runtimeClasses = runtimeClasses
        self.networkMode = networkMode
        self.containerServiceUserID = containerServiceUserID
        self.installRoot = installRoot
        self.startServices = startServices
        self.dryRun = dryRun
        self.debug = debug
    }
}

extension MacOSKubeadmJoinOptions {
    public var defaultRuntimeClass: MacOSKubeadmRuntimeClassProfile {
        MacOSKubeadmRuntimeClassProfile(
            name: networkMode.runtimeClassName,
            handler: networkMode.runtimeHandler,
            sandboxImage: sandboxImage,
            networkMode: networkMode
        )
    }

    public var effectiveRuntimeClasses: [MacOSKubeadmRuntimeClassProfile] {
        [defaultRuntimeClass] + runtimeClasses
    }

    public var rootPrefix: String {
        let trimmed = installRoot.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmed.isEmpty {
            return ""
        }
        return "/" + trimmed
    }

    public func rooted(_ absolutePath: String) -> String {
        precondition(absolutePath.hasPrefix("/"), "path must be absolute")
        guard !rootPrefix.isEmpty else {
            return absolutePath
        }
        return rootPrefix + absolutePath
    }
}
