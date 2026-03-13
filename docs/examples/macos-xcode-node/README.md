# macOS Xcode + Node.js image example

This example shows how to build a `darwin/arm64` image on top of `local/macos-base:latest`
by locally injecting a downloaded Xcode `.xip` and a Node.js installation tarball.

## Expected build context files

Place these files in this directory before building:

- `Xcode.xip`: the Apple silicon Xcode archive downloaded from Apple.
- `node.tar`: a tar archive created from the root of a darwin/arm64 Node.js installation so that the archive contains `bin/node`, `bin/npm`, and related files.

One way to prepare the context from this repository root is:

```bash
cd /Users/jianliang/Code/container

ln -f "$PWD/Xcode_26.3_Apple_silicon.xip" \
  "$PWD/docs/examples/macos-xcode-node/Xcode.xip"

tar -C "$HOME/.local/share/mise/installs/node/22.19.0" \
  -cf "$PWD/docs/examples/macos-xcode-node/node.tar" .
```

## Build

```bash
cd /Users/jianliang/Code/container

bin/container build \
  --platform darwin/arm64 \
  --progress plain \
  -f "$PWD/docs/examples/macos-xcode-node/Dockerfile" \
  -t local/macos-xcode-node-ready:latest \
  "$PWD/docs/examples/macos-xcode-node"
```

## Verify

```bash
bin/container run --os darwin --rm local/macos-xcode-node-ready:latest \
  /bin/sh -lc 'xcodebuild -version && xcrun swift --version && node -v && npm -v'
```

The image build performs these initialization steps during `RUN`:

- expands `Xcode.xip` into `/Applications/Xcode.app`
- switches the active developer directory
- accepts the Xcode license
- runs `xcodebuild -runFirstLaunch`
- verifies `xcodebuild`, `swift`, `node`, and `npm`
