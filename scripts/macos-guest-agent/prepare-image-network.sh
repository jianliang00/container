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

if [[ "$(id -u)" -ne 0 || $# -ne 1 || -z "$1" ]]; then
    echo "Usage (as root inside the GUI image before capture): $0 <network-service>" >&2
    exit 1
fi

service="$1"
marker=/var/db/container-macos-deferred-network-service
services=$(/usr/sbin/networksetup -listallnetworkservices)
if ! /usr/bin/grep -Fx -- "$service" <<< "$services" >/dev/null &&
   ! /usr/bin/grep -Fx -- "*$service" <<< "$services" >/dev/null; then
    echo "Network service not found: $service" >&2
    exit 1
fi

printf '%s\n' "$service" > "$marker"
/usr/sbin/networksetup -setnetworkserviceenabled "$service" off
/usr/sbin/networksetup -listallnetworkservices | /usr/bin/grep -Fx -- "*$service" >/dev/null
