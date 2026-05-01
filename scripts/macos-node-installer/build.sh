#!/usr/bin/env bash
#
# Copyright © 2026 Apple Inc. and the container project authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#   https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -euo pipefail

usage() {
    cat <<'EOF'
Usage: scripts/macos-node-installer/build.sh --kubelet-artifact PATH [options]

Builds a macOS Kubernetes worker-node installer package that embeds a forked
Darwin arm64 kubelet artifact.

Required:
  --kubelet-artifact PATH     kubelet binary, extracted artifact directory, or
                              kubelet-darwin-arm64-*.tar.gz release artifact

Options:
  --node-name NAME            node name substituted into kubelet and kube-proxy
                              templates. Default: macos-node-1
  --build-configuration NAME  Swift build configuration. Default: release
  --output PATH               output pkg path. Default:
                              bin/<configuration>/container-macos-node-<version>-k8s-v1.27.2.pkg
  --package-version VERSION   pkg version. Default: RELEASE_VERSION or git describe
  --skip-build                use existing Swift build outputs
  --skip-codesign             do not codesign staged executables
  --dry-run                   resolve inputs and print the planned package
                              layout without building or writing pkg output
  -h, --help                  show this help

Environment:
  RELEASE_VERSION             default package version
  CODESIGN_IDENTITY           executable signing identity. Default: ad-hoc '-'
  CODESIGN_TIMESTAMP_OPTS     codesign timestamp flags. Default: --timestamp=none
  CODESIGN_EXTRA_OPTS         additional codesign flags
  CODESIGN_KEYCHAIN           optional codesign keychain
  PKG_SIGN_IDENTITY           productsign identity for the pkg
  PKG_SIGN_TIMESTAMP_OPTS     productsign timestamp flags. Default: --timestamp
  PKG_SIGN_KEYCHAIN           optional productsign keychain
EOF
}

fail() {
    echo "error: $*" >&2
    exit 2
}

log() {
    printf '[macos-node-installer] %s\n' "$*"
}

ROOT_DIR="$(git rev-parse --show-toplevel)"
SWIFT="${SWIFT:-/usr/bin/swift}"
PACKAGING_DIR="${ROOT_DIR}/packaging/macos-node"
K8S_BASELINE="v1.27.2"
NODE_NAME="${NODE_NAME:-macos-node-1}"
BUILD_CONFIGURATION="${BUILD_CONFIGURATION:-release}"
PACKAGE_VERSION="${RELEASE_VERSION:-}"
KUBELET_ARTIFACT=""
OUTPUT_PATH=""
SKIP_BUILD=false
SKIP_CODESIGN=false
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --kubelet-artifact)
            [[ $# -ge 2 ]] || fail "--kubelet-artifact requires a path"
            KUBELET_ARTIFACT="$2"
            shift 2
            ;;
        --node-name)
            [[ $# -ge 2 ]] || fail "--node-name requires a value"
            NODE_NAME="$2"
            shift 2
            ;;
        --build-configuration)
            [[ $# -ge 2 ]] || fail "--build-configuration requires a value"
            BUILD_CONFIGURATION="$2"
            shift 2
            ;;
        --output)
            [[ $# -ge 2 ]] || fail "--output requires a path"
            OUTPUT_PATH="$2"
            shift 2
            ;;
        --package-version)
            [[ $# -ge 2 ]] || fail "--package-version requires a value"
            PACKAGE_VERSION="$2"
            shift 2
            ;;
        --skip-build)
            SKIP_BUILD=true
            shift
            ;;
        --skip-codesign)
            SKIP_CODESIGN=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            fail "unknown argument: $1"
            ;;
    esac
done

[[ -n "$KUBELET_ARTIFACT" ]] || fail "--kubelet-artifact is required"
[[ "$BUILD_CONFIGURATION" == "debug" || "$BUILD_CONFIGURATION" == "release" ]] || fail "--build-configuration must be debug or release"
[[ "$NODE_NAME" =~ ^[A-Za-z0-9._-]+$ ]] || fail "--node-name may only contain letters, numbers, '.', '_', and '-'"

if [[ -z "$PACKAGE_VERSION" ]]; then
    PACKAGE_VERSION="$(git -C "$ROOT_DIR" describe --tags --always 2>/dev/null || echo dev)"
fi

if [[ -z "$OUTPUT_PATH" ]]; then
    OUTPUT_PATH="${ROOT_DIR}/bin/${BUILD_CONFIGURATION}/container-macos-node-${PACKAGE_VERSION}-k8s-${K8S_BASELINE}.pkg"
elif [[ "$OUTPUT_PATH" != /* ]]; then
    OUTPUT_PATH="${ROOT_DIR}/${OUTPUT_PATH}"
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/container-macos-node-installer.XXXXXX")"
cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

find_kubelet_binary() {
    local base="$1"
    local candidate
    for candidate in \
        "${base}/bin/kubelet" \
        "${base}/kubelet" \
        "${base}/usr/local/bin/kubelet"
    do
        if [[ -f "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

resolve_kubelet() {
    local source="$1"
    local candidate=""
    local extracted="${WORK_DIR}/kubelet-artifact"

    [[ -e "$source" ]] || fail "kubelet artifact does not exist: $source"

    if [[ -d "$source" ]]; then
        candidate="$(find_kubelet_binary "$source" || true)"
    elif [[ "$source" == *.tar.gz || "$source" == *.tgz ]]; then
        mkdir -p "$extracted"
        tar -xzf "$source" -C "$extracted"
        candidate="$(find_kubelet_binary "$extracted" || true)"
    elif [[ -f "$source" ]]; then
        candidate="$source"
    fi

    [[ -n "$candidate" && -f "$candidate" ]] || fail "could not find kubelet binary in artifact: $source"
    printf '%s\n' "$candidate"
}

install_template() {
    local source="$1"
    local dest="$2"
    local mode="$3"

    mkdir -p "$(dirname "$dest")"
    sed -e "s#__NODE_NAME__#${NODE_NAME}#g" "$source" > "$dest"
    chmod "$mode" "$dest"
}

codesign_path() {
    local path="$1"
    shift

    local identity="${CODESIGN_IDENTITY:--}"
    local timestamp_opts="${CODESIGN_TIMESTAMP_OPTS:---timestamp=none}"
    local keychain="${CODESIGN_KEYCHAIN:-}"
    local -a args=(--force --sign "$identity")

    if [[ -n "$timestamp_opts" ]]; then
        # shellcheck disable=SC2206
        args+=($timestamp_opts)
    fi
    if [[ -n "${CODESIGN_EXTRA_OPTS:-}" ]]; then
        # shellcheck disable=SC2206
        args+=(${CODESIGN_EXTRA_OPTS})
    fi
    if [[ -n "$keychain" ]]; then
        args+=(--keychain "$keychain")
    fi
    args+=("$@" "$path")

    codesign "${args[@]}"
}

stage_file() {
    local source="$1"
    local dest="$2"
    local mode="$3"

    [[ -f "$source" ]] || fail "required file is missing: $source"
    mkdir -p "$(dirname "$dest")"
    install -m "$mode" "$source" "$dest"
}

KUBELET_BINARY="$(resolve_kubelet "$KUBELET_ARTIFACT")"
BUILD_BIN_DIR="$("$SWIFT" build -c "$BUILD_CONFIGURATION" --show-bin-path)"
PKGROOT="${ROOT_DIR}/bin/${BUILD_CONFIGURATION}/macos-node-pkgroot"
PKG_UNSIGNED_PATH="$OUTPUT_PATH"

if [[ -n "${PKG_SIGN_IDENTITY:-}" ]]; then
    PKG_UNSIGNED_PATH="${OUTPUT_PATH%.pkg}-unsigned.pkg"
fi

log "node name: ${NODE_NAME}"
log "package version: ${PACKAGE_VERSION}"
log "kubelet binary: ${KUBELET_BINARY}"
log "Swift build output: ${BUILD_BIN_DIR}"
log "package output: ${OUTPUT_PATH}"

if [[ "$DRY_RUN" == true ]]; then
    log "dry run: package would stage into ${PKGROOT}"
    log "dry run: package would install kubelet, container binaries, CRI/CNI/kube-proxy configs, and launchd plists"
    exit 0
fi

if [[ "$SKIP_BUILD" != true ]]; then
    log "building Swift package (${BUILD_CONFIGURATION})"
    "$SWIFT" build -c "$BUILD_CONFIGURATION"
fi

rm -rf "$PKGROOT"
mkdir -p \
    "${PKGROOT}/usr/local/bin" \
    "${PKGROOT}/usr/local/libexec/container/plugins/container-runtime-macos/bin" \
    "${PKGROOT}/usr/local/libexec/container/plugins/container-network-vmnet/bin" \
    "${PKGROOT}/usr/local/libexec/container/plugins/container-core-images/bin" \
    "${PKGROOT}/usr/local/libexec/container/macos-guest-agent/bin" \
    "${PKGROOT}/usr/local/libexec/container/macos-image-prepare/bin" \
    "${PKGROOT}/usr/local/libexec/container/macos-vm-manager/bin" \
    "${PKGROOT}/usr/local/share/container-macos-node/manifests" \
    "${PKGROOT}/etc/kubernetes/manifests" \
    "${PKGROOT}/etc/kubernetes/pki" \
    "${PKGROOT}/etc/cni/net.d" \
    "${PKGROOT}/opt/cni/bin" \
    "${PKGROOT}/Library/LaunchDaemons" \
    "${PKGROOT}/var/lib/kubelet" \
    "${PKGROOT}/var/lib/container/cri-shim-macos" \
    "${PKGROOT}/var/lib/container/cni/macvmnet" \
    "${PKGROOT}/var/log/pods" \
    "${PKGROOT}/var/log/containers"

stage_file "${BUILD_BIN_DIR}/container" "${PKGROOT}/usr/local/bin/container" 0755
stage_file "${BUILD_BIN_DIR}/container-apiserver" "${PKGROOT}/usr/local/bin/container-apiserver" 0755
stage_file "${BUILD_BIN_DIR}/container-cri-shim-macos" "${PKGROOT}/usr/local/bin/container-cri-shim-macos" 0755
stage_file "${BUILD_BIN_DIR}/container-cni-macvmnet" "${PKGROOT}/usr/local/bin/container-cni-macvmnet" 0755
stage_file "${BUILD_BIN_DIR}/container-cni-macvmnet" "${PKGROOT}/opt/cni/bin/container-cni-macvmnet" 0755
stage_file "${BUILD_BIN_DIR}/container-kube-proxy-macos" "${PKGROOT}/usr/local/bin/container-kube-proxy-macos" 0755
stage_file "${BUILD_BIN_DIR}/container-k8s-networkpolicy-macos" "${PKGROOT}/usr/local/bin/container-k8s-networkpolicy-macos" 0755
stage_file "${BUILD_BIN_DIR}/container-macos-kubeadm" "${PKGROOT}/usr/local/bin/container-macos-kubeadm" 0755
stage_file "$KUBELET_BINARY" "${PKGROOT}/usr/local/bin/kubelet" 0755

stage_file "${BUILD_BIN_DIR}/container-runtime-macos" "${PKGROOT}/usr/local/libexec/container/plugins/container-runtime-macos/bin/container-runtime-macos" 0755
stage_file "${BUILD_BIN_DIR}/container-runtime-macos-sidecar" "${PKGROOT}/usr/local/libexec/container/plugins/container-runtime-macos/bin/container-runtime-macos-sidecar" 0755
stage_file "${ROOT_DIR}/config/container-runtime-macos-config.json" "${PKGROOT}/usr/local/libexec/container/plugins/container-runtime-macos/config.json" 0644
stage_file "${BUILD_BIN_DIR}/container-network-vmnet" "${PKGROOT}/usr/local/libexec/container/plugins/container-network-vmnet/bin/container-network-vmnet" 0755
stage_file "${ROOT_DIR}/config/container-network-vmnet-config.json" "${PKGROOT}/usr/local/libexec/container/plugins/container-network-vmnet/config.json" 0644
stage_file "${BUILD_BIN_DIR}/container-core-images" "${PKGROOT}/usr/local/libexec/container/plugins/container-core-images/bin/container-core-images" 0755
stage_file "${ROOT_DIR}/config/container-core-images-config.json" "${PKGROOT}/usr/local/libexec/container/plugins/container-core-images/config.json" 0644
stage_file "${BUILD_BIN_DIR}/container-macos-guest-agent" "${PKGROOT}/usr/local/libexec/container/macos-guest-agent/bin/container-macos-guest-agent" 0755
stage_file "${BUILD_BIN_DIR}/container-macos-image-prepare" "${PKGROOT}/usr/local/libexec/container/macos-image-prepare/bin/container-macos-image-prepare" 0755
stage_file "${BUILD_BIN_DIR}/container-macos-vm-manager" "${PKGROOT}/usr/local/libexec/container/macos-vm-manager/bin/container-macos-vm-manager" 0755

stage_file "${PACKAGING_DIR}/config/container-cri-shim-macos-config.json" "${PKGROOT}/etc/kubernetes/container-cri-shim-macos-config.json" 0644
stage_file "${PACKAGING_DIR}/config/container-cni-macvmnet.conflist" "${PKGROOT}/etc/cni/net.d/10-macvmnet.conflist" 0644
install_template "${PACKAGING_DIR}/config/kube-proxy.conf" "${PKGROOT}/etc/kubernetes/kube-proxy.conf" 0644
stage_file "${PACKAGING_DIR}/config/kubelet-config.yaml" "${PKGROOT}/etc/kubernetes/kubelet-config.yaml" 0644
stage_file "${PACKAGING_DIR}/manifests/runtimeclass-macos.yaml" "${PKGROOT}/usr/local/share/container-macos-node/manifests/runtimeclass-macos.yaml" 0644
stage_file "${PACKAGING_DIR}/manifests/macos-node-bootstrap-rbac.yaml" "${PKGROOT}/usr/local/share/container-macos-node/manifests/macos-node-bootstrap-rbac.yaml" 0644

install_template "${PACKAGING_DIR}/launchd/com.apple.container.cri-shim-macos.plist" "${PKGROOT}/Library/LaunchDaemons/com.apple.container.cri-shim-macos.plist" 0644
install_template "${PACKAGING_DIR}/launchd/com.apple.container.kube-proxy-macos.plist" "${PKGROOT}/Library/LaunchDaemons/com.apple.container.kube-proxy-macos.plist" 0644
install_template "${PACKAGING_DIR}/launchd/com.apple.container.kubelet.plist" "${PKGROOT}/Library/LaunchDaemons/com.apple.container.kubelet.plist" 0644

cat > "${PKGROOT}/usr/local/share/container-macos-node/release-manifest.json" <<EOF
{
    "package": "container-macos-node",
    "packageVersion": "${PACKAGE_VERSION}",
    "kubernetesBaseline": "${K8S_BASELINE}",
    "nodeName": "${NODE_NAME}",
    "containerCommit": "$(git -C "$ROOT_DIR" rev-parse HEAD)",
    "kubeletArtifact": "$(basename "$KUBELET_ARTIFACT")"
}
EOF
chmod 0644 "${PKGROOT}/usr/local/share/container-macos-node/release-manifest.json"

if [[ "$SKIP_CODESIGN" != true ]]; then
    log "codesigning staged executables"
    codesign_path "${PKGROOT}/usr/local/bin/container" --identifier com.apple.container.cli
    codesign_path "${PKGROOT}/usr/local/bin/container-apiserver" --identifier com.apple.container.apiserver
    codesign_path "${PKGROOT}/usr/local/bin/container-cri-shim-macos" --prefix=com.apple.container.
    codesign_path "${PKGROOT}/usr/local/bin/container-cni-macvmnet" --prefix=com.apple.container.
    codesign_path "${PKGROOT}/opt/cni/bin/container-cni-macvmnet" --prefix=com.apple.container.
    codesign_path "${PKGROOT}/usr/local/bin/container-kube-proxy-macos" --prefix=com.apple.container.
    codesign_path "${PKGROOT}/usr/local/bin/container-k8s-networkpolicy-macos" --prefix=com.apple.container.
    codesign_path "${PKGROOT}/usr/local/bin/container-macos-kubeadm" --prefix=com.apple.container.
    codesign_path "${PKGROOT}/usr/local/bin/kubelet" --identifier com.apple.container.kubelet
    codesign_path "${PKGROOT}/usr/local/libexec/container/plugins/container-runtime-macos/bin/container-runtime-macos" --prefix=com.apple.container. --entitlements="${ROOT_DIR}/signing/container-runtime-macos.entitlements"
    codesign_path "${PKGROOT}/usr/local/libexec/container/plugins/container-runtime-macos/bin/container-runtime-macos-sidecar" --prefix=com.apple.container. --entitlements="${ROOT_DIR}/signing/container-runtime-macos.entitlements"
    codesign_path "${PKGROOT}/usr/local/libexec/container/plugins/container-network-vmnet/bin/container-network-vmnet" --prefix=com.apple.container. --entitlements="${ROOT_DIR}/signing/container-network-vmnet.entitlements"
    codesign_path "${PKGROOT}/usr/local/libexec/container/plugins/container-core-images/bin/container-core-images" --prefix=com.apple.container.
    codesign_path "${PKGROOT}/usr/local/libexec/container/macos-guest-agent/bin/container-macos-guest-agent" --prefix=com.apple.container.
    codesign_path "${PKGROOT}/usr/local/libexec/container/macos-image-prepare/bin/container-macos-image-prepare" --prefix=com.apple.container. --entitlements="${ROOT_DIR}/signing/container-runtime-macos.entitlements"
    codesign_path "${PKGROOT}/usr/local/libexec/container/macos-vm-manager/bin/container-macos-vm-manager" --prefix=com.apple.container. --entitlements="${ROOT_DIR}/signing/container-runtime-macos.entitlements"
fi

mkdir -p "$(dirname "$OUTPUT_PATH")"
rm -f "$PKG_UNSIGNED_PATH" "$OUTPUT_PATH"

log "creating pkg"
pkgbuild \
    --root "$PKGROOT" \
    --identifier com.apple.container.macos-node \
    --install-location / \
    --version "$PACKAGE_VERSION" \
    --ownership recommended \
    "$PKG_UNSIGNED_PATH"

if [[ -n "${PKG_SIGN_IDENTITY:-}" ]]; then
    log "signing pkg"
    product_args=(--sign "$PKG_SIGN_IDENTITY")
    if [[ -n "${PKG_SIGN_TIMESTAMP_OPTS:---timestamp}" ]]; then
        # shellcheck disable=SC2206
        product_args+=(${PKG_SIGN_TIMESTAMP_OPTS:---timestamp})
    fi
    if [[ -n "${PKG_SIGN_KEYCHAIN:-}" ]]; then
        product_args+=(--keychain "$PKG_SIGN_KEYCHAIN")
    fi
    productsign "${product_args[@]}" "$PKG_UNSIGNED_PATH" "$OUTPUT_PATH"
    rm -f "$PKG_UNSIGNED_PATH"
fi

rm -rf "$PKGROOT"
log "wrote ${OUTPUT_PATH}"
