#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

XCODE_XIP="${XCODE_XIP:-${REPO_ROOT}/Xcode_26.3_Apple_silicon.xip}"
XCODE_OUT="${SCRIPT_DIR}/Xcode.xip"

if [[ ! -e "${XCODE_XIP}" ]]; then
  echo "Xcode archive not found: ${XCODE_XIP}" >&2
  exit 2
fi

rm -f "${XCODE_OUT}"
if ! ln -f "${XCODE_XIP}" "${XCODE_OUT}" 2>/dev/null; then
  cp -f "${XCODE_XIP}" "${XCODE_OUT}"
fi

echo "Prepared build context in ${SCRIPT_DIR}"
echo "  Xcode.xip  $(du -sh "${XCODE_OUT}" | awk '{print $1}')"
