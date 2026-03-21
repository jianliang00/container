# macOS Base Image Guest-Agent Refresh

This example refreshes an existing `darwin/arm64` base image by replacing only the installed
`container-macos-guest-agent` binary in the image filesystem.

Use this flow when:

- the guest-agent protocol or implementation changed
- the install location stays `/usr/local/bin/container-macos-guest-agent`
- the LaunchDaemon plist and install scripts remain compatible

Do not use this flow when:

- `scripts/macos-guest-agent/install.sh` changed incompatibly
- `scripts/macos-guest-agent/install-in-guest-from-seed.sh` changed incompatibly
- the LaunchDaemon plist or service layout changed

In those cases, refresh the base image with the full seed + in-guest reinstall flow from
[`docs/macos-guest-local-validation-guide.md`](../../macos-guest-local-validation-guide.md).

## 1. Prepare the Context

Build or install the latest guest-agent binary first:

```bash
make release
```

Then copy the binary into this example build context:

```bash
export REPO_ROOT="${REPO_ROOT:-$PWD}"
cd "$REPO_ROOT"

chmod +x "$REPO_ROOT/docs/examples/macos-base-agent-refresh/prepare-context.sh"
"$REPO_ROOT/docs/examples/macos-base-agent-refresh/prepare-context.sh"
```

Override the source binary if needed:

```bash
export REPO_ROOT="${REPO_ROOT:-$PWD}"

CONTAINER_MACOS_GUEST_AGENT_BIN="$REPO_ROOT/.build/arm64-apple-macosx/release/container-macos-guest-agent" \
  "$REPO_ROOT/docs/examples/macos-base-agent-refresh/prepare-context.sh"
```

## 2. Build the Refreshed Base Image

```bash
export REPO_ROOT="${REPO_ROOT:-$PWD}"
cd "$REPO_ROOT"

bin/container build \
  --platform darwin/arm64 \
  --progress plain \
  -f "$REPO_ROOT/docs/examples/macos-base-agent-refresh/Dockerfile" \
  -t ghcr.io/<your-org>/macos-base:26.3 \
  "$REPO_ROOT/docs/examples/macos-base-agent-refresh"
```

Notes:

- The darwin build path may stay quiet for a while after guest execution finishes.
- The current post-build packaging and chunk compression phase is slow enough that it can look stalled.

Override the source base image if needed:

```bash
export REPO_ROOT="${REPO_ROOT:-$PWD}"

bin/container build \
  --platform darwin/arm64 \
  --progress plain \
  --build-arg BASE_REF=ghcr.io/<your-org>/macos-base:26.3 \
  -f "$REPO_ROOT/docs/examples/macos-base-agent-refresh/Dockerfile" \
  -t ghcr.io/<your-org>/macos-base:26.3 \
  "$REPO_ROOT/docs/examples/macos-base-agent-refresh"
```

## 3. Verify the Refreshed Image

Check that the refreshed image contains the newer guest-agent protocol strings:

```bash
bin/container run --os darwin --rm ghcr.io/<your-org>/macos-base:26.3 \
  /bin/sh -lc '/usr/bin/grep -a "networkConfigure" /usr/local/bin/container-macos-guest-agent >/dev/null && echo guest-agent-updated'
```

If the purpose of the refresh is `vmnetShared` support, continue with the darwin networking validation flow and verify that a fresh container can boot with the updated guest-agent without an in-guest binary replacement step.

## 4. Push the Image

```bash
bin/container image push ghcr.io/<your-org>/macos-base:26.3
```
