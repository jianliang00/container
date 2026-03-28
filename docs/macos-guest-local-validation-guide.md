# macOS Guest Local Development Validation Guide

This guide keeps one common local-development path only:

1. prepare or refresh a runnable `darwin/arm64` base image
2. validate `container build --platform darwin/arm64` against that base image

Except for the one-time in-guest initialization and agent installation that follows manual VM startup, the rest of the steps can run directly from the host terminal.

This guide assumes the default `container macos start-vm` seed injection path:

- virtiofs tag: `com.apple.virtio-fs.automount`
- guest seed path: `/Volumes/My Shared Files/seed`

That means you do not need to mount the seed path manually inside the guest.

## 1. Prerequisites

- the host is Apple Silicon
- commands run inside a local graphical session, not only over a headless remote shell
- Xcode command line tools, the Swift toolchain, and `zstd` are installed
- for the initial base-image creation path, you already have a usable IPSW such as `UniversalMac_*.ipsw`
- if the current branch changed any of the following files, refresh the base image before validating build:
  - `container-macos-guest-agent`
  - `scripts/macos-guest-agent/install.sh`
  - `scripts/macos-guest-agent/install-in-guest-from-seed.sh`
  - `scripts/macos-guest-agent/container-macos-guest-agent.plist`

Use the following environment variables consistently:

```bash
export REPO_ROOT="${REPO_ROOT:-$PWD}"
cd "$REPO_ROOT"

export CONTAINER_BIN="$REPO_ROOT/bin/container"
export BASE_REF="local/macos-base:latest"
export IMAGE_DIR="/tmp/macos-image-base"
export SEED_DIR="/tmp/macos-agent-seed"
export OCI_TAR="/tmp/macos-image-base-oci.tar"
export TEST_NS="local/macos-build-phase1"
export WORKROOT="/tmp/macos-build-phase1-acceptance"
export IPSW="/path/to/UniversalMac_xxx_Restore.ipsw"
```

If you only want to validate build, `IPSW` can stay unset.

## 2. Prepare the Base Image

First make sure the current repository build artifacts are up to date:

```bash
export REPO_ROOT="${REPO_ROOT:-$PWD}"
cd "$REPO_ROOT"
make release

export CONTAINER_BIN="$REPO_ROOT/bin/container"
export CONTAINER_ZSTD_BIN="${CONTAINER_ZSTD_BIN:-$(command -v zstd)}"
```

### 2.1 Create the Base Image for the First Time

Prepare the image directory and seed on the host:

```bash
rm -rf "$IMAGE_DIR" "$SEED_DIR" "$OCI_TAR"

"$CONTAINER_BIN" macos prepare-base \
  --ipsw "$IPSW" \
  --output "$IMAGE_DIR" \
  --disk-size-gib 64 \
  --memory-mib 8192 \
  --cpus 4

ls -lh "$IMAGE_DIR"/Disk.img "$IMAGE_DIR"/AuxiliaryStorage "$IMAGE_DIR"/HardwareModel.bin

"$CONTAINER_BIN" macos guest-agent prepare -o "$SEED_DIR" --overwrite

"$CONTAINER_BIN" macos start-vm \
  --image "$IMAGE_DIR" \
  --share "$SEED_DIR" \
  --cpus 4 \
  --memory-mib 8192
```

From this point, manual guest interaction is required. In the launched macOS VM, complete Setup Assistant, reach the desktop, open Terminal, and run:

```bash
sudo bash '/Volumes/My Shared Files/seed/install-in-guest-from-seed.sh'

sudo launchctl print system/com.apple.container.macos.guest-agent | head -n 40
sudo tail -n 50 /var/log/container-macos-guest-agent.log
sudo shutdown -h now
```

After the guest fully powers off, return to the host and run:

```bash
"$CONTAINER_BIN" macos package \
  --input "$IMAGE_DIR" \
  --output "$OCI_TAR" \
  --reference "$BASE_REF"

"$CONTAINER_BIN" image load -i "$OCI_TAR"
"$CONTAINER_BIN" run --os darwin --rm "$BASE_REF" /bin/ls /
```

At this point, `"$BASE_REF"` should be directly runnable.

### 2.2 Refresh Only the Guest Agent

If you already have a bootable `IMAGE_DIR`, you can regenerate the seed, reinstall the agent, and repackage without recreating the base image:

```bash
rm -rf "$SEED_DIR"
"$CONTAINER_BIN" macos guest-agent prepare -o "$SEED_DIR" --overwrite

"$CONTAINER_BIN" macos start-vm \
  --image "$IMAGE_DIR" \
  --share "$SEED_DIR" \
  --cpus 4 \
  --memory-mib 8192
```

Inside the guest, run the same installation steps:

```bash
sudo bash '/Volumes/My Shared Files/seed/install-in-guest-from-seed.sh'

sudo launchctl print system/com.apple.container.macos.guest-agent | head -n 40
sudo tail -n 50 /var/log/container-macos-guest-agent.log
sudo shutdown -h now
```

After shutdown, return to the host and run:

```bash
"$CONTAINER_BIN" macos package \
  --input "$IMAGE_DIR" \
  --output "$OCI_TAR" \
  --reference "$BASE_REF"

"$CONTAINER_BIN" image load -i "$OCI_TAR"
"$CONTAINER_BIN" run --os darwin --rm "$BASE_REF" /bin/ls /
```

If only the guest-agent binary changed and the installed path plus LaunchDaemon layout are still compatible, you can also use the lightweight refresh flow under [`docs/examples/macos-base-agent-refresh`](docs/examples/macos-base-agent-refresh/README.md). That example rebuilds the base image on top of the existing tag by replacing `/usr/local/bin/container-macos-guest-agent` during `container build`, without going through the full seed + in-guest reinstall loop.

### 2.3 Auto-Inject the Latest Guest Agent from the Current Repository

If you just changed `container-macos-guest-agent` or anything under `scripts/macos-guest-agent/*` and do not want to prepare `$SEED_DIR` manually, let `start-vm --auto-seed` create a temporary injection directory during startup.

Build the latest agent first and point explicitly at the binary and script sources:

```bash
export REPO_ROOT="${REPO_ROOT:-$PWD}"
cd "$REPO_ROOT"

xcrun swift build -c release --product container-macos-guest-agent

export CONTAINER_MACOS_GUEST_AGENT_BIN="$REPO_ROOT/.build/arm64-apple-macosx/release/container-macos-guest-agent"
export CONTAINER_MACOS_GUEST_AGENT_SCRIPTS_DIR="$REPO_ROOT/scripts/macos-guest-agent"

"$CONTAINER_BIN" macos start-vm \
  --image "$IMAGE_DIR" \
  --auto-seed \
  --cpus 4 \
  --memory-mib 8192
```

Inside the guest, run the same installation commands:

```bash
sudo bash '/Volumes/My Shared Files/seed/install-in-guest-from-seed.sh'

sudo launchctl print system/com.apple.container.macos.guest-agent | head -n 40
sudo tail -n 50 /var/log/container-macos-guest-agent.log
sudo shutdown -h now
```

After shutdown, repackage and reload:

```bash
"$CONTAINER_BIN" macos package \
  --input "$IMAGE_DIR" \
  --output "$OCI_TAR" \
  --reference "$BASE_REF"

"$CONTAINER_BIN" image load -i "$OCI_TAR"
"$CONTAINER_BIN" run --os darwin --rm "$BASE_REF" /bin/ls /
```

If you already ran `make release` and the installed `container-macos-guest-agent` is current, you can omit the two override variables and use `--auto-seed` directly.

## 3. Pre-Build Initialization

```bash
export REPO_ROOT="${REPO_ROOT:-$PWD}"
cd "$REPO_ROOT"
make release

export CONTAINER_BIN="$REPO_ROOT/bin/container"
export BASE_REF="local/macos-base:latest"
export TEST_NS="local/macos-build-phase1"
export WORKROOT="/tmp/macos-build-phase1-acceptance"
export CONTAINER_ZSTD_BIN="${CONTAINER_ZSTD_BIN:-$(command -v zstd)}"

rm -rf "$WORKROOT"
mkdir -p "$WORKROOT"

"$CONTAINER_BIN" image delete --force \
  "${TEST_NS}:smoke" \
  "${TEST_NS}:copy" \
  "${TEST_NS}:add-config" \
  "${TEST_NS}:user" \
  "${TEST_NS}:tar" >/dev/null 2>&1 || true

"$CONTAINER_BIN" system stop || true
"$CONTAINER_BIN" system start --install-root "$REPO_ROOT" --disable-kernel-install --timeout 60
"$CONTAINER_BIN" system status

"$CONTAINER_BIN" run --os darwin --rm "$BASE_REF" /bin/ls /
```

If this is not stable, do not continue to `container build`. Go directly to [`docs/macos-guest-development-debugging.md`](docs/macos-guest-development-debugging.md).

## 4. Validation Cases

### 4.1 Basic Build and Dispatch

```bash
mkdir -p "$WORKROOT/01-smoke"

cat > "$WORKROOT/01-smoke/Dockerfile" <<EOF
FROM --platform=darwin/arm64 ${BASE_REF}
RUN sw_vers
EOF

"$CONTAINER_BIN" build \
  --platform darwin/arm64 \
  --progress plain \
  -t "${TEST_NS}:smoke" \
  "$WORKROOT/01-smoke" 2>&1 | tee "$WORKROOT/01-smoke/build.log"

if grep -q "Dialing builder" "$WORKROOT/01-smoke/build.log"; then
  echo "unexpected linux builder path"
  exit 1
fi

"$CONTAINER_BIN" run --os darwin --rm "${TEST_NS}:smoke" /usr/bin/sw_vers
```

Expected result: the build succeeds, the logs do not contain `Dialing builder`, and the image runs directly.

### 4.2 `COPY`, `.dockerignore`, and Symlinks

```bash
mkdir -p "$WORKROOT/02-copy/payload/nested"

printf 'keep\n' > "$WORKROOT/02-copy/payload/keep.txt"
printf 'ignore\n' > "$WORKROOT/02-copy/payload/debug.log"
printf 'ignore\n' > "$WORKROOT/02-copy/payload/nested/app.log"
ln -sfn keep.txt "$WORKROOT/02-copy/payload/link.txt"

cat > "$WORKROOT/02-copy/.dockerignore" <<'EOF'
*.log
**/*.log
EOF

cat > "$WORKROOT/02-copy/Dockerfile" <<EOF
FROM ${BASE_REF}
WORKDIR /opt/copy-check
COPY payload/ /opt/copy-check/
RUN test -f /opt/copy-check/keep.txt
RUN test -L /opt/copy-check/link.txt
RUN test "\$(/usr/bin/readlink /opt/copy-check/link.txt)" = "keep.txt"
RUN test ! -e /opt/copy-check/debug.log
RUN test ! -e /opt/copy-check/nested/app.log
EOF

"$CONTAINER_BIN" build \
  --platform darwin/arm64 \
  --progress plain \
  -t "${TEST_NS}:copy" \
  "$WORKROOT/02-copy"

"$CONTAINER_BIN" run --os darwin --rm "${TEST_NS}:copy" /bin/sh -lc 'ls -l /opt/copy-check'
```

Expected result: `keep.txt` exists, `link.txt` points to `keep.txt`, and files excluded by `.dockerignore` are absent.

### 4.3 `ADD(local archive)` and Image Config

```bash
mkdir -p "$WORKROOT/03-add-config/archive-root/sub"

printf 'from add\n' > "$WORKROOT/03-add-config/archive-root/sub/hello.txt"
tar -C "$WORKROOT/03-add-config/archive-root" -cf "$WORKROOT/03-add-config/payload.tar" .

cat > "$WORKROOT/03-add-config/Dockerfile" <<EOF
FROM ${BASE_REF}
ENV PHASE1_VALUE=from-env
WORKDIR /opt/app
LABEL com.apple.container.phase=phase1
ADD payload.tar /opt/app/archive/
RUN test -f /opt/app/archive/sub/hello.txt
ENTRYPOINT ["/bin/sh"]
CMD ["-lc", "printf '%s %s\\n' \"\$PWD\" \"\$PHASE1_VALUE\""]
EOF

"$CONTAINER_BIN" build \
  --platform darwin/arm64 \
  --progress plain \
  -t "${TEST_NS}:add-config" \
  "$WORKROOT/03-add-config"

"$CONTAINER_BIN" run --os darwin --rm "${TEST_NS}:add-config"

"$CONTAINER_BIN" image inspect "${TEST_NS}:add-config" > "$WORKROOT/03-add-config/inspect.json"
grep -q '"com.apple.container.phase":"phase1"' "$WORKROOT/03-add-config/inspect.json"
```

Expected result: the default startup prints `/opt/app from-env`, and `inspect.json` contains `com.apple.container.phase=phase1`.

### 4.4 `type=tar`

```bash
mkdir -p "$WORKROOT/out"

"$CONTAINER_BIN" build \
  --platform darwin/arm64 \
  --progress plain \
  --output type=tar,dest="$WORKROOT/out/phase1.tar" \
  -t "${TEST_NS}:tar" \
  "$WORKROOT/01-smoke"

if "$CONTAINER_BIN" image inspect "${TEST_NS}:tar" >/dev/null 2>&1; then
  echo "type=tar should not auto-load the image"
  exit 1
fi

tar -tf "$WORKROOT/out/phase1.tar" > "$WORKROOT/out/phase1.tar.list"
grep -q '^index.json$' "$WORKROOT/out/phase1.tar.list"
grep -q '^oci-layout$' "$WORKROOT/out/phase1.tar.list"

"$CONTAINER_BIN" image load -i "$WORKROOT/out/phase1.tar"
"$CONTAINER_BIN" run --os darwin --rm "${TEST_NS}:tar" /usr/bin/sw_vers
```

Expected result: `type=tar` does not auto-load the image, but after `image load` the image runs correctly.

### 4.5 `type=local`

```bash
mkdir -p "$WORKROOT/out"

"$CONTAINER_BIN" build \
  --platform darwin/arm64 \
  --progress plain \
  --output type=local,dest="$WORKROOT/out/local-image" \
  "$WORKROOT/01-smoke"

ls -lh \
  "$WORKROOT/out/local-image/Disk.img" \
  "$WORKROOT/out/local-image/AuxiliaryStorage" \
  "$WORKROOT/out/local-image/HardwareModel.bin"

"$CONTAINER_BIN" macos start-vm \
  --image "$WORKROOT/out/local-image" \
  --auto-seed
```

Expected result: `type=local` exports a macOS image directory containing at least `Disk.img`, `AuxiliaryStorage`, and `HardwareModel.bin`, and that directory works with `macos start-vm`.

### 4.6 `USER`

```bash
mkdir -p "$WORKROOT/04-user"

cat > "$WORKROOT/04-user/Dockerfile" <<EOF
FROM ${BASE_REF}
USER nobody
RUN test "\$(/usr/bin/id -un)" = "nobody"
ENTRYPOINT ["/usr/bin/id"]
CMD ["-un"]
EOF

"$CONTAINER_BIN" build \
  --platform darwin/arm64 \
  --progress plain \
  -t "${TEST_NS}:user" \
  "$WORKROOT/04-user"

"$CONTAINER_BIN" run --os darwin --rm "${TEST_NS}:user"

"$CONTAINER_BIN" image inspect "${TEST_NS}:user" > "$WORKROOT/04-user/inspect.json"
grep -Eq '"User"[[:space:]]*:[[:space:]]*"nobody"' "$WORKROOT/04-user/inspect.json"
```

Expected result: the build succeeds, the `RUN` step executes as `nobody`, the default startup prints `nobody`, and image inspection shows `User=nobody`.

### 4.7 Rejection Paths

```bash
expect_fail() {
  local name="$1"
  local needle="$2"
  shift 2

  local log="$WORKROOT/logs/${name}.log"
  mkdir -p "$WORKROOT/logs"

  if "$@" >"$log" 2>&1; then
    echo "[$name] unexpected success"
    return 1
  fi

  if ! grep -Fq "$needle" "$log"; then
    echo "[$name] missing expected text: $needle"
    cat "$log"
    return 1
  fi
}

mkdir -p "$WORKROOT/05-negative/add-url"
mkdir -p "$WORKROOT/05-negative/copy-from"

cat > "$WORKROOT/05-negative/add-url/Dockerfile" <<EOF
FROM ${BASE_REF}
ADD https://example.com/file.tar /tmp/file.tar
EOF

cat > "$WORKROOT/05-negative/copy-from/Dockerfile" <<EOF
FROM ${BASE_REF} AS build
RUN sw_vers

FROM ${BASE_REF}
COPY --from=build /tmp/out /tmp/out
EOF

expect_fail mixed-platform \
  "darwin builds do not support mixed or multi-target platforms" \
  "$CONTAINER_BIN" build --platform linux/arm64,darwin/arm64 "$WORKROOT/01-smoke"

expect_fail darwin-amd64 \
  "darwin builds require darwin/arm64" \
  "$CONTAINER_BIN" build --platform darwin/amd64 "$WORKROOT/01-smoke"

expect_fail add-url-unsupported \
  "darwin builds do not support ADD <url> in phase 1" \
  "$CONTAINER_BIN" build --platform darwin/arm64 "$WORKROOT/05-negative/add-url"

expect_fail copy-from-unsupported \
  "darwin builds do not support COPY --from in phase 1" \
  "$CONTAINER_BIN" build --platform darwin/arm64 "$WORKROOT/05-negative/copy-from"
```

Expected result: all four commands fail, and each log contains the expected error text.

## 5. `vmnetShared` Networking Validation

This section validates the host-visible macOS guest network path rather than the build-only `virtualizationNAT` compatibility path.

Prerequisites:

- the host is macOS 26 or newer
- `"$BASE_REF"` is already bootable through `run --os darwin`
- the container API service is running

Use a dedicated runtime network so the reported guest state is unambiguous:

```bash
export NETWORK_NS="macos-vmnet-validate"
export PEER_NAME="macos-linux-peer"
export GUEST_NAME="macos-vmnet-guest"
export SAME_NODE_PORT=18080
export EXTERNAL_URL="${EXTERNAL_URL:-https://example.com}"

"$CONTAINER_BIN" delete --force "$PEER_NAME" >/dev/null 2>&1 || true
"$CONTAINER_BIN" delete --force "$GUEST_NAME" >/dev/null 2>&1 || true
"$CONTAINER_BIN" network delete "$NETWORK_NS" >/dev/null 2>&1 || true
"$CONTAINER_BIN" network create "$NETWORK_NS"
```

Start a same-node peer on that network:

```bash
"$CONTAINER_BIN" run \
  --rm \
  -d \
  --name "$PEER_NAME" \
  --network "$NETWORK_NS" \
  docker.io/library/python:alpine \
  python3 -m http.server --bind 0.0.0.0 "$SAME_NODE_PORT"

"$CONTAINER_BIN" inspect "$PEER_NAME" > "$WORKROOT/05-network-peer.inspect.json"
PEER_IP="$(ruby -rjson -e 'print JSON.parse(STDIN.read)[0]["networks"][0]["ipv4Address"]["address"]' < "$WORKROOT/05-network-peer.inspect.json")"
```

Start a macOS guest on the same network and confirm that `inspect` reports the real attachment state:

```bash
"$CONTAINER_BIN" run \
  --rm \
  -d \
  --os darwin \
  --name "$GUEST_NAME" \
  --network "$NETWORK_NS" \
  "$BASE_REF" \
  /usr/bin/tail -f /dev/null

"$CONTAINER_BIN" inspect "$GUEST_NAME" > "$WORKROOT/05-network-guest.inspect.json"
grep -q "\"network\":\"$NETWORK_NS\"" "$WORKROOT/05-network-guest.inspect.json"
grep -q '"networkBackend":"vmnetShared"' "$WORKROOT/05-network-guest.inspect.json"
```

Validate same-node connectivity by using the reported peer IP directly from `inspect`:

```bash
"$CONTAINER_BIN" exec \
  "$GUEST_NAME" \
  /usr/bin/curl \
  --fail \
  --silent \
  --show-error \
  --max-time 10 \
  "http://$PEER_IP:$SAME_NODE_PORT/"
```

Validate external connectivity from the same macOS guest:

```bash
"$CONTAINER_BIN" exec \
  "$GUEST_NAME" \
  /usr/bin/curl \
  --fail \
  --silent \
  --show-error \
  --location \
  --max-time 20 \
  "$EXTERNAL_URL"
```

Expected result: the guest reports a `vmnetShared` attachment for `"$NETWORK_NS"`, the guest can fetch the same-node peer by the peer IP reported from `inspect`, and the guest can also fetch `"$EXTERNAL_URL"`.

If your environment requires an outbound proxy, add the same `-e HTTP_PROXY=...`, `-e HTTPS_PROXY=...`, and `-e NO_PROXY=...` flags to both the `run` and `exec` commands above.

## 6. Pass Criteria

Validation is sufficient when all of the following are true:

- `"$BASE_REF"` runs reliably with `run --os darwin`
- sections 4.1 through 4.6 all succeed
- the four rejection-path checks in 4.7 fail with the expected messages
- section 5 succeeds with reported `vmnetShared` state plus same-node and external connectivity

This validation does not cover:

- `ADD URL`
- multi-stage `COPY --from`
- broader Dockerfile semantic alignment

## 7. Cleanup

```bash
"$CONTAINER_BIN" delete --force "$PEER_NAME" >/dev/null 2>&1 || true
"$CONTAINER_BIN" delete --force "$GUEST_NAME" >/dev/null 2>&1 || true
"$CONTAINER_BIN" network delete "$NETWORK_NS" >/dev/null 2>&1 || true

"$CONTAINER_BIN" image delete --force \
  "${TEST_NS}:smoke" \
  "${TEST_NS}:copy" \
  "${TEST_NS}:add-config" \
  "${TEST_NS}:user" \
  "${TEST_NS}:tar"

rm -rf "$WORKROOT"
```

If you need to restart the service during validation:

```bash
"$CONTAINER_BIN" system stop
"$CONTAINER_BIN" system start --install-root "$REPO_ROOT" --disable-kernel-install --timeout 60
```

## 8. Common Issues

- missing entitlements in `prepare-base` or `start-vm`:
  Prefer the `make release` output. If you must run binaries from `.build/release/*`, sign `container-macos-image-prepare` and `container-macos-vm-manager` with `signing/container-runtime-macos.entitlements`.
- manual VM window does not appear:
  The command is probably not running inside a graphical session.
- `run --os darwin` or `exec` cannot connect to the guest-agent:
  Re-check `launchctl print system/com.apple.container.macos.guest-agent` and `/var/log/container-macos-guest-agent.log` inside the guest.
- `prepare-base` fails during installation:
  Check the IPSW, network access, proxy, and VPN setup first. Errors such as `Unknown option '--disk-size-gib'` usually mean an outdated binary is still in use.
- only the guest-agent changed:
  Follow section 2.2. You do not need to run `prepare-base` again.
- section 5 external connectivity fails but same-node connectivity succeeds:
  Re-run the `exec /usr/bin/curl` command with the required proxy environment flags, or set `EXTERNAL_URL` to an endpoint that is reachable from your environment.

For deeper debugging, go straight to [`docs/macos-guest-development-debugging.md`](docs/macos-guest-development-debugging.md).
