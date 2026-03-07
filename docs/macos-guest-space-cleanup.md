# macOS Guest 磁盘空间清理速查

本文档整理一套在当前仓库开发环境里可重复执行的清理流程，目标是：

1. 快速判断空间到底被谁占了
2. 按“先安全、后激进”的顺序清掉常见残留
3. 清理后把 `container system` 恢复到可继续开发的状态

本文默认你在仓库根目录执行，并且平时就是用当前仓库构建产物管理 `container system`。

## 1. 先统一命令入口

在当前分支开发态里，`system stop/start/status` 建议始终使用同一套二进制和参数，不要混用 debug/release/安装版。

本地开发推荐：

```bash
cd /Users/jianliang/Code/container

export SYSTEM_BIN="$PWD/.build/debug/container"
export DATA_ROOT="$HOME/Library/Application Support/com.apple.container"
export CACHE_ROOT="$HOME/Library/Caches/com.apple.container"
export TMP_ROOT="${TMPDIR%/}"
```

如果你平时不是这样启动 `container system`，把 `SYSTEM_BIN` 换成你实际在用的那一套，但后面的 `stop/start/status` 要保持一致。

实战里已经踩过一个坑：如果服务原本是按 debug 开发态拉起来的，中途改用另一套 release/安装版二进制去 `system start`，可能会出现 `cannot find network plugin` 或 launchd 里仍然挂着旧 install root。下次清理时不要混用。

## 2. 先看空间在哪

优先看 Data 卷，不要只看 `/`：

```bash
df -h /System/Volumes/Data
"$SYSTEM_BIN" system df

find "$DATA_ROOT" -mindepth 1 -maxdepth 1 -exec du -sh {} + 2>/dev/null | sort -h
find "$CACHE_ROOT" -mindepth 1 -maxdepth 1 -exec du -sh {} + 2>/dev/null | sort -h
find "$TMP_ROOT" -maxdepth 1 -name 'macos-oci-layout-*' -exec du -sh {} + 2>/dev/null | sort -h
du -sh /private/tmp/macos-image-base 2>/dev/null
```

经验上最常见的大头是：

- stopped 容器：`container prune`
- 本地镜像：`container image delete --all --force`
- `macos-guest-disk-cache`
- `rebuild-cache`
- `TMPDIR` 下面的 `macos-oci-layout-*`
- `/private/tmp/macos-image-base`

其中 `/private/tmp/macos-image-base` 常常是手工测试要保留的镜像目录，不确定时先不要删。

## 3. 一遍清理的推荐顺序

### 3.1 先清 stopped 容器

```bash
"$SYSTEM_BIN" prune
```

这一步只会删除 stopped 容器，不会碰镜像和 cache。

### 3.2 不需要保留镜像时，清空本地镜像

```bash
"$SYSTEM_BIN" image list
"$SYSTEM_BIN" image delete --all --force
```

`image delete` / `image prune` 现在会顺带清理“已经不再被任何本地 image 引用”的 `rebuild-cache` 条目，但仍被当前 image 引用的 cache 不会自动删除。

如果你还要继续复用某个 base image，就不要做这一步，或者只删不用的 tag。

### 3.3 删除 `macos-oci-layout-*` 临时目录

`container macos package` 过程中可能在 `TMPDIR` 留下大体积 OCI layout 临时目录。

先看有哪些：

```bash
find "$TMP_ROOT" -maxdepth 1 -name 'macos-oci-layout-*' -print
```

确认后删除：

```bash
find "$TMP_ROOT" -maxdepth 1 -name 'macos-oci-layout-*' -exec rm -rf {} +
```

### 3.4 需要保留 `macos-image-base` 时，跳过它

如果你还要继续拿同一个镜像目录做测试，不要删除：

```bash
/private/tmp/macos-image-base
```

如果你确认这个目录已经没用了，再手工删：

```bash
rm -rf /private/tmp/macos-image-base
```

## 4. 清理 macOS guest 缓存

这两类 cache 可以回收很多空间，但建议先停服务再删：

- `"$DATA_ROOT/macos-guest-disk-cache"`
- `"$CACHE_ROOT/rebuild-cache"`

这两类缓存删除后，下次 `run --os darwin` 时会按需重新生成。

### 4.1 停服务

```bash
"$SYSTEM_BIN" system stop
```

### 4.2 清 `macos-guest-disk-cache`

```bash
du -sh "$DATA_ROOT/macos-guest-disk-cache" 2>/dev/null
find "$DATA_ROOT/macos-guest-disk-cache" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null
du -sh "$DATA_ROOT/macos-guest-disk-cache" 2>/dev/null
```

### 4.3 清 `rebuild-cache`

```bash
du -sh "$CACHE_ROOT/rebuild-cache" 2>/dev/null
find "$CACHE_ROOT/rebuild-cache" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null
du -sh "$CACHE_ROOT/rebuild-cache" 2>/dev/null
```

### 4.4 恢复服务

当前仓库开发态建议这样恢复：

```bash
"$SYSTEM_BIN" system start --install-root "$PWD" --disable-kernel-install
"$SYSTEM_BIN" system status
```

如果你平时不是这样启动服务，改成你平时那套启动命令即可。关键点只有一个：`stop/start/status` 用同一套 binary 和 install root。

## 5. 一条最小清理链路

如果你只是想“照着跑一遍”，下面这组命令就是最常用的一套：

```bash
cd /Users/jianliang/Code/container

export SYSTEM_BIN="$PWD/.build/debug/container"
export DATA_ROOT="$HOME/Library/Application Support/com.apple.container"
export CACHE_ROOT="$HOME/Library/Caches/com.apple.container"
export TMP_ROOT="${TMPDIR%/}"

df -h /System/Volumes/Data
"$SYSTEM_BIN" system df

"$SYSTEM_BIN" prune

find "$TMP_ROOT" -maxdepth 1 -name 'macos-oci-layout-*' -exec rm -rf {} +

"$SYSTEM_BIN" system stop
find "$DATA_ROOT/macos-guest-disk-cache" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null
find "$CACHE_ROOT/rebuild-cache" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null
"$SYSTEM_BIN" system start --install-root "$PWD" --disable-kernel-install
"$SYSTEM_BIN" system status

df -h /System/Volumes/Data
"$SYSTEM_BIN" system df
```

如果这次还不需要保留任何镜像，可以在 `prune` 后面追加：

```bash
"$SYSTEM_BIN" image delete --all --force
```

## 6. 清理后的复查

至少复查这几项：

```bash
df -h /System/Volumes/Data
"$SYSTEM_BIN" system df

du -sh "$DATA_ROOT"/macos-guest-disk-cache 2>/dev/null
du -sh "$CACHE_ROOT"/rebuild-cache 2>/dev/null
find "$TMP_ROOT" -maxdepth 1 -name 'macos-oci-layout-*' -print
```

如果 `df -h /` 和 `df -h /System/Volumes/Data` 看起来不一致，不要误判。APFS 下应以 Data 卷的剩余空间为准。

## 7. 本次实战里实际回收过的空间类型

这次开发过程中，实际清理过的主要大项包括：

- stopped 容器，约 `200+ GB`
- `TMPDIR` 下的 `macos-oci-layout-*`，约 `50 GB`
- `macos-guest-disk-cache`，约 `27 GB`
- `rebuild-cache`，约 `83 GB`

这几个目录都很容易在反复 `prepare/package/load/run --os darwin` 后重新堆起来。

## 8. 什么时候不要删

下面这些场景要先停一下：

- 你还要继续复用 `/private/tmp/macos-image-base` 做手工 VM 或重新 `package`
- 你还要继续复用某个本地 base image
- 你当前正在跑 `container run --os darwin`
- 你不确定当前 `container system` 是用哪套 binary 启动的

最后一种最容易把环境搞乱。先用：

```bash
"$SYSTEM_BIN" system status
```

确认当前服务和你手里的 binary 是同一路径，再执行清理。
