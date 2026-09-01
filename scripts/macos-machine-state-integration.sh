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

if [ "${CONTAINER_MACOS_MACHINE_STATE_INTEGRATION_ROOT:-}" = "" ]; then
    echo "CONTAINER_MACOS_MACHINE_STATE_INTEGRATION_ROOT must name a provisioned VM runtime directory" >&2
    exit 2
fi

if [ "${DEVELOPER_DIR:-}" = "" ] && [ -d /Applications/Xcode-26.3.app/Contents/Developer ]; then
    DEVELOPER_DIR=/Applications/Xcode-26.3.app/Contents/Developer
    export DEVELOPER_DIR
fi

exec swift test --filter MachineStateRealMacIntegrationTests
