# macOS guest 启动诊断

隔离实例通过 `CONTAINER_BOOT_DIAGNOSTIC_ID` 精确匹配容器 ID 后，sidecar 呈现该实例的 VM 窗口，在启动虚拟机前检查窗口采集能力，并为 guest-agent Ready 提供 180 秒观察预算。画面保存在容器根目录的 `bootstrap-diagnostics/`，不读取 `CONTAINER_BOOT_DIAGNOSTIC_DIR`。采集范围只包含该进程的 VM 窗口。

`container-runtime-macos` 对 `vm.bootstrapStart` 使用 240 秒请求超时，为 180 秒观察及资源回收预留时间。其他控制请求仍使用各自的超时。运行时与 sidecar 必须来自同一提交的完整签名产物；只替换 sidecar 不会更新调用方的请求预算。

通过 Kubernetes 启动时，还须在解除隔离节点的禁止调度前回读 kubelet、CRI 和外层观察器的请求预算。kubelet 发起的启动请求必须允许超过 240 秒；外层观察窗口还须覆盖调度和供盘。仅扩大 sidecar 的等待时间不能绕过上层取消。节点参数的调整和恢复应纳入同一次隔离验证的运维记录。

每次验证保存源码提交、程序哈希、CREATE operation UUID、序号、Pod UID、Assignment、存储导出及诊断日志。首次失败后删除该实例并恢复禁止调度，分别核对 API、Pod、Assignment、容器记录、runtime/sidecar/VM 进程、NBD socket、Gateway 导出、RBD 与临时权限均已清理。容器记录仍在时，使用精确实例 ID 执行非强制 `container delete`，并再次检查节点 Ready。

连接重置只表明 guest-agent 通道尚未就绪。黑屏不能单独确定 guest 启动失败原因；存储导出存在和写入偏移变化也不能替代 I/O 计数或吞吐量测量。
