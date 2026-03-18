# macOS Guest Image OCI Format: Chunked tar(sparse)+zstd (v1)

This document defines an OCI-compatible format for distributing **macOS guest** images. It is designed to solve the following problems:

- avoid uploading and downloading the full 64 GiB linear byte stream of a raw `Disk.img` during push and pull
- split the disk into 1 GiB blobs so a new image version can reuse unchanged chunk blobs from an older version
- rebuild a runnable sparse `Disk.img` immediately after `pull` or `load`, while still allowing on-demand rebuild as a fallback if the cache is missing

This format is intended for production use. It emphasizes **determinism** (stable digests for registry reuse), **verifiability**, and **evolvability**.

## 1. Background and Current State

The current implementation stores `Disk.img` as a single OCI layer blob with a custom media type. Registry push and pull transfer the entire blob byte stream by digest. For raw disk images, even when the file contains sparse holes and the physical usage is much smaller than the logical 64 GiB size, push and pull still degenerate into transferring the full 64 GiB.

## 2. Terminology

- **logicalSize**: logical size of the disk image, for example 64 GiB
- **chunkSize**: logical size of each chunk, fixed at 1 GiB
- **chunk**: a disk segment cut at a fixed offset; the last chunk may be smaller than 1 GiB
- **sparse tar**: a tar archive that encodes holes sparsely and records only non-empty extents
- **rebuild**: unpack chunk blobs and write them back by offset to produce a runnable `Disk.img`

## 3. Design Goals

- **OCI-compatible**: follows the OCI Image Spec structure for index, manifest, and config, without requiring the registry to understand the content semantics
- **bounded transfer size**: stores disk data as tar(sparse)+zstd
- **blob reuse**: unchanged chunk contents keep the same blob digest and are reused on push
- **ready before run**: requires rebuilding the `Disk.img` cache immediately after `pull` or `load`
- **robustness**: allows on-demand rebuild as a fallback when the cache is missing or damaged

## 4. OCI Object Model

### 4.1 Platform

Fixed values:

- `os = darwin`
- `architecture = arm64`

### 4.2 Media Types (v1)

Existing media types kept as-is:

- `application/vnd.apple.container.macos.hardware-model`
- `application/vnd.apple.container.macos.auxiliary-storage`

New media types:

- `application/vnd.apple.container.macos.disk-layout.v1+json`
- `application/vnd.apple.container.macos.disk-chunk.v1.tar+zstd`

Notes:

- `disk-layout` is a standalone layer carrying chunk metadata such as offsets, lengths, and checksums.
- Each `disk-chunk` is an independent layer blob whose payload is tar(sparse)+zstd.

### 4.3 Manifest Layer Order (Recommended to Be Fixed)

Use a fixed layer order for consistency and debugging:

1. hardwareModel
2. auxiliaryStorage
3. diskLayout (JSON)
4. diskChunk[0..N-1]

> Note: in normal OCI semantics, layer order is used for rootfs overlay behavior. This design uses OCI as an artifact transport. Fixed ordering is only for implementation consistency.

### 4.4 OCI Config Extension Fields (Recommended)

Continue using the standard config media type:

- `application/vnd.oci.image.config.v1+json`

Add extension fields under the config's `config` node so the format can be recognized quickly:

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

## 5. `diskLayout.v1+json` Specification

### 5.1 Schema (Recommended)

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

Field descriptions:

- `logicalSize`: logical size of the final `Disk.img`; rebuild must truncate to this size
- `chunkSize`: fixed at 1 GiB (`1073741824`)
- `chunkCount`: `ceil(logicalSize / chunkSize)`
- `layerDigest/layerSize`: digest and size of the compressed OCI layer blob
- `rawDigest/rawLength`: digest and length of the raw chunk byte stream, used for cross-implementation validation and debugging

### 5.2 Chunk Layer Annotations (Recommended Redundancy)

Each chunk layer descriptor should also carry annotations so tools can locate the chunk without reading the layout:

- `org.apple.container.macos.chunk.index = "<int>"`
- `org.apple.container.macos.chunk.offset = "<bytes>"`
- `org.apple.container.macos.chunk.length = "<bytes>"`
- `org.apple.container.macos.chunk.raw.digest = "sha256:..."`
- `org.apple.container.macos.chunk.raw.length = "<bytes>"`

## 6. `diskChunk.v1.tar+zstd` Content Specification

Each chunk layer blob consists of:

1. tar (PAX, sparse enabled)
2. zstd-compressed output

### 6.1 tar Constraints (Required)

- tar format: PAX, without GNU-private extensions
- exactly **one entry** in the tar, with a fixed path: `disk.chunk`
- entry type: regular file
- entry logical size must equal `chunk.length`
- the entry must use sparse encoding, so holes are not written to the tar data stream

### 6.2 Determinism Requirements (Required)

To ensure the same chunk content yields the same blob digest across time and machines, the following must be fixed:

- tar header metadata:
  - `uid=0`, `gid=0`, `uname=""`, `gname=""`
  - fixed mode, for example `0644`
  - fixed mtime, for example `0`
- tar content contains only one entry, avoiding directory traversal ordering differences
- zstd parameters:
  - fixed compression level, for example `3`
  - preferably fixed single-threaded output
  - no external dictionary
  - no timestamps or random fields

`rawDigest` validates the unpacked raw chunk byte stream, so correctness remains checkable even if the tar or zstd implementation changes later.

## 7. Lifecycle: `package` / `push` / `pull` / `load` / `rebuild` / `run`

### 7.1 `package` (Create the Image)

Input: an image directory containing `Disk.img`, `AuxiliaryStorage`, and `HardwareModel.bin`.

Flow:

1. Compute `logicalSize`, the logical size of `Disk.img`.
2. Split `Disk.img` into chunks at fixed offsets using `chunkSize=1GiB`.
3. For each chunk:
   - generate tar(PAX sparse) containing only `disk.chunk`
   - compress it with zstd
   - produce a `diskChunk` layer blob and record its digest and size
   - compute and record `rawDigest/rawLength`
4. Generate the `diskLayout.v1+json` layer with metadata for all chunks.
5. Generate the OCI manifest and index, and write blobs under `blobs/sha256`.

### 7.2 `push` (Upload to a Registry)

Push deduplicates at blob digest granularity. Because the disk is chunked:

- unchanged chunks keep the same digest and reuse registry blobs
- changed chunks upload only their own blobs instead of re-uploading the full disk

### 7.3 `pull` / `load` (Import into the Local Content Store): Rebuild Immediately

Requirements:

- after `pull`, rebuild must run immediately
- after `load` from tar, rebuild must run immediately

Reasons:

- runtime should not defer rebuild until the first `run`, which would create user-visible latency
- rebuilt output can be cached and reused for later copy-on-write clones

### 7.4 `rebuild` (Rebuild the `Disk.img` Cache): Sparse Output Required

Input:

- `diskLayout` JSON
- all `diskChunk` blobs (`tar.zst`)

Output:

- one runnable `Disk.img` file with logical size equal to `logicalSize`

Rebuild rules:

1. Create the output file and truncate it to `logicalSize`.
2. For each chunk:
   - decompress zstd
   - read sparse extents from the tar entry
   - for each non-empty extent, write data at `seek(offset + extentOffset)`
   - for holes, only seek without writing so sparsity is preserved
3. Optional validation:
   - compute `rawDigest` for each chunk and compare it with the layout

Cache strategy:

- recommended cache key: `manifestDigest + chunkSize + layoutVersion`
- cache output includes `Disk.img`
- if the cache is missing, on-demand rebuild remains allowed as described below

### 7.5 Runtime Fallback: Rebuild on Demand if the Cache Is Missing

Even when rebuild is required immediately after `pull` or `load`, a fallback is still necessary:

- the cache may have been cleaned up
- rebuild may have been interrupted
- a user may copy the content store without triggering rebuild

Fallback policy:

- if runtime detects that the `Disk.img` cache is missing before startup, trigger rebuild once and write the cache
- continue to normal startup only after rebuild succeeds

## 8. Compatibility and Migration

Support both disk representations:

- v0: one raw disk-image layer, the current legacy implementation
- v1: `diskLayout` plus `diskChunk*`

Recommended parsing rules:

1. If the manifest contains `disk-layout.v1+json`, process it as v1.
2. Otherwise fall back to the v0 raw disk-image path.

## 9. Operational Recommendations

- Keep `chunkSize` fixed at 1 GiB. A 64 GiB image produces about 64 chunks, which is acceptable for production.
- Keep rebuild cache and content store in separate directories for easier garbage collection and troubleshooting.
- Rebuild should be resumable and idempotent. The same cache key should be safe to rebuild repeatedly and overwrite.
- Per-chunk `rawDigest` validation increases rebuild CPU cost but materially improves production reliability.
