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

set -euo pipefail

validator="$(cd "$(dirname "$0")" && pwd)/validate-source-provenance.sh"
test_dir="$(mktemp -d)"
trap 'rm -rf "${test_dir}"' EXIT
git init -q "${test_dir}/repo"
cd "${test_dir}/repo"
git config user.name 'Provenance Test'
git config user.email 'provenance@example.invalid'
git config commit.gpgsign false

expect_pass() {
    bash "${validator}" "$1" "$2" >"${test_dir}/result" 2>&1 || {
        cat "${test_dir}/result"
        exit 1
    }
}
expect_fail() {
    if bash "${validator}" "$1" "$2" >"${test_dir}/result" 2>&1; then
        echo "Unexpected provenance acceptance: $1 -> $2" >&2
        exit 1
    fi
}

echo base > source
git add source
git commit -qm base
base="$(git rev-parse HEAD)"
echo feature >> source
git commit -qam 'original release'
paired="$(git rev-parse HEAD)"
git checkout -q -b rewritten "${base}"
echo feature >> source
git commit -qam 'rewritten release with identical tree'
equivalent="$(git rev-parse HEAD)"
test "${paired}" != "${equivalent}"
echo fix >> source
git commit -qam 'host fix'
release="$(git rev-parse HEAD)"

expect_pass "${base}" "${release}"
expect_pass "${paired}" "${equivalent}"
expect_pass "${paired}" "${release}"
grep -q "${equivalent}" "${test_dir}/result"

# An equivalent tree on another branch must not count as release ancestry.
git checkout -q -b unrelated "${base}"
echo unrelated > source
git commit -qam unrelated
unrelated="$(git rev-parse HEAD)"
expect_fail "${paired}" "${unrelated}"

# File modes are part of provenance even when file contents match.
git checkout -q -b mode-change "${equivalent}"
chmod +x source
git update-index --chmod=+x source
git commit -qm 'executable mode'
mode_commit="$(git rev-parse HEAD)"
expect_fail "${mode_commit}" "${release}"

expect_fail 0000000000000000000000000000000000000000 "${release}"
expect_fail HEAD "${release}"

git checkout -q rewritten
git clone -q --depth 1 "file://${test_dir}/repo" "${test_dir}/shallow"
cd "${test_dir}/shallow"
expect_fail "${release}" "${release}"
grep -q 'complete Git history' "${test_dir}/result"
echo 'Source provenance tests passed (ancestry, equivalent tree, divergence, modes, missing commit, invalid SHA, shallow history)'
