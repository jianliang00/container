# macOS Guest Dockerfile 镜像构建方案设计（基于现有 container 项目）

本文档给出一套可落地的设计：让当前项目在已有 macOS guest 运行时与 chunked OCI 镜像能力基础上，支持“像 Linux 镜像一样”使用 Dockerfile 进行增量构建，输入基础镜像，输出新镜像。

目标场景包括：

- 基于已有 `darwin/arm64` 基础镜像继续构建
- 安装 Xcode、Homebrew 等工具
- 创建用户、切换用户执行后续步骤
- 通过标准镜像流转（`load/push/pull/run`）复用

## 1. 背景与现状

当前代码能力（与本设计直接相关）：

- `container build` 现有实现以 BuildKit 为核心，定位 Linux 构建路径。
- macOS guest 已具备：
  - `container run --os darwin` 启动与进程执行
  - sidecar + guest-agent 协议
  - `container macos package` 将 `Disk.img/AuxiliaryStorage/HardwareModel.bin` 打包成 OCI
  - `disk-layout.v1 + disk-chunk.v1.tar+zstd` 分块格式
  - runtime 启动前的 chunk 重建

现状差距：

- 缺少基于 Dockerfile 的 macOS 镜像构建执行器
- 缺少“从运行后磁盘提交镜像（commit）”的一体化流程
- 缺少面向 `COPY/ADD` 的正式文件注入协议与对应 guest 侧执行器

## 2. 目标与非目标

### 2.1 目标

1. 在 `container build` 内支持 `--platform darwin/arm64`。
2. 使用 Dockerfile 作为统一输入，不引入新的专用 DSL。
3. 基于 `FROM` 引用已有 macOS OCI 镜像，执行指令并提交新镜像。
4. 首阶段优先支持以下指令子集：
   - `FROM`, `ARG`, `ENV`, `WORKDIR`, `RUN`, `COPY`, `ADD(local)`, `USER`, `LABEL`, `CMD`, `ENTRYPOINT`
5. 第二阶段补齐高复杂度指令与语义：
   - `ADD(URL)`, 多阶段 `COPY --from`
6. 支持 `COPY/ADD` 本地输入注入，统一通过 `fs` 协议实现，避免依赖共享目录或 guest 内工具链。
7. 长期支持增量复用：
   - 阶段级缓存（stage cache）
   - 后续演进到指令级缓存（instruction cache）
   - chunk blob 级复用（基于 `rawDigest`）

### 2.2 非目标（首阶段）

1. 不在首版支持完整 BuildKit 特性（如 `RUN --mount=type=secret`、inline cache 全语义）。
2. 不在首版支持跨平台多架构合并构建（只支持 `darwin/arm64`）。
3. 不改动现有 Linux BuildKit 路径语义。
4. 不在首版支持 `ADD URL`、多阶段 `COPY --from`。
5. 不在首版承诺细粒度 build cache；首版以“先完成构建闭环”为目标。
6. 不把首版目标定义为 headless CI；当前运行前提仍以登录态开发机为主。
7. 不采用共享目录 / `virtiofs` 作为 `COPY/ADD` 的构建输入方案。

## 3. 总体架构

### 3.1 构建入口策略

保留单一入口：`container build`。

- 在 `BuildCommand` 完成 `--platform/--os/--arch` 解析后立即分流，且分流必须发生在“拨号或启动 BuildKit builder”之前。
- `linux/*`：继续走现有 BuildKit 流程。
- 单一目标 `darwin/arm64`：进入新 `MacOSBuildEngine`。
- 混合平台或多目标平台（例如同时构建 `linux/amd64,darwin/arm64`）：首阶段显式报错，不做隐式拆分。

这样避免用户记忆新命令，同时不影响现有 Linux 生态。

### 3.2 Dockerfile 解析策略

首阶段不建议手写一套完整 Dockerfile parser/front-end。

1. 优先复用现有 Dockerfile parser/front-end 或与其兼容的 AST/expansion 结果，避免重新实现完整语法、变量展开与转义细节。
2. 首阶段只保证支持下文矩阵中的指令及常见 shell/exec form；其他语法在解析或计划阶段直接返回 `unsupported`。
3. 若复用路径暂不可得，才退化为“最小子集 parser”，但该实现只服务首阶段，不视为长期方案。

### 3.3 新增核心组件

1. `MacOSBuildEngine`
   - 负责 Dockerfile 解析、stage 执行、最终提交。
2. `MacOSDockerfileExecutor`
   - 将 Dockerfile 指令映射为对临时 build container 的操作。
3. `MacOSImageCommitter`
   - 从 build container 的磁盘产物生成 OCI（复用现有 packager/chunker）。
4. `MacOSBuildCache`
   - 第二阶段开始管理阶段级缓存与 chunk 复用索引。
5. `BuildContextProvider`
   - 将 context（`.dockerignore` 过滤后）规范化为可传输输入集合。
6. `MacOSBuildFileTransport`
   - 负责 host -> sidecar -> guest-agent 的文件协议传输（`fs.begin/fs.chunk/fs.end`）。

### 3.4 执行时对象关系

1. 每个 Dockerfile stage 对应一个临时 macOS build container（运行时 `container-runtime-macos`）。
2. stage 生命周期内保持 VM 常驻，避免每条 `RUN` 冷启动。
3. 首阶段仅保证“stage 结束时 commit 一次”，作为阶段产物输出；细粒度指令 checkpoint 不在首版范围内。
4. 第二阶段在 stage 产物基础上支持多阶段 `FROM`/`COPY --from` 复用。

## 4. 指令语义与支持矩阵

| 指令 | 首阶段支持 | 处理方式 |
|---|---|---|
| `FROM` | 是 | 拉取/解析 `darwin/arm64` 基础镜像，创建 stage 根磁盘 |
| `ARG` | 是 | 解析期和执行期变量表 |
| `ENV` | 是 | 更新 stage 环境，影响后续 `RUN` 与镜像 config |
| `WORKDIR` | 是 | 在 guest 内确保目录存在，更新 stage 默认 cwd |
| `RUN` | 是 | 通过 sidecar + guest-agent 执行，记录退出码与日志 |
| `COPY` | 是 | 通过 `fs` 协议直传并按目标路径语义落盘 |
| `ADD`(本地) | 是 | host 解包后通过 `fs` 协议直传 |
| `ADD`(URL) | 第二阶段 | 宿主下载到临时目录后再注入，保证可审计 |
| `USER` | 是 | 更新 stage 默认用户，后续 `RUN` 与目标镜像 config 继承该身份 |
| `LABEL` | 是 | 写入目标镜像 config |
| `CMD`/`ENTRYPOINT` | 是 | 写入目标镜像 config |
| 多阶段 `COPY --from` | 第二阶段 | 先留接口，后补 |

## 5. `COPY/ADD` 输入注入方案（仅保留 `fs` 协议）

结论：`COPY/ADD` 统一采用 host ↔ sidecar ↔ guest-agent 的 `fs` 协议，不再把共享目录或 guest 内 `tar` 解包保留为正式方案。

### 5.1 设计决策

1. 共享目录 / `virtiofs` 不纳入本设计：其可用性依赖 guest 侧授权与交互式访问条件，不适合作为非交互 build 主链路。
2. guest 内 `tar` 解包不纳入本设计：它依赖 guest 镜像内工具链，且难以作为长期稳定语义。
3. 因此，`COPY/ADD(local)` 的唯一正式路径为协议化文件写入。

### 5.2 设计原则

1. 所有路径解析、白名单和越界校验在 host 侧完成，guest 仅执行受控文件操作。
2. 协议默认流式传输，支持大文件、可重试和背压控制。
3. 小文件可 inline，一次请求完成，减少协议往返成本。
4. 写入采用“临时文件 + 原子 rename”提交，避免中断留下半成品。
5. 首阶段只实现 `COPY/ADD(local)` 必需的基础操作，不预先扩展成通用文件系统 RPC。

### 5.3 协议模型（3 个基础操作）

1. `fs.begin`
   - 入参：`txId`, `op`, `path`, `mode`, `uid/gid`（可选）, `mtime`（可选）, `linkTarget`（可选）, `overwrite`, `inlineData`（可选）, `autoCommit`（可选，默认 `false`）等。
   - 作用：声明一次文件系统事务（例如 `write_file`, `mkdir`, `symlink`）；当 `autoCommit=true` 且无需后续分块时，可在一次请求内完成提交。
2. `fs.chunk`
   - 入参：`txId`, `offset`, `data`（二进制块）。
   - 作用：仅在需要数据流时发送（通常用于 `write_file` 且 `autoCommit=false`）。
3. `fs.end`
   - 入参：`txId`, `commit|abort`, `digest`（可选）。
   - 作用：提交或回滚事务；提交时可做完整性校验与原子落盘。`autoCommit=true` 的事务可省略 `fs.end`。

首阶段基础操作类型：`write_file`, `mkdir`, `symlink`。

后续按需要扩展：`chmod`, `chown`, `utime`, `rename`, `remove`。

### 5.4 传输策略

1. metadata-only 操作（首阶段为 `mkdir/symlink`）默认使用 `fs.begin(autoCommit=true)` 一次请求完成。
2. 小文件（例如 `<=256KiB`）可由 `fs.begin` 的 `inlineData` 携带；建议配合 `autoCommit=true`，跳过 `fs.chunk/fs.end`。
3. 大文件走 `fs.chunk` 流式发送（建议块大小 `64KiB~1MiB`，默认 `256KiB`），流程为 `fs.begin(autoCommit=false) -> fs.chunk* -> fs.end(commit)`。
4. 单块失败支持重试；流式事务失败时 `fs.end(abort)` 后清理临时文件。

### 5.5 指令映射

1. `COPY`
   - host 展开源文件列表并排序；
   - 按目录/文件/软链接映射为 `fs` 操作序列；
   - 按 Dockerfile 目标路径语义落盘。
2. `ADD`（本地 tar）
   - host 解包到临时 staging；
   - 再复用同一套 `fs` 操作序列下发。
3. `ADD URL`
   - host 下载并校验；
   - 作为普通文件（或归档）进入上述流程。

### 5.6 Phase 1 范围

首阶段必须交付：

1. `RuntimeMacOSSidecarShared`
   - 新增 `fs.begin/fs.chunk/fs.end` 方法与 payload 结构。
2. `RuntimeMacOSSidecar`
   - 新增 `fs` 请求分发与 vsock 透传。
3. `MacOSGuestAgent`
   - 支持基础操作：`write_file`, `mkdir`, `symlink`，包含临时文件落盘、提交、回滚。
4. `MacOSSidecarClient` / `MacOSSandboxService`
   - 暴露 `fs` 发送接口，复用现有连接管理与错误回传。
5. `MacOSBuildEngine`
   - `COPY/ADD(local)` 统一走 `fs` 协议发送路径。

### 5.7 后续扩展

1. `RuntimeMacOSSidecarShared`
   - 继续扩展 metadata 字段与附加操作类型。
2. `RuntimeMacOSSidecar`
   - 增加并发窗口、背压与诊断能力。
3. `MacOSGuestAgent`
   - 增加 `chmod/chown/utime/rename/remove` 等扩展操作。
4. `MacOSSidecarClient` / `MacOSSandboxService`
   - 完善错误分类与重试策略。
5. `MacOSBuildEngine`
   - 基于协议能力继续补齐 `ADD(URL)`、缓存与性能优化。

## 6. 用户与权限模型（`USER`）

当前实现已经把 `USER` 语义接到 macOS build 主链路：

1. sidecar 协议 `exec payload` 增加 `user/uid/gid/supplementalGroups` 字段。
2. build stage 维护当前默认用户；`USER <name|uid[:gid]>` 会更新后续 `RUN` 的执行身份。
3. guest-agent 使用“只影响子进程、不污染 daemon 本身”的执行模型，在子进程启动前完成：
   - `setgid`
   - `setgroups` / 补充组解析
   - `setuid`
4. 最终镜像 config 写入 `config.user`，因此后续 `container run --os darwin` 默认也会继承该用户。

当前限制：

1. 首阶段仅实现 `USER` 的执行与镜像 config 语义，不额外提供 `useradd`/`dscl` 一类用户创建封装；用户仍需通过前序 `RUN` 自行准备。
2. `ADD URL` 与多阶段 `COPY --from` 仍然保留在后续阶段。

## 7. 镜像提交（Commit）与格式复用

### 7.1 提交目标

把 stage 当前磁盘状态（`Disk.img` + `AuxiliaryStorage` + `HardwareModel.bin`）提交为新的 OCI 镜像。

### 7.2 提交流程

1. 停止该 stage build container。
2. 读取 container bundle 下三件套文件。
3. 复用现有 `MacOSImagePackager`/chunker 生成 OCI tar（必要时扩展 packager 以接收镜像 config 元数据）。
4. 写入 image config（首阶段包含 `ENV/CMD/ENTRYPOINT/LABEL/WORKDIR/USER`）。
5. 首阶段直接复用现有 `image load`/`tag` 流程导入本地 image store，而不是一开始新增独立 `commit` API。
6. 当 commit 能力需要被 API Server 或远端客户端复用时，再抽象为内部接口或新增路由。

### 7.3 与现有 chunked OCI 的关系

直接复用当前 `disk-layout.v1 + disk-chunk.v1.tar+zstd` 方案，不引入新格式。

## 8. 缓存与增量构建

### 8.1 首阶段行为

首阶段以“功能闭环优先”为原则，不承诺细粒度 build cache：

1. 同一次 build 内只维护 stage 执行状态，不做持久化指令缓存。
2. 重复 build 主要复用已有基础镜像、本地 image store 和 OCI blob 去重能力。
3. `--no-cache` 仍保留为 CLI 兼容参数；在首阶段 darwin 路径下，其效果等价于“显式要求全量重跑”。

### 8.2 第二阶段：阶段级缓存

缓存键建议包含：

- `FROM` digest
- stage 内受支持指令的规范化结果
- 相关上下文文件 digest（`COPY/ADD(local)`）
- `ARG/ENV/WORKDIR` 相关状态

命中后可跳过整个 stage 执行，直接复用此前 commit 的阶段镜像。

### 8.3 第二阶段：chunk 级复用

在 `MacOSDiskChunker` 增加“父镜像 layout 对比模式”：

1. 计算本次 chunk `rawDigest`
2. 若与父镜像同 index chunk 的 `rawDigest` 相同，直接复用父 `layerDigest/layerSize`
3. 仅对变化 chunk 重新 tar+zstd

收益：推送时只上传变化 chunk，显著降低 Xcode/Homebrew 大镜像迭代成本。

### 8.4 第三阶段：指令级缓存

指令级缓存依赖“每条可缓存指令后都能生成并索引中间 checkpoint”，因此不在首阶段承诺。只有在阶段级缓存稳定后，再演进到 instruction cache。

## 9. 与现有命令和服务的集成

### 9.1 CLI

保持 `container build`。

- 新增校验：`darwin` 仅允许 `arm64`。
- 分流必须发生在现有 BuildKit builder 拨号之前；darwin 路径不应为了“保持形式一致”而先启动 Linux builder。
- 首阶段继续支持 `-f`, `-t`, `--build-arg`, `--target`, `--no-cache`, `--output`。
- 首阶段 `--output` 合同明确如下：
  - `type=oci`：支持。由 `MacOSBuildEngine` 生成 OCI tar，随后复用现有 `image load`/`tag` 路径导入本地镜像库。
  - `type=tar`：支持。直接输出 packager 生成的 tar。
  - `type=local`：首阶段显式报 `unsupported`；第二阶段再定义其语义（例如导出 macOS bundle 目录）。

### 9.2 API Server / Images Service

首阶段不强制新增 `commit` 路由。

1. `MacOSBuildEngine` 可先直接复用现有 packager 和 `image load`/`tag` 流程完成闭环。
2. 若后续 API Server 也需要“从运行后 macOS 容器提交镜像”的能力，再抽象为内部接口或新增路由。

### 9.3 兼容性

继续兼容：

- v0（单 `disk-image` layer）镜像读取
- v1（chunked）镜像读取

构建输出统一为 v1（推荐）。

## 10. 可靠性、安全与运行前提

### 10.1 运行前提

1. 宿主必须是 Apple Silicon，且目标镜像固定为 `darwin/arm64`。
2. 当前 macOS sidecar 运行模式依赖登录态 GUI/Aqua session；首阶段目标环境是本地开发机，而非 headless CI。
3. 若未来需要无人值守构建，需要单独设计 sidecar/VM 启动模型，而不是默认复用当前交互式 LaunchAgent 约束。

### 10.2 可靠性

1. stage VM 崩溃自动失败并保留诊断日志。
2. build 中断后可清理临时容器与挂载目录。
3. 长任务（如 Xcode 解包）支持超时参数。

### 10.3 安全

1. `COPY/ADD(local)` 默认且唯一通过 `fs` 协议注入输入。
2. host 侧先完成 context 白名单、`.dockerignore` 过滤和路径越界校验。
3. guest 仅执行受控落盘操作，不暴露共享目录作为构建输入面。
4. host 路径严格限制在 build context。
5. `ADD URL` 在第二阶段默认启用协议与域名策略（可配置）。

## 11. 分阶段实施计划

### Phase 1（MVP）

1. `container build --platform darwin/arm64` 在 builder 拨号前调度到 `MacOSBuildEngine`。
2. Dockerfile 仅支持受控子集：`FROM/ARG/ENV/WORKDIR/RUN/COPY/ADD(local)/USER/CMD/ENTRYPOINT/LABEL`。
3. 不支持的语法（含 `ADD URL`、`COPY --from`）在解析或计划阶段直接失败。
4. 实现基础 `fs` 协议：`fs.begin/fs.chunk/fs.end`。
5. guest 侧支持基础文件操作：`write_file/mkdir/symlink`。
6. `COPY/ADD(local)` 统一通过 `fs` 协议落盘，不保留共享目录或 `tar+stdin` 路径。
7. commit 成镜像并可 `run/push`。
8. 支持 `--output type=oci|tar`，`type=local` 明确报错。

### Phase 2（增强）

1. 多阶段 `COPY --from`
2. `ADD URL` 策略化下载
3. 阶段级缓存
4. chunk `rawDigest` 复用
5. 扩展 `fs` 操作类型与错误模型
6. 明确 `type=local` 的 darwin 输出语义

### Phase 3（优化）

1. 并行 chunk 压缩
2. 构建失败恢复与断点复用
3. `fs` 传输层性能优化（并发窗口、背压、自适应 chunk）
4. 指令级缓存
5. 更完整 Dockerfile 特性对齐（按优先级迭代）

## 12. 验收标准

### 12.1 Phase 1 验收

满足以下场景即通过：

1. 基础构建
   - `FROM local/macos-base:latest`
   - `RUN sw_vers`
   - 成功产出并可 `container run --os darwin` 执行
2. 工具安装
   - Dockerfile 安装 Homebrew 并可 `brew --version`
3. 上下文复制
   - `COPY` 和 `ADD`（本地）通过 `fs` 协议正确落盘
   - `.dockerignore` 生效
   - 不依赖 guest 内 `tar` 或共享目录
4. 用户切换
   - `USER nobody`
   - 后续 `RUN id -un` 输出 `nobody`
   - 最终镜像 config 正确写入 `User`
5. 输出契约
   - `--output type=oci` 可成功导入并打 tag
   - `--output type=tar` 可成功导出 tar

### 12.2 Phase 2 补充验收

1. 远程输入
   - `ADD URL` 满足策略控制并可重复校验
2. 多阶段复制
   - `COPY --from` 可从前序 stage 正确取文件
3. 增量复用
   - 修改少量文件后二次 build，仅少量 chunk 发生变化

## 13. 典型 Dockerfile 示例

```dockerfile
FROM local/macos-base:latest

ENV HOMEBREW_NO_ANALYTICS=1
WORKDIR /opt/setup

COPY scripts/ /opt/setup/scripts/
RUN /bin/bash /opt/setup/scripts/install-homebrew.sh

RUN brew --version
CMD ["/bin/zsh"]
```

## 14. 风险与待决问题

1. `USER` 已依赖新的 guest 内子进程启动模型；后续改动需要继续避免污染长生命周期 guest-agent 自身权限状态。
2. `ADD URL` 的可重复构建语义（内容漂移）需配合 checksum 策略。
3. Dockerfile 解析若无法复用现有 frontend，将显著放大首阶段实现成本。
4. 当前 sidecar 依赖登录态 GUI/Aqua session，headless CI 支持仍是独立议题。
5. 首阶段将基础 `fs` 协议前移后，文件传输吞吐、事务开销与错误恢复路径需要尽早验证。
6. Xcode 安装耗时和许可证处理策略（建议以脚本标准化）。
7. macOS 构建资源占用高，需明确默认 `cpus/memory` 和并发限制。

---

该方案默认以“最小破坏”集成到现有代码：Linux BuildKit 不改，macOS 增量引擎独立演进；镜像格式复用现有 chunked OCI，保障落地速度与兼容性。
