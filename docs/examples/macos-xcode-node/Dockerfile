FROM local/macos-base:latest

# Build context must provide:
# - Xcode.xip: Apple-downloaded Xcode archive for Apple silicon
# - node.tar: darwin/arm64 Node.js installation archived from its install root
COPY Xcode.xip /tmp/Xcode.xip
ADD node.tar /opt/node/

ENV PATH=/opt/node/bin:/Applications/Xcode.app/Contents/Developer/usr/bin:/usr/bin:/bin:/usr/sbin:/sbin
ENV DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

RUN /bin/sh -lc '\
  cd /Applications && \
  /usr/bin/xip --expand /tmp/Xcode.xip && \
  /bin/rm -f /tmp/Xcode.xip && \
  /usr/bin/xcode-select --switch /Applications/Xcode.app/Contents/Developer && \
  /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild -license accept && \
  /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild -runFirstLaunch && \
  xcodebuild -version && \
  xcrun swift --version && \
  node -v && \
  npm -v \
'

CMD ["/bin/sh", "-lc", "xcodebuild -version && xcrun swift --version && node -v && npm -v"]
