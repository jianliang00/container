# macOS Guest 镜像：分块 tar(sparse)+zstd 的 OCI 格式（v1）

本文档定义一套用于 **macOS Guest** 镜像分发的 OCI 兼容格式，用于解决：

- push/pull 时避免上传/下载 RAW `Disk.img` 的 64GiB 线性字节流；
- 通过按 1GiB 分块生成多个 blob，使新版本镜像可以复用旧版本未变更的 chunk blob；
- 在 pull/load 后立即重建可运行的 `Disk.img`（保稀疏），并允许在缓存缺失时按需重建作为回退。

该格式面向生产环境：强调 **确定性**（digest 稳定以实现 registry 复用）、**可校验**、**可演进**。

## 1. 背景与现状

当前实现把 `Disk.img` 作为一个单独的 OCI layer blob（自定义 mediaType），registry push/pull 会按 digest 上传/下载该 blob 的完整字节流。对于 RAW 磁盘镜像，即使其中存在稀疏洞（逻辑 64GiB、物理占用更小），也会在 push/pull 时退化为传输 64GiB。

## 2. 术语

- **logicalSize**：磁盘镜像逻辑大小（例如 64GiB）。
- **chunkSize**：每个 chunk 的逻辑大小（固定 1GiB）。
- **chunk**：以固定 offset 切分的磁盘片段；最后一块可小于 1GiB。
- **sparse tar**：tar 归档对“洞”采用稀疏编码（仅记录非空 extents）。
- **rebuild**：将 chunk blob 解包并按 offset 写回，生成可运行的 `Disk.img`。

## 3. 设计目标

- **OCI 兼容**：符合 OCI Image Spec 的 index/manifest/config 结构，registry 无需理解内容语义。
- **push/pull 体积可控**：disk 数据以 tar(sparse)+zstd 存储。
- **blob 复用**：chunk 内容未变则 blob digest 不变，push 时复用已有 blob。
- **运行前已准备**：强制在 pull/load 后立即重建 `Disk.img` 缓存。
- **健壮性**：若缓存缺失/损坏，允许按需重建作为回退路径。

## 4. OCI 对象模型

### 4.1 平台

固定：

- `os = darwin`
- `architecture = arm64`

### 4.2 Media Types（v1）

保留现有：

- `application/vnd.apple.container.macos.hardware-model`
- `application/vnd.apple.container.macos.auxiliary-storage`

新增：

- `application/vnd.apple.container.macos.disk-layout.v1+json`
- `application/vnd.apple.container.macos.disk-chunk.v1.tar+zstd`

说明：

- `disk-layout` 作为独立 layer，携带 chunk 列表、offset、长度、校验等元数据。
- 每个 `disk-chunk` 是一个独立 layer blob，内容为 tar(sparse)+zstd。

### 4.3 Manifest layers 顺序（建议固定）

建议 layers 顺序固定，利于一致性与调试：

1. hardwareModel
2. auxiliaryStorage
3. diskLayout（JSON）
4. diskChunk[0..N-1]

> 注意：OCI 语义上 layer 顺序通常用于 rootfs 叠加；本方案把 OCI 作为 artifact 载体，不依赖 rootfs 叠加语义。顺序固定仅用于实现一致性。

### 4.4 OCI config 扩展字段（推荐）

仍使用标准 mediaType：`application/vnd.oci.image.config.v1+json`。

在 config 的 `config` 节点增加扩展字段，便于快速判别格式：

```json
{
  "os": "darwin",
  "architecture": "arm64",
  "rootfs": { "type": "layers", "diff_ids": [] },
  "config": {
    "org.apple.container.macos.disk.format": "chunked-tar-sparse-zstd/v1",
    "org.apple.container.macos.disk.chunk_size": 1073741824,
    "org.apple.container.macos.disk.logical_size": 68719476736
  }
}
```

## 5. diskLayout.v1+json 规范

### 5.1 Schema（建议）

```json
{
  "version": 1,
  "logicalSize": 68719476736,
  "chunkSize": 1073741824,
  "chunkCount": 64,
  "compression": { "type": "zstd", "level": 3 },
  "tar": { "format": "pax", "sparse": true },
  "chunks": [
    {
      "index": 0,
      "offset": 0,
      "length": 1073741824,
      "layerDigest": "sha256:<digest-of-chunk-blob>",
      "layerSize": 123456789,
      "rawDigest": "sha256:<digest-of-raw-bytes>",
      "rawLength": 1073741824
    }
  ]
}
```

字段说明：

- `logicalSize`：最终 `Disk.img` 逻辑大小，重建时必须 truncate 到该值。
- `chunkSize`：固定 1GiB（1073741824）。
- `chunkCount`：`ceil(logicalSize / chunkSize)`。
- `layerDigest/layerSize`：OCI layer blob digest/size（压缩态）。
- `rawDigest/rawLength`：chunk 的原始字节序列摘要与长度，用于跨实现校验与调试。

### 5.2 chunk layer annotations（推荐冗余）

每个 chunk 的 layer descriptor 建议写入 annotations（便于不读 layout 也能定位）：

- `org.apple.container.macos.chunk.index = "<int>"`
- `org.apple.container.macos.chunk.offset = "<bytes>"`
- `org.apple.container.macos.chunk.length = "<bytes>"`
- `org.apple.container.macos.chunk.raw.digest = "sha256:..."`
- `org.apple.container.macos.chunk.raw.length = "<bytes>"`

## 6. diskChunk.v1.tar+zstd 内容规范

每个 chunk layer blob 内容为：

1. tar（PAX，sparse enabled）
2. zstd 压缩输出

### 6.1 tar 约束（强制）

- tar 格式：PAX（不使用 GNU 私有扩展）。
- tar 内只允许 **一个 entry**，路径固定为：`disk.chunk`。
- entry 类型：regular file。
- entry 逻辑大小必须等于 `chunk.length`。
- entry 必须使用 sparse 表达（洞不写入 tar 数据流）。

### 6.2 确定性要求（强制）

为确保“相同 chunk 内容”在不同时间/不同机器得到相同 blob digest，必须固定：

- tar header 元数据固定化：
  - uid=0、gid=0、uname=""、gname=""；
  - mode 固定（例如 0644）；
  - mtime 固定（例如 0）。
- tar 内容仅 1 个 entry，避免目录遍历顺序影响。
- zstd 参数固定：
  - level 固定（例如 3）；
  - 建议固定单线程；
  - 不使用外部字典；
  - 不引入时间戳/随机字段。

`rawDigest` 用于验证“解包后的原始 chunk 字节序列”正确性，即使未来替换 tar/zstd 实现，也能保持可校验。

## 7. 生命周期：package / push / pull / load / rebuild / run

### 7.1 package（生成镜像）

输入：镜像目录包含 `Disk.img` / `AuxiliaryStorage` / `HardwareModel.bin`。

流程：

1. 计算 `logicalSize`（Disk.img 逻辑大小）；
2. 按固定 offset 切分 `Disk.img` 为 chunk（chunkSize=1GiB）；
3. 对每个 chunk：
   - 生成 tar(PAX sparse)（只含 `disk.chunk`）；
   - 以 zstd 压缩；
   - 得到 `diskChunk` layer blob（digest/size）；
   - 计算并记录 `rawDigest/rawLength`；
4. 生成 `diskLayout.v1+json` layer，记录所有 chunk 元数据；
5. 生成 OCI manifest/index，并写入 blobs/sha256。

### 7.2 push（上传到 registry）

push 的去重粒度是 blob digest。由于 disk 被分为多个 chunk：

- 未变化的 chunk digest 不变，push 时可复用 registry 已存在的 blob；
- 变化的 chunk 仅上传对应 blob，不需要上传整盘内容。

### 7.3 pull/load（导入到本地内容库）——强制立即重建

要求：

- pull：拉取镜像后，必须立即执行 rebuild；
- load：从 tar 导入镜像后，必须立即执行 rebuild。

原因：

- 运行时不应在首次 `run` 时才做重建，避免用户体验抖动；
- 重建结果可缓存，并用于后续容器 clone（写时复制）。

### 7.4 rebuild（重建 Disk.img 缓存）——必须保稀疏

输入：

- `diskLayout` JSON
- 所有 `diskChunk` blob（tar.zst）

输出：

- 一个可运行的 `Disk.img` 文件（逻辑大小=logicalSize）

重建规则：

1. 创建输出文件并 truncate 到 `logicalSize`；
2. 对每个 chunk：
   - 解压 zstd；
   - 读取 tar entry 的 sparse extents；
   - 对每个非空 extent：`seek(offset+extentOffset)` 写入数据；
   - 对洞区间：只 `seek` 跳过，不写入（保持稀疏）。
3. 可选校验：
   - 对每个 chunk 计算 rawDigest 并与 layout 对比（用于完整性检查）。

缓存策略：

- 缓存 key 建议使用 `manifestDigest + chunkSize + layoutVersion`；
- 缓存产物包含 `Disk.img`；
- 缓存缺失时允许按需重建（见 7.5）。

### 7.5 运行时回退：缓存缺失允许按需重建

即使采用“强制 pull/load 后立即重建”，仍需要回退：

- 缓存被清理；
- rebuild 过程中中断；
- 用户直接拷贝 content store 而未触发 rebuild。

回退策略：

- runtime 在启动前发现 `Disk.img` 缓存缺失时，触发一次 rebuild 并写入缓存；
- rebuild 成功后再进入正常启动流程。

## 8. 兼容性与迁移策略

需要支持两种 disk 表达：

- v0（旧）：单一 raw disk-image layer（现有实现）。
- v1（新）：diskLayout + diskChunk*。

解析规则（建议）：

1. 若 manifest 存在 `disk-layout.v1+json`，优先按 v1 处理；
2. 否则回退到 v0 raw disk-image 处理。

## 9. 操作与运维建议

- chunkSize 固定为 1GiB，chunk 数量约 64 个（64GiB 镜像），生产可接受。
- 建议将 rebuild 缓存与 content store 分离目录，便于 GC 与故障排查。
- rebuild 应支持断点/幂等：对同一缓存 key 可重复执行并覆盖。
- 若启用每 chunk rawDigest 校验，会增加 rebuild CPU 成本，但能显著增强生产可靠性。

