#!/bin/bash

set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "This script must run as root." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE="${SCRIPT_DIR}/container-macos-guest-agent.plist"
LABEL="com.apple.container.macos.guest-agent"
PLIST_DEST="/Library/LaunchDaemons/${LABEL}.plist"

BINARY_PATH="${1:-/usr/local/bin/container-macos-guest-agent}"
PORT="${CONTAINER_MACOS_AGENT_PORT:-27000}"

if [[ ! -x "${BINARY_PATH}" ]]; then
  echo "Guest agent binary is not executable: ${BINARY_PATH}" >&2
  exit 1
fi

TMP_PLIST="$(mktemp)"
trap 'rm -f "${TMP_PLIST}"' EXIT

sed \
  -e "s#__BINARY__#${BINARY_PATH}#g" \
  -e "s#__PORT__#${PORT}#g" \
  "${TEMPLATE}" > "${TMP_PLIST}"

install -m 0644 "${TMP_PLIST}" "${PLIST_DEST}"

launchctl bootout "system/${LABEL}" >/dev/null 2>&1 || true
launchctl bootstrap system "${PLIST_DEST}"
launchctl enable "system/${LABEL}"
launchctl kickstart -k "system/${LABEL}"

echo "Installed and started ${LABEL} on vsock port ${PORT}"
