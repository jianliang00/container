#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
resolution_mode="${CONTAINER_SWIFTPM_RESOLUTION_MODE:-locked}"
cache_path="${CONTAINER_SWIFTPM_CACHE_PATH:-}"

consumer_dir="$(mktemp -d "${TMPDIR:-/tmp}/container-swiftpm-consumer.XXXXXX")"
trap 'rm -rf "${consumer_dir}"' EXIT

mkdir -p "${consumer_dir}/Sources/Consumer"

package_path="${repo_root//\\/\\\\}"
package_path="${package_path//\"/\\\"}"

resolver_args=()
if [[ "${resolution_mode}" == "locked" ]]; then
    if [[ ! -f "${repo_root}/Package.resolved" ]]; then
        echo "error: Package.resolved is required when CONTAINER_SWIFTPM_RESOLUTION_MODE=locked" >&2
        exit 1
    fi
    cp "${repo_root}/Package.resolved" "${consumer_dir}/Package.resolved"
    resolver_args+=(--only-use-versions-from-resolved-file)
elif [[ "${resolution_mode}" != "fresh" ]]; then
    echo "error: unsupported CONTAINER_SWIFTPM_RESOLUTION_MODE=${resolution_mode} (expected locked or fresh)" >&2
    exit 1
fi

cat > "${consumer_dir}/Package.swift" <<EOF
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ContainerKitConsumerSmoke",
    platforms: [.macOS("15")],
    dependencies: [
        .package(path: "${package_path}")
    ],
    targets: [
        .executableTarget(
            name: "Consumer",
            dependencies: [
                .product(name: "ContainerKit", package: "container"),
                .product(name: "ContainerKitServices", package: "container"),
            ]
        )
    ]
)
EOF

cat > "${consumer_dir}/Sources/Consumer/main.swift" <<'EOF'
import ContainerKit
import ContainerKitServices
import Foundation

@main
struct ConsumerSmoke {
    static func main() async throws {
        let _: ContainerConfiguration.Type = ContainerConfiguration.self
        let _: ContainerCreateOptions.Type = ContainerCreateOptions.self
        let _: ContainerListFilters.Type = ContainerListFilters.self
        let _: ContainerSnapshot.Type = ContainerSnapshot.self
        let _: ContainerStopOptions.Type = ContainerStopOptions.self
        let _: DiskUsageStats.Type = DiskUsageStats.self
        let _: Image.Type = Image.self
        let _: NetworkConfiguration.Type = NetworkConfiguration.self
        let _: NetworkState.Type = NetworkState.self
        let _: ProcessConfiguration.Type = ProcessConfiguration.self
        let _: ServiceStatus.Type = ServiceStatus.self
        let _: SystemHealth.Type = SystemHealth.self
        let _: Volume.Type = Volume.self

        let kit = ContainerKit()
        let _: (Duration?) async throws -> SystemHealth = { timeout in
            try await kit.health(timeout: timeout)
        }

        let installation = ContainerInstallation(
            installRoot: URL(fileURLWithPath: "/usr/local"),
            apiServerExecutableURL: URL(fileURLWithPath: "/usr/local/bin/container-apiserver")
        )
        let services = ContainerKitServices(installation: installation)
        let _: () async throws -> ServiceStatus = {
            try await services.status()
        }
        let _: (Duration) async throws -> Void = { timeout in
            try await services.ensureRunning(timeout: timeout)
        }

        _ = services
    }
}
EOF

echo "Verifying external SwiftPM consumer integration using ${resolution_mode} dependency resolution"
build_args=(
    --package-path "${consumer_dir}"
    --configuration release
)

if [[ -n "${cache_path}" ]]; then
    mkdir -p "${cache_path}"
    build_args+=(--cache-path "${cache_path}")
fi

swift build "${build_args[@]}" "${resolver_args[@]}"
