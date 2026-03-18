# macOS Codex Image Example

This example builds a `darwin/arm64` image from `ghcr.io/<your-org>/macos-base:26.3` and adds:

- Xcode 26.3
- Homebrew
- Node.js
- Codex CLI
- `Codex.app`

Assumptions:

- Only `Xcode.xip` is injected from the local host into the build context.
- Homebrew, Node.js, Codex CLI, and `Codex.app` are downloaded during image build.
- The Dockerfile creates a non-root `brew` user and sets it as the default user of the final image.

Replace the placeholder image references in the commands below with your own registry namespace.

## 1. Prepare the Build Context

By default, the helper script expects:

- `XCODE_XIP=/path/to/Xcode_26.3_Apple_silicon.xip`

Run:

```bash
export REPO_ROOT="${REPO_ROOT:-$PWD}"
cd "$REPO_ROOT"

chmod +x "$REPO_ROOT/docs/examples/macos-codex/prepare-context.sh"
"$REPO_ROOT/docs/examples/macos-codex/prepare-context.sh"
```

The script creates:

- `docs/examples/macos-codex/Xcode.xip`

Override the source path if needed:

```bash
export REPO_ROOT="${REPO_ROOT:-$PWD}"

XCODE_XIP=/path/to/Xcode_26.3_Apple_silicon.xip \
  "$REPO_ROOT/docs/examples/macos-codex/prepare-context.sh"
```

## 2. Build the Image

```bash
export REPO_ROOT="${REPO_ROOT:-$PWD}"
cd "$REPO_ROOT"

bin/container build \
  --platform darwin/arm64 \
  --progress plain \
  -f "$REPO_ROOT/docs/examples/macos-codex/Dockerfile" \
  -t ghcr.io/<your-org>/macos-codex:26.3 \
  "$REPO_ROOT/docs/examples/macos-codex"
```

Override the Node.js or Codex CLI version with build args if needed:

```bash
export REPO_ROOT="${REPO_ROOT:-$PWD}"

bin/container build \
  --platform darwin/arm64 \
  --progress plain \
  --build-arg NODE_FORMULA=node@22 \
  --build-arg CODEX_NPM_SPEC=@openai/codex@0.111.0 \
  -f "$REPO_ROOT/docs/examples/macos-codex/Dockerfile" \
  -t ghcr.io/<your-org>/macos-codex:26.3 \
  "$REPO_ROOT/docs/examples/macos-codex"
```

During build, the guest VM must be able to reach the public internet, including at least:

- `raw.githubusercontent.com` for the Homebrew install script
- Homebrew taps and bottle/cask download endpoints
- the npm registry for `@openai/codex`

## 3. Verify the Image

```bash
bin/container run --os darwin --rm ghcr.io/<your-org>/macos-codex:26.3 \
  /bin/sh -lc 'whoami && xcodebuild -version && xcrun swift --version && node -v && npm -v && codex --version && ls -ld /Applications/Codex.app && ls -ld "$HOME/Applications/Codex.app"'
```

## 4. Push the Image

```bash
bin/container image push ghcr.io/<your-org>/macos-codex:26.3
```
