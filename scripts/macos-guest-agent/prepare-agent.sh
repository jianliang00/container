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

usage() {
  cat <<'EOF'
Usage:
  prepare-agent.sh --seed-dir <dir> [--guest-agent-bin <path>] [--scripts-dir <dir>] [--overwrite]

Options:
  --seed-dir           Output directory to create/populate.
  --guest-agent-bin    Path to container-macos-guest-agent binary.
  --scripts-dir        Directory containing install.sh, container-macos-guest-agent.plist, install-in-guest-from-seed.sh.
  --overwrite          Remove existing seed-dir before writing.

Environment:
  GUEST_AGENT_BIN can be used instead of --guest-agent-bin.
EOF
}

SEED_DIR=""
GUEST_AGENT_BIN_ARG=""
SCRIPTS_DIR_ARG=""
OVERWRITE="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --seed-dir)
      SEED_DIR="${2:-}"
      shift 2
      ;;
    --guest-agent-bin)
      GUEST_AGENT_BIN_ARG="${2:-}"
      shift 2
      ;;
    --scripts-dir)
      SCRIPTS_DIR_ARG="${2:-}"
      shift 2
      ;;
    --overwrite)
      OVERWRITE="true"
      shift 1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "${SEED_DIR}" ]]; then
  echo "--seed-dir is required" >&2
  usage >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS_DIR="${SCRIPTS_DIR_ARG:-$SCRIPT_DIR}"

GUEST_AGENT_BIN="${GUEST_AGENT_BIN_ARG:-${GUEST_AGENT_BIN:-}}"
if [[ -z "${GUEST_AGENT_BIN}" ]]; then
  if [[ -x "/usr/local/libexec/container/macos-guest-agent/bin/container-macos-guest-agent" ]]; then
    GUEST_AGENT_BIN="/usr/local/libexec/container/macos-guest-agent/bin/container-macos-guest-agent"
  else
    echo "Guest agent binary not specified. Provide --guest-agent-bin or set GUEST_AGENT_BIN." >&2
    exit 2
  fi
fi

if [[ ! -x "${GUEST_AGENT_BIN}" ]]; then
  echo "Guest agent binary is not executable: ${GUEST_AGENT_BIN}" >&2
  exit 2
fi

INSTALL_SH="${SCRIPTS_DIR}/install.sh"
PLIST_TEMPLATE="${SCRIPTS_DIR}/container-macos-guest-agent.plist"
INSTALL_FROM_SEED_SH="${SCRIPTS_DIR}/install-in-guest-from-seed.sh"

for required in "${INSTALL_SH}" "${PLIST_TEMPLATE}" "${INSTALL_FROM_SEED_SH}"; do
  if [[ ! -f "${required}" ]]; then
    echo "Missing required file: ${required}" >&2
    exit 2
  fi
done

if [[ -e "${SEED_DIR}" ]]; then
  if [[ "${OVERWRITE}" == "true" ]]; then
    rm -rf "${SEED_DIR}"
  else
    echo "Seed directory exists: ${SEED_DIR}. Use --overwrite to replace it." >&2
    exit 2
  fi
fi

mkdir -p "${SEED_DIR}"

install -m 0755 "${GUEST_AGENT_BIN}" "${SEED_DIR}/container-macos-guest-agent"
install -m 0755 "${INSTALL_SH}" "${SEED_DIR}/install.sh"
install -m 0644 "${PLIST_TEMPLATE}" "${SEED_DIR}/container-macos-guest-agent.plist"
install -m 0755 "${INSTALL_FROM_SEED_SH}" "${SEED_DIR}/install-in-guest-from-seed.sh"

echo "${SEED_DIR}"
