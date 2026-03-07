# macOS Guest Dockerfile Build Phase 1 手工验收流程

本文档面向 2026-03-06 当前分支，用来手工验收
[`docs/macos-guest-dockerfile-build-design.md`](docs/macos-guest-dockerfile-build-design.md)
里的 Phase 1 主链路。

目标不是覆盖所有 Dockerfile 语义，而是确认当前已经接通的能力在真实
`darwin/arm64` 基础镜像上可用，并且关键拒绝路径行为正确。

## 1. 验收范围

本流程覆盖：

- `container build --platform darwin/arm64` 走 macOS build 路径，而不是 Linux BuildKit builder
- 支持 `FROM/ARG/ENV/WORKDIR/RUN/COPY/ADD(local)/LABEL/CMD/ENTRYPOINT`
- `COPY`、`.dockerignore`、symlink 与 `ADD(local archive)` 的主链路
- `type=oci` 自动 load + tag
- `type=tar` 正常导出，且需要手工 `image load`
- `type=local`、`USER`、`ADD URL`、`COPY --from`、混合平台、`darwin/amd64` 的拒绝路径

本流程不覆盖：

- `USER`
- `ADD URL`
- 多阶段 `COPY --from`
- `COPY` 更细粒度的“目标已存在目录/文件”对齐
- headless CI 场景

## 2. 前置条件

开始前请确认：

- 宿主机是 Apple Silicon，并在本机登录态图形会话里执行
- 已有可运行的 `darwin/arm64` 基础镜像，或准备先按第 3 节制作一个；下面示例假定它的 tag 是 `local/macos-base:latest`
- 如果当前分支修改了 `container-macos-guest-agent`、`scripts/macos-guest-agent/install.sh`、`scripts/macos-guest-agent/install-in-guest-from-seed.sh` 或 guest-agent plist，需要先按第 3.2 节刷新基础镜像，再开始验收
- 验收时使用的基础镜像必须已经包含当前分支可识别 `fs.begin/fs.chunk/fs.end` 的 guest-agent
- 宿主已安装 `zstd`；如果 `zstd` 不在默认搜索路径，可在 `system start` 前设置 `CONTAINER_ZSTD_BIN="$(command -v zstd)"`
- 宿主插件目录已经是当前分支构建结果，而不是旧安装版本

若以上两项还没准备好，先参考：

- [`docs/macos-guest-image-prepare.md`](docs/macos-guest-image-prepare.md)
- [`docs/macos-guest-development-debugging.md`](docs/macos-guest-development-debugging.md)

建议把下面这个命令先跑通，再开始后续验收：

```bash
container run --os darwin --rm local/macos-base:latest /bin/ls /
```

如果这一步都不稳定，先不要继续验证 `container build`。

## 3. 制作或刷新验收基础镜像

本节的目标是得到一个可直接用于后续验收的 `BASE_REF=local/macos-base:latest`。

### 3.1 没有基础镜像时：先走完整制作流程

如果你本地还没有可用的 macOS 基础镜像，不要直接跳到后面的 build 验收。先按
[`docs/macos-guest-image-prepare.md`](docs/macos-guest-image-prepare.md)
完整跑通下面这条最小命令链：

```bash
cd /Users/jianliang/Code/container
make release

export CONTAINER_BIN="$PWD/bin/container"
export BASE_REF="local/macos-base:latest"
export IPSW="/path/to/UniversalMac_xxx_Restore.ipsw"
export IMAGE_DIR="/tmp/macos-image-base"
export SEED_DIR="/tmp/macos-agent-seed"
export OCI_TAR="/tmp/macos-image-base-oci.tar"

"$CONTAINER_BIN" macos prepare-base \
  --ipsw "$IPSW" \
  --output "$IMAGE_DIR" \
  --disk-size-gib 64 \
  --memory-mib 8192 \
  --cpus 4

"$CONTAINER_BIN" macos guest-agent prepare -o "$SEED_DIR" --overwrite

"$CONTAINER_BIN" macos start-vm \
  --image "$IMAGE_DIR" \
  --share "$SEED_DIR" \
  --cpus 4 \
  --memory-mib 8192
```

在 guest 里执行：

```bash
sudo mkdir -p /Volumes/seed
sudo mount -t virtiofs seed /Volumes/seed
sudo bash /Volumes/seed/install-in-guest-from-seed.sh

sudo launchctl print system/com.apple.container.macos.guest-agent | head -n 40
sudo tail -n 50 /var/log/container-macos-guest-agent.log
sudo shutdown -h now
```

guest 完全关机后，在宿主继续：

```bash
"$CONTAINER_BIN" macos package \
  --input "$IMAGE_DIR" \
  --output "$OCI_TAR" \
  --reference "$BASE_REF"

"$CONTAINER_BIN" image load -i "$OCI_TAR"
"$CONTAINER_BIN" run --os darwin --rm "$BASE_REF" /bin/ls /
```

建议最终把验收用基础镜像统一做成：

```bash
export BASE_REF="local/macos-base:latest"
```

如果你在 `package` 时使用了别的 reference，先补一个 tag：

```bash
container image tag <your-loaded-ref> "$BASE_REF"
```

### 3.2 agent 有变更时：刷新基础镜像

如果你当前分支改了 guest-agent 或安装脚本，不需要重跑 `prepare-base`，但需要把变更重新安装进镜像磁盘，然后重新 `package + image load`，否则后面的验收仍然会跑在旧 agent 上。

下面假定你已经有一个可启动的 `IMAGE_DIR`，即之前 `prepare-base` 产出的镜像目录：

```bash
cd /Users/jianliang/Code/container
make release

export CONTAINER_BIN="$PWD/bin/container"
export BASE_REF="local/macos-base:latest"
export IMAGE_DIR="/tmp/macos-image-base"
export SEED_DIR="/tmp/macos-agent-seed"
export OCI_TAR="/tmp/macos-image-base-oci.tar"
```

重新生成注入目录：

```bash
rm -rf "$SEED_DIR"
"$CONTAINER_BIN" macos guest-agent prepare -o "$SEED_DIR" --overwrite
```

启动手工 VM：

```bash
"$CONTAINER_BIN" macos start-vm \
  --image "$IMAGE_DIR" \
  --share "$SEED_DIR" \
  --cpus 4 \
  --memory-mib 8192
```

在 guest 里重新安装 agent：

```bash
sudo mkdir -p /Volumes/seed
sudo mount -t virtiofs seed /Volumes/seed
sudo bash /Volumes/seed/install-in-guest-from-seed.sh

sudo launchctl print system/com.apple.container.macos.guest-agent | head -n 40
sudo tail -n 50 /var/log/container-macos-guest-agent.log
sudo shutdown -h now
```

guest 完全关机后，在宿主重新打包并加载镜像：

```bash
"$CONTAINER_BIN" macos package \
  --input "$IMAGE_DIR" \
  --output "$OCI_TAR" \
  --reference "$BASE_REF"

"$CONTAINER_BIN" image load -i "$OCI_TAR"
"$CONTAINER_BIN" run --os darwin --rm "$BASE_REF" /bin/ls /
```

通过标准：

- `launchctl print system/com.apple.container.macos.guest-agent` 正常
- `macos package` 成功
- `image load` 成功
- 刷新后的 `"$BASE_REF"` 能直接 `run --os darwin`

## 4. 环境初始化

如果仓库根目录下的 `bin/` 和 `libexec/` 不是当前分支最新产物，先刷新一次：

```bash
cd /Users/jianliang/Code/container
make release
```

然后设置本次验收使用的环境变量：

```bash
cd /Users/jianliang/Code/container

export CONTAINER_BIN="$PWD/bin/container"
export BASE_REF="local/macos-base:latest"
export TEST_NS="local/macos-build-phase1"
export WORKROOT="/tmp/macos-build-phase1-acceptance"

command -v zstd
export CONTAINER_ZSTD_BIN="${CONTAINER_ZSTD_BIN:-$(command -v zstd)}"

rm -rf "$WORKROOT"
mkdir -p "$WORKROOT"

"$CONTAINER_BIN" image delete --force \
  "${TEST_NS}:smoke" \
  "${TEST_NS}:copy" \
  "${TEST_NS}:add-config" \
  "${TEST_NS}:tar" >/dev/null 2>&1 || true
```

启动当前仓库对应的 `container system` 服务：

```bash
"$CONTAINER_BIN" system stop || true
"$CONTAINER_BIN" system start --install-root "$PWD" --disable-kernel-install --timeout 60
"$CONTAINER_BIN" system status
```

做一次 preflight：

```bash
"$CONTAINER_BIN" run --os darwin --rm "$BASE_REF" /bin/ls /
```

预期结果：

- `system start` 成功
- `system status` 显示服务正常
- 基础镜像能直接 `run --os darwin`

如果这里失败，优先回到：

- [`docs/macos-guest-development-debugging.md`](docs/macos-guest-development-debugging.md) 的第 4 节和第 8 节

## 5. 用例 1：基础构建与路由

准备最小 Dockerfile：

```bash
mkdir -p "$WORKROOT/01-smoke"

cat > "$WORKROOT/01-smoke/Dockerfile" <<EOF
FROM --platform=darwin/arm64 ${BASE_REF}
RUN sw_vers
EOF
```

执行构建：

```bash
"$CONTAINER_BIN" build \
  --platform darwin/arm64 \
  --progress plain \
  -t "${TEST_NS}:smoke" \
  "$WORKROOT/01-smoke" 2>&1 | tee "$WORKROOT/01-smoke/build.log"
```

检查：

```bash
if grep -q "Dialing builder" "$WORKROOT/01-smoke/build.log"; then
  echo "unexpected linux builder path"
  exit 1
fi

"$CONTAINER_BIN" run --os darwin --rm "${TEST_NS}:smoke" /usr/bin/sw_vers
```

通过标准：

- 构建成功
- `build.log` 里能看到 `sw_vers` 输出
- `build.log` 里不出现 `Dialing builder`
- 生成的镜像已经自动 load 并打上 `"${TEST_NS}:smoke"`，可直接 `run --os darwin`

## 6. 用例 2：`COPY`、`.dockerignore`、symlink

准备 context：

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
```

执行构建：

```bash
"$CONTAINER_BIN" build \
  --platform darwin/arm64 \
  --progress plain \
  -t "${TEST_NS}:copy" \
  "$WORKROOT/02-copy"
```

运行一次人工检查：

```bash
"$CONTAINER_BIN" run --os darwin --rm "${TEST_NS}:copy" /bin/sh -lc 'ls -l /opt/copy-check'
```

通过标准：

- build 内的 `RUN test ...` 全部通过
- `/opt/copy-check/keep.txt` 存在
- `/opt/copy-check/link.txt` 是软链接，且指向 `keep.txt`
- 被 `.dockerignore` 排除的 `debug.log` 和 `nested/app.log` 不存在

## 7. 用例 3：`ADD(local archive)` 与 image config

准备 archive 和 Dockerfile：

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
```

执行构建：

```bash
"$CONTAINER_BIN" build \
  --platform darwin/arm64 \
  --progress plain \
  -t "${TEST_NS}:add-config" \
  "$WORKROOT/03-add-config"
```

验证默认启动行为和 label：

```bash
"$CONTAINER_BIN" run --os darwin --rm "${TEST_NS}:add-config"

"$CONTAINER_BIN" image inspect "${TEST_NS}:add-config" > "$WORKROOT/03-add-config/inspect.json"
grep -q '"com.apple.container.phase":"phase1"' "$WORKROOT/03-add-config/inspect.json"
```

通过标准：

- build 内的 `RUN test -f /opt/app/archive/sub/hello.txt` 通过，说明 `ADD(local archive)` 已解包
- 默认启动输出正好是 `/opt/app from-env`
- `image inspect` 结果里能找到 `com.apple.container.phase=phase1`

这条用例实际覆盖了：

- `ADD(local archive)`
- `ENV`
- `WORKDIR`
- `LABEL`
- `ENTRYPOINT`
- `CMD`

## 8. 用例 4：`type=tar` 导出契约

执行导出：

```bash
mkdir -p "$WORKROOT/out"

"$CONTAINER_BIN" build \
  --platform darwin/arm64 \
  --progress plain \
  --output type=tar,dest="$WORKROOT/out/phase1.tar" \
  -t "${TEST_NS}:tar" \
  "$WORKROOT/01-smoke"
```

先验证它没有自动 load：

```bash
if "$CONTAINER_BIN" image inspect "${TEST_NS}:tar" >/dev/null 2>&1; then
  echo "type=tar should not auto-load the image"
  exit 1
fi
```

再验证 tar 内容并手工导入：

```bash
tar -tf "$WORKROOT/out/phase1.tar" > "$WORKROOT/out/phase1.tar.list"
grep -q '^index.json$' "$WORKROOT/out/phase1.tar.list"
grep -q '^oci-layout$' "$WORKROOT/out/phase1.tar.list"

"$CONTAINER_BIN" image load -i "$WORKROOT/out/phase1.tar"
"$CONTAINER_BIN" run --os darwin --rm "${TEST_NS}:tar" /usr/bin/sw_vers
```

通过标准：

- 构建成功并生成 `phase1.tar`
- `type=tar` 不会自动 load 本地镜像
- tar 里至少包含 `index.json` 和 `oci-layout`
- 手工 `image load` 之后能按 `"${TEST_NS}:tar"` 运行

## 9. 用例 5：关键拒绝路径

先准备一个失败检测 helper：

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
```

准备 3 个非法 Dockerfile：

```bash
mkdir -p "$WORKROOT/04-negative/user"
mkdir -p "$WORKROOT/04-negative/add-url"
mkdir -p "$WORKROOT/04-negative/copy-from"

cat > "$WORKROOT/04-negative/user/Dockerfile" <<EOF
FROM ${BASE_REF}
USER builder
EOF

cat > "$WORKROOT/04-negative/add-url/Dockerfile" <<EOF
FROM ${BASE_REF}
ADD https://example.com/file.tar /tmp/file.tar
EOF

cat > "$WORKROOT/04-negative/copy-from/Dockerfile" <<EOF
FROM ${BASE_REF} AS build
RUN sw_vers

FROM ${BASE_REF}
COPY --from=build /tmp/out /tmp/out
EOF
```

执行拒绝路径验证：

```bash
expect_fail mixed-platform \
  "darwin builds do not support mixed or multi-target platforms" \
  "$CONTAINER_BIN" build --platform linux/arm64,darwin/arm64 "$WORKROOT/01-smoke"

expect_fail darwin-amd64 \
  "darwin builds require darwin/arm64" \
  "$CONTAINER_BIN" build --platform darwin/amd64 "$WORKROOT/01-smoke"

expect_fail local-output \
  "darwin builds do not support --output type=local in phase 1" \
  "$CONTAINER_BIN" build --platform darwin/arm64 --output type=local,dest="$WORKROOT/local-out" "$WORKROOT/01-smoke"

expect_fail user-unsupported \
  "darwin builds do not support USER in phase 1" \
  "$CONTAINER_BIN" build --platform darwin/arm64 "$WORKROOT/04-negative/user"

expect_fail add-url-unsupported \
  "darwin builds do not support ADD <url> in phase 1" \
  "$CONTAINER_BIN" build --platform darwin/arm64 "$WORKROOT/04-negative/add-url"

expect_fail copy-from-unsupported \
  "darwin builds do not support COPY --from in phase 1" \
  "$CONTAINER_BIN" build --platform darwin/arm64 "$WORKROOT/04-negative/copy-from"
```

通过标准：

- 上面 6 条命令都失败
- 每条失败日志里都包含对应的固定错误文本

## 10. 验收通过判定

当下面这些条件同时成立时，可以认为当前分支的 Phase 1 主链路通过手工验收：

- 用例 1 到 4 全部成功
- 用例 5 的 6 条拒绝路径全部命中预期错误
- `type=oci` 路径下生成的镜像都能直接 `run --os darwin`
- `type=tar` 路径下导出的 tar 能手工 `image load`

仍然不在本次“通过”范围里的事项：

- `USER`
- `ADD URL`
- 多阶段 `COPY --from`
- 更完整的 Dockerfile 语义对齐
- 自动化 CLI / E2E 测试矩阵

## 11. 清理

如果只想清掉本次验收留下的样例目录和镜像：

```bash
"$CONTAINER_BIN" image delete --force \
  "${TEST_NS}:smoke" \
  "${TEST_NS}:copy" \
  "${TEST_NS}:add-config" \
  "${TEST_NS}:tar"

rm -rf "$WORKROOT"
```

如果验收中途需要重启服务：

```bash
"$CONTAINER_BIN" system stop
"$CONTAINER_BIN" system start --install-root "$PWD" --disable-kernel-install --timeout 60
```
