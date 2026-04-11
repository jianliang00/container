ARG BASE_REF=ghcr.io/jianliang00/macos-base:26.3
FROM --platform=darwin/arm64 ${BASE_REF}

ARG HOMEBREW_INSTALL_URL=https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh
ARG NODE_FORMULA=node@22
ARG PYTHON_FORMULA=python@3.12
ARG JAVA_FORMULA=openjdk@21
ARG CLAUDE_CODE_CASK=claude-code
ARG ANDROID_CMDLINE_CASK=android-commandlinetools
ARG ANDROID_PLATFORM=android-35
ARG ANDROID_BUILD_TOOLS=35.0.0
ARG ANDROID_NDK=27.2.12479018
ARG ANDROID_CMAKE=3.22.1
ARG DEERFLOW_REPO=https://github.com/bytedance/deer-flow.git
ARG DEERFLOW_REF=main
ARG HERMES_REPO=https://github.com/NousResearch/hermes-agent.git
ARG HERMES_REF=main
ARG DEERFLOW_PYTHON=3.12
ARG HERMES_PYTHON=3.11
ARG CODEX_NPM_SPEC=@openai/codex
ARG COPILOT_NPM_SPEC=@github/copilot
ARG OPENCLAW_NPM_SPEC=openclaw@latest

LABEL org.opencontainers.image.title="macOS Dev Agent"
LABEL org.opencontainers.image.description="macOS 26.3 image with Xcode, Android build tooling, Homebrew, DeerFlow, Hermes Agent, Claude Code, Codex CLI, GitHub Copilot CLI, and OpenClaw"

COPY Xcode.xip /tmp/Xcode.xip
COPY container-dev-env.sh /etc/container-dev-env.sh
COPY deerflow /usr/local/bin/deerflow

ENV HOMEBREW_INSTALL_URL=${HOMEBREW_INSTALL_URL}
ENV NODE_FORMULA=${NODE_FORMULA}
ENV PYTHON_FORMULA=${PYTHON_FORMULA}
ENV JAVA_FORMULA=${JAVA_FORMULA}
ENV CLAUDE_CODE_CASK=${CLAUDE_CODE_CASK}
ENV ANDROID_CMDLINE_CASK=${ANDROID_CMDLINE_CASK}
ENV ANDROID_PLATFORM=${ANDROID_PLATFORM}
ENV ANDROID_BUILD_TOOLS=${ANDROID_BUILD_TOOLS}
ENV ANDROID_NDK=${ANDROID_NDK}
ENV ANDROID_CMAKE=${ANDROID_CMAKE}
ENV DEERFLOW_REPO=${DEERFLOW_REPO}
ENV DEERFLOW_REF=${DEERFLOW_REF}
ENV HERMES_REPO=${HERMES_REPO}
ENV HERMES_REF=${HERMES_REF}
ENV DEERFLOW_PYTHON=${DEERFLOW_PYTHON}
ENV HERMES_PYTHON=${HERMES_PYTHON}
ENV CODEX_NPM_SPEC=${CODEX_NPM_SPEC}
ENV COPILOT_NPM_SPEC=${COPILOT_NPM_SPEC}
ENV OPENCLAW_NPM_SPEC=${OPENCLAW_NPM_SPEC}
ENV DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
ENV JAVA_HOME=/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home
ENV ANDROID_HOME=/opt/homebrew/share/android-commandlinetools
ENV ANDROID_SDK_ROOT=/opt/homebrew/share/android-commandlinetools
ENV ANDROID_NDK_HOME=/opt/homebrew/share/android-commandlinetools/ndk/${ANDROID_NDK}
ENV ANDROID_NDK_ROOT=/opt/homebrew/share/android-commandlinetools/ndk/${ANDROID_NDK}
ENV DEERFLOW_HOME=/opt/deer-flow
ENV HERMES_HOME=/opt/hermes-agent
ENV PATH=/usr/local/bin:/Users/admin/.local/bin:/opt/homebrew/share/android-commandlinetools/platform-tools:/opt/homebrew/share/android-commandlinetools/cmdline-tools/latest/bin:/opt/homebrew/opt/openjdk@21/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/Applications/Xcode.app/Contents/Developer/usr/bin:/usr/bin:/bin:/usr/sbin:/sbin

RUN /bin/sh -lc '\
  cd /Applications && \
  /usr/bin/xip --expand /tmp/Xcode.xip && \
  /bin/rm -f /tmp/Xcode.xip && \
  /usr/bin/xcode-select --switch /Applications/Xcode.app/Contents/Developer && \
  /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild -license accept && \
  /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild -runFirstLaunch \
'

RUN /bin/sh -lc '\
  if ! /usr/bin/id -u admin >/dev/null 2>&1; then \
    /usr/bin/dscl . -create /Users/admin && \
    /usr/bin/dscl . -create /Users/admin UserShell /bin/zsh && \
    /usr/bin/dscl . -create /Users/admin RealName "Admin" && \
    /usr/bin/dscl . -create /Users/admin UniqueID 700 && \
    /usr/bin/dscl . -create /Users/admin PrimaryGroupID 20 && \
    /usr/bin/dscl . -create /Users/admin NFSHomeDirectory /Users/admin; \
  fi && \
  /usr/sbin/dseditgroup -o edit -a admin -t user admin && \
  /bin/mkdir -p /Users/admin \
    /Users/admin/Applications \
    /Users/admin/Library/Caches/Homebrew \
    /Users/admin/Library/Logs/Homebrew \
    /Users/admin/.local/bin \
    /Users/admin/.android \
    /Users/admin/workspace \
    /opt/homebrew \
    /opt/deer-flow \
    /opt/hermes-agent && \
  /usr/sbin/chown admin:staff \
    /Users/admin \
    /Users/admin/Applications \
    /Users/admin/Library/Caches/Homebrew \
    /Users/admin/Library/Logs/Homebrew \
    /Users/admin/.local \
    /Users/admin/.local/bin \
    /Users/admin/.android \
    /Users/admin/workspace \
    /opt/homebrew \
    /opt/deer-flow \
    /opt/hermes-agent && \
  /bin/mkdir -p /etc/sudoers.d && \
  /usr/bin/printf "%s\n" "admin ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/admin && \
  /bin/chmod 0440 /etc/sudoers.d/admin && \
  /bin/chmod 0755 /etc/container-dev-env.sh /usr/local/bin/deerflow && \
  for shell_rc in /etc/profile /etc/zprofile /etc/zshrc /Users/admin/.bash_profile /Users/admin/.zprofile /Users/admin/.zshrc; do \
    /usr/bin/touch "${shell_rc}"; \
    /usr/bin/grep -F "/etc/container-dev-env.sh" "${shell_rc}" >/dev/null 2>&1 || /usr/bin/printf "\n[ -f /etc/container-dev-env.sh ] && . /etc/container-dev-env.sh\n" >> "${shell_rc}"; \
  done && \
  /usr/sbin/chown admin:staff /Users/admin/.bash_profile /Users/admin/.zprofile /Users/admin/.zshrc \
'

USER admin
ENV HOME=/Users/admin
WORKDIR /Users/admin

RUN /bin/sh -lc '\
  NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL "${HOMEBREW_INSTALL_URL}")" && \
  eval "$(/opt/homebrew/bin/brew shellenv)" && \
  HOMEBREW_NO_AUTO_UPDATE=1 brew install "${NODE_FORMULA}" "${PYTHON_FORMULA}" "${JAVA_FORMULA}" uv pnpm git-lfs jq ripgrep watchman cmake ninja gradle cocoapods fastlane xcbeautify gh && \
  HOMEBREW_NO_AUTO_UPDATE=1 brew link --overwrite --force "${NODE_FORMULA}" "${PYTHON_FORMULA}" && \
  HOMEBREW_NO_AUTO_UPDATE=1 brew install --cask "${ANDROID_CMDLINE_CASK}" "${CLAUDE_CODE_CASK}" && \
  uv python install "${DEERFLOW_PYTHON}" "${HERMES_PYTHON}" && \
  npm install -g "${CODEX_NPM_SPEC}" "${COPILOT_NPM_SPEC}" "${OPENCLAW_NPM_SPEC}" && \
  /usr/bin/touch "${HOME}/.android/repositories.cfg" && \
  brew cleanup -s && \
  /bin/rm -rf "${HOME}/Library/Caches/Homebrew" "$(brew --cache)" && \
  node -v && \
  npm -v && \
  pnpm -v && \
  python3 --version && \
  uv --version && \
  pod --version && \
  fastlane --version && \
  codex --version && \
  claude --version && \
  copilot --version && \
  openclaw --version \
'

USER root
RUN /bin/sh -lc '\
  /bin/mkdir -p /Library/Java/JavaVirtualMachines && \
  /bin/ln -sfn /opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk /Library/Java/JavaVirtualMachines/openjdk-21.jdk && \
  /usr/sbin/chown -h root:wheel /Library/Java/JavaVirtualMachines/openjdk-21.jdk \
'

USER admin
RUN /bin/sh -lc '\
  yes | sdkmanager --sdk_root="${ANDROID_SDK_ROOT}" --licenses >/dev/null && \
  sdkmanager --sdk_root="${ANDROID_SDK_ROOT}" \
    "platform-tools" \
    "platforms;${ANDROID_PLATFORM}" \
    "build-tools;${ANDROID_BUILD_TOOLS}" \
    "cmake;${ANDROID_CMAKE}" \
    "ndk;${ANDROID_NDK}" && \
  adb version && \
  sdkmanager --version \
'

RUN /bin/sh -lc '\
  git clone --depth 1 --branch "${DEERFLOW_REF}" "${DEERFLOW_REPO}" "${DEERFLOW_HOME}" && \
  cd "${DEERFLOW_HOME}" && \
  make config && \
  make install && \
  deerflow help >/dev/null \
'

RUN /bin/sh -lc '\
  git clone --depth 1 --branch "${HERMES_REF}" --recurse-submodules --shallow-submodules "${HERMES_REPO}" "${HERMES_HOME}" && \
  cd "${HERMES_HOME}" && \
  uv venv venv --python "${HERMES_PYTHON}" && \
  export VIRTUAL_ENV="${HERMES_HOME}/venv" && \
  uv pip install -e ".[all]" && \
  uv pip install -e "./tinker-atropos" && \
  npm install && \
  /bin/mkdir -p "${HOME}/.hermes/cron" "${HOME}/.hermes/sessions" "${HOME}/.hermes/logs" "${HOME}/.hermes/memories" "${HOME}/.hermes/skills" "${HOME}/.hermes/pairing" "${HOME}/.hermes/hooks" "${HOME}/.hermes/image_cache" "${HOME}/.hermes/audio_cache" "${HOME}/.hermes/whatsapp/session" && \
  /bin/cp cli-config.yaml.example "${HOME}/.hermes/config.yaml" && \
  : > "${HOME}/.hermes/.env" && \
  /bin/ln -sfn "${HERMES_HOME}/venv/bin/hermes" "${HOME}/.local/bin/hermes" && \
  hermes version \
'

WORKDIR /Users/admin/workspace

RUN /bin/sh -lc '\
  whoami | /usr/bin/grep "^admin$" >/dev/null && \
  xcodebuild -version && \
  xcrun swift --version && \
  node -v && \
  npm -v && \
  python3 --version && \
  java -version && \
  adb version && \
  sdkmanager --version && \
  codex --version && \
  claude --version && \
  copilot --version && \
  openclaw --version && \
  hermes version && \
  deerflow help >/dev/null \
'

CMD ["/bin/zsh", "-l"]
