#!/bin/sh
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

set -eu

# Kubernetes nodes require protection in the installed CRI, not just a candidate
# sidecar. Keep the standalone VM entrypoint usable without Kubernetes.
exec python3 "$(dirname "$0")/macos-storage-preflight.py" \
    --node "${MACOS_STORAGE_NODE:?required}" \
    --node-uid "${MACOS_STORAGE_NODE_UID:?required}" \
    --kubelet-evidence "${MACOS_STORAGE_KUBELET_EVIDENCE:?required}" \
    --endpoint "${MACOS_STORAGE_CRI_ENDPOINT:?required}" \
    --require-pinned "${MACOS_STORAGE_BASE_IMAGE_ID:?required}" \
    --peak-additional-bytes "${MACOS_STORAGE_PEAK_ADDITIONAL_BYTES:?required}" \
    --lock-file "${MACOS_STORAGE_LOCK_FILE:?required}" \
    --storage-root "${CONTAINER_MACOS_MACHINE_STATE_INTEGRATION_ROOT:?required}" \
    --storage-root "${PWD}" \
    -- sh "$(dirname "$0")/macos-machine-state-integration.sh"
