# macOS Guest Dockerfile Build TODO

本文档按 2026-03-08 当前代码状态整理，目标是把
[`docs/macos-guest-dockerfile-build-design.md`](docs/macos-guest-dockerfile-build-design.md)
中的 Phase 1 和后续阶段拆成可执行清单，并明确哪些已经完成，哪些还没开始。

## 1. 状态总览

### 1.1 已有基础能力（构建前置，不属于本轮新增）

- [x] macOS guest runtime 已可启动和执行进程
  - `container run --os darwin`
  - sidecar + guest-agent 通路
- [x] macOS bundle 打包能力已存在
  - `container macos package`
  - v1 chunked OCI 格式
- [x] 运行前 chunk rebuild 已存在
  - `Disk.img` 可由 layout + chunks 重建
- [x] 现有 `container build` Linux 路径仍正常存在
  - 仍由 BuildKit 负责

### 1.2 本轮已经完成

- [x] 定义并落地 `fs.begin / fs.chunk / fs.end` 协议 payload
- [x] sidecar control 协议增加 `fsBegin / fsChunk / fsEnd` 方法
- [x] host 侧 `MacOSSidecarClient` 增加文件事务调用接口
- [x] sandbox XPC route 增加 `fsBegin / fsChunk / fsEnd`
- [x] guest-agent 支持 `write_file / mkdir / symlink`
- [x] `write_file` 使用临时文件 + 原子 rename 提交
- [x] 支持 `commit / abort`
- [x] 支持小文件 inline data
- [x] 支持大文件按 offset 分块写入
- [x] 支持可选 digest 校验
- [x] 补齐协议层、client 层、guest 落盘层测试
- [x] `BuildCommand` 已在 builder 拨号前完成 darwin 分流
- [x] `darwin/arm64` 平台校验与混合平台拒绝逻辑已接入
- [x] `MacOSBuildEngine` 最小主链路已接入 `container build`
- [x] 最小 Dockerfile 计划器、build context、`.dockerignore`、`COPY/ADD(local)` host 编排已落地
- [x] `RUN / WORKDIR / ENV / LABEL / CMD / ENTRYPOINT / USER` 的单 stage 执行语义已接入
- [x] 按 `--target` 顺序逐 stage 创建临时 macOS build container 并执行/清理已接通
- [x] stage stop + package/export + `type=oci|tar|local` 导出主链路已接通
- [x] `type=local` 在 darwin build 路径上已支持导出 macOS image directory
- [x] 新增 `ContainerCommandsTests` / `CLITests` 覆盖 darwin build 分流、计划器、context、`COPY` 目标语义、错误分类与 CLI 拒绝路径行为

### 1.3 还没有完成的核心目标

- [x] 真实 darwin 基础镜像上的 CLI / E2E 验收
- [x] darwin build 的集成测试矩阵补齐
- [x] `COPY` 目标已存在目录/文件等细粒度语义继续对齐 Dockerfile 行为
- [x] host 侧非法 symlink 等错误分类继续补齐
- [x] Phase 1 端到端 CLI/E2E 验收

## 2. 本轮已完成清单

### 2.1 协议定义

- [x] 新增共享文件系统协议类型
  - 文件：`Sources/Helpers/RuntimeMacOSSidecarShared/SidecarFileSystemProtocol.swift`
  - 内容：
    - `MacOSSidecarFSOperation`
    - `MacOSSidecarFSEndAction`
    - `MacOSSidecarFSBeginRequestPayload`
    - `MacOSSidecarFSChunkRequestPayload`
    - `MacOSSidecarFSEndRequestPayload`
- [x] 扩展 sidecar control request
  - 文件：`Sources/Helpers/RuntimeMacOSSidecarShared/SidecarControlProtocol.swift`
  - 新增：
    - `MacOSSidecarMethod.fsBegin`
    - `MacOSSidecarMethod.fsChunk`
    - `MacOSSidecarMethod.fsEnd`
    - request 上挂载 `fsBegin / fsChunk / fsEnd` payload

### 2.2 Host 侧调用入口

- [x] `MacOSSidecarClient` 增加文件事务接口
  - 文件：`Sources/Helpers/RuntimeMacOS/MacOSSidecarClient.swift`
  - 新增：
    - `fsBegin(port:request:)`
    - `fsChunk(request:)`
    - `fsEnd(request:)`
- [x] sandbox client 增加 XPC 包装
  - 文件：`Sources/Services/ContainerSandboxService/Client/SandboxClient+FileSystem.swift`
  - 新增：
    - `SandboxClient.fsBegin`
    - `SandboxClient.fsChunk`
    - `SandboxClient.fsEnd`
- [x] sandbox route / key 注册
  - 文件：
    - `Sources/Services/ContainerSandboxService/Client/SandboxRoutes.swift`
    - `Sources/Services/ContainerSandboxService/Client/SandboxKeys.swift`
  - 新增：
    - `fsBegin`
    - `fsChunk`
    - `fsEnd`
    - `fsPayload`
- [x] runtime helper 暴露对应 route
  - 文件：`Sources/Helpers/RuntimeMacOS/RuntimeMacOSHelper+Start.swift`

### 2.3 Sidecar 转发实现

- [x] guest-agent frame 增加文件事务消息类型
  - 文件：`Sources/Helpers/RuntimeMacOSSidecar/RuntimeMacOSSidecar.swift`
  - 新增：
    - frame type: `fsBegin / fsChunk / fsEnd / ack`
    - payload 字段映射
- [x] sidecar 增加文件事务 session 管理
  - 以 `txID` 为键维护连接
  - 区分 process stream session 与 fs transfer session
- [x] sidecar 支持：
  - `fs.begin` 时新建 vsock 连接
  - 等待 guest ready
  - 下发 begin
  - 等待 guest ack
  - `autoCommit=true` 直接收尾
  - `autoCommit=false` 保持事务连接用于后续 chunk/end
- [x] sidecar 支持：
  - `fs.chunk` 写入并等待 ack
  - `fs.end` 提交/回滚并等待 ack
  - client 断开时清理所属事务
  - `vm.stop` / `sidecar.quit` 时关闭全部 fs session

### 2.4 Guest 侧文件落盘实现

- [x] guest-agent 主循环增加文件事务处理
  - 文件：`Sources/Helpers/MacOSGuestAgent/MacOSGuestAgent.swift`
  - 新增：
    - `beginFileTransaction`
    - `appendFileTransaction`
    - `finishFileTransaction`
- [x] 抽出独立事务对象
  - 文件：`Sources/Helpers/MacOSGuestAgent/FileTransferTransaction.swift`
- [x] `write_file` 语义
  - 创建临时文件
  - 支持 inline data
  - 支持按 offset 追加 chunk
  - `commit` 时可校验 sha256 digest
  - `commit` 时原子 rename 到最终路径
  - 失败或 `abort` 时清理临时文件
- [x] `mkdir` 语义
  - 支持创建目录
  - 已存在目录时允许更新 metadata
  - 已存在非目录时按 `overwrite` 处理
- [x] `symlink` 语义
  - 支持创建符号链接
  - 已存在目标时按 `overwrite` 处理
- [x] metadata 支持
  - `mode`
  - `uid/gid`
  - `mtime`

### 2.5 测试与验证

- [x] 协议 round-trip 测试
  - 文件：`Tests/RuntimeMacOSSidecarSharedTests/SidecarControlProtocolTests.swift`
- [x] sidecar client 请求测试
  - 文件：`Tests/RuntimeMacOSSidecarClientTests/MacOSSidecarClientTests.swift`
- [x] guest 文件事务落盘测试
  - 文件：`Tests/MacOSGuestAgentTests/GuestAgentFileTransferTransactionTests.swift`
- [x] 已验证命令
  - `xcrun swift build --product container-macos-guest-agent`
  - `xcrun swift test --filter RuntimeMacOSSidecarSharedTests`
  - `xcrun swift test --filter RuntimeMacOSSidecarClientTests`
  - `xcrun swift test --filter MacOSGuestAgentTests`
  - `xcrun swift test --filter MacOSBuildEngineTests`
  - `xcrun swift test --filter CLIMacOSBuildFailureTest`
  - `CONTAINER_ENABLE_MACOS_BUILD_E2E=1 CONTAINER_MACOS_BASE_REF=local/macos-base:agent-new xcrun swift test --filter CLIMacOSBuildE2ETest`
    - 包含 `USER nobody` 正向验收场景

### 2.6 Build 主链路接线

- [x] `BuildCommand` 在 builder 拨号前对 darwin 路径完成前置分流
  - 文件：`Sources/ContainerCommands/BuildCommand.swift`
- [x] 平台校验已前置
  - `darwin` 仅允许 `arm64`
  - 拒绝混合平台和多目标平台
- [x] 新增 `MacOSBuildEngine`
  - 文件：`Sources/ContainerCommands/MacOS/MacOSBuildEngine.swift`
- [x] 新增最小 Dockerfile 计划器
  - 支持：`FROM/ARG/ENV/WORKDIR/RUN/COPY/ADD(local)/LABEL/CMD/ENTRYPOINT/USER`
  - 当前仍显式拒绝：`ADD URL`
- [x] 新增 build context + `.dockerignore` 处理
  - 支持 context 内路径白名单、排序枚举、目录/文件/软链接遍历
- [x] 新增 host 侧文件传输编排
  - `COPY/ADD(local)` 映射到 `mkdir/write_file/symlink`
  - 小文件 `inlineData + autoCommit`
  - 大文件 `begin -> chunk* -> end(commit)`
  - 默认 chunk size `256KiB`
- [x] 新增单 stage build runtime 主链路
  - 创建临时 macOS build container
  - stage 内保持 guest 常驻
  - `RUN` 通过现有 sidecar + guest-agent 执行
- [x] packager 已支持写入构建后的 image config
  - 文件：`Sources/ContainerCommands/MacOS/MacOSTemplatePackager.swift`
  - 已注入：`ENV`、`WORKDIR`、`LABEL`、`CMD`、`ENTRYPOINT`、`USER`
- [x] `type=oci|tar|local` 导出路径已接通
- [x] 新增单元测试
  - 文件：`Tests/ContainerCommandsTests/MacOSBuildEngineTests.swift`

## 3. Phase 1 剩余 TODO

### 3.1 CLI 分流和平台校验

- [x] 在 `BuildCommand` 中把 darwin 分流前置到 builder 拨号之前
- [x] 校验 `darwin` 仅允许 `arm64`
- [x] 拒绝混合平台和多目标平台
  - 示例：
    - `linux/amd64,darwin/arm64`
    - `darwin/amd64`
- [x] 保持 Linux 路径零回归
  - 说明：
    - Linux 仍保留原有 BuildKit 路径
    - 本轮已跑 `ContainerCommandsTests`；Linux build 相关 CLI/E2E 仍按既有测试矩阵验证

### 3.2 `MacOSBuildEngine` 主体

- [x] 新建 `Sources/ContainerCommands/MacOS/MacOSBuildEngine.swift`
- [x] 定义 engine 输入
  - context dir
  - Dockerfile data/path
  - build args
  - target stage
  - no-cache
  - output config
  - tags
- [x] 定义 engine 输出
  - 当前最小输出为 archive 路径
  - image load / tag 收尾仍由 `BuildCommand` 负责
- [x] 约束 engine 不依赖 Linux builder

### 3.3 Dockerfile 解析与计划

- [x] 选择 parser/front-end 复用方案
  - 当前落地为最小子集 parser
  - 后续仍可再评估复用现有 frontend
- [x] 支持首阶段允许的指令
  - `FROM`
  - `ARG`
  - `ENV`
  - `WORKDIR`
  - `RUN`
  - `COPY`
  - `ADD(local)`
  - `USER`
  - `LABEL`
  - `CMD`
  - `ENTRYPOINT`
- [x] 已补齐 `USER`
  - 计划器接受 `USER <name|uid[:gid]>`
  - `RUN` 按当前 stage 用户身份执行
  - 最终镜像 config 写入 `config.user`
- [x] 显式拒绝首阶段不支持语法
  - `ADD URL`
  - `FROM <previous-stage>`
  - 其他未覆盖高级语法
- [x] 明确变量展开规则
  - `ARG`
  - `ENV`
  - instruction 参数替换

### 3.4 Build Context 与 `.dockerignore`

- [x] 新建 `BuildContextProvider`
- [x] 读取并应用 `.dockerignore`
- [x] 约束所有 host 路径必须在 context 内
- [x] 规范化源文件枚举与排序
- [x] 处理目录、普通文件、软链接
- [x] 明确 `COPY` 目标路径语义
  - 末尾 `/`
  - 目标存在/不存在
  - 单文件到文件
  - 多源到目录
- [x] `ADD(local)` 解包策略
  - host 侧解压到 staging dir
  - 再复用同一套 fs 发送路径
- [x] 补 host 侧错误分类
  - 越界路径
  - 缺失文件
  - 非法 symlink
  - ignore 后无匹配

### 3.5 `COPY / ADD(local)` 与 fs 协议集成

- [x] 新建 host 侧传输编排器
  - 例如 `MacOSBuildFileTransport`
- [x] 目录映射为 `mkdir`
- [x] 普通文件映射为 `write_file`
- [x] 软链接映射为 `symlink`
- [x] 小文件默认 `inlineData + autoCommit`
- [x] 大文件默认 `begin -> chunk* -> end(commit)`
- [x] 明确 chunk size 默认值
  - 设计建议 `256KiB`
- [x] 失败回滚
  - begin 后异常时发送 `end(abort)`
- [x] 校验 digest 使用策略
  - 当前实现：大文件 commit 时附带 sha256
  - 小文件走 `autoCommit`，不单独发送 `fs.end`

### 3.6 stage 执行模型

- [x] 每个 stage 创建临时 macOS build container
  - 当前实现按 `--target` 之前的 stage 顺序逐个创建、执行并清理临时 container
  - 当前已支持跨 stage 文件复用的 `COPY --from`；`FROM <previous-stage>` 继续留在后续阶段
- [x] stage 生命周期内保持 guest 常驻
- [x] `FROM` 解析基础镜像
  - 限定 `darwin/arm64`
- [x] `RUN` 通过现有 sidecar + guest-agent 执行
- [x] `WORKDIR`
  - guest 内确保目录存在
  - 更新后续默认 cwd
- [x] `ENV`
  - 维护 stage environment
  - 传递给后续 `RUN`
  - 写入最终 image config
- [x] `LABEL / CMD / ENTRYPOINT`
  - 维护最终 image config
- [x] `ARG`
  - 区分解析期和执行期
- [x] `target stage`
  - 支持 `--target`

### 3.7 镜像提交与导出

- [x] 停止 stage build container
- [x] 收集 bundle 三件套
  - `Disk.img`
  - `AuxiliaryStorage`
  - `HardwareModel.bin`
- [x] 扩展 packager 以写入构建后的 image config
  - `ENV`
  - `WORKDIR`
  - `LABEL`
  - `CMD`
  - `ENTRYPOINT`
- [x] `--output type=tar`
  - 直接输出 macOS OCI tar
- [x] `--output type=oci`
  - 生成 tar
  - 复用现有 `image load`
  - 复用现有 `tag`
- [x] `--output type=local`
  - 导出 macOS image directory
  - 包含 `Disk.img`
  - 包含 `AuxiliaryStorage`
  - 包含 `HardwareModel.bin`
- [x] 明确未设置 `dest` 时的行为

### 3.8 CLI / 集成测试

- [x] 新增 darwin build CLI 测试
  - 平台校验
  - 不支持语法报错
  - `type=local` 导出目录内容
- [x] 新增 `COPY`/`ADD(local)` 端到端测试
  - 已添加 `CLITests`，需 `CONTAINER_ENABLE_MACOS_BUILD_E2E=1`
  - 默认基础镜像引用：`CONTAINER_MACOS_BASE_REF` 或 `local/macos-base:latest`
- [x] 新增 `.dockerignore` 生效测试
  - 走同一套 env-gated darwin E2E
- [x] 新增 `RUN sw_vers` 基础镜像构建测试
  - 走同一套 env-gated darwin E2E
- [x] 新增 `type=tar` 导出测试
  - 走同一套 env-gated darwin E2E
- [x] 新增 `type=oci` 导入并 tag 测试
  - 走同一套 env-gated darwin E2E
- [x] 新增失败清理测试
  - [x] 中断后临时 container
  - [x] 中断后 staging dir
  - [x] 中断后 fs transaction（guest-agent 单测）
- [x] 新增非 CLI 单元测试
  - `BuildCommand` darwin 分流
  - 最小 Dockerfile 计划器
  - build context / `.dockerignore`
  - `COPY/ADD(local)` 目标路径解析
  - 非法 symlink / 越界 source 错误分类
  - darwin build CLI 拒绝路径

## 4. 已完成但还需要收尾的点

这些不是“未做”，但离可直接接入 build 还有一层工程化收尾。

### 4.1 fs 协议层可增强项

- [x] 给 sidecar / guest-agent 文件事务加更明确日志
  - `txID`
  - path
  - op
  - commit/abort
- [x] 明确 auto-commit 路径的 digest 语义
  - host 对小文件 `inlineData + autoCommit` 也发送 sha256 digest
  - guest 在 auto-commit 路径直接校验 digest
- [x] 梳理错误码和 message 约定
  - sidecar response code 已统一回落到 `ContainerizationError` 已知类别
  - `MacOSSidecarClient` / `SandboxClient+FileSystem` 现已保留原始错误分类，同时补上 container / transaction 上下文

### 4.2 测试覆盖补强

- [x] 增加 `mkdir` metadata 测试
- [x] 增加 digest mismatch 测试
- [x] 增加 `overwrite=false` 测试
- [x] 增加 sidecar 事务异常清理测试
  - `RuntimeMacOSSidecarTests` 已覆盖 owner client disconnect 与 chunk ack 异常后的 session 清理
- [x] 增加 guest connection close 时临时文件清理测试

### 4.3 `zstd` 外部依赖收尾

- [x] 去掉 runtime/helper 对外部 `zstd` 命令和 `PATH` 的硬依赖
  - 优先把 `MacOSDiskRebuilder` 的解压路径改成 builtin / `libzstd`
  - 目标：`container run --os darwin`、运行前 chunk rebuild 不依赖宿主机 shell 环境
  - 保持对现有 `disk-chunk.v1.tar+zstd` 镜像的兼容读取
- [x] 去掉打包/构建路径对外部 `zstd` 命令的依赖
  - 把 `MacOSDiskChunker` 的压缩路径改成 builtin / `libzstd`
  - 目标：`container macos package`、darwin `container build` 不依赖宿主额外安装 `zstd`
- [x] 抽出共享 `zstd` codec/locator 层
  - 避免压缩端和解压端各自维护一套行为与错误模型
  - 明确 override / fallback / diagnostics 约定
- [x] 补齐 `zstd` 兼容性与回归测试
  - 旧格式 chunk 可被 builtin 解压
  - builtin 压缩产物可被 builtin 解压
  - 损坏 frame / 缺失依赖路径报错可读

### 4.4 已消除问题

- [x] load 镜像后第一次运行 `"$CONTAINER_BIN" run --os darwin --rm "$NEW_BASE_REF" /bin/ls /` 时无输出
  - 已改为按 sidecar 事件流顺序投递 `stdout/stderr/exit`
  - 真实新构建镜像首次 `run --os darwin` 已验证直接有输出

## 5. Phase 2 延后项

- 已提前完成：`USER`
  - 通过 sidecar exec payload + guest-agent 子进程身份切换执行
- [ ] 收敛 darwin runtime / guest-agent 启动不稳定
  - 已收敛：
    - `containerCreate` / CLI 返回链路卡住：已定位为 APIServer `ContainersService` 跨 `await` 持锁，已修
    - `macos start-vm --agent-probe` 崩溃：已定位为非主线程调用 `VZVirtioSocketDevice.connect(toPort:)`，已修
  - 当前剩余：
    - 纯 `container macos start-vm --headless --agent-probe/--agent-repl` 仍可能持续 `Code=54 Connection reset by peer`
    - 同一镜像下 `--headless-display` 可连通 guest-agent，说明主 runtime/sidecar 路径与纯 headless 调试路径需要分开看
  - 影响：会干扰把“纯 headless 调试工具不稳定”与“darwin runtime 主链路不稳定”清晰区分
  - 下一步目标：决定纯 headless 是否仅保留为复现模式，还是增加显式失败/自动 fallback 语义
- [ ] 保留 `--runtime` 的显式覆盖能力，避免客户端把 runtime 名称硬编码为平台推导值
  - 当前问题：客户端仍要求显式 `--runtime` 必须等于按平台推断出的内建 runtime
  - 目标：把平台兼容性和插件能力约束下沉到服务端或 runtime 元数据，避免阻断第三方 runtime
- [x] 修复 `MacOSSandboxService.waitForProcess(timeout:)` 的 waiter 生命周期
  - `wait` 未命中进程时已直接返回 `notFound`，不再把 waiter 挂死
  - 超时、`stop`、`shutdown`、`closeAllSessions()` 路径都会清理并唤醒 outstanding waiter
  - 已补 `MacOSSandboxServiceWaiterTests` 覆盖 missing/timeout/closeAllSessions
- [x] 在 `container-macos-guest-agent` 中忽略 `SIGPIPE`
  - 启动时已设置 `signal(SIGPIPE, SIG_IGN)`
  - 避免 host 提前断连时 guest-agent 在写回 `stdout/stderr/exit` 时被异常杀掉
- [x] 收敛 guest-agent / shared frame parser 健壮性
  - shared / guest-agent / vm-manager debugger 已统一改为非对齐安全的 frame 长度读取
  - guest-agent 已复用 shared 侧 `maxFrameSize` 上限
  - 已补 oversized frame 自动化测试
- [ ] 实现 TTY 模式 `stdin close` 语义
  - host EOF 触发 `process.close` 后，guest PTY 侧需要真正传递 EOF/关闭语义
  - 补 `-it` EOF 回归测试，避免交互命令在输入结束后继续挂起
- [ ] 继续补齐 guest-agent / 协议异常路径自动化测试
  - 当前 sidecar/shared/client 的断连、EOF、请求匹配、session 清理已有测试
  - 后续重点放在 guest-agent 坏帧、SIGPIPE、TTY close、EOF/断连路径
- [ ] `ADD URL`
  - host 下载
  - checksum / policy
- [x] 多阶段 `COPY --from`
  - 当前范围：支持从前序 stage 通过别名或索引复制文件/目录/软链接
  - 当前限制：仍不支持 `FROM <previous-stage>` 和 `COPY --from` 通配符源路径
- [ ] 阶段级缓存
- [ ] 导出链路性能优化
  - [ ] 父镜像同索引 chunk `rawDigest` 复用
  - [ ] `type=oci` 直写 content store，去掉 tar round-trip
  - [ ] 用单次 tar writer / streaming writer 替代逐 blob `/usr/bin/tar -rf`
  - [ ] `Disk.img -> tar -> zstd -> sha256/size` 改成流式单遍 I/O
  - [ ] `type=tar` 避免 staging tar 到目标路径之间的潜在跨卷二次复制
- [x] `type=local` 的正式 darwin 导出语义
- [ ] 扩展 fs metadata 操作
  - `chmod`
  - `chown`
  - `utime`
  - `rename`
  - `remove`

## 6. 推荐实施顺序

### 6.1 下一批建议直接做

- [x] `BuildCommand` darwin 分流
- [x] `MacOSBuildEngine` 框架搭建
- [x] 最小 Dockerfile 计划器
- [x] `COPY / ADD(local)` host 编排
- [x] 单 stage `FROM + COPY + RUN + commit`
- [x] 先把 runtime 侧 `zstd` 解压内建化，消除 `container run --os darwin` 对宿主 `PATH`/外部命令的依赖
- [x] 真实 darwin 基础镜像上的 CLI / E2E 构建验收
- [x] `COPY` 目标存在态语义继续对齐
- [x] host 侧非法 symlink / 错误分类补齐

### 6.2 第二批

- [x] image config 注入
- [x] `type=oci / type=tar / type=local`
- [x] `.dockerignore`
- [x] `--target`
- [x] 端到端 CLI 测试

### 6.3 第三批

- [ ] parser/front-end 完整化
- [ ] 多 stage 规划接口
- [ ] cache 基础设施预留
- [ ] Phase 2 能力拆分

## 7. Phase 1 完成标准

说明：
- 本节以“集成验收通过”为准。
- fs 协议错误码整理与 sidecar 异常清理收尾仍在继续，但不阻塞 Phase 1 主链路验收。

当以下事项全部完成时，可以认为 Phase 1 真正闭环：

- [x] `container build --platform darwin/arm64` 不经过 Linux builder
- [x] 支持 `FROM/ARG/ENV/WORKDIR/RUN/COPY/ADD(local)/LABEL/CMD/ENTRYPOINT`
- [x] `COPY/ADD(local)` 全部走 fs 协议
- [x] guest 不依赖共享目录或 `tar` 工具解包
- [x] 可以从基础 macOS 镜像构建并 commit 新镜像
- [x] `--output type=oci` 可导入本地镜像库并 tag
- [x] `--output type=tar` 可导出 tar
- [x] `--output type=local` 可导出供 `start-vm` / `macos package` 使用的 macOS image directory
- [x] 核心 E2E 测试可稳定通过
