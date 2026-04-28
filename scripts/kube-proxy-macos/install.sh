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

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE="${SCRIPT_DIR}/container-kube-proxy-macos.plist"
LABEL="com.apple.container.kube-proxy-macos"

BINARY_PATH="/usr/local/bin/container-kube-proxy-macos"
CONFIG_PATH="/etc/kubernetes/kube-proxy.conf"
PLIST_DEST="/Library/LaunchDaemons/${LABEL}.plist"
DRY_RUN=false
START_SERVICE=true
PFCTL_PATH="/sbin/pfctl"

usage() {
  cat <<EOF
Usage: $0 [options]

Install the macOS kube-proxy launchd service.

Options:
  --binary PATH       container-kube-proxy-macos binary path. Default: ${BINARY_PATH}
  --config PATH       kube-proxy macOS JSON config path. Default: ${CONFIG_PATH}
  --plist-dest PATH   LaunchDaemon plist destination. Default: ${PLIST_DEST}
  --pfctl PATH        pfctl path used for PF status checks. Default: ${PFCTL_PATH}
  --no-start          Install the plist but do not bootstrap/kickstart launchd.
  --dry-run           Print the actions without changing the system.
  -h, --help          Show this help.
EOF
}

quote() {
  printf "'%s'" "${1//\'/\'\\\'\'}"
}

sed_replacement() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//&/\\&}"
  value="${value//#/\\#}"
  printf '%s' "${value}"
}

xml_escape() {
  local value="$1"
  value="${value//&/&amp;}"
  value="${value//</&lt;}"
  value="${value//>/&gt;}"
  value="${value//\"/&quot;}"
  printf '%s' "${value}"
}

run() {
  if [[ "${DRY_RUN}" == true ]]; then
    printf '+'
    for arg in "$@"; do
      printf ' %s' "$(quote "$arg")"
    done
    printf '\n'
    return 0
  fi
  "$@"
}

run_best_effort() {
  if [[ "${DRY_RUN}" == true ]]; then
    run "$@"
    return 0
  fi
  "$@" >/dev/null 2>&1 || true
}

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "This script must run as root. Re-run with sudo, or use --dry-run to inspect actions." >&2
    exit 1
  fi
}

require_pf_enabled() {
  if [[ "${DRY_RUN}" == true ]]; then
    echo "+ $(quote "${PFCTL_PATH}") -s info | grep -q 'Status: Enabled'"
    return 0
  fi
  if ! "${PFCTL_PATH}" -s info | grep -q 'Status: Enabled'; then
    echo "PF is not enabled. Enable PF before starting ${LABEL}; this installer will not run pfctl -e automatically." >&2
    exit 1
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --binary)
      BINARY_PATH="$2"
      shift 2
      ;;
    --config)
      CONFIG_PATH="$2"
      shift 2
      ;;
    --plist-dest)
      PLIST_DEST="$2"
      shift 2
      ;;
    --pfctl)
      PFCTL_PATH="$2"
      shift 2
      ;;
    --no-start)
      START_SERVICE=false
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ "${DRY_RUN}" != true ]]; then
  require_root
  if [[ ! -x "${BINARY_PATH}" ]]; then
    echo "kube-proxy binary is not executable: ${BINARY_PATH}" >&2
    exit 1
  fi
  if [[ ! -r "${CONFIG_PATH}" ]]; then
    echo "kube-proxy config is not readable: ${CONFIG_PATH}" >&2
    exit 1
  fi
fi

require_pf_enabled

TMP_PLIST="$(mktemp)"
trap 'rm -f "${TMP_PLIST}"' EXIT
BINARY_REPLACEMENT="$(sed_replacement "$(xml_escape "${BINARY_PATH}")")"
CONFIG_REPLACEMENT="$(sed_replacement "$(xml_escape "${CONFIG_PATH}")")"

sed \
  -e "s#__BINARY__#${BINARY_REPLACEMENT}#g" \
  -e "s#__CONFIG__#${CONFIG_REPLACEMENT}#g" \
  "${TEMPLATE}" > "${TMP_PLIST}"

plutil -lint "${TMP_PLIST}" >/dev/null

run install -m 0644 "${TMP_PLIST}" "${PLIST_DEST}"

if [[ "${START_SERVICE}" == true ]]; then
  run_best_effort launchctl bootout "system/${LABEL}"
  run launchctl bootstrap system "${PLIST_DEST}"
  run launchctl enable "system/${LABEL}"
  run launchctl kickstart -k "system/${LABEL}"
fi

echo "Installed ${LABEL} with config ${CONFIG_PATH}"
