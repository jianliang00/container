# macOS Xcode + Node.js image example

This example shows how to build a `darwin/arm64` image on top of `local/macos-base:latest`
by locally injecting a downloaded Xcode `.xip` and a Node.js installation tarball.

## Expected build context files

Place these files in this directory before building:

- `Xcode.xip`: the Apple silicon Xcode archive downloaded from Apple.
- `node.tar`: a tar archive created from the root of a darwin/arm64 Node.js installation so that the archive contains `bin/node`, `bin/npm`, and related files.

One way to prepare the context from the repository root is:

```bash
export REPO_ROOT="${REPO_ROOT:-$PWD}"
cd "$REPO_ROOT"

ln -f "$REPO_ROOT/Xcode_26.3_Apple_silicon.xip" \
  "$REPO_ROOT/docs/examples/macos-xcode-node/Xcode.xip"

tar -C "$HOME/.local/share/mise/installs/node/22.19.0" \
  -cf "$REPO_ROOT/docs/examples/macos-xcode-node/node.tar" .
```

## Build

```bash
export REPO_ROOT="${REPO_ROOT:-$PWD}"
cd "$REPO_ROOT"

bin/container build \
  --platform darwin/arm64 \
  --progress plain \
  -f "$REPO_ROOT/docs/examples/macos-xcode-node/Dockerfile" \
  -t local/macos-xcode-node-ready:latest \
  "$REPO_ROOT/docs/examples/macos-xcode-node"
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
