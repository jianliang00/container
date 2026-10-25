#!/usr/bin/env bash
#
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

# Accept a recorded source commit or an identical full source tree in release history.
set -euo pipefail

if [[ "$#" != 2 ]]; then
    echo "usage: $0 <paired-source-commit> <release-commit>" >&2
    exit 2
fi

paired_commit="$1"
release_commit="$2"
for commit in "${paired_commit}" "${release_commit}"; do
    if [[ ! "${commit}" =~ ^[0-9a-f]{40}$ ]]; then
        echo "Source provenance requires full commit SHA values" >&2
        exit 1
    fi
    git cat-file -e "${commit}^{commit}"
done

if [[ "$(git rev-parse --is-shallow-repository)" != false ]]; then
    echo "Source provenance requires complete Git history (fetch-depth: 0)" >&2
    exit 1
fi

if git merge-base --is-ancestor "${paired_commit}" "${release_commit}"; then
    echo "Source provenance: recorded commit ${paired_commit} is in release history"
    exit 0
fi

paired_tree="$(git rev-parse "${paired_commit}^{tree}")"
# Consume the full log to avoid SIGPIPE under pipefail. Compare the entire tree,
# including paths, modes and submodule pins, rather than a subset of guest sources.
equivalent_commit="$(git log --format='%H %T' "${release_commit}" -- |
    awk -v tree="${paired_tree}" '$2 == tree && !found { print $1; found = 1 }')"
if [[ -z "${equivalent_commit}" ]]; then
    echo "Source provenance failed: ${paired_commit} has no ancestor or identical source tree in release ${release_commit}" >&2
    exit 1
fi

echo "Source provenance: recorded commit ${paired_commit} matches full tree ${paired_tree} at release ancestor ${equivalent_commit}"
