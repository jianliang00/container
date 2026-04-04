#!/usr/bin/env bash
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

if [[ $# -ne 1 ]]; then
    echo "usage: $0 <release-version>" >&2
    exit 1
fi

version="$1"

cat <<EOF
This draft release publishes the signed installer package and debug symbols for \`container\`.

## SwiftPM integration

Third-party Swift projects can depend on this tagged release directly:

\`\`\`swift
dependencies: [
    .package(url: "https://github.com/apple/container.git", from: "${version}")
],
targets: [
    .executableTarget(
        name: "ExampleApp",
        dependencies: [
            .product(name: "ContainerKit", package: "container")
        ]
    )
]
\`\`\`

Add \`.product(name: "ContainerKitServices", package: "container")\` only when
the embedding app needs explicit lifecycle control for the local \`container\`
services. \`ContainerKit\` itself expects the runtime to already be installed
and running.

Reference docs for this tag:

- [Use ContainerKit from SwiftPM](https://github.com/apple/container/tree/${version}/docs/how-to.md#use-containerkit-from-swiftpm)
- [SwiftPM Embedding Design: ContainerKit](https://github.com/apple/container/tree/${version}/docs/swiftpm-containerkit-design.md)
EOF
