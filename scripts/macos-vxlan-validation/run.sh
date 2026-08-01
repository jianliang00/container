#!/bin/bash
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

MODE="${1:-all}"
case "${MODE}" in
    all|forwarding|benchmark) ;;
    *)
        echo "usage: $0 [all|forwarding|benchmark]" >&2
        exit 2
        ;;
esac

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SOURCE_DIR="${ROOT_DIR}/scripts/macos-vxlan-validation"
BUILD_DIR="${MACOS_VXLAN_VALIDATION_BUILD_DIR:-${ROOT_DIR}/.build/macos-vxlan-validation}"
mkdir -p "${BUILD_DIR}"

echo "host_os=$(sw_vers -productVersion)"
echo "host_build=$(sw_vers -buildVersion)"
echo "host_arch=$(uname -m)"
echo "xcode=$(xcodebuild -version | tr '\n' ' ')"

if [[ "${MODE}" == "all" || "${MODE}" == "forwarding" ]]; then
    clang \
        -std=c17 \
        -Wall \
        -Wextra \
        -Werror \
        -fblocks \
        -framework vmnet \
        "${SOURCE_DIR}/host_forwarding.c" \
        -o "${BUILD_DIR}/host-forwarding"
    codesign \
        --force \
        --sign - \
        --entitlements "${ROOT_DIR}/signing/container-network-vmnet.entitlements" \
        "${BUILD_DIR}/host-forwarding"
    sudo -n "${BUILD_DIR}/host-forwarding"
fi

if [[ "${MODE}" == "all" || "${MODE}" == "benchmark" ]]; then
    clang \
        -std=c17 \
        -Wall \
        -Wextra \
        -Werror \
        -pthread \
        "${SOURCE_DIR}/vxlan_benchmark.c" \
        -o "${BUILD_DIR}/vxlan-benchmark"
    "${BUILD_DIR}/vxlan-benchmark" --duration "${VXLAN_BENCHMARK_DURATION:-5}"
    "${BUILD_DIR}/vxlan-benchmark" \
        --duration "${VXLAN_SOAK_DURATION:-60}" \
        --packet-size 1400 \
        --target-gbps "${VXLAN_SOAK_TARGET_GBPS:-0.5}" \
        --max-loss-percent "${VXLAN_SOAK_MAX_LOSS_PERCENT:-0.01}"
fi
