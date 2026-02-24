# macOS Guest 功能开发与调试手册（基于实战排障过程）

本文档整理了 macOS guest 功能在多轮开发与排障中的关键结论、调试手段、常见故障与修复流程，目标是帮助你在后续迭代中快速定位问题，不再重复踩坑。

适用范围：

- `container run --os darwin ...`
- `container-runtime-macos` / `container-runtime-macos-sidecar`
- `container-macos-guest-agent`
- 镜像 VM（`prepare-base` 生成的 `IMAGE_DIR`）
- 手工调试工具：`container macos start-vm`

配套文档：

- 镜像制作/打包/推送流程：`docs/macos-guest-image-prepare.md`

建议先复用 `docs/macos-guest-image-prepare.md` 中的环境变量约定（如 `CONTAINER_BIN`、`IMAGE_DIR`、`SEED_DIR`、`OCI_TAR`、`LOCAL_REF`）。

## 1. 当前架构（重构后）

当前默认路径已经不是在 `container-runtime-macos` helper 进程内直接承载 `VZVirtualMachine`，而是：

1. `container-runtime-macos`（helper）负责：
   - XPC `SandboxService` 路由
   - 容器 root / 镜像文件准备
   - 启动/管理 sidecar（LaunchAgent）
   - 转发 stdio、wait、signal、resize 等高层操作
2. `container-runtime-macos-sidecar`（GUI 域 LaunchAgent）负责：
   - 承载 `VZVirtualMachine`
   - 使用“无窗口但保留显示设备（headless-display）”模式启动 macOS VM
   - 与 guest 内 `container-macos-guest-agent` 建立 vsock 连接
   - 处理 `process.start/stdin/signal/resize/close`
   - 向 helper 回传 `stdout/stderr/exit` 事件

这个架构是为了规避此前 `container-runtime-macos` 在 helper/XPC 上下文中直接调用 `VZVirtioSocketDevice.connect(toPort:)` 时高概率出现的 `Code=54 Connection reset by peer` 问题。

## 2. 核心结论（先看这个）

### 2.1 纯 headless 与 headless-display 的差异是关键

实际验证结果：

- `container macos start-vm --headless`：常见 `vsock Code=54 reset by peer`
- `container macos start-vm --headless-display`：guest-agent 可正常连通
- `container-runtime-macos` 直接在 helper 内“无窗口+保留显示设备”仍可能失败（运行上下文差异）
- 将 VM 承载迁移到 GUI 域 sidecar 后，稳定性显著提升

结论：

- “纯 headless”不是可靠启动模式（至少对当前镜像/agent 组合不是）
- “无窗口 + 保留显示设备”是更稳定的默认模式

### 2.2 手工 VM 正常，不等于 `container run` 一定正常

你可能遇到过：

- `start-vm` 里 agent 正常
- `container run` 仍报 `failed to connect to guest agent ... Code=54`

常见原因并不矛盾，通常是以下之一：

- 打包镜像时镜像盘还没关机落盘（用的是旧镜像内容）
- 插件目录里仍是旧版 `container-runtime-macos` / `sidecar`（你只重编译了 `.build`）
- `container system` 未重启，仍在运行旧插件进程
- 某个旧容器/旧 sidecar 卡死，拖住 APIServer，导致后续 `containerCreate` XPC 超时

### 2.3 不要直接改 `.build`

`.build` 是编译产物目录。正确做法：

- 修改源码（`Sources/...` 或 `scripts/...`）
- 重新编译
- 将二进制部署到实际运行路径（例如插件目录）
- 重签 entitlement（macOS Virtualization 必需）
- 重启 `container system`

## 3. 常用环境与路径

常用环境变量（建议复用）：

```bash
export CONTAINER_BIN="$PWD/.build/release/container"
export IMAGE_DIR="/tmp/macos-image-base"
export SEED_DIR="/tmp/macos-agent-seed"
export OCI_TAR="/tmp/macos-image-base-oci.tar"
export LOCAL_REF="local/macos-image:base"
```

关键路径：

- 插件 helper：`libexec/container/plugins/container-runtime-macos/bin/container-runtime-macos`
- 插件 sidecar：`libexec/container/plugins/container-runtime-macos/bin/container-runtime-macos-sidecar`
- 手工调试 VM helper（安装包路径）：`/usr/local/libexec/container/macos-vm-manager/bin/container-macos-vm-manager`
- guest-agent 日志（guest 内）：`/var/log/container-macos-guest-agent.log`
- 容器 helper 日志（宿主容器 root）：`<container-root>/stdio.log`

## 4. 构建、部署、重签（开发迭代必做）

### 4.1 构建相关二进制

```bash
xcrun swift build -c release --product container
xcrun swift build -c release --product container-runtime-macos
xcrun swift build -c release --product container-runtime-macos-sidecar
xcrun swift build -c release --product container-macos-guest-agent
```

### 4.2 部署 runtime helper + sidecar 到插件目录（重要）

仅编译 `.build` 不会自动替换运行中的插件。需要显式覆盖：

```bash
cp .build/arm64-apple-macosx/release/container-runtime-macos \
  libexec/container/plugins/container-runtime-macos/bin/container-runtime-macos

cp .build/arm64-apple-macosx/release/container-runtime-macos-sidecar \
  libexec/container/plugins/container-runtime-macos/bin/container-runtime-macos-sidecar
```

### 4.3 重新签名（两个二进制都要）

```bash
codesign --force --sign - \
  --entitlements signing/container-runtime-macos.entitlements \
  libexec/container/plugins/container-runtime-macos/bin/container-runtime-macos

codesign --force --sign - \
  --entitlements signing/container-runtime-macos.entitlements \
  libexec/container/plugins/container-runtime-macos/bin/container-runtime-macos-sidecar
```

校验（应看到 `com.apple.security.virtualization`）：

```bash
codesign -d --entitlements :- \
  libexec/container/plugins/container-runtime-macos/bin/container-runtime-macos 2>&1 | \
  grep com.apple.security.virtualization

codesign -d --entitlements :- \
  libexec/container/plugins/container-runtime-macos/bin/container-runtime-macos-sidecar 2>&1 | \
  grep com.apple.security.virtualization
```

### 4.4 重启服务（加载新插件）

```bash
"$CONTAINER_BIN" system stop
"$CONTAINER_BIN" system start --install-root "$PWD" --disable-kernel-install
```

说明：

- `--install-root "$PWD"` 可以确保使用当前仓库插件路径
- 若不加，可能走到别的安装路径/旧插件
- `system stop` 如果遇到旧容器卡死，日志里可能看到某个 runtime helper 的 `XPC timeout`，但通常后续 `bootout` 仍会强制卸载对应 launchd 单元

## 5. 镜像 VM 调试（不依赖 `container run`）

这是最有效的隔离调试手段，用来判断问题在：

- guest-agent 协议
- guest 内 daemon 启动
- host vsock 连接路径
- runtime/helper 上下文差异

### 5.1 启动手工 VM（`container macos start-vm`）

### 5.2 三种启动模式（A/B 必备）

如需简化流程（不手工创建 `$SEED_DIR`），可在启动时使用 `--auto-seed` 让 `start-vm` 自动创建临时注入目录并挂载：

```bash
"$CONTAINER_BIN" macos start-vm \
  --image "$IMAGE_DIR" \
  --auto-seed \
  --cpus 4 \
  --memory-mib 8192
```

#### GUI（正常人工调试）

```bash
"$CONTAINER_BIN" macos start-vm \
  --image "$IMAGE_DIR" \
  --share "$SEED_DIR" \
  --cpus 4 \
  --memory-mib 8192
```

#### 纯 headless（用于复现问题，不推荐作为默认）

```bash
"$CONTAINER_BIN" macos start-vm \
  --image "$IMAGE_DIR" \
  --share "$SEED_DIR" \
  --cpus 4 \
  --memory-mib 8192 \
  --headless
```

#### headless-display（无窗口，但保留显示设备；接近稳定路径）

```bash
"$CONTAINER_BIN" macos start-vm \
  --image "$IMAGE_DIR" \
  --share "$SEED_DIR" \
  --cpus 4 \
  --memory-mib 8192 \
  --headless-display
```

### 5.3 直接调 guest-agent：REPL（vsock）

在手工 VM 启动时增加 `--agent-repl`：

```bash
"$CONTAINER_BIN" macos start-vm \
  --image "$IMAGE_DIR" \
  --share "$SEED_DIR" \
  --cpus 4 \
  --memory-mib 8192 \
  --agent-repl \
  --agent-port 27000 \
  --agent-connect-retries 240
```

常用命令：

```text
connect
connect-wait
sh /bin/ls /
exec /bin/echo hello
exec-tty /bin/sh
stdin echo hello
close
signal 15
resize 120 40
quit
```

关键判断信号：

- `[agent-repl] vsock connect callback succeeded; waiting for ready frame...`
- `[ready] guest-agent is ready`
- `[stdout] ...`
- `[exit] code=0`

如果只有 `connect callback succeeded` 但一直没有 `[ready]`：

- guest 端没有发 `ready` frame
- 或宿主 REPL 读路径有 bug（此前确实修过，最终改为 `Darwin.read/write`）

### 5.4 非交互探针（适合脚本化）

```bash
"$CONTAINER_BIN" macos start-vm ... --agent-probe --agent-port 27000
```

预期：

- 成功：`[agent-probe] success: guest-agent ready on port 27000`
- 失败：会打印连接阶段错误（如 `Code=54`、ready timeout）

### 5.5 Unix socket 控制口（sidecar 风格调试）

`start-vm` 支持用 `--control-socket` 启动一个控制服务器，便于脚本化验证：

```bash
"$CONTAINER_BIN" macos start-vm \
  --image "$IMAGE_DIR" \
  --share "$SEED_DIR" \
  --cpus 4 \
  --memory-mib 8192 \
  --headless-display \
  --control-socket /tmp/macos-vm-manager.sock
```

控制命令（通过 Unix socket 发送文本行）：

- `help`
- `probe`
- `exec <path> [args...]`
- `sh <command>`
- `quit`

这条链路用于验证：

- GUI 域 sidecar 承载 VM 是可行的
- 宿主通过控制面可以完成 `probe/exec`，不依赖 `container run`

## 6. guest-agent 安装与验证（镜像盘内）

### 6.1 在 guest 内安装（通过 seed 目录）

```bash
sudo mkdir -p /Volumes/seed
sudo mount -t virtiofs seed /Volumes/seed
sudo bash /Volumes/seed/install-in-guest-from-seed.sh
```

### 6.2 验证 daemon 与日志

```bash
sudo launchctl print system/com.apple.container.macos.guest-agent | head -n 80
sudo tail -n 120 /var/log/container-macos-guest-agent.log
```

### 6.3 前台手动启动（强隔离调试）

用于排除 LaunchDaemon 干扰，尤其是排查 `ready frame` 问题：

```bash
sudo launchctl bootout system/com.apple.container.macos.guest-agent || true
sudo /usr/local/bin/container-macos-guest-agent --port 27001
```

然后宿主侧用 REPL 连 `27001`：

```text
connect
exec /bin/echo hello
```

若前台 agent 日志显示：

- `sending ready frame`
- `ready frame sent`
- `peer closed stream`

同时宿主仍看不到 `[ready]`，说明更可能是宿主读路径问题（此前已修复）。

## 7. `container run` 调试总流程（推荐顺序）

当 `container run --os darwin` 出问题时，不要一开始就反复试 `run`。按这个顺序能最快缩小范围：

1. 确认 `container system` 正常启动
2. 手工 VM（GUI）验证 guest-agent / REPL
3. 手工 VM 做 `headless` vs `headless-display` A/B
4. 确认镜像盘改动已关机落盘，再 `package + image load`
5. 确认插件目录已更新（不是 `.build` 里的新版本）
6. 重启 `container system`
7. 再跑 `container run`

## 8. 常见错误与定位方法（实战版）

### 8.1 `container system start` 卡在 `Verifying apiserver is running...`

可能原因：

- `launchctl bootstrap` 使用了错误/旧的安装路径
- 残留 launchd 单元 / 插件路径不一致

已见过的报错：

```text
launchctl bootstrap gui/502 .../apiserver.plist failed with status 5
```

建议：

- 用 `--install-root "$PWD"` 显式指定当前仓库路径
- 必要时 `system stop` 后再 `system start --disable-kernel-install`

### 8.2 `image load` 报 `XPC connection error: Connection interrupted`

通常是 `container system` 没起来或中途挂掉：

```text
Ensure container system service has been started with `container system start`.
```

先修复 `container system start`，再重试 `image load`。

### 8.3 `image load` 报 `failed to extract archive: failed to write data for ...`

常见原因：

- 空间不足
- 临时目录或本地存储状态异常

处理建议：

- 先做镜像清理（`image prune` 或删除旧本地镜像/tag）
- 删除不需要的 OCI tar（例如 `/tmp/macos-image-base-oci.tar`）
- 再重新 `package` / `image load`

### 8.4 `container run` 报 `Code=54 Connection reset by peer`

这是最常见故障之一，先判断发生在哪一层：

#### 情况 A：手工 VM + REPL 也复现 `Code=54`

优先看：

- guest-agent 是否真的监听了端口
- 是 connect callback 失败，还是 ready timeout
- 是否使用了 `--headless`（纯 headless 常见 reset）

#### 情况 B：手工 VM 正常，但 `container run` 失败

优先检查：

1. 镜像盘是否已关机并重新打包
2. `container run` 用的镜像 tag/digest 是否真是最新
3. 插件目录二进制是否已替换 + 重签
4. `container system` 是否已重启

此前真实踩坑就是：

- 手工 VM 验证的是新镜像盘
- `container run` 实际跑的是旧打包镜像或旧插件

### 8.5 `containerCreate` XPC timeout（APIServer 超时）

表现：

```text
failed to create container
XPC timeout for request to com.apple.container.apiserver/containerCreate
```

实战根因（本次确认过）：

- 有一个旧版 runtime/sidecar 进程卡死（例如 sidecar 卡在 `process.start attempt 2`）
- APIServer 请求被拖住，后续 `containerCreate` 超时

处理步骤：

1. 更新插件目录 `container-runtime-macos` 和 `container-runtime-macos-sidecar`
2. 重签 entitlement
3. `container system stop`
4. `container system start --install-root "$PWD" --disable-kernel-install`
5. 重试 `container run`

## 9. 日志采集清单（宿主 / guest）

### 9.1 宿主统一日志

```bash
"$CONTAINER_BIN" system logs --last 5m
```

常用过滤关键词：

- `container-runtime-macos`
- `RuntimeMacOSSidecar`
- `vm.connectVsock`
- `callback timed out`
- `process.start attempt`
- `containerCreate`

### 9.2 容器 helper 本地日志（stdio）

查看最新容器目录：

```bash
d=$(ls -td "$HOME/Library/Application Support/com.apple.container/containers"/* | head -n 1)
echo "$d"
tail -n 200 "$d/stdio.log"
```

这里能看到：

- sidecar 启动日志
- `process.start` 重试过程
- wait/exit 路径

### 9.3 sidecar 日志（容器 root）

sidecar 的 `stdout/stderr` 由 LaunchAgent 重定向到容器 root 内文件，通常是：

- `sidecar.stdout.log`
- `sidecar.stderr.log`

容器 root 路径同样位于：

- `~/Library/Application Support/com.apple.container/containers/<container-id>/`

### 9.4 guest 内日志

```bash
sudo launchctl print system/com.apple.container.macos.guest-agent | head -n 80
sudo tail -n 200 /var/log/container-macos-guest-agent.log
```

注意“残留日志”误判：

- 你之前遇到过 `Operation not supported by device` 是旧日志残留
- 重启后没有新错误，则应以最新时间段日志为准

## 10. 镜像打包与更新的关键注意事项

### 10.1 镜像盘改完一定先关机

如果 VM 没关机就 `package`，非常容易把旧内容打包进去（尤其是 `Disk.img` / `AuxiliaryStorage` 还没落盘）。

正确步骤：

1. 在 guest 内 `sudo shutdown -h now`
2. 确认 VM 进程退出
3. 再执行 `container macos package`

### 10.2 重新打包后确认真的是新产物

可以用这些信号交叉验证：

- `OCI tar` 修改时间
- `IMAGE_DIR/Disk.img` 修改时间
- `IMAGE_DIR/AuxiliaryStorage` 修改时间
- 必要时比较 digest（排查“看起来重打包了，实际上还是旧内容”）

## 11. 磁盘空间清理（实战常用）

当 `image load` 或打包过程异常时，先确认磁盘空间足够。

常用清理项：

- 删除旧本地镜像 tag
- 删除旧 OCI tar（例如 `/tmp/macos-image-base-oci.tar`）
- 删除 dangling 镜像（`image prune`）

建议优先删：

1. 旧 OCI tar（容易重新生成）
2. 不再使用的本地镜像 tag

## 12. 典型排障时间线（本次实战提炼）

下面是这次排障中的关键阶段，总结成可复用方法：

1. `container run` 报 guest-agent 连接失败（`Code=54`）
2. 进入手工 VM 验证 guest 内 agent：发现前台 agent/日志正常
3. 怀疑协议问题，新增 `container macos start-vm --agent-repl` 直接走 vsock
4. 发现 REPL 重连竞态/读写实现问题，改为 `Darwin.read/write`
5. 发现 guest-agent 对短命令（`ls`/`echo`）丢 `stdout/exit`，修复为先安装回调再 `process.run()`
6. 发现纯 `headless` 启动路径不稳定（`Code=54`），`headless-display` 正常
7. 在 `macos-vm-manager` 做 GUI 域 sidecar 实验（`control-socket`），验证 `probe/exec` 成功
8. 将 macOS VM 承载迁移到 `container-runtime-macos-sidecar`
9. 逐步迁移到 sidecar 高层进程协议（`process.start/stdin/signal/resize/close + stdout/stderr/exit`）
10. 清理 helper 旧实现（本地 VM / guest-agent 帧处理逻辑）
11. 再次出现 `containerCreate` 超时，最终确认是插件目录还在跑旧 sidecar + 旧容器卡死
12. 部署新插件、重签、重启 `container system` 后恢复正常

## 13. 快速回归清单（每次改代码后）

最小建议回归集：

### 13.1 非交互

```bash
"$CONTAINER_BIN" run --os darwin --rm "$LOCAL_REF" /bin/ls /
```

### 13.2 stdin 流式（注意 `-i`）

```bash
printf "hello-sidecar-stream\n" | \
  "$CONTAINER_BIN" run -i --os darwin --rm "$LOCAL_REF" /bin/cat
```

### 13.3 TTY 交互

```bash
"$CONTAINER_BIN" run --os darwin -it --rm "$LOCAL_REF" /bin/bash
```

在 shell 内执行：

```bash
echo tty-ok
pwd
exit
```

### 13.4 stdout/stderr

```bash
"$CONTAINER_BIN" run --os darwin --rm "$LOCAL_REF" /bin/sh -lc 'echo out; echo err >&2'
```

## 14. 常用命令速查（开发迭代）

### 14.1 完整重建并部署 runtime 插件

```bash
xcrun swift build -c release --product container-runtime-macos --product container-runtime-macos-sidecar

cp .build/arm64-apple-macosx/release/container-runtime-macos \
  libexec/container/plugins/container-runtime-macos/bin/container-runtime-macos
cp .build/arm64-apple-macosx/release/container-runtime-macos-sidecar \
  libexec/container/plugins/container-runtime-macos/bin/container-runtime-macos-sidecar

codesign --force --sign - \
  --entitlements signing/container-runtime-macos.entitlements \
  libexec/container/plugins/container-runtime-macos/bin/container-runtime-macos
codesign --force --sign - \
  --entitlements signing/container-runtime-macos.entitlements \
  libexec/container/plugins/container-runtime-macos/bin/container-runtime-macos-sidecar

"$CONTAINER_BIN" system stop
"$CONTAINER_BIN" system start --install-root "$PWD" --disable-kernel-install
```

### 14.2 更新镜像盘内 guest-agent（增量）

```bash
xcrun swift build -c release --product container-macos-guest-agent
CONTAINER_MACOS_GUEST_AGENT_BIN="$PWD/.build/release/container-macos-guest-agent" \
CONTAINER_MACOS_GUEST_AGENT_SCRIPTS_DIR="$PWD/scripts/macos-guest-agent" \
"$CONTAINER_BIN" macos guest-agent prepare -o "$SEED_DIR" --overwrite

# 启动手工 VM -> 在 guest 内执行
sudo mkdir -p /Volumes/seed
sudo mount -t virtiofs seed /Volumes/seed
sudo bash /Volumes/seed/install-in-guest-from-seed.sh
sudo shutdown -h now
```

### 14.3 重新打包并加载镜像

```bash
"$CONTAINER_BIN" macos package \
  --input "$IMAGE_DIR" \
  --output "$OCI_TAR" \
  --reference "$LOCAL_REF"

"$CONTAINER_BIN" image load -i "$OCI_TAR"
```

## 15. 后续可继续改进（非阻塞）

当前功能已可用，但仍有一些工程质量项可继续收敛：

- sidecar 中部分 `Virtualization` 对象跨 `DispatchQueue.main` capture 的 Swift 6 并发警告（`#SendingRisksDataRace`）
- 日志噪音控制（保留关键重试/错误，减少重复 info）
- 将更多手工调试工具能力沉淀为可复用测试脚本（例如自动 A/B `headless` vs `headless-display`）

---

如果你在后续迭代里再次看到 `Code=54` 或 `containerCreate` XPC timeout，优先回到本文档的第 4、7、8、9、13 节按顺序排查，通常能在几分钟内定位到“镜像/插件/服务/guest-agent/运行上下文”中的具体层级。
