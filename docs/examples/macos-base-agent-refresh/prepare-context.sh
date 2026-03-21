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

REPO_ROOT="${REPO_ROOT:-$(pwd)}"
CONTEXT_DIR="${REPO_ROOT}/docs/examples/macos-base-agent-refresh"

if [[ -n "${CONTAINER_MACOS_GUEST_AGENT_BIN:-}" ]]; then
  GUEST_AGENT_BIN="${CONTAINER_MACOS_GUEST_AGENT_BIN}"
else
  GUEST_AGENT_BIN="${REPO_ROOT}/libexec/container/macos-guest-agent/bin/container-macos-guest-agent"
fi

if [[ ! -x "${GUEST_AGENT_BIN}" ]]; then
  echo "Guest agent binary is missing or not executable: ${GUEST_AGENT_BIN}" >&2
  echo "Build it first with 'make release' or 'xcrun swift build -c release --product container-macos-guest-agent'." >&2
  exit 1
fi

install -m 0755 "${GUEST_AGENT_BIN}" "${CONTEXT_DIR}/container-macos-guest-agent"
echo "${CONTEXT_DIR}/container-macos-guest-agent"
