# macOS Guest 改动综合 Review 报告（未 Push 的最近 6 个 Commit）

## 范围

- 审查范围：`origin/main..HEAD`（当前本地 `main` ahead 6）
- 审查方式：合并视角（不按 commit 逐个拆分）
- 不包含：未提交/未跟踪文件（如本地草稿文档、下载产物）

涉及 commit：

- `2250867` Refactor macOS guest runtime around sidecar control
- `1c1abaf` feat(macos): implement sidecar process.execSync
- `53d4fdb` feat(macos): add runtime sidecar for guest VM control
- `7808c7f` fix(macos): harden guest-agent runtime and diagnostics
- `8c0d80f` fix(macos): improve image prep and guest-agent workflow
- `2aba56e` feat: add macOS guest runtime workflow and tests

## 结论摘要

- 架构方向总体合理：`container-runtime-macos` helper + GUI 域 sidecar 的分层符合现有 `CLI -> API server -> runtime plugin/helper` 架构。
- 当前实现已具备基本可用性，但仍存在少量高风险问题，尤其是安装产物完整性、CLI 对外契约与实现一致性、以及 sidecar/waiter 生命周期健壮性。
- 文档层面，实操类文档整体质量较高；新增方案文档与当前实现状态存在明显偏差，需要明确标注为 RFC/方案稿。

## TODO List（按优先级）

- [x] `P0` 修复安装包未包含 `container-runtime-macos-sidecar` 的问题（已在本次修改中完成，见 `Makefile`）
- [x] `P1` 明确 `--gui` / `--snapshot` 行为：未实现前改为显式报错，或补实现并补测试
- [ ] `P1` 恢复/保留 `--runtime` 的插件扩展能力，避免客户端仅允许硬编码 runtime 名称
- [ ] `P1` 修复 `MacOSSandboxService.waitForProcess(timeout:)` 的 waiter 生命周期问题（超时/关闭路径清理 waiters）
- [ ] `P1` 在 `container-macos-guest-agent` 中忽略 `SIGPIPE`（或设置 `SO_NOSIGPIPE`）避免异常断连杀进程
- [ ] `P2` 收敛 frame parser 健壮性：长度上限、非对齐读取（shared 协议与 guest-agent 保持一致）
- [ ] `P2` 为 macOS runtime 的 sidecar Unix socket path 增加前置长度保护（容器 ID 过长场景）
- [ ] `P2` 实现 TTY 模式 `stdin close` 语义，避免 `-it` EOF 场景挂起
- [ ] `P3` 将 `apple-container-macos-guest.md` 标注为 RFC/方案稿，并区分“已实现/规划中”
- [ ] `P3` 拆分超大文件（`RuntimeMacOSSidecar.swift` / `MacOSSandboxService.swift`），抽取复用 `launchctl` helper
- [ ] `P3` 为 sidecar/client/guest-agent 协议异常路径补自动化测试（断连、超时、EOF、坏帧、TTY close）

## 详细 Findings（按严重级别）

### P0 / 阻塞

#### 1. 安装包未包含 `container-runtime-macos-sidecar`

影响：

- 通过 installer 安装的环境中，`container-runtime-macos` helper 会在启动 VM 时查找同目录 sidecar；
- 但 `Makefile` 的 staging/codesign/dSYM 流程未处理 sidecar，导致发布安装产物缺关键二进制；
- 最终会使 `container run --os darwin` 在真实安装环境中启动失败（除非手工覆盖 sidecar 路径）。

证据：

- `Package.swift:48`（sidecar 是正式 executable target）
- `Sources/Helpers/RuntimeMacOS/MacOSSandboxService+Sidecar.swift:44`（默认在 helper 同目录查找 sidecar）
- 修复前 `Makefile` 未安装/签名 sidecar（本次已修复）

处理结果：

- 已修复（本次变更）。

### P1 / 高

#### 2. `--gui` / `--snapshot` 已对外暴露，但当前实现为静默 no-op

影响：

- CLI 接受参数并写入配置，用户会认为功能已生效；
- runtime 当前仅消费 `agentPort`，未消费 `snapshotEnabled` / `guiEnabled`，形成“契约与实现不一致”。

证据：

- `Sources/Services/ContainerAPIService/Client/Flags.swift:239`
- `Sources/Services/ContainerAPIService/Client/Flags.swift:242`
- `Sources/Services/ContainerAPIService/Client/Utility.swift:314`
- `Sources/ContainerResource/Container/ContainerConfiguration.swift:143`
- `Sources/Helpers/RuntimeMacOS/MacOSSandboxService.swift:510`

建议：

- 未实现前改为显式 `unsupported` 报错；或补实现并增加回归测试。

#### 3. `--runtime` 行为退化，破坏插件扩展性

影响：

- 当前显式 `--runtime` 只允许等于客户端硬编码推断值；
- 第三方 runtime 插件 / 自定义 runtime 名称会在客户端被提前拒绝；
- 与现有插件架构方向（服务端按插件名查找）不一致。

证据：

- `Sources/Services/ContainerAPIService/Client/Utility.swift:324`
- `Sources/Services/ContainerAPIService/Client/Utility.swift:341`
- `Sources/Services/ContainerAPIService/Server/Containers/ContainersService.swift:252`

建议：

- 保留 `--runtime` 显式覆盖能力，将平台兼容性校验与插件能力约束下沉到服务端或插件元数据。

#### 4. `waitForProcess(timeout:)` 存在 waiter 生命周期问题

影响：

- 超时后取消等待 task，但 continuation waiter 没有移除；
- `closeAllSessions()` 也未统一 fail 掉 `waiters`；
- 在 stop/shutdown/异常事件丢失场景下可能造成等待方悬挂。

证据：

- `Sources/Helpers/RuntimeMacOS/MacOSSandboxService.swift:440`
- `Sources/Helpers/RuntimeMacOS/MacOSSandboxService.swift:477`
- `Sources/Helpers/RuntimeMacOS/MacOSSandboxService.swift:490`
- `Sources/Helpers/RuntimeMacOS/MacOSSandboxService.swift:495`
- `Sources/Helpers/RuntimeMacOS/MacOSSandboxService.swift:602`

建议：

- 为 waiter 引入 token，并在超时/取消时移除；
- 在 `closeAllSessions()` / shutdown 路径统一失败唤醒所有 waiter。

#### 5. guest-agent 未处理 `SIGPIPE`

影响：

- 宿主提前断开 vsock 时，guest-agent 向 socket 写回 stdout/stderr/exit 可能触发 `SIGPIPE`；
- LaunchDaemon 会重启，但在途请求会失败，日志/事件可能丢失。

证据：

- `Sources/Helpers/MacOSGuestAgent/MacOSGuestAgent.swift:31`（无 `SIGPIPE` 处理）
- `Sources/Helpers/MacOSGuestAgent/MacOSGuestAgent.swift:321`（直接 `Darwin.write` 写 socket）
- 对比 host 侧已处理：
  - `Sources/Helpers/RuntimeMacOSSidecar/RuntimeMacOSSidecar.swift:36`
  - `Sources/Helpers/RuntimeMacOS/RuntimeMacOSHelper+Start.swift:51`

建议：

- 启动时 `signal(SIGPIPE, SIG_IGN)`，并/或设置 `SO_NOSIGPIPE`。

### P2 / 中

#### 6. 协议帧解析健壮性不足（非对齐读取 + guest-agent 无长度上限）

影响：

- `Data.withUnsafeBytes(...load(as: UInt32.self))` 存在非对齐读取风险；
- guest-agent 手写 frame parser 未做长度上限，异常帧可能造成内存占用放大。

证据：

- `Sources/Helpers/RuntimeMacOSSidecarShared/SidecarControlProtocol.swift:198`
- `Sources/Helpers/MacOSGuestAgent/MacOSGuestAgent.swift:151`

建议：

- 改用非对齐安全读取（如 `loadUnaligned` 或 byte shift）；
- guest-agent 增加与 shared 协议一致的 `maxFrameSize` 校验。

#### 7. sidecar Unix socket path 可能因容器 ID 过长失败（缺少前置校验）

影响：

- 路径使用 `/tmp/ctrm-sidecar-<id>.sock`，长 ID 会触发 AF_UNIX path length 限制；
- 错误在 bootstrap 阶段才暴露，可诊断性较差。

证据：

- `Sources/Services/ContainerAPIService/Client/Utility.swift:63`
- `Sources/Helpers/RuntimeMacOS/MacOSSandboxService+Sidecar.swift:8`
- `Sources/Helpers/RuntimeMacOSSidecarShared/SidecarControlProtocol.swift:332`

建议：

- 对 macOS runtime 的容器 ID 增加长度约束，或将 socket 文件名改为 hash/截断。

#### 8. TTY 模式 `stdin close` 未实现

影响：

- helper 在 host stdin EOF 时会发送 `processClose`；
- guest-agent 对 terminal session 的 `closeStdin()` 当前是 no-op；
- 可能导致某些 `-it` 场景程序持续阻塞等待输入。

证据：

- `Sources/Helpers/RuntimeMacOS/MacOSSandboxService.swift:563`
- `Sources/Helpers/MacOSGuestAgent/MacOSGuestAgent.swift:423`

建议：

- 实现 PTY EOF 语义，并补 `-it` + EOF 回归测试。

### P3 / 低

#### 9. `apple-container-macos-guest.md` 与当前实现状态偏差较大

影响：

- 文档更像设计/RFC 方案（含 SSH 注入、端口发布、snapshot save/restore 等），但未明确标注；
- 容易被误读为当前已实现行为；
- 文中 `cite` 标记在仓库内不可解析。

证据：

- `apple-container-macos-guest.md:4`
- `apple-container-macos-guest.md:37`
- `apple-container-macos-guest.md:38`
- `apple-container-macos-guest.md:39`
- 当前限制见 `Sources/Services/ContainerAPIService/Client/Utility.swift:112`

建议：

- 标注为 RFC/方案稿，或分成“已实现”和“规划中”章节；移除无效引用标记。

#### 10. 维护性问题：文件职责过载 / 重复 helper / 未使用状态

影响：

- Sidecar、helper 相关代码集中在超大文件中，后续维护/测试成本偏高；
- 存在重复 `launchctl` 封装和重复 ready-wait 逻辑；
- 存在未使用状态字段，增加理解成本。

证据：

- `Sources/Helpers/RuntimeMacOSSidecar/RuntimeMacOSSidecar.swift`（约 1150 行）
- `Sources/Helpers/RuntimeMacOS/MacOSSandboxService.swift`（约 692 行）
- `Sources/Helpers/RuntimeMacOSSidecar/RuntimeMacOSSidecar.swift:305`
- `Sources/Helpers/RuntimeMacOSSidecar/RuntimeMacOSSidecar.swift:921`
- `Sources/ContainerCommands/Application.swift:229`
- `Sources/ContainerCommands/System/SystemStart.swift:231`
- `Sources/Helpers/RuntimeMacOS/MacOSSidecarClient.swift:21`（`lastControlError` 未读取）

建议：

- 按职责拆分 sidecar/server/process-stream 代码；
- 抽取共享 `launchctl` helper；
- 清理未使用状态或将其接入实际错误恢复逻辑。

## 测试覆盖评估

已覆盖（新增或增强）：

- OCI 镜像格式解析：`Tests/ContainerAPIClientTests/MacOSOCIFormatTests.swift`
- `ContainerConfiguration` 的 macOS 字段兼容性：`Tests/ContainerResourceTests/ContainerConfigurationMacOSTests.swift`
- `clonefile` fallback copy：`Tests/ContainerResourceTests/FilesystemCloneFallbackTests.swift`
- `ContainersService.validateCreateInput`（macOS/Linux kernel 校验）：`Tests/ContainerSandboxServiceTests/MacOSCreateValidationTests.swift`
- runtime 推断冲突基础校验：`Tests/ContainerAPIClientTests/UtilityTests.swift`

主要缺口：

- `MacOSSidecarClient` / `RuntimeMacOSSidecar` / `MacOSGuestAgent` 的协议异常路径和并发路径缺自动化测试
- `TTY close` / EOF / 断连恢复 / 坏帧 / 超时场景缺覆盖

## 文档一致性评估

- `docs/macos-guest-image-prepare.md` 与 `docs/macos-guest-development-debugging.md` 基本与当前实现一致，可作为实操文档继续维护。
- `apple-container-macos-guest.md` 需要明确定位（RFC vs 现状），避免误导。
