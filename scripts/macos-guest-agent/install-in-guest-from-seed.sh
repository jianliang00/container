#!/bin/bash

set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "This script must run as root (use sudo)." >&2
  exit 1
fi

SEED_TAG="${CONTAINER_SEED_TAG:-seed}"
SEED_MOUNT="${CONTAINER_SEED_MOUNT:-/Volumes/${SEED_TAG}}"
AGENT_PORT="${CONTAINER_MACOS_AGENT_PORT:-27000}"
AGENT_DEST="${CONTAINER_MACOS_AGENT_BIN_PATH:-/usr/local/bin/container-macos-guest-agent}"
WORK_DIR="${CONTAINER_MACOS_AGENT_WORK_DIR:-/tmp/container-agent-install}"

AGENT_SRC="${SEED_MOUNT}/container-macos-guest-agent"
INSTALL_SRC="${SEED_MOUNT}/install.sh"
PLIST_SRC="${SEED_MOUNT}/container-macos-guest-agent.plist"

mkdir -p "${SEED_MOUNT}"
if ! mount | grep -F " on ${SEED_MOUNT} " | grep -q "virtio-fs"; then
  echo "Mounting virtiofs '${SEED_TAG}' at ${SEED_MOUNT}..."
  mount -t virtiofs "${SEED_TAG}" "${SEED_MOUNT}"
fi

for required in "${AGENT_SRC}" "${INSTALL_SRC}" "${PLIST_SRC}"; do
  if [[ ! -f "${required}" ]]; then
    echo "Missing required file in seed share: ${required}" >&2
    exit 1
  fi
done

install -d "$(dirname "${AGENT_DEST}")"
install -m 0755 "${AGENT_SRC}" "${AGENT_DEST}"

mkdir -p "${WORK_DIR}"
cp "${INSTALL_SRC}" "${WORK_DIR}/install.sh"
cp "${PLIST_SRC}" "${WORK_DIR}/container-macos-guest-agent.plist"
chmod +x "${WORK_DIR}/install.sh"

(
  cd "${WORK_DIR}"
  CONTAINER_MACOS_AGENT_PORT="${AGENT_PORT}" ./install.sh "${AGENT_DEST}"
)

echo "Guest agent installed."
echo "Validate with:"
echo "  sudo launchctl print system/com.apple.container.macos.guest-agent | head -n 40"
echo "  sudo tail -n 50 /var/log/container-macos-guest-agent.log"
