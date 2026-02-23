# macOS Guest 运行时技术方案（当前实现）

本文档面向需要维护或扩展 macOS guest 功能的开发者，说明当前实现的架构、关键数据流、控制协议、并发模型与已知约束。

本文档关注“技术方案细节”，不覆盖模板制作与日常排障操作步骤。操作流程请参考：

- `docs/macos-guest-agent-package-push.md`
- `docs/macos-guest-development-debugging.md`

## 1. 目标与背景

### 1.1 目标

在 `container run --os darwin` 场景下，为 macOS guest 提供稳定的：

- VM 启动与停止
- guest 内进程执行（TTY / 非 TTY）
- stdio 流转发
- signal / resize / close
- `dial`（通过 vsock 获取 guest 连接）

### 1.2 背景问题（为何需要 sidecar）

早期实现中，`container-runtime-macos` helper 进程直接承载 `VZVirtualMachine` 并在 helper 内连接 guest-agent（vsock）。在实际运行环境中（XPC helper / 后台 launch 上下文）出现了稳定性问题：

- `VZVirtioSocketDevice.connect(toPort:)` callback 在某些场景下失败或不稳定
- 常见报错：`NSPOSIXErrorDomain Code=54 "Connection reset by peer"`
- “纯 headless”启动路径对 macOS guest-agent 可用性影响明显

经过多轮实验，最终采用：

- **GUI 域 LaunchAgent sidecar 承载 VM**
- **无窗口但保留显示设备（headless-display）**
- `container-runtime-macos` helper 只保留 XPC 与容器会话管理职责

## 2. 实现概览（当前架构）

### 2.1 组件划分

当前实现由 3 层组成：

1. `container-runtime-macos`（helper / XPC SandboxService 实现）
2. `container-runtime-macos-sidecar`（GUI 域 LaunchAgent，承载 `VZVirtualMachine`）
3. `container-macos-guest-agent`（运行在 guest 内的 LaunchDaemon）

### 2.2 关键代码位置

- helper 路由与会话管理：`Sources/Helpers/RuntimeMacOS/MacOSSandboxService.swift`
- helper sidecar 启停与 LaunchAgent 管理：`Sources/Helpers/RuntimeMacOS/MacOSSandboxService+Sidecar.swift`
- helper sidecar 控制客户端：`Sources/Helpers/RuntimeMacOS/MacOSSidecarClient.swift`
- sidecar 进程主程序、控制服务器、VM 与 guest-agent 适配：`Sources/Helpers/RuntimeMacOSSidecar/RuntimeMacOSSidecar.swift`
- helper/sidecar 共享控制协议与 socket IO：`Sources/Helpers/RuntimeMacOSSidecarShared/SidecarControlProtocol.swift`
- SwiftPM target 定义：`Package.swift`

### 2.3 设计原则

- helper 对上层 XPC API 行为尽量保持不变（`SandboxService` 路由不变）
- sidecar 对 helper 暴露“高层进程控制协议”，而不是 guest-agent 协议细节
- `dial` 保持兼容（`FileHandle` 返回），通过 `SCM_RIGHTS` 传递 fd
- sidecar 使用 GUI 域 + `NSApplication` run loop，但不展示本地窗口

## 3. 为什么是 GUI Sidecar + Headless Display

### 3.1 关键经验结论

实测表明：

- 纯 `headless`（无显示设备）在某些模板上会导致 guest-agent vsock 连接异常（reset）
- “无窗口但保留显示设备”显著改善稳定性
- helper/XPC 上下文内直接承载 VM 即使保留显示设备，也可能与 `manual-template-vm` 表现不同

因此当前方案固定为：

- sidecar 在 GUI 域 (`gui/<uid>`) 启动
- `NSApplication.shared` + `.prohibited`（无窗口）
- VM 配置包含 `graphicsDevices`

### 3.2 运行模式对比

- `container-runtime-macos-sidecar`：默认使用 headless-display（无窗口、有显示设备）
- `manual-template-vm --headless-display`：用于复现实验和对照验证
- `manual-template-vm --headless`：保留为问题复现工具，不作为推荐路径

## 4. Build / Packaging 集成点

### 4.1 SwiftPM targets

当前新增/涉及的目标：

- `container-runtime-macos-sidecar`（executable）
- `RuntimeMacOSSidecarShared`（shared internal target）

目标定义见 `Package.swift`。

### 4.2 部署路径

运行时实际加载的插件二进制在：

- `libexec/container/plugins/container-runtime-macos/bin/container-runtime-macos`
- `libexec/container/plugins/container-runtime-macos/bin/container-runtime-macos-sidecar`

注意：仅更新 `.build/...` 不会生效，必须复制到插件目录并重签，然后重启 `container system`。

## 5. Helper（`MacOSSandboxService`）职责与状态模型

### 5.1 对外接口（XPC 路由）

`MacOSSandboxService` 继续实现 `SandboxService` 路由，主要包括：

- `bootstrap`
- `createProcess`
- `startProcess`
- `wait`
- `kill`
- `resize`
- `stop`
- `shutdown`
- `state`
- `dial`
- `statistics`

路由实现见 `Sources/Helpers/RuntimeMacOS/MacOSSandboxService.swift`。

### 5.2 Helper 内部状态

`MacOSSandboxService` actor 使用 `State` 管理容器生命周期：

- `created`
- `booted`
- `running`
- `stopping`
- `stopped(Int32)`
- `shuttingDown`

这与 sidecar 的 VM 状态不同（sidecar 只关心 VM 生命周期），helper 还负责容器会话和 XPC 路由语义。

### 5.3 Session 模型（进程级）

helper 内部 `Session` 结构保存每个 process 的宿主视图状态：

- `processID`
- `ProcessConfiguration`
- `stdio`（宿主端 `FileHandle?` 三元组）
- `stdinClosed`（避免重复发送 `process.close`）
- `started`
- `exitStatus`
- `lastAgentError`

helper 不再直接持有 guest-agent vsock fd、read loop 或 guest-agent frame buffer。

### 5.4 `wait` / `completeProcess` 一致性策略

helper 使用：

- `sessions: [String: Session]`
- `waiters: [String: [CheckedContinuation<ExitStatus, Never>]]`

并在 sidecar `process.exit` 事件到达后：

1. 更新 `session.exitStatus`
2. 关闭该 session 的 stdio handle
3. 唤醒所有 `waiters`

这避免了短命令（如 `ls`/`echo`）的竞态问题。

## 6. Sidecar 启动与 LaunchAgent 生命周期

### 6.1 Sidecar 启动域

helper 侧显式选择 GUI 域：

- `gui/\(getuid())`

而不是依赖当前 launchd 上下文自动推断。

### 6.2 LaunchAgent 元数据

helper 会在容器 root 下生成 sidecar plist（示例字段）：

- `Label`: `com.apple.container.runtime.container-runtime-macos-sidecar.<sandbox-id>`
- `ProgramArguments`: sidecar 路径 + `--uuid` + `--root` + `--control-socket`
- `LimitLoadToSessionType = Aqua`
- `ProcessType = Interactive`
- `StandardOutPath`, `StandardErrorPath`

相关实现：

- `writeSidecarLaunchAgentPlist(...)` in `MacOSSandboxService+Sidecar.swift`

### 6.3 Socket 路径与日志路径

当前实现使用：

- 控制 socket：`/tmp/ctrm-sidecar-<sandbox-id>.sock`
- sidecar stdout/stderr：写入容器 root 下的日志文件

### 6.4 启动时序（helper -> sidecar）

`bootstrap` 路径（高层顺序）：

1. helper 准备容器 bundle（模板文件 clone/copy + config）
2. helper 打开容器 `stdio.log` / `vminitd.log`
3. helper 生成 sidecar LaunchAgent plist
4. helper `bootout` 旧 unit（best effort）并删除旧 socket
5. helper `launchctl bootstrap gui/<uid> ...`
6. helper 创建 `MacOSSidecarClient`
7. helper 建立控制连接并发送 `vm.bootstrapStart`
8. sidecar 启动 VM 成功后返回 `ok`
9. helper 将容器状态置为 `booted`

### 6.5 停止时序（helper -> sidecar）

`stop` / `shutdown` 路径会执行：

1. （如 init 进程还在运行）发送 signal 并等待退出
2. `stopAndQuitSidecarIfPresent()`
   - `vm.stop`
   - `sidecar.quit`
   - `launchctl bootout gui/<uid>/<label>`
   - 关闭 helper 侧控制连接
3. helper 关闭所有 `Session` 的 stdio 并清空 session map

## 7. Sidecar 控制协议（helper <-> sidecar）

共享协议定义在：

- `Sources/Helpers/RuntimeMacOSSidecarShared/SidecarControlProtocol.swift`

### 7.1 传输层

- Unix domain stream socket
- 帧格式：`uint32(big-endian length)` + `JSON payload`
- 控制连接使用单持久连接（helper `MacOSSidecarClient`）
- `vm.connectVsock` 使用单独短连接，并通过 `SCM_RIGHTS` 回传 fd

### 7.2 Envelope 模型

所有 JSON payload 包装在 `MacOSSidecarEnvelope` 中：

- `kind = request`
- `kind = response`
- `kind = event`

### 7.3 Request 模型

`MacOSSidecarRequest` 关键字段：

- `requestID`
- `method`
- `port`
- `processID`
- `exec`
- `data`
- `signal`
- `width` / `height`

当前协议是“稀疏字段”模型（不同 method 使用不同字段组合）。

### 7.4 Response 模型

`MacOSSidecarResponse`：

- `requestID`
- `ok`
- `fdAttached`
- `error { code, message, details }`

注意：

- 当前不再使用 `vm.state`，响应里也不再携带 `state` 字段

### 7.5 Event 模型

`MacOSSidecarEventType` 当前支持：

- `process.stdout`
- `process.stderr`
- `process.exit`
- `process.error`

事件负载由 `MacOSSidecarEvent` 承载：

- `processID`
- `data`（stdout/stderr）
- `exitCode`
- `message`

### 7.6 当前支持的方法（helper 可用）

- `vm.bootstrapStart`
- `vm.connectVsock`
- `process.start`
- `process.stdin`
- `process.signal`
- `process.resize`
- `process.close`
- `vm.stop`
- `sidecar.quit`

## 8. `SCM_RIGHTS` fd 传递（`dial` 与 `vm.connectVsock`）

### 8.1 目标

保持 helper 上层 `dial` 行为不变（仍返回 `FileHandle`），同时让实际的 VM vsock connect 发生在 sidecar 内。

### 8.2 实现方式

在共享 `MacOSSidecarSocketIO` 中实现：

- `sendFileDescriptorMarker(...)`
- `sendNoFileDescriptorMarker(...)`
- `receiveOptionalFileDescriptorMarker(...)`

协议约定：

1. sidecar 在控制 socket 上先发送 1-byte marker（有/无 fd）
2. 若有 fd，则使用 `SCM_RIGHTS` 附带文件描述符
3. 然后发送 `response` envelope（JSON）

helper `MacOSSidecarClient.connectVsock(port:)` 流程：

1. 建立一条临时控制 socket 连接
2. 发 `vm.connectVsock` request
3. 先收 fd marker + optional fd
4. 再收 `response`
5. 校验 `requestID`、`ok`
6. 返回 fd 给 helper，包装成 `FileHandle`

### 8.3 为什么 `vm.connectVsock` 不复用持久控制连接

因为 `SCM_RIGHTS` + 响应配对更适合“一次请求一条连接”的简单语义，避免在持久连接上与事件流串扰。

## 9. Sidecar 进程内部结构

`container-runtime-macos-sidecar` 主要由两层组成：

1. `MacOSSidecarService`（actor，管理 VM 生命周期）
2. `SidecarControlServer`（多线程 Unix socket server，处理控制协议与进程流）

### 9.1 入口与运行环境

入口在 `RuntimeMacOSSidecar.swift`：

- `@MainActor @main struct RuntimeMacOSSidecar`
- 使用 `ArgumentParser` 解析 `--uuid`, `--root`, `--control-socket`
- 调用 `NSApplication.shared`
- `activationPolicy = .prohibited`
- 在主线程启动 control server
- 进入 `NSApplication` run loop

sidecar 会记录 host context 信息（screens、session、launch label 等），便于定位 GUI 域运行问题。

### 9.2 `MacOSSidecarService`（VM actor）

职责：

- 加载 `config.json`
- 构建 `VZVirtualMachineConfiguration`
- 在主线程创建/启动/停止 `VZVirtualMachine`
- 执行 `connectVsock(port:)`

状态：

- `created`
- `running`
- `stopped`

### 9.3 VM 配置（当前实现）

sidecar 使用容器 root 中的模板文件：

- `Disk.img`
- `AuxiliaryStorage`
- `HardwareModel.bin`
- `MachineIdentifier.bin`（不存在则创建）

配置包含：

- `VZMacOSBootLoader`
- `VZMacPlatformConfiguration`
- `VZVirtioBlockDeviceConfiguration`
- `VZNATNetworkDeviceAttachment`
- `VZVirtioSocketDeviceConfiguration`
- `VZMacGraphicsDeviceConfiguration`（始终配置）

关键点：

- **始终配置 `graphicsDevices`**（headless-display）
- `createGraphicsDevice()` 会优先使用 `NSScreen.main`/`NSScreen.screens.first`
- 无 screen 时使用固定像素 fallback 配置

### 9.4 `connectVsock` 超时兜底

sidecar `connectVsock(port:)` 内部调用：

- `connectSocketOnMainWithTimeout(... timeoutSeconds: 3)`

原因：

- `VZVirtioSocketDevice.connect(toPort:)` callback 在某些异常场景可能不返回
- 若不加兜底，会导致 helper `process.start` 某次重试永久挂起，进而拖住 `containerCreate`

实现方式：

- `CompletionGate` 保证 callback / timeout 只完成一次 continuation
- timeout 后返回 `ContainerizationError(.timeout, ...)`
- 若超时后 callback 迟到，成功连接会被立即关闭（防止 fd 泄漏）

## 10. SidecarControlServer：控制协议与进程流桥接

### 10.1 为什么不用 actor 直接处理所有 socket IO

当前采用混合模型：

- VM 生命周期：actor（`MacOSSidecarService`）
- 控制 socket / 进程流 socket：线程 + 锁

原因：

- 控制协议包含同步 request/response 语义与 fd 传递（`SCM_RIGHTS`）
- guest-agent 进程流需要独立阻塞读取
- 与现有 helper 同步等待模型兼容更直接

### 10.2 Control Server 基本结构

`SidecarControlServer` 维护：

- `listenFD`
- `eventClientFD`（当前事件接收端）
- `processSessions: [processID: ProcessStreamSession]`
- 若干锁（listen/event/process/write）

### 10.3 `eventClientFD` 语义（重要）

当前实现是“单事件接收端”模型：

- 非 `vm.connectVsock` request 到来时，当前 `clientFD` 被设置为 `eventClientFD`
- `process.stdout/stderr/exit/error` 事件统一发给 `eventClientFD`

这在当前 helper 实现中是成立的，因为 helper 使用一条持久控制连接作为主要 request+event 通道。

### 10.4 `process.start` 到 guest-agent 的桥接流程

sidecar `process.start` 处理流程：

1. 通过 `MacOSSidecarService.connectVsock(port:)` 获取 guest-agent vsock fd
2. 等待 guest-agent `ready` frame（3s timeout）
3. 发送 `exec` frame（内部 `SidecarGuestAgentFrame.exec`）
4. 注册 `ProcessStreamSession`
5. 启动独立读线程 `processReadLoop`

若任一步骤失败：

- 关闭 fd
- 返回 sidecar error response 给 helper

### 10.5 进程流事件发射

`processReadLoop` 从 guest-agent fd 持续读取内部 frame（`SidecarGuestAgentFrame`）：

- `stdout` -> 发 `process.stdout` event
- `stderr` -> 发 `process.stderr` event
- `error` -> 发 `process.error` event
- `exit` -> 发 `process.exit` event 并结束 loop

如果出现非预期 EOF 或读错误：

- 发 `process.error`（部分场景）
- `defer` 中若还未发送 exit，则合成 `process.exit(code=1)`

这保证 helper `wait` 不会无限挂起。

### 10.6 进程控制命令桥接

`process.stdin` / `process.signal` / `process.resize` / `process.close` 通过：

- 查找 `processSessions[processID]`
- 对 session fd 加 `writeLock`
- 写入对应内部 `SidecarGuestAgentFrame`

## 11. Helper <-> Sidecar 时序（关键路径）

### 11.1 `container run --os darwin ...` 高层时序（简化）

1. APIServer 调用 runtime helper `bootstrap`
2. helper 准备容器 root 与模板文件
3. helper 启动 sidecar LaunchAgent
4. helper `vm.bootstrapStart`
5. APIServer 调用 `createProcess`（init process）
6. APIServer 调用 `startProcess`
7. helper 调 sidecar `process.start`（带重试）
8. sidecar 连接 guest-agent、等待 ready、发送 exec
9. sidecar 发 `process.stdout/stderr/exit` 事件
10. helper 写入宿主 stdio，并在 `process.exit` 时唤醒 `wait`

### 11.2 `dial` 路径时序（简化）

1. APIServer 调 helper `dial`
2. helper 调 sidecar `vm.connectVsock`
3. sidecar 在 VM 内 connect 指定 vsock port
4. sidecar 用 `SCM_RIGHTS` 将 fd 回传 helper
5. helper 将 fd 包装为 `FileHandle` 返回上层

## 12. 重试、超时与错误传播策略

### 12.1 helper `process.start` 重试策略

helper 在 `startProcessViaSidecarWithRetries(...)` 中对 sidecar `process.start` 进行重试：

- 最大次数：240
- 间隔：500ms
- 总等待约：120s

这主要用于 guest 刚启动阶段，guest-agent 还未 ready 时的过渡窗口。

### 12.2 sidecar 单次连接超时策略

sidecar 单次 `connectVsock` 与 guest-agent ready 等待有独立超时：

- `vsock connect callback` timeout：3s
- `guest-agent ready frame` timeout：3s

这样即使某次 callback 卡死，也能快速失败并让 helper 继续下一轮重试。

### 12.3 错误传播链路

错误通常按以下路径传播：

sidecar 内部错误 -> sidecar `response.error` -> helper `MacOSSidecarClient.validate(...)` -> `ContainerizationError(.internalError, ...)` -> XPC reply -> CLI

helper 在 `startProcess` 场景会进一步包装错误消息，增加：

- guest-agent vsock 端口
- guest 日志路径提示（`/var/log/container-macos-guest-agent.log`）

## 13. 并发模型与同步策略

### 13.1 Helper（actor 主导）

`MacOSSandboxService` 是 `actor`：

- `sessions` / `waiters` / `sandboxState` 由 actor 隔离保护
- 宿主 stdin 的 `readabilityHandler` 回调中通过 `Task { await service.forwardHostStdin(...) }` 回到 actor 上下文

### 13.2 Sidecar Client（线程 + 锁）

`MacOSSidecarClient` 使用：

- 一条 reader thread 持续读取 envelope
- `stateLock` 保护 `controlFD` / `pending` / `eventHandler`
- `writeLock` 串行化控制连接写入
- `PendingResponse` + `DispatchSemaphore` 做同步 request/response 等待

### 13.3 Sidecar Control Server（线程 + 锁）+ VM actor

`SidecarControlServer`：

- `acceptLoop` 线程
- 每个 client 一个 handler thread
- 每个 process stream 一个 read thread
- VM 操作通过 `sync` / `syncValue` 桥接到 `MacOSSidecarService` actor

这种结构的优点：

- guest-agent fd 流处理简单直接
- 与 `SCM_RIGHTS`、同步控制请求兼容

代价：

- 锁较多，需要注意 `eventClientFD` 和 `processSessions` 的一致性

## 14. 兼容性与约束（当前实现）

### 14.1 当前实现假设

- 单容器对应一个 sidecar 进程
- helper 使用一条主要持久控制连接处理 request/response + event
- `eventClientFD` 是单一事件订阅者（不是多播）

### 14.2 未覆盖/已知限制

- sidecar 内部仍有一些 Swift 6 并发告警（`Virtualization` 对象捕获到主线程 closure 的 `#SendingRisksDataRace`）
- 协议是内部协议，未做版本协商
- `eventClientFD` 模型不适合未来多客户端并发观察 sidecar 事件
- sidecar 当前以线程模型实现控制 server，尚未统一到 actor-only 架构

### 14.3 非目标（当前版本）

- 不对外暴露 sidecar 控制协议
- 不支持多个 helper 共享一个 sidecar
- 不提供“纯 headless”稳定保证

## 15. 关键故障场景与技术定位建议

### 15.1 `containerCreate` XPC timeout

常见根因：

- 旧 sidecar 卡在某次 `process.start`（例如单次 `connect` callback 不返回）
- helper/APIServer 请求被阻塞

技术定位：

- 看容器 `stdio.log` 是否停在 `sidecar process.start attempt N/...`
- 看 sidecar 日志是否出现 `control request received [method=process.start]` 但无完成日志

### 15.2 `Code=54 reset by peer`

先区分发生层级：

- sidecar `vm.connectVsock` callback 失败
- sidecar 已 connect 成功但 `ready` timeout
- helper 与 sidecar 的控制连接失败（不是 guest-agent 问题）

建议结合以下日志：

- helper `stdio.log`
- sidecar `stdout/stderr` 日志
- guest `/var/log/container-macos-guest-agent.log`

## 16. 扩展指南（给后续开发者）

### 16.1 增加一个新的 sidecar 控制方法（示例思路）

假设要增加 `process.killGroup`：

1. 在 `RuntimeMacOSSidecarShared/SidecarControlProtocol.swift` 中新增 `MacOSSidecarMethod`
2. 如需新字段，扩展 `MacOSSidecarRequest` / `MacOSSidecarEvent`
3. 在 `MacOSSidecarClient.swift` 增加 helper 封装方法
4. 在 `RuntimeMacOSSidecar.swift` 的 `perform(request:clientFD:)` 增加分支
5. 在 helper `MacOSSandboxService.swift` 路由或内部方法接入
6. 更新日志与错误文案
7. 回归验证（非 TTY、TTY、失败路径）

### 16.2 修改 guest-agent 协议时的边界

当前 sidecar 内部使用 `SidecarGuestAgentFrame` 适配 guest-agent 协议（内部桥接层）：

- helper 不应直接依赖 guest-agent frame 细节
- guest-agent 协议变化优先在 sidecar 层吸收

这样可以保持 helper 的复杂度稳定。

## 17. 推荐阅读顺序（新接手开发者）

建议按以下顺序阅读源码：

1. `Sources/Helpers/RuntimeMacOS/MacOSSandboxService.swift`
   - 看 XPC 路由与 helper session 语义
2. `Sources/Helpers/RuntimeMacOS/MacOSSandboxService+Sidecar.swift`
   - 看 LaunchAgent 生命周期与重试策略
3. `Sources/Helpers/RuntimeMacOS/MacOSSidecarClient.swift`
   - 看控制协议客户端实现（持久连接 + 事件）
4. `Sources/Helpers/RuntimeMacOSSidecarShared/SidecarControlProtocol.swift`
   - 看协议结构与 socket/fd 传递封装
5. `Sources/Helpers/RuntimeMacOSSidecar/RuntimeMacOSSidecar.swift`
   - 看 sidecar VM 生命周期与 guest-agent 桥接

再配合：

- `docs/macos-guest-development-debugging.md`（排障方法）
- `docs/macos-guest-agent-package-push.md`（模板制作/打包链路）

## 18. 总结

当前 macOS guest 方案的核心思想是：

- **helper 保留对外接口与容器会话语义**
- **sidecar 在 GUI 域内承载 VM 并桥接 guest-agent**
- **通过内部高层协议（JSON + Unix socket + fd 传递）解耦 VM 运行环境差异**

这套方案已经在以下路径上验证可用：

- 非交互执行（如 `/bin/ls /`）
- stdin 流式（`-i ... /bin/cat`）
- TTY 交互（`-it /bin/bash`）
- stdout/stderr 事件转发
- `dial` fd 传递

后续优化重点应放在：

- sidecar 并发告警清理
- 协议演进与版本化策略（如未来需要）
- 更系统化的自动化测试与故障注入
