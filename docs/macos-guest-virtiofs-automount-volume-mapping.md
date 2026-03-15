# macOS guest 下基于 automount 的 volume 映射方案

当前推荐把默认 automount tag `com.apple.virtio-fs.automount` 作为 macOS guest 里所有 hostPath volume 的统一入口，不再回到“每个 volume 一个自定义 tag，再手工挂到 `/Users/...`”这条路径。

## 核心思路

- host 侧把多个 `Filesystem.virtiofs` 聚合成一个 `VZMultipleDirectoryShare`
- guest 侧统一从 `/Volumes/My Shared Files/<share-id>` 访问这些目录
- `-v hostPath:guestPath[:opts]` 的 `guestPath` 不直接通过 `mount_virtiofs` 落到任意路径，而是由 guest runtime 再做一层受控映射

这样做的原因很简单：默认 automount 这条链路已经验证过会被系统视为 `local, automounted`，并且在无人登录时也能由 system guest-agent 直接读取；自定义 tag + 非 `/Volumes` 挂载点则是已知高风险区。

## `-v` 怎么映射

建议把每个 `-v` 解析成两层路径：

- 真实共享路径：`/Volumes/My Shared Files/<share-id>`
- workload 期望路径：`guestPath`

例如：

- `-v /host/work:/Users/Shared/workspace`
- host 侧共享名可以是 `v-workspace`
- guest 里真实数据在 `/Volumes/My Shared Files/v-workspace`
- runtime 再把 `/Users/Shared/workspace` 映射到这个真实路径

`<share-id>` 应该满足两点：

- 稳定，可从 mount 配置重复生成
- 无空格，避免把 `My Shared Files` 之外的路径复杂度继续扩散到构建工具

## guest 内的映射方式

第一版建议直接用 symlink，不追求和 Linux bind mount 完全等价。

做法：

- 在 guest 启动 workload 前读取 `config.mounts`
- 对每个 `virtiofs` mount，确认 `/Volumes/My Shared Files/<share-id>` 已出现
- 如果 `guestPath` 不存在，则创建父目录并建立 symlink
- 如果 `guestPath` 已存在，只接受“不存在”或“空目录”这类可安全接管的情况；其他情况直接报错
- `guestPath` 只允许落在 macOS guest 的稳定可写前缀下，例如 `/Users/...`、`/private/...`、`/tmp/...`、`/var/...`、`/usr/local/...`、`/opt/...`

这样能先把主链路做通，同时避免重新引入自定义 tag 和额外挂载动作。

## 读写和选项

- `rw`：默认读写
- `ro`：host 侧对应目录用只读 `VZSharedDirectory`

也就是说，`-v /host/cache:/cache:ro` 最终仍然会落到 `/Volumes/My Shared Files/<share-id>`，只是这个 share 本身是只读的。

## 实现落点

建议按这个顺序做：

1. macOS runtime 开始真正消费 `config.mounts` 里的 `Filesystem.virtiofs`
2. 现有单目录 share 升级成 `VZMultipleDirectoryShare`
3. 在 guest-agent / sidecar 的 workload 启动前增加 volume 映射步骤
4. 第一版只支持 `hostPath:absGuestPath[:ro]`
5. 后面再考虑 named volume、tmpfs、ConfigMap/Secret 这类注入能力

## 边界

第一版最好明确限制：

- 不保证覆盖已有非空目录
- 不支持把 volume 映射到受保护系统路径
- 不支持 `/workspace` 这类 sealed system volume 顶层新路径
- 不追求完全复制 Linux bind mount 语义
- 自定义 `--share-tag` 保留给手工调试，不作为 `-v` 主链路

这个方案的重点不是“把 virtiofs 挂到任意位置”，而是“始终留在默认 automount 的安全路径里，再由 runtime 提供一层稳定映射”。
