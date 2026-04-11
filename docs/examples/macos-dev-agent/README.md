# macOS Dev Agent Image Example

This example builds a `darwin/arm64` image from `ghcr.io/<your-org>/macos-base:26.3` and adds:

- Xcode 26.3 for iOS builds
- Homebrew
- Android SDK command-line tools, platform tools, build tools, platforms, CMake, and NDK
- Node.js 22, Python 3.12, Java 21, Gradle, CocoaPods, Fastlane, Watchman, `uv`, and `pnpm`
- DeerFlow
- Hermes Agent
- Claude Code
- Codex CLI
- GitHub Copilot CLI
- OpenClaw
- A non-root `admin` user as the default user

The image also wires the toolchain paths into shell startup files so GUI terminals launched inside the guest can resolve `brew`, `xcodebuild`, `sdkmanager`, `adb`, `codex`, `claude`, `copilot`, `openclaw`, `hermes`, and `deerflow` without extra manual setup.

Assumptions:

- The build context provides `Xcode.xip`.
- External dependencies are downloaded during the image build.
- Authentication is completed after the image is built:
  - `codex`
  - `claude`
  - `copilot` and `/login`
  - `openclaw`
  - `hermes model`
  - `deerflow setup` or manual model configuration in `/opt/deer-flow/config.yaml`

## 1. Prepare the Build Context

```bash
export REPO_ROOT="${REPO_ROOT:-$PWD}"
cd "$REPO_ROOT"

chmod +x "$REPO_ROOT/docs/examples/macos-dev-agent/prepare-context.sh"
"$REPO_ROOT/docs/examples/macos-dev-agent/prepare-context.sh"
```

By default the helper script expects:

- `XCODE_XIP=/path/to/Xcode_26.3_Apple_silicon.xip`

It creates:

- `docs/examples/macos-dev-agent/Xcode.xip`

Override the source path if needed:

```bash
export REPO_ROOT="${REPO_ROOT:-$PWD}"

XCODE_XIP=/path/to/Xcode_26.3_Apple_silicon.xip \
  "$REPO_ROOT/docs/examples/macos-dev-agent/prepare-context.sh"
```

## 2. Build the Image

```bash
export REPO_ROOT="${REPO_ROOT:-$PWD}"
cd "$REPO_ROOT"

bin/container build \
  --platform darwin/arm64 \
  --progress plain \
  -f "$REPO_ROOT/docs/examples/macos-dev-agent/Dockerfile" \
  -t ghcr.io/<your-org>/macos-dev-agent:26.3 \
  "$REPO_ROOT/docs/examples/macos-dev-agent"
```

Useful overrides:

```bash
export REPO_ROOT="${REPO_ROOT:-$PWD}"

bin/container build \
  --platform darwin/arm64 \
  --progress plain \
  --build-arg NODE_FORMULA=node@22 \
  --build-arg ANDROID_PLATFORM=android-35 \
  --build-arg ANDROID_BUILD_TOOLS=35.0.0 \
  --build-arg ANDROID_NDK=27.2.12479018 \
  --build-arg DEERFLOW_REF=main \
  --build-arg HERMES_REF=main \
  --build-arg CODEX_NPM_SPEC=@openai/codex@latest \
  --build-arg COPILOT_NPM_SPEC=@github/copilot@latest \
  --build-arg OPENCLAW_NPM_SPEC=openclaw@latest \
  -f "$REPO_ROOT/docs/examples/macos-dev-agent/Dockerfile" \
  -t ghcr.io/<your-org>/macos-dev-agent:26.3 \
  "$REPO_ROOT/docs/examples/macos-dev-agent"
```

The build needs internet access to at least:

- `raw.githubusercontent.com` for Homebrew install and repository metadata
- Homebrew formula, bottle, and cask endpoints
- `registry.npmjs.org` for Codex, GitHub Copilot CLI, and OpenClaw
- Python package indexes used by `uv`
- GitHub repositories for DeerFlow and Hermes Agent
- Android SDK repositories
- Anthropic download endpoints used by the `claude-code` cask

## 3. Verify the Image

```bash
bin/container run --os darwin --rm ghcr.io/<your-org>/macos-dev-agent:26.3 \
  /bin/zsh -lc 'whoami && xcodebuild -version && xcrun swift --version && node -v && npm -v && python3 --version && java -version && adb version && sdkmanager --version && codex --version && claude --version && copilot --version && openclaw --version && hermes version && deerflow help'
```

If you want to confirm the shell wiring inside a GUI/login shell, run:

```bash
bin/container run --os darwin --rm ghcr.io/<your-org>/macos-dev-agent:26.3 \
  /bin/zsh -lc 'echo "$PATH" && command -v brew xcodebuild sdkmanager adb codex claude copilot openclaw hermes deerflow'
```

## 4. First-Run Setup

Open a shell in the image as `admin`:

```bash
bin/container run --os darwin -it ghcr.io/<your-org>/macos-dev-agent:26.3
```

Then authenticate or finish configuring the tools you want to use:

```bash
codex
claude
copilot
openclaw
hermes model
deerflow doctor
```

For DeerFlow, the repository is pre-cloned at `/opt/deer-flow`, dependencies are already installed, and the `deerflow` wrapper maps to `make` targets:

```bash
deerflow help
deerflow doctor
deerflow dev
```

Hermes Agent is pre-cloned at `/opt/hermes-agent` and exposed directly as:

```bash
hermes
```

## 5. Push the Image

```bash
bin/container image push ghcr.io/<your-org>/macos-dev-agent:26.3
```
