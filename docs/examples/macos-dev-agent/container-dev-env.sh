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

if [ -x /opt/homebrew/bin/brew ]; then
  eval "$(/opt/homebrew/bin/brew shellenv)"
fi

path_prepend() {
  case ":${PATH:-}:" in
    *":$1:"*) ;;
    *)
      if [ -n "${PATH:-}" ]; then
        PATH="$1:$PATH"
      else
        PATH="$1"
      fi
      ;;
  esac
}

export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
export JAVA_HOME="/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home"
export ANDROID_HOME="/opt/homebrew/share/android-commandlinetools"
export ANDROID_SDK_ROOT="${ANDROID_HOME}"
export ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-${ANDROID_HOME}/ndk/27.2.12479018}"
export ANDROID_NDK_ROOT="${ANDROID_NDK_HOME}"
export ANDROID_USER_HOME="${HOME:-/Users/admin}/.android"
export DEERFLOW_HOME="/opt/deer-flow"
export HERMES_HOME="/opt/hermes-agent"

path_prepend "/usr/local/bin"
path_prepend "${HOME:-/Users/admin}/.local/bin"
path_prepend "${ANDROID_HOME}/platform-tools"
path_prepend "${ANDROID_HOME}/cmdline-tools/latest/bin"
path_prepend "/opt/homebrew/opt/openjdk@21/bin"
path_prepend "/Applications/Xcode.app/Contents/Developer/usr/bin"

export PATH
