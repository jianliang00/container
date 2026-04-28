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

LABEL="com.apple.container.kube-proxy-macos"
PLIST_DEST="/Library/LaunchDaemons/${LABEL}.plist"
PF_CONFIG="/etc/pf.conf"
PF_ANCHORS="/etc/pf.anchors"
PFCTL_PATH="/sbin/pfctl"
DRY_RUN=false
REMOVE_PF_ANCHOR=true

usage() {
  cat <<EOF
Usage: $0 [options]

Uninstall the macOS kube-proxy launchd service.

Options:
  --plist-dest PATH      LaunchDaemon plist path. Default: ${PLIST_DEST}
  --pf-config PATH       PF config path. Default: ${PF_CONFIG}
  --pf-anchors PATH      PF anchors directory. Default: ${PF_ANCHORS}
  --pfctl PATH           pfctl path. Default: ${PFCTL_PATH}
  --keep-pf-anchor       Leave PF anchor file and pf.conf references in place.
  --dry-run              Print the actions without changing the system.
  -h, --help             Show this help.
EOF
}

quote() {
  printf "'%s'" "${1//\'/\'\\\'\'}"
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

remove_pf_anchor() {
  local anchor_path="${PF_ANCHORS}/${LABEL}"
  local tmp_config

  if [[ "${DRY_RUN}" == true ]]; then
    echo "+ remove exact '${LABEL}' rdr-anchor/load anchor lines from $(quote "${PF_CONFIG}")"
    echo "+ $(quote "${PFCTL_PATH}") -n -f <candidate-pf.conf>"
    echo "+ install candidate pf.conf to $(quote "${PF_CONFIG}")"
    echo "+ rm -f $(quote "${anchor_path}")"
    echo "+ $(quote "${PFCTL_PATH}") -f $(quote "${PF_CONFIG}")"
    return 0
  fi

  if [[ ! -f "${PF_CONFIG}" ]]; then
    rm -f "${anchor_path}"
    return 0
  fi

  tmp_config="$(mktemp)"
  trap 'rm -f "${tmp_config}"' RETURN

  grep -v -F \
    -e "rdr-anchor \"${LABEL}\"" \
    -e "load anchor \"${LABEL}\" from \"${anchor_path}\"" \
    "${PF_CONFIG}" > "${tmp_config}" || true

  "${PFCTL_PATH}" -n -f "${tmp_config}"
  install -m 0644 "${tmp_config}" "${PF_CONFIG}"
  rm -f "${anchor_path}"
  "${PFCTL_PATH}" -f "${PF_CONFIG}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --plist-dest)
      PLIST_DEST="$2"
      shift 2
      ;;
    --pf-config)
      PF_CONFIG="$2"
      shift 2
      ;;
    --pf-anchors)
      PF_ANCHORS="$2"
      shift 2
      ;;
    --pfctl)
      PFCTL_PATH="$2"
      shift 2
      ;;
    --keep-pf-anchor)
      REMOVE_PF_ANCHOR=false
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
fi

run_best_effort launchctl bootout "system/${LABEL}"
run rm -f "${PLIST_DEST}"

if [[ "${REMOVE_PF_ANCHOR}" == true ]]; then
  remove_pf_anchor
fi

echo "Uninstalled ${LABEL}"
