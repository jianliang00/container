# macOS Guest 模板：从构建 Agent 到 `package/push` 全流程

本文档覆盖一条完整的最小闭环链路：

1. 在宿主构建 `container-macos-guest-agent`
2. 生成模板目录（`prepare-base`）
3. 用手工 GUI VM 启动模板并通过 virtiofs 注入 agent
4. 将模板打包为 OCI tar（`container macos package`）
5. 推送到远端镜像仓库（`container macos push`）

## 1. 前置条件

- 宿主机为 Apple Silicon（`arm64`）
- 宿主可用 Virtualization.framework（建议 macOS 13+）
- 已安装 Xcode 命令行工具与 Swift 工具链
- 当前目录为仓库根目录：`<repo-root>`
- 已准备可用 IPSW（示例：`UniversalMac_*.ipsw`）
- 推送镜像时已具备目标 registry 账号凭据

## 2. 构建 `container` 与 guest agent

```bash
cd <repo-root>

xcrun swift build -c release --product container
xcrun swift build -c release --product container-macos-guest-agent

export CONTAINER_BIN="$PWD/.build/release/container"
export GUEST_AGENT_BIN="$PWD/.build/release/container-macos-guest-agent"

test -x "$CONTAINER_BIN"
test -x "$GUEST_AGENT_BIN"
```

## 3. 生成模板目录（prepare-base）

```bash
export IPSW="/path/to/UniversalMac_xxx_Restore.ipsw"
export TEMPLATE_DIR="/tmp/macos-template-base"

"$CONTAINER_BIN" macos prepare-base \
  --ipsw "$IPSW" \
  --output "$TEMPLATE_DIR" \
  --disk-size-gib 64 \
  --memory-mib 8192 \
  --cpus 4

ls -lh "$TEMPLATE_DIR"/Disk.img "$TEMPLATE_DIR"/AuxiliaryStorage "$TEMPLATE_DIR"/HardwareModel.bin
```

成功后模板目录至少应包含：

- `Disk.img`
- `AuxiliaryStorage`
- `HardwareModel.bin`

## 4. 准备注入目录（宿主）

把 agent 二进制与安装脚本放进一个共享目录，供 VM 通过 virtiofs 挂载读取：

```bash
export SEED_DIR="/tmp/macos-agent-seed"

rm -rf "$SEED_DIR"
mkdir -p "$SEED_DIR"

install -m 0755 "$GUEST_AGENT_BIN" "$SEED_DIR/container-macos-guest-agent"
install -m 0755 scripts/macos-guest-agent/install.sh "$SEED_DIR/install.sh"
install -m 0644 scripts/macos-guest-agent/container-macos-guest-agent.plist "$SEED_DIR/container-macos-guest-agent.plist"
```

## 5. 手工启动模板 VM（GUI + virtiofs）

### 5.1 编译手工 VM 工具

```bash
xcrun swiftc scripts/macos-guest-agent/manual-template-vm.swift \
  -framework AppKit \
  -framework Virtualization \
  -o /tmp/manual-template-vm
```

注意：

- 不要直接用 `swift manual-template-vm.swift` 运行，已知可能触发 JIT/符号链接问题
- 请在本地 Aqua 图形会话下运行（纯 SSH 无窗口环境会失败）

### 5.2 启动 VM

```bash
/tmp/manual-template-vm \
  --template "$TEMPLATE_DIR" \
  --share "$SEED_DIR" \
  --share-tag seed \
  --cpus 4 \
  --memory-mib 8192
```

启动后会弹出 GUI 窗口。

## 6. 在 Guest 内安装 agent（人工注入）

在 VM 内终端执行：

```bash
sudo mkdir -p /Volumes/seed
sudo mount -t virtiofs seed /Volumes/seed
ls -l /Volumes/seed

sudo install -d /usr/local/bin
sudo install -m 0755 /Volumes/seed/container-macos-guest-agent /usr/local/bin/container-macos-guest-agent

sudo mkdir -p /tmp/container-agent-install
sudo cp /Volumes/seed/install.sh /tmp/container-agent-install/
sudo cp /Volumes/seed/container-macos-guest-agent.plist /tmp/container-agent-install/
sudo chmod +x /tmp/container-agent-install/install.sh

cd /tmp/container-agent-install
sudo CONTAINER_MACOS_AGENT_PORT=27000 ./install.sh /usr/local/bin/container-macos-guest-agent
```

验证 LaunchDaemon 状态：

```bash
sudo launchctl print system/com.apple.container.macos.guest-agent | head -n 40
sudo tail -n 50 /var/log/container-macos-guest-agent.log
```

注入完成后，在 guest 内关机：

```bash
sudo shutdown -h now
```

等待 VM 完全停止并关闭窗口，再回到宿主继续打包。

## 7. 打包模板（`container macos package`）

```bash
export OCI_TAR="/tmp/macos-template-base-oci.tar"

"$CONTAINER_BIN" macos package \
  --input "$TEMPLATE_DIR" \
  --output "$OCI_TAR" \
  --reference "local/macos-template:base"
```

可选校验（需要 `jq`）：

```bash
TMP_LAYOUT="$(mktemp -d)"
tar -xf "$OCI_TAR" -C "$TMP_LAYOUT"
MANIFEST_DIGEST="$(jq -r '.manifests[0].digest' "$TMP_LAYOUT/index.json" | sed 's#sha256:##')"
jq -r '.layers[].mediaType' "$TMP_LAYOUT/blobs/sha256/$MANIFEST_DIGEST"
```

预期至少包含三种 layer mediaType：

- `application/vnd.apple.container.macos.hardware-model`
- `application/vnd.apple.container.macos.auxiliary-storage`
- `application/vnd.apple.container.macos.disk-image`

## 8. 推送模板（`container macos push`）

先登录 registry（示例以 `ghcr.io`）：

```bash
echo "$REGISTRY_TOKEN" | "$CONTAINER_BIN" registry login ghcr.io --username "$REGISTRY_USER" --password-stdin
```

执行推送（内部会自动 package -> load -> tag -> push）：

```bash
export REF="ghcr.io/<org>/<repo>:macos-template-v1"

"$CONTAINER_BIN" macos push \
  --input "$TEMPLATE_DIR" \
  --reference "$REF" \
  --scheme https
```

## 9. 常见问题

1. `prepare-base` 报 host unsupported  
   当前宿主不是 Apple Silicon，或不满足 Virtualization 对 macOS guest 的条件。

2. 手工 VM 无法弹窗  
   命令不在图形会话执行；请在本机登录会话中运行，不要仅通过无 GUI 的远程 shell。

3. `package` 报缺少模板文件  
   检查 `TEMPLATE_DIR` 是否同时包含 `Disk.img`、`AuxiliaryStorage`、`HardwareModel.bin`。

4. 后续 `container run --os darwin` 无法 `exec`  
   通常是模板中未成功安装或未启动 `container-macos-guest-agent`，回到第 6 步检查 `launchctl` 与日志。

5. `prepare-base` 报 `Unknown option '--disk-size-gib'`（或 `--memory-mib`）  
   你当前二进制可能仍使用旧的自动命名参数：`--disk-size-gi-b`、`--memory-mi-b`。更新到包含参数别名修复的新构建，或临时改用旧参数名。
