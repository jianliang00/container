ARG BASE_REF=ghcr.io/jianliang00/macos-base:26.3
FROM --platform=darwin/arm64 ${BASE_REF}

ARG HOMEBREW_INSTALL_URL=https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh
ARG NODE_FORMULA=node@22
ARG CODEX_APP_CASK=codex-app
ARG CODEX_NPM_SPEC=@openai/codex

LABEL org.opencontainers.image.title="macOS Codex"
LABEL org.opencontainers.image.description="macOS 26.3 image with Xcode, Homebrew, Node.js, Codex CLI, and Codex.app"

COPY Xcode.xip /tmp/Xcode.xip

ENV HOMEBREW_INSTALL_URL=${HOMEBREW_INSTALL_URL}
ENV NODE_FORMULA=${NODE_FORMULA}
ENV CODEX_APP_CASK=${CODEX_APP_CASK}
ENV CODEX_NPM_SPEC=${CODEX_NPM_SPEC}
ENV DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
ENV PATH=/opt/homebrew/bin:/opt/homebrew/sbin:/Applications/Xcode.app/Contents/Developer/usr/bin:/usr/bin:/bin:/usr/sbin:/sbin

RUN /bin/sh -lc '\
  cd /Applications && \
  /usr/bin/xip --expand /tmp/Xcode.xip && \
  /bin/rm -f /tmp/Xcode.xip && \
  /usr/bin/xcode-select --switch /Applications/Xcode.app/Contents/Developer && \
  /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild -license accept && \
  /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild -runFirstLaunch \
'

RUN /bin/sh -lc '\
  if ! /usr/bin/id -u brew >/dev/null 2>&1; then \
    /usr/bin/dscl . -create /Users/brew && \
    /usr/bin/dscl . -create /Users/brew UserShell /bin/zsh && \
    /usr/bin/dscl . -create /Users/brew RealName "Homebrew User" && \
    /usr/bin/dscl . -create /Users/brew UniqueID 699 && \
    /usr/bin/dscl . -create /Users/brew PrimaryGroupID 20 && \
    /usr/bin/dscl . -create /Users/brew NFSHomeDirectory /Users/brew; \
  fi && \
  /usr/sbin/dseditgroup -o edit -a brew -t user admin && \
  /bin/mkdir -p /Users/brew /Users/brew/Applications /Users/brew/Library/Caches/Homebrew /opt/homebrew && \
  /usr/sbin/chown -R brew:staff /Users/brew /opt/homebrew && \
  /bin/mkdir -p /etc/sudoers.d && \
  /usr/bin/printf "%s\n" "brew ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/brew && \
  /bin/chmod 0440 /etc/sudoers.d/brew \
'

USER brew
ENV HOME=/Users/brew
WORKDIR /Users/brew

RUN /bin/sh -lc '\
  NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL "${HOMEBREW_INSTALL_URL}")" && \
  eval "$(/opt/homebrew/bin/brew shellenv)" && \
  HOMEBREW_NO_AUTO_UPDATE=1 brew install "${NODE_FORMULA}" && \
  HOMEBREW_NO_AUTO_UPDATE=1 brew link --overwrite --force "${NODE_FORMULA}" && \
  HOMEBREW_NO_AUTO_UPDATE=1 brew install --cask --appdir="${HOME}/Applications" "${CODEX_APP_CASK}" && \
  npm install -g "${CODEX_NPM_SPEC}" && \
  /bin/test -x "${HOME}/Applications/Codex.app/Contents/MacOS/Codex" && \
  brew cleanup -s && \
  xcodebuild -version && \
  xcrun swift --version && \
  node -v && \
  npm -v && \
  codex --version \
'

USER root
RUN /bin/sh -lc '\
  /bin/ln -sfn /Users/brew/Applications/Codex.app /Applications/Codex.app && \
  /usr/sbin/chown -h root:wheel /Applications/Codex.app \
'

USER brew
CMD ["/bin/sh", "-lc", "whoami && xcodebuild -version && xcrun swift --version && node -v && npm -v && codex --version && ls -ld /Applications/Codex.app && ls -ld \"$HOME/Applications/Codex.app\""]
