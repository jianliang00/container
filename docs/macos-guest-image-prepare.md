# macOS Guest 镜像：从构建 Agent 到 `package/load/push` 全流程

本文档覆盖一条完整的最小闭环链路：

1. 在宿主构建 `container-macos-guest-agent`
2. 生成镜像目录（`prepare-base`）
3. 用手工 GUI VM 启动镜像并通过 virtiofs 注入 agent
4. 将镜像打包为 OCI tar（`container macos package`）
5. 加载并推送到远端镜像仓库（`container image load` + `container image push`）

## 1. 前置条件

- 宿主机为 Apple Silicon（`arm64`）
- 宿主可用 Virtualization.framework（建议 macOS 13+）
- 已安装 Xcode 命令行工具与 Swift 工具链
- 当前目录为仓库根目录：`<repo-root>`
- 已准备可用 IPSW（示例：`UniversalMac_*.ipsw`）
- 推送镜像时已具备目标 registry 账号凭据

## 2. 构建 `container`、prepare helper 与 guest agent

```bash
cd <repo-root>

xcrun swift build -c release --product container
xcrun swift build -c release --product container-macos-guest-agent
xcrun swift build -c release --product container-macos-image-prepare

export CONTAINER_BIN="$PWD/.build/release/container"
export GUEST_AGENT_BIN="$PWD/.build/release/container-macos-guest-agent"
export MACOS_IMAGE_PREPARE_BIN="$PWD/.build/release/container-macos-image-prepare"

test -x "$CONTAINER_BIN"
test -x "$GUEST_AGENT_BIN"
test -x "$MACOS_IMAGE_PREPARE_BIN"
```

说明：`container macos prepare-base` 会调用后端 helper `container-macos-image-prepare`。如果你使用的是本地 `swift build` 产物，建议在执行 `prepare-base` 前确认 helper 具备 `com.apple.security.virtualization` entitlement：

```bash
codesign -d --entitlements :- "$MACOS_IMAGE_PREPARE_BIN" 2>&1 | grep com.apple.security.virtualization
```

若没有输出（或后续 `prepare-base` 报 `The restore image failed to load. Unable to connect to installation service.`），可为当前二进制补签：

```bash
codesign --force --sign - \
  --entitlements signing/container-runtime-macos.entitlements \
  "$MACOS_IMAGE_PREPARE_BIN"
```

## 3. 生成镜像目录（prepare-base）

```bash
export IPSW="/path/to/UniversalMac_xxx_Restore.ipsw"
export IMAGE_DIR="/tmp/macos-image-base"

"$CONTAINER_BIN" macos prepare-base \
  --ipsw "$IPSW" \
  --output "$IMAGE_DIR" \
  --disk-size-gib 64 \
  --memory-mib 8192 \
  --cpus 4

ls -lh "$IMAGE_DIR"/Disk.img "$IMAGE_DIR"/AuxiliaryStorage "$IMAGE_DIR"/HardwareModel.bin
```

成功后镜像目录至少应包含：

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
install -m 0755 scripts/macos-guest-agent/install-in-guest-from-seed.sh "$SEED_DIR/install-in-guest-from-seed.sh"
```

## 5. 手工启动镜像 VM（GUI + virtiofs）

### 5.1 编译手工 VM 工具

```bash
xcrun swiftc scripts/macos-guest-agent/macos-vm-manager.swift \
  -framework AppKit \
  -framework Virtualization \
  -o /tmp/macos-vm-manager

# 关键：为手工 VM 工具补签 Virtualization entitlement
codesign --force --sign - \
  --entitlements signing/container-runtime-macos.entitlements \
  /tmp/macos-vm-manager

# 可选校验：应能看到 com.apple.security.virtualization
codesign -d --entitlements :- /tmp/macos-vm-manager 2>&1 | grep com.apple.security.virtualization
```

注意：

- 不要直接用 `swift macos-vm-manager.swift` 运行，已知可能触发 JIT/符号链接问题
- 请在本地 Aqua 图形会话下运行（纯 SSH 无窗口环境会失败）
- 若跳过补签，`5.2` 启动时可能报：`VZErrorDomain Code=2 "The process doesn’t have the com.apple.security.virtualization entitlement."`
- 若第 6 步日志出现 `Error: ... Operation not supported by device`，通常是手工镜像 VM 未启用 `VZVirtioSocketDeviceConfiguration()`；请更新到最新 `scripts/macos-guest-agent/macos-vm-manager.swift` 后重新编译 `/tmp/macos-vm-manager`

### 5.2 启动 VM

```bash
/tmp/macos-vm-manager start \
  --image "$IMAGE_DIR" \
  --share "$SEED_DIR" \
  --share-tag seed \
  --cpus 4 \
  --memory-mib 8192
```

启动后会弹出 GUI 窗口。

### 5.3 直接用 vsock 调试 guest-agent（不依赖 `container`）

如果你要在手工 VM 场景下直接调试 guest-agent 协议，可在启动 VM 时增加 `--agent-repl`：

```bash
/tmp/macos-vm-manager start \
  --image "$IMAGE_DIR" \
  --share "$SEED_DIR" \
  --share-tag seed \
  --cpus 4 \
  --memory-mib 8192 \
  --agent-repl \
  --agent-port 27000
```

VM 启动成功后，宿主终端会进入 `agent>` 交互模式，可直接发送 frame：

```text
connect
sh /bin/ls /
exec /usr/bin/id
exec-tty /bin/sh
stdin echo hello
close
signal 15
resize 120 40
quit
```

说明：

- 该 REPL 与 VM 在同一进程内，使用 Virtualization.framework 的 `VZVirtioSocketDevice.connect(toPort:)` 直接连 guest-agent。
- `quit` 只退出 REPL，不会关闭 VM 窗口；关闭 VM 请在 guest 内 `sudo shutdown -h now` 或直接关窗口。
- 使用该模式前，仍需确保 guest 内 `com.apple.container.macos.guest-agent` 已安装并在 `system` 域运行。

## 6. 在 Guest 内安装 agent（人工注入）

首次进入该镜像磁盘时，macOS 可能会进入 Setup Assistant 并要求创建本地用户名/密码。请先完成初始化并进入桌面，再执行下面的安装步骤。

说明：

- 这一步创建的账号主要用于镜像制作阶段（执行 `sudo` 安装 agent）
- 后续通过 `container run --os darwin` 启动时，`container` 依赖的是 system 域 `LaunchDaemon`（`com.apple.container.macos.guest-agent`），通常不需要手动图形登录输入密码

在 VM 内终端执行（先挂载以访问脚本；脚本内部会检测已挂载并避免重复挂载）：

```bash
sudo mkdir -p /Volumes/seed
sudo mount -t virtiofs seed /Volumes/seed
sudo bash /Volumes/seed/install-in-guest-from-seed.sh
```

如需自定义端口/挂载参数，可在执行时传入环境变量（示例）：

```bash
sudo CONTAINER_MACOS_AGENT_PORT=27000 \
  CONTAINER_SEED_TAG=seed \
  CONTAINER_SEED_MOUNT=/Volumes/seed \
  bash /Volumes/seed/install-in-guest-from-seed.sh
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

### 6.1 仅更新 guest agent（增量）

当你只修改了 `container-macos-guest-agent`（或 `install.sh` / plist），不需要重跑 `prepare-base`。按下面步骤更新镜像磁盘内的 agent：

1. 在宿主重编译并刷新 seed 目录内容：

```bash
cd <repo-root>
xcrun swift build -c release --product container-macos-guest-agent
export GUEST_AGENT_BIN="$PWD/.build/release/container-macos-guest-agent"

install -m 0755 "$GUEST_AGENT_BIN" "$SEED_DIR/container-macos-guest-agent"
install -m 0755 scripts/macos-guest-agent/install.sh "$SEED_DIR/install.sh"
install -m 0644 scripts/macos-guest-agent/container-macos-guest-agent.plist "$SEED_DIR/container-macos-guest-agent.plist"
install -m 0755 scripts/macos-guest-agent/install-in-guest-from-seed.sh "$SEED_DIR/install-in-guest-from-seed.sh"
```

2. 若你修改的是手工 VM 配置（例如新增 `VZVirtioSocketDeviceConfiguration()`），需要关闭当前手工 VM，并在宿主重新编译/重启 `/tmp/macos-vm-manager`；这类改动不能在运行中的 VM 热生效。

3. 在 guest 内重新执行安装（先挂载以访问脚本；脚本内部会检测已挂载并避免重复挂载）：

```bash
sudo mkdir -p /Volumes/seed
sudo mount -t virtiofs seed /Volumes/seed
sudo bash /Volumes/seed/install-in-guest-from-seed.sh
```

4. 验证更新结果：

```bash
sudo launchctl print system/com.apple.container.macos.guest-agent | head -n 40
sudo tail -n 50 /var/log/container-macos-guest-agent.log
```

5. 验证通过后，按第 7、8 步重新 `package` / `load` / `push` 镜像。

## 7. 打包镜像（`container macos package`）

```bash
export OCI_TAR="/tmp/macos-image-base-oci.tar"

"$CONTAINER_BIN" macos package \
  --input "$IMAGE_DIR" \
  --output "$OCI_TAR" \
  --reference "local/macos-image:base"
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

### 7.1 本地 `load + run/exec` 验证（不推远端）

如果你想在执行第 8 步前，先在宿主做一次端到端验证，可先把第 7 步产物加载到本地镜像存储，然后直接 `run/exec`：

```bash
export LOCAL_REF="local/macos-image:base"

# 1) load 到本地 image store
"$CONTAINER_BIN" image load -i "$OCI_TAR"
"$CONTAINER_BIN" image ls | grep "$LOCAL_REF"

# 2) 冒烟验证：直接跑一条命令（成功返回即说明 guest-agent 基本可用）
"$CONTAINER_BIN" run --os darwin --rm "$LOCAL_REF" /bin/ls /
```

如需额外验证 `container exec` 路径，可再做一次短时驻留容器：

```bash
"$CONTAINER_BIN" run --os darwin --name macos-agent-check --detach \
  "$LOCAL_REF" /bin/sh -lc 'while true; do sleep 3600; done'

"$CONTAINER_BIN" exec macos-agent-check /bin/ls /
"$CONTAINER_BIN" delete --force macos-agent-check
```

## 8. 加载并推送镜像（`container image load` + `container image push`）

先登录 registry（示例以 `ghcr.io`）：

```bash
echo "$REGISTRY_TOKEN" | "$CONTAINER_BIN" registry login ghcr.io --username "$REGISTRY_USER" --password-stdin
```

先将第 7 步生成的 OCI tar 加载到本地镜像存储，再通过通用 `image push` 推送：

```bash
export REF="ghcr.io/<org>/<repo>:macos-image-v1"

"$CONTAINER_BIN" image load --input "$OCI_TAR"
"$CONTAINER_BIN" image push --platform darwin/arm64 --scheme https "$REF"
```

## 9. 常见问题

1. `prepare-base` 报 host unsupported  
   当前宿主不是 Apple Silicon，或不满足 Virtualization 对 macOS guest 的条件。

2. 手工 VM 无法弹窗  
   命令不在图形会话执行；请在本机登录会话中运行，不要仅通过无 GUI 的远程 shell。

3. `package` 报缺少镜像文件  
   检查 `IMAGE_DIR` 是否同时包含 `Disk.img`、`AuxiliaryStorage`、`HardwareModel.bin`。

4. 后续 `container run --os darwin` 无法 `exec`  
   通常是镜像中未成功安装或未启动 `container-macos-guest-agent`，回到第 6 步检查 `launchctl` 与日志。

5. `prepare-base` 报 `The restore image failed to load. Unable to connect to installation service.`  
   常见原因是 `container-macos-image-prepare` helper 缺少 `com.apple.security.virtualization` entitlement（本地 `swift build` 场景）。按第 2 节补签后重试。

6. `prepare-base` 报 `zsh: trace trap`，且目录里只有 `Disk.img` 和 `AuxiliaryStorage`，没有 `HardwareModel.bin`  
   这是旧实现里 `VZMacOSInstaller` 非主线程初始化导致的崩溃。请更新到包含修复的新二进制（至少重新 `xcrun swift build -c release --product container-macos-image-prepare`），并清理旧镜像目录后重试。

7. `prepare-base` 报 `Unknown option '--disk-size-gib'`（或 `--memory-mib`）  
   你当前二进制可能仍使用旧的自动命名参数：`--disk-size-gi-b`、`--memory-mi-b`。更新到包含参数别名修复的新构建，或临时改用旧参数名。

8. `prepare-base` 报 `An error occurred during installation. Installation failed.`（常见伴随 `VZErrorDomain code 10007` / `MobileRestore code 4014`）  
   常见原因是安装阶段访问 Apple restore 服务时被 VPN/TUN/代理或 TLS 拦截影响。建议临时关闭代理/VPN（尤其是 TUN 模式）、确保直连 Apple 服务后重试；必要时改用无代理网络（如手机热点）验证。

9. `5.2` 启动手工 VM 报 `VZErrorDomain Code=2`：`The process doesn’t have the "com.apple.security.virtualization" entitlement.`  
   这是 `/tmp/macos-vm-manager` 未签 `com.apple.security.virtualization` entitlement。按第 `5.1` 节对该二进制执行 `codesign --entitlements signing/container-runtime-macos.entitlements` 后重试。

10. 手工配置镜像时提示创建用户名/密码，担心后续每次启动都要手动登录  
   首次镜像注入时完成 Setup Assistant 是正常现象。只要第 6 步把 `container-macos-guest-agent` 安装为 `system` 域 `LaunchDaemon`（`RunAtLoad` + `KeepAlive`），后续 `container run --os darwin` 一般不依赖图形登录。若运行时报 guest-agent 连接超时，再回到镜像里检查 `launchctl print system/com.apple.container.macos.guest-agent` 和 `/var/log/container-macos-guest-agent.log`。

11. 第 6 步 `launchctl print` 显示 `spawn scheduled`，日志报 `Error: The operation couldn't be completed. Operation not supported by device`  
   这是 guest agent 在创建 `AF_VSOCK` 监听时失败，常见原因是手工镜像 VM 没有配置 virtio socket 设备。请确认 `scripts/macos-guest-agent/macos-vm-manager.swift` 包含 `vmConfiguration.socketDevices = [VZVirtioSocketDeviceConfiguration()]`，然后重新编译并启动手工 VM，再执行第 6 步安装与验证。

12. 我只更新了 guest agent，是否必须重跑 `prepare-base`  
   不需要。按第 `6.1` 节做增量更新即可；若镜像 VM 配置本身有变更（如 socketDevices），需先重启手工 VM 后再重装 agent，最后重新 `package` / `push`。
