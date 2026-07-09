// swift-tools-version: 6.2
//===----------------------------------------------------------------------===//
// Copyright © 2025-2026 Apple Inc. and the container project authors.
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

// The swift-tools-version declares the minimum version of Swift required to build this package.

import Foundation
import PackageDescription

let releaseVersion = ProcessInfo.processInfo.environment["RELEASE_VERSION"] ?? "0.0.0"
let gitCommit = ProcessInfo.processInfo.environment["GIT_COMMIT"] ?? "unspecified"
let builderShimVersion = "0.13.0"
let scVersion = "0.37.0"

let package = Package(
    name: "container",
    platforms: [.macOS("15")],
    products: [
        .library(name: "ContainerCommands", targets: ["ContainerCommands"]),
        .library(name: "ContainerCRI", targets: ["ContainerCRI"]),
        .library(name: "ContainerCRIShimMacOS", targets: ["ContainerCRIShimMacOS"]),
        .library(name: "ContainerCNIMacvmnet", targets: ["ContainerCNIMacvmnet"]),
        .library(name: "ContainerK8sNetworkPolicyMacOS", targets: ["ContainerK8sNetworkPolicyMacOS"]),
        .library(name: "ContainerK8sKubeProxyMacOS", targets: ["ContainerK8sKubeProxyMacOS"]),
        .library(name: "ContainerBuild", targets: ["ContainerBuild"]),
        .library(name: "ContainerAPIService", targets: ["ContainerAPIService"]),
        .library(name: "ContainerAPIClient", targets: ["ContainerAPIClient"]),
        .library(name: "ContainerKit", targets: ["ContainerKit"]),
        .library(name: "ContainerKitServices", targets: ["ContainerKitServices"]),
        .library(name: "ContainerImagesService", targets: ["ContainerImagesService", "ContainerImagesServiceClient"]),
        .library(name: "ContainerNetworkClient", targets: ["ContainerNetworkClient"]),
        .library(name: "ContainerNetworkServer", targets: ["ContainerNetworkServer"]),
        .library(name: "ContainerNetworkVmnetServer", targets: ["ContainerNetworkVmnetServer"]),
        .library(name: "ContainerResource", targets: ["ContainerResource"]),
        .library(name: "ContainerLog", targets: ["ContainerLog"]),
        .library(name: "ContainerPersistence", targets: ["ContainerPersistence"]),
        .library(name: "ContainerPlugin", targets: ["ContainerPlugin"]),
        .library(name: "ContainerRuntimeClient", targets: ["ContainerRuntimeClient"]),
        .library(name: "ContainerRuntimeLinuxClient", targets: ["ContainerRuntimeLinuxClient"]),
        .library(name: "ContainerRuntimeLinuxServer", targets: ["ContainerRuntimeLinuxServer"]),
        .library(name: "ContainerVersion", targets: ["ContainerVersion"]),
        .library(name: "ContainerXPC", targets: ["ContainerXPC"]),
        .library(name: "ContainerOS", targets: ["ContainerOS"]),
        .library(name: "SocketForwarder", targets: ["SocketForwarder"]),
        .library(name: "TerminalProgress", targets: ["TerminalProgress"]),
        .executable(name: "container-runtime-macos", targets: ["container-runtime-macos"]),
        .executable(name: "container-runtime-macos-sidecar", targets: ["container-runtime-macos-sidecar"]),
        .executable(name: "container-macos-guest-agent", targets: ["container-macos-guest-agent"]),
        .executable(name: "container-macos-image-prepare", targets: ["container-macos-image-prepare"]),
        .executable(name: "container-macos-vm-manager", targets: ["container-macos-vm-manager"]),
        .executable(name: "container-cri-shim-macos", targets: ["container-cri-shim-macos"]),
        .executable(name: "container-cni-macvmnet", targets: ["container-cni-macvmnet"]),
        .executable(name: "container-k8s-networkpolicy-macos", targets: ["container-k8s-networkpolicy-macos"]),
        .executable(name: "container-kube-proxy-macos", targets: ["container-kube-proxy-macos"]),
        .executable(name: "container-macos-kubeadm", targets: ["container-macos-kubeadm"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/containerization.git", exact: Version(stringLiteral: scVersion)),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-collections.git", from: "1.2.0"),
        .package(url: "https://github.com/apple/swift-configuration", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.80.0"),
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.36.0"),
        .package(url: "https://github.com/apple/swift-system.git", from: "1.6.4"),
        .package(url: "https://github.com/grpc/grpc-swift-2.git", from: "2.3.0"),
        .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", from: "2.9.0"),
        .package(url: "https://github.com/grpc/grpc-swift-protobuf.git", from: "2.2.0"),
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.20.1"),
        .package(url: "https://github.com/orlandos-nl/DNSClient.git", from: "2.4.1"),
        .package(url: "https://github.com/Bouke/DNS.git", from: "1.2.0"),
        .package(url: "https://github.com/apple/containerization.git", exact: Version(stringLiteral: scVersion)),
        .package(url: "https://github.com/facebook/zstd.git", exact: "1.5.7"),
    ],
    targets: [
        .executableTarget(
            name: "container",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                "ContainerAPIClient",
                "ContainerCommands",
            ],
            path: "Sources/CLI"
        ),
        .testTarget(
            name: "IntegrationTests",
            dependencies: [
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "SystemPackage", package: "swift-system"),
                .product(name: "Containerization", package: "containerization"),
                .product(name: "ContainerizationArchive", package: "containerization"),
                .product(name: "ContainerizationExtras", package: "containerization"),
                .product(name: "ContainerizationOCI", package: "containerization"),
                .product(name: "ContainerizationOS", package: "containerization"),
                .product(name: "TOML", package: "swift-toml"),
                "ContainerAPIClient",
                "ContainerLog",
                "ContainerPersistence",
                "ContainerResource",
                "MachineAPIClient",
                "Yams",
            ],
            path: "Tests/IntegrationTests"
        ),
        .target(
            name: "ContainerCommands",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "TOML", package: "swift-toml"),
                .product(name: "Containerization", package: "containerization"),
                .product(name: "ContainerizationArchive", package: "containerization"),
                .product(name: "ContainerizationOCI", package: "containerization"),
                .product(name: "ContainerizationOS", package: "containerization"),
                "ContainerBuild",
                "ContainerAPIClient",
                "ContainerLog",
                "ContainerPersistence",
                "ContainerPlugin",
                "ContainerResource",
                "ContainerSandboxServiceClient",
                "RuntimeMacOSSidecarShared",
                "ContainerVersion",
                .product(name: "SystemPackage", package: "swift-system"),
                "ContainerXPC",
                "MachineAPIClient",
                "TerminalProgress",
                "Yams",
            ],
            path: "Sources/ContainerCommands"
        ),
        .target(
            name: "ContainerBuild",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "Containerization", package: "containerization"),
                .product(name: "ContainerizationArchive", package: "containerization"),
                .product(name: "ContainerizationOCI", package: "containerization"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport"),
                .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
                "ContainerAPIClient",
            ]
        ),
        .testTarget(
            name: "ContainerBuildTests",
            dependencies: [
                "ContainerBuild"
            ]
        ),
        .target(
            name: "ContainerCRI",
            dependencies: [
                .product(name: "GRPC", package: "grpc-swift"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ]
        ),
        .testTarget(
            name: "ContainerCRITests",
            dependencies: [
                "ContainerCRI"
            ]
        ),
        .target(
            name: "ContainerCRIShimMacOS",
            dependencies: [
                .product(name: "GRPC", package: "grpc-swift"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
                .product(name: "Containerization", package: "containerization"),
                .product(name: "ContainerizationOS", package: "containerization"),
                .product(name: "ContainerizationOCI", package: "containerization"),
                "ContainerAPIClient",
                "ContainerCRI",
                "ContainerKit",
                "ContainerK8sNetworkPolicyMacOS",
                "ContainerResource",
                "ContainerVersion",
            ]
        ),
        .executableTarget(
            name: "container-cri-shim-macos",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Logging", package: "swift-log"),
                "ContainerCRIShimMacOS",
                "ContainerLog",
                "ContainerVersion",
            ],
            path: "Sources/Helpers/CRIShimMacOS"
        ),
        .testTarget(
            name: "ContainerCRIShimMacOSTests",
            dependencies: [
                .product(name: "ContainerizationExtras", package: "containerization"),
                .product(name: "GRPC", package: "grpc-swift"),
                .product(name: "NIO", package: "swift-nio"),
                "ContainerCRI",
                "ContainerCRIShimMacOS",
                "ContainerKit",
                "ContainerK8sNetworkPolicyMacOS",
            ]
        ),
        .target(
            name: "ContainerCNIMacvmnet",
            dependencies: [
                .product(name: "Containerization", package: "containerization"),
                "ContainerAPIClient",
                "ContainerNetworkServiceClient",
                "ContainerResource",
                "ContainerSandboxServiceClient",
            ]
        ),
        .executableTarget(
            name: "container-cni-macvmnet",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                "ContainerCNIMacvmnet",
            ],
            path: "Sources/Helpers/CNIMacvmnet"
        ),
        .testTarget(
            name: "ContainerCNIMacvmnetTests",
            dependencies: [
                .product(name: "ContainerizationExtras", package: "containerization"),
                "ContainerCNIMacvmnet",
                "ContainerResource",
                "ContainerSandboxServiceClient",
            ]
        ),
        .target(
            name: "ContainerK8sNetworkPolicyMacOS",
            dependencies: [
                .product(name: "ContainerizationExtras", package: "containerization"),
                "ContainerKit",
                "ContainerResource",
            ]
        ),
        .executableTarget(
            name: "container-k8s-networkpolicy-macos",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                "ContainerK8sNetworkPolicyMacOS",
            ],
            path: "Sources/Helpers/K8sNetworkPolicyMacOS"
        ),
        .testTarget(
            name: "ContainerK8sNetworkPolicyMacOSTests",
            dependencies: [
                .product(name: "ContainerizationExtras", package: "containerization"),
                "ContainerK8sNetworkPolicyMacOS",
                "ContainerResource",
            ]
        ),
        .target(
            name: "ContainerK8sKubeProxyMacOS",
            dependencies: []
        ),
        .executableTarget(
            name: "container-kube-proxy-macos",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                "ContainerK8sKubeProxyMacOS",
            ],
            path: "Sources/Helpers/KubeProxyMacOS"
        ),
        .testTarget(
            name: "ContainerK8sKubeProxyMacOSTests",
            dependencies: [
                "ContainerK8sKubeProxyMacOS"
            ]
        ),
        .target(
            name: "ContainerMacOSKubeadm",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                "ContainerLog",
            ]
        ),
        .executableTarget(
            name: "container-macos-kubeadm",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Logging", package: "swift-log"),
                "ContainerLog",
                "ContainerMacOSKubeadm",
            ],
            path: "Sources/Helpers/MacOSKubeadm"
        ),
        .testTarget(
            name: "ContainerMacOSKubeadmTests",
            dependencies: [
                "ContainerMacOSKubeadm"
            ]
        ),
        .testTarget(
            name: "ContainerCommandsTests",
            dependencies: [
                "ContainerCommands"
            ]
        ),
        .executableTarget(
            name: "container-apiserver",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "Containerization", package: "containerization"),
                .product(name: "ContainerizationExtras", package: "containerization"),
                .product(name: "ContainerizationOS", package: "containerization"),
                .product(name: "ContainerizationEXT4", package: "containerization"),
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport"),
                .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "SystemPackage", package: "swift-system"),
                "ContainerAPIService",
                "ContainerAPIClient",
                "ContainerLog",
                "ContainerNetworkClient",
                "ContainerPersistence",
                "ContainerPlugin",
                "ContainerResource",
                "ContainerVersion",
                "ContainerXPC",
                "ContainerOS",
                "DNSServer",
            ],
            path: "Sources/APIServer"
        ),
        .executableTarget(
            name: "container-macos-vm-manager",
            dependencies: [
                "ContainerResource",
                "RuntimeMacOSSidecarShared",
            ],
            path: "Sources/Helpers/MacOSVMManager",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Virtualization"),
            ]
        ),
        .target(
            name: "ContainerAPIService",
            dependencies: [
                .product(name: "Containerization", package: "containerization"),
                .product(name: "ContainerizationArchive", package: "containerization"),
                .product(name: "ContainerizationExtras", package: "containerization"),
                .product(name: "ContainerizationOS", package: "containerization"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "SystemPackage", package: "swift-system"),
                "CVersion",
                "ContainerAPIClient",
                "ContainerNetworkClient",
                "ContainerPersistence",
                "ContainerPlugin",
                "ContainerResource",
                "ContainerRuntimeClient",
                "ContainerVersion",
                "ContainerXPC",
                "TerminalProgress",
            ],
            path: "Sources/Services/ContainerAPIService/Server"
        ),
        .testTarget(
            name: "ContainerAPIServiceTests",
            dependencies: [
                .product(name: "Containerization", package: "containerization"),
                "ContainerAPIService",
                "ContainerResource",
                "ContainerRuntimeLinuxClient",
                "ContainerRuntimeClient",
            ]
        ),
        .target(
            name: "ContainerAPIClient",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Containerization", package: "containerization"),
                .product(name: "ContainerizationArchive", package: "containerization"),
                .product(name: "ContainerizationOCI", package: "containerization"),
                .product(name: "ContainerizationOS", package: "containerization"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "SystemPackage", package: "swift-system"),
                "ContainerImagesServiceClient",
                "ContainerPersistence",
                "ContainerPlugin",
                "ContainerResource",
                "ContainerSandboxServiceClient",
                "ContainerXPC",
                "DNSServer",
                "TerminalProgress",
            ],
            path: "Sources/Services/ContainerAPIService/Client"
        ),
        .target(
            name: "ContainerKit",
            dependencies: [
                "ContainerAPIClient",
                "ContainerResource",
                "ContainerSandboxServiceClient",
            ]
        ),
        .testTarget(
            name: "ContainerAPIClientTests",
            dependencies: [
                .product(name: "Containerization", package: "containerization"),
                .product(name: "SystemPackage", package: "swift-system"),
                "ContainerAPIClient",
                "ContainerResource",
                "ContainerPersistence",
                "ContainerTestSupport",
            ]
        ),
        .testTarget(
            name: "ContainerKitTests",
            dependencies: [
                "ContainerKit"
            ]
        ),
        .testTarget(
            name: "ContainerImagesServiceTests",
            dependencies: [
                .product(name: "ContainerizationOCI", package: "containerization"),
                "ContainerImagesService",
            ]
        ),
        .executableTarget(
            name: "container-core-images",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Containerization", package: "containerization"),
                .product(name: "SystemPackage", package: "swift-system"),
                "ContainerImagesService",
                "ContainerLog",
                "ContainerPersistence",
                "ContainerPlugin",
                "ContainerVersion",
                "ContainerXPC",
            ],
            path: "Sources/Plugins/CoreImages",
            exclude: ["config.toml"]
        ),
        .target(
            name: "ContainerImagesService",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Containerization", package: "containerization"),
                .product(name: "ContainerizationArchive", package: "containerization"),
                .product(name: "ContainerizationExtras", package: "containerization"),
                .product(name: "ContainerizationOCI", package: "containerization"),
                .product(name: "ContainerizationOS", package: "containerization"),
                "ContainerAPIClient",
                "ContainerImagesServiceClient",
                "ContainerLog",
                "ContainerPersistence",
                "ContainerResource",
                "ContainerXPC",
                "TerminalProgress",
            ],
            path: "Sources/Services/ContainerImagesService/Server"
        ),
        .target(
            name: "ContainerImagesServiceClient",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Containerization", package: "containerization"),
                "ContainerXPC",
                "ContainerLog",
            ],
            path: "Sources/Services/ContainerImagesService/Client"
        ),
        .executableTarget(
            name: "container-network-vmnet",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "ContainerizationExtras", package: "containerization"),
                .product(name: "ContainerizationOS", package: "containerization"),
                "ContainerLog",
                "ContainerNetworkClient",
                "ContainerNetworkServer",
                "ContainerNetworkVmnetServer",
                "ContainerPersistence",
                "ContainerPlugin",
                "ContainerResource",
                "ContainerVersion",
                "ContainerXPC",
            ],
            path: "Sources/Plugins/NetworkVmnet",
            exclude: ["config.toml"]
        ),
        .target(
            name: "ContainerNetworkClient",
            dependencies: [
                .product(name: "ContainerizationExtras", package: "containerization"),
                "ContainerResource",
                "ContainerXPC",
            ],
            path: "Sources/Services/Network/Client"
        ),
        .target(
            name: "ContainerNetworkServer",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                .product(name: "ContainerizationExtras", package: "containerization"),
                "ContainerNetworkClient",
                "ContainerResource",
                "ContainerXPC",
            ],
            path: "Sources/Services/Network/Server"
        ),
        .testTarget(
            name: "ContainerNetworkServerTests",
            dependencies: [
                .product(name: "ContainerizationExtras", package: "containerization"),
                "ContainerNetworkServer",
            ]
        ),
        .target(
            name: "ContainerNetworkVmnetServer",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                .product(name: "ContainerizationExtras", package: "containerization"),
                "ContainerNetworkServer",
                "ContainerResource",
                "ContainerXPC",
            ],
            path: "Sources/Services/NetworkVmnet/Server"
        ),
        .target(
            name: "ContainerRuntimeLinuxClient",
            dependencies: [],
            path: "Sources/Services/RuntimeLinux/Client"
        ),
        .executableTarget(
            name: "container-runtime-linux",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Containerization", package: "containerization"),
                "ContainerLog",
                "ContainerPlugin",
                "ContainerResource",
                "ContainerRuntimeClient",
                "ContainerRuntimeLinuxClient",
                "ContainerRuntimeLinuxServer",
                "ContainerVersion",
                "ContainerXPC",
            ],
            path: "Sources/Plugins/RuntimeLinux",
            exclude: ["config.toml"]
        ),
        .executableTarget(
            name: "container-runtime-macos",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "Containerization", package: "containerization"),
                .product(name: "ContainerizationArchive", package: "containerization"),
                .product(name: "ContainerizationOCI", package: "containerization"),
                "ContainerAPIClient",
                "ContainerImagesServiceClient",
                "ContainerNetworkServiceClient",
                "ContainerLog",
                "ContainerResource",
                "ContainerSandboxServiceClient",
                "RuntimeMacOSSidecarShared",
                "SocketForwarder",
                "ContainerVersion",
                "ContainerXPC",
                "TerminalProgress",
            ],
            path: "Sources/Helpers/RuntimeMacOS"
        ),
        .executableTarget(
            name: "container-runtime-macos-sidecar",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Containerization", package: "containerization"),
                "ContainerNetworkServiceClient",
                "ContainerLog",
                "ContainerResource",
                "RuntimeMacOSSidecarShared",
                "ContainerVersion",
            ],
            path: "Sources/Helpers/RuntimeMacOSSidecar"
        ),
        .executableTarget(
            name: "container-macos-guest-agent",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                "RuntimeMacOSSidecarShared",
            ],
            path: "Sources/Helpers/MacOSGuestAgent"
        ),
        .executableTarget(
            name: "container-macos-image-prepare",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Containerization", package: "containerization"),
                "ContainerVersion",
            ],
            path: "Sources/Helpers/MacOSImagePrepare"
        ),
        .target(
            name: "RuntimeMacOSSidecarShared",
            dependencies: [],
            path: "Sources/Helpers/RuntimeMacOSSidecarShared"
        ),
        .testTarget(
            name: "RuntimeMacOSSidecarSharedTests",
            dependencies: [
                "RuntimeMacOSSidecarShared"
            ],
            path: "Tests/RuntimeMacOSSidecarSharedTests"
        ),
        .testTarget(
            name: "RuntimeMacOSSidecarClientTests",
            dependencies: [
                "ContainerAPIClient",
                "ContainerCommands",
                .product(name: "Containerization", package: "containerization"),
                .product(name: "ContainerizationArchive", package: "containerization"),
                .product(name: "ContainerizationOCI", package: "containerization"),
                "ContainerResource",
                "ContainerSandboxServiceClient",
                "RuntimeMacOSSidecarShared",
                .product(name: "Logging", package: "swift-log", condition: .when(platforms: [.macOS])),
                .target(name: "container-runtime-macos", condition: .when(platforms: [.macOS])),
            ],
            path: "Tests/RuntimeMacOSSidecarClientTests"
        ),
        .testTarget(
            name: "RuntimeMacOSSidecarTests",
            dependencies: [
                "ContainerResource",
                "RuntimeMacOSSidecarShared",
                .product(name: "Logging", package: "swift-log", condition: .when(platforms: [.macOS])),
                .target(name: "container-runtime-macos-sidecar", condition: .when(platforms: [.macOS])),
            ],
            path: "Tests/RuntimeMacOSSidecarTests"
        ),
        .testTarget(
            name: "MacOSGuestAgentTests",
            dependencies: [
                "RuntimeMacOSSidecarShared",
                .target(name: "container-macos-guest-agent", condition: .when(platforms: [.macOS])),
            ],
            path: "Tests/MacOSGuestAgentTests"
        ),
        .target(
            name: "ContainerSandboxService",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Containerization", package: "containerization"),
                .product(name: "ContainerizationExtras", package: "containerization"),
                .product(name: "ContainerizationOS", package: "containerization"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                "ContainerAPIClient",
                "ContainerNetworkClient",
                "ContainerOS",
                "ContainerPersistence",
                "ContainerResource",
                "ContainerRuntimeClient",
                "ContainerRuntimeLinuxClient",
                "ContainerXPC",
                "SocketForwarder",
            ],
            path: "Sources/Services/RuntimeLinux/Server"
        ),
        .target(
            name: "ContainerRuntimeClient",
            dependencies: [
                "ContainerAPIClient",
                "ContainerResource",
                "TerminalProgress",
                "ContainerXPC",
                "RuntimeMacOSSidecarShared",
            ],
            path: "Sources/Services/Runtime/RuntimeClient"
        ),
        .target(
            name: "ContainerResource",
            dependencies: [
                .product(name: "Containerization", package: "containerization"),
                .product(name: "libzstd", package: "zstd"),
            ]
        ),
        .testTarget(
            name: "ContainerResourceTests",
            dependencies: [
                .product(name: "Containerization", package: "containerization"),
                .product(name: "ContainerizationExtras", package: "containerization"),
                .product(name: "libzstd", package: "zstd"),
                "ContainerAPIService",
                "ContainerResource",
            ]
        ),
        .target(
            name: "ContainerLog",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                .product(name: "SystemPackage", package: "swift-system"),
            ]
        ),
        .target(
            name: "ContainerPersistence",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Containerization", package: "containerization"),
                .product(name: "Configuration", package: "swift-configuration"),
                .product(name: "ConfigurationTOML", package: "swift-configuration-toml"),
                .product(name: "SystemPackage", package: "swift-system"),
                "CVersion",
                "ContainerVersion",
            ]
        ),
        .testTarget(
            name: "ContainerPersistenceTests",
            dependencies: [
                .product(name: "Configuration", package: "swift-configuration"),
                .product(name: "ContainerizationExtras", package: "containerization"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "SystemPackage", package: "swift-system"),
                "ContainerPersistence",
                "ContainerTestSupport",
            ]
        ),
        .target(
            name: "ContainerPlugin",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                .product(name: "ContainerizationOS", package: "containerization"),
                .product(name: "SystemPackage", package: "swift-system"),
                .product(name: "TOML", package: "swift-toml"),
                "ContainerVersion",
            ]
        ),
        .target(
            name: "ContainerKitServices",
            dependencies: [
                "ContainerAPIClient",
                "ContainerKit",
                "ContainerPlugin",
                "ContainerPersistence",
            ]
        ),
        .testTarget(
            name: "ContainerPluginTests",
            dependencies: [
                "ContainerPlugin"
            ]
        ),
        .testTarget(
            name: "ContainerKitServicesTests",
            dependencies: [
                "ContainerKitServices"
            ]
        ),
        .testTarget(
            name: "ContainerSandboxServiceTests",
            dependencies: [
                .product(name: "Containerization", package: "containerization"),
                "ContainerAPIService",
                "ContainerResource",
                "ContainerSandboxServiceClient",
            ]
        ),
        .target(
            name: "ContainerXPC",
            dependencies: [
                .product(name: "ContainerizationExtras", package: "containerization"),
                .product(name: "Logging", package: "swift-log"),
                "CAuditToken",
            ]
        ),
        .testTarget(
            name: "ContainerXPCTests",
            dependencies: [
                .product(name: "Containerization", package: "containerization"),
                "ContainerXPC",
            ]
        ),
        .target(
            name: "ContainerOS",
            dependencies: [
                .product(name: "Containerization", package: "containerization"),
                .product(name: "ContainerizationOS", package: "containerization"),
            ],
            path: "Sources/ContainerOS"
        ),
        .testTarget(
            name: "ContainerOSTests",
            dependencies: [
                "ContainerOS"
            ]
        ),
        .target(
            name: "TerminalProgress",
            dependencies: [
                .product(name: "ContainerizationOS", package: "containerization")
            ]
        ),
        .testTarget(
            name: "TerminalProgressTests",
            dependencies: ["TerminalProgress"]
        ),
        .target(
            name: "DNSServer",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "ContainerizationExtras", package: "containerization"),
                .product(name: "ContainerizationOS", package: "containerization"),
            ]
        ),
        .testTarget(
            name: "DNSServerTests",
            dependencies: [
                "DNSServer"
            ]
        ),
        .target(
            name: "SocketForwarder",
            dependencies: [
                .product(name: "Collections", package: "swift-collections"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
            ]
        ),
        .testTarget(
            name: "SocketForwarderTests",
            dependencies: ["SocketForwarder"]
        ),
        .target(
            name: "ContainerVersion",
            dependencies: [
                .product(name: "SystemPackage", package: "swift-system"),
                "CVersion",
            ],
        ),
        .testTarget(
            name: "ContainerVersionTests",
            dependencies: [
                .product(name: "SystemPackage", package: "swift-system"),
                "ContainerVersion",
            ]
        ),
        .target(
            name: "CVersion",
            dependencies: [],
            publicHeadersPath: "include",
            cSettings: [
                .define("CZ_VERSION", to: "\"\(scVersion)\""),
                .define("GIT_COMMIT", to: "\"\(gitCommit)\""),
                .define("RELEASE_VERSION", to: "\"\(releaseVersion)\""),
                .define("BUILDER_SHIM_VERSION", to: "\"\(builderShimVersion)\""),
            ],
        ),
        .target(
            name: "CAuditToken",
            dependencies: [],
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedLibrary("bsm")
            ]
        ),
        .target(
            name: "ContainerTestSupport",
            dependencies: [
                .product(name: "SystemPackage", package: "swift-system")
            ]
        ),
        .target(
            name: "MachineAPIClient",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "ContainerizationOCI", package: "containerization"),
                .product(name: "Logging", package: "swift-log"),
                "ContainerAPIClient",
                "ContainerPersistence",
                "ContainerResource",
                "ContainerXPC",
                "TerminalProgress",
            ],
            path: "Sources/Services/MachineAPIService/Client"
        ),
        .target(
            name: "MachineAPIService",
            dependencies: [
                .product(name: "Containerization", package: "containerization"),
                .product(name: "ContainerizationEXT4", package: "containerization"),
                .product(name: "ContainerizationExtras", package: "containerization"),
                .product(name: "ContainerizationOCI", package: "containerization"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "SystemPackage", package: "swift-system"),
                "ContainerAPIClient",
                "ContainerResource",
                "ContainerRuntimeClient",
                "ContainerXPC",
                "MachineAPIClient",
            ],
            path: "Sources/Services/MachineAPIService/Server"
        ),
        .executableTarget(
            name: "machine-apiserver",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Logging", package: "swift-log"),
                "ContainerAPIClient",
                "ContainerLog",
                "ContainerPersistence",
                "ContainerPlugin",
                "ContainerVersion",
                "ContainerXPC",
                "MachineAPIClient",
                "MachineAPIService",
            ],
            path: "Sources/Plugins/MachineAPIServer",
            exclude: ["config.toml", "Resources"]
        ),
    ]
)
