# macOS Guest 本地开发验证指南

这份文档只保留一条本地开发常用路径：

1. 准备或刷新一个可运行的 `darwin/arm64` 基础镜像
2. 用这个基础镜像验证 `container build --platform darwin/arm64`

除启动手工 VM 后需要在 guest 里完成初始化和安装 agent 之外，其他步骤都可以直接在宿主命令行执行。

这份指南默认使用 `container macos start-vm` 的默认 seed 注入方式：

- virtiofs tag: `com.apple.virtio-fs.automount`
- guest 内 seed 路径: `/Volumes/My Shared Files/seed`

因此 guest 内不需要再手工 `mount -t virtiofs seed /Volumes/seed`。

## 1. 前置条件

- 宿主机是 Apple Silicon
- 在本机图形会话里执行，不要只在无 GUI 的远程 shell 里跑
- 已安装 Xcode 命令行工具、Swift 工具链和 `zstd`
- 首次制作基础镜像时，已准备好可用 IPSW，例如 `UniversalMac_*.ipsw`
- 如果当前分支改了下面这些文件，先刷新基础镜像再做 build 验证：
  - `container-macos-guest-agent`
  - `scripts/macos-guest-agent/install.sh`
  - `scripts/macos-guest-agent/install-in-guest-from-seed.sh`
  - `scripts/macos-guest-agent/container-macos-guest-agent.plist`

统一使用下面这些环境变量：

```bash
cd /Users/jianliang/Code/container

export CONTAINER_BIN="$PWD/bin/container"
export BASE_REF="local/macos-base:latest"
export IMAGE_DIR="/tmp/macos-image-base"
export SEED_DIR="/tmp/macos-agent-seed"
export OCI_TAR="/tmp/macos-image-base-oci.tar"
export TEST_NS="local/macos-build-phase1"
export WORKROOT="/tmp/macos-build-phase1-acceptance"
export IPSW="/path/to/UniversalMac_xxx_Restore.ipsw"
```

如果只是做 build 验证，`IPSW` 可以不设。

## 2. 准备基础镜像

先确保当前仓库产物是最新的：

```bash
cd /Users/jianliang/Code/container
make release

export CONTAINER_BIN="$PWD/bin/container"
export CONTAINER_ZSTD_BIN="${CONTAINER_ZSTD_BIN:-$(command -v zstd)}"
```

### 2.1 首次制作基础镜像

先在宿主准备镜像目录和 seed：

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

从这一步开始需要人工操作：在弹出的 macOS VM 里完成 Setup Assistant，进入桌面后打开 Terminal，执行：

```bash
sudo bash '/Volumes/My Shared Files/seed/install-in-guest-from-seed.sh'

sudo launchctl print system/com.apple.container.macos.guest-agent | head -n 40
sudo tail -n 50 /var/log/container-macos-guest-agent.log
sudo shutdown -h now
```

guest 完全关机后回到宿主执行：

```bash
"$CONTAINER_BIN" macos package \
  --input "$IMAGE_DIR" \
  --output "$OCI_TAR" \
  --reference "$BASE_REF"

"$CONTAINER_BIN" image load -i "$OCI_TAR"
"$CONTAINER_BIN" run --os darwin --rm "$BASE_REF" /bin/ls /
```

到这里 `"$BASE_REF"` 应该已经可以直接运行。

### 2.2 只刷新 guest-agent

如果你已经有可启动的 `IMAGE_DIR`，只需要重新生成 seed、重新安装 agent，然后重新打包：

```bash
rm -rf "$SEED_DIR"
"$CONTAINER_BIN" macos guest-agent prepare -o "$SEED_DIR" --overwrite

"$CONTAINER_BIN" macos start-vm \
  --image "$IMAGE_DIR" \
  --share "$SEED_DIR" \
  --cpus 4 \
  --memory-mib 8192
```

这一步同样需要人工在 guest 里执行：

```bash
sudo bash '/Volumes/My Shared Files/seed/install-in-guest-from-seed.sh'

sudo launchctl print system/com.apple.container.macos.guest-agent | head -n 40
sudo tail -n 50 /var/log/container-macos-guest-agent.log
sudo shutdown -h now
```

guest 关机后回到宿主执行：

```bash
"$CONTAINER_BIN" macos package \
  --input "$IMAGE_DIR" \
  --output "$OCI_TAR" \
  --reference "$BASE_REF"

"$CONTAINER_BIN" image load -i "$OCI_TAR"
"$CONTAINER_BIN" run --os darwin --rm "$BASE_REF" /bin/ls /
```

### 2.3 自动注入当前仓库里的最新 guest-agent

如果你刚改了 `container-macos-guest-agent` 或 `scripts/macos-guest-agent/*`，又不想手工准备 `$SEED_DIR`，可以直接让 `start-vm --auto-seed` 在启动时生成临时注入目录。

先构建最新 agent，并显式指定二进制和脚本来源：

```bash
cd /Users/jianliang/Code/container

xcrun swift build -c release --product container-macos-guest-agent

export CONTAINER_MACOS_GUEST_AGENT_BIN="$PWD/.build/arm64-apple-macosx/release/container-macos-guest-agent"
export CONTAINER_MACOS_GUEST_AGENT_SCRIPTS_DIR="$PWD/scripts/macos-guest-agent"

"$CONTAINER_BIN" macos start-vm \
  --image "$IMAGE_DIR" \
  --auto-seed \
  --cpus 4 \
  --memory-mib 8192
```

guest 内仍然执行同一套安装命令：

```bash
sudo bash '/Volumes/My Shared Files/seed/install-in-guest-from-seed.sh'

sudo launchctl print system/com.apple.container.macos.guest-agent | head -n 40
sudo tail -n 50 /var/log/container-macos-guest-agent.log
sudo shutdown -h now
```

guest 关机后重新打包并加载：

```bash
"$CONTAINER_BIN" macos package \
  --input "$IMAGE_DIR" \
  --output "$OCI_TAR" \
  --reference "$BASE_REF"

"$CONTAINER_BIN" image load -i "$OCI_TAR"
"$CONTAINER_BIN" run --os darwin --rm "$BASE_REF" /bin/ls /
```

如果你已经执行过 `make release`，并且安装目录里的 `container-macos-guest-agent` 就是最新的，也可以省略这两个环境变量，直接用 `--auto-seed`。

## 3. build 前初始化

```bash
cd /Users/jianliang/Code/container
make release

export CONTAINER_BIN="$PWD/bin/container"
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
"$CONTAINER_BIN" system start --install-root "$PWD" --disable-kernel-install --timeout 60
"$CONTAINER_BIN" system status

"$CONTAINER_BIN" run --os darwin --rm "$BASE_REF" /bin/ls /
```

如果这里都不稳定，先不要继续验证 `container build`，直接去看 [`docs/macos-guest-development-debugging.md`](docs/macos-guest-development-debugging.md)。

## 4. 验证用例

### 4.1 基础构建与路由

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

预期：构建成功，日志里没有 `Dialing builder`，并且镜像能直接运行。

### 4.2 `COPY`、`.dockerignore`、symlink

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

预期：`keep.txt` 存在，`link.txt` 是指向 `keep.txt` 的软链接，被 `.dockerignore` 排除的日志文件不存在。

### 4.3 `ADD(local archive)` 与 image config

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

预期：默认启动输出 `/opt/app from-env`，并且 `inspect.json` 里能看到 `com.apple.container.phase=phase1`。

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

预期：`type=tar` 不会自动 load，手工 `image load` 后可以运行。

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

预期：`type=local` 会导出一个 macOS image directory，目录里至少包含 `Disk.img`、`AuxiliaryStorage`、`HardwareModel.bin`，并且可直接给 `macos start-vm` 使用。

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

预期：构建成功，`RUN` 阶段按 `nobody` 执行，默认启动输出 `nobody`，并且镜像 inspect 结果里能看到 `User=nobody`。

### 4.7 拒绝路径

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

预期：上面 4 条命令都失败，而且日志里包含对应错误文本。

## 5. 通过标准

满足下面这些条件就够了：

- `"$BASE_REF"` 可以稳定执行 `run --os darwin`
- 4.1 到 4.5 全部成功
- 4.6 的 5 条拒绝路径都命中预期错误

这次验证不包含：

- `ADD URL`
- 多阶段 `COPY --from`
- 更完整的 Dockerfile 语义对齐

## 6. 清理

```bash
"$CONTAINER_BIN" image delete --force \
  "${TEST_NS}:smoke" \
  "${TEST_NS}:copy" \
  "${TEST_NS}:add-config" \
  "${TEST_NS}:user" \
  "${TEST_NS}:tar"

rm -rf "$WORKROOT"
```

如果中途需要重启服务：

```bash
"$CONTAINER_BIN" system stop
"$CONTAINER_BIN" system start --install-root "$PWD" --disable-kernel-install --timeout 60
```

## 7. 常见问题

- `prepare-base` 或 `start-vm` 缺 entitlement：
  优先用 `make release` 产物；如果必须用 `.build/release/*`，给 `container-macos-image-prepare` 和 `container-macos-vm-manager` 补签 `signing/container-runtime-macos.entitlements`。
- 手工 VM 不弹窗：
  说明命令不在图形会话里执行。
- `run --os darwin` 或 `exec` 连不上 guest-agent：
  回到 guest 里重新检查 `launchctl print system/com.apple.container.macos.guest-agent` 和 `/var/log/container-macos-guest-agent.log`。
- `prepare-base` 安装阶段失败：
  先检查 IPSW、网络、代理和 VPN；`Unknown option '--disk-size-gib'` 这类错误通常说明你还在用旧二进制。
- 只改了 guest-agent：
  走 2.2 即可，不需要重跑 `prepare-base`。

如需更细的排障步骤，直接看 [`docs/macos-guest-development-debugging.md`](docs/macos-guest-development-debugging.md)。
