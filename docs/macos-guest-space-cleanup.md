# macOS Guest Disk Space Cleanup Quick Reference

This document describes a repeatable cleanup workflow for the current repository's development environment. The goals are:

1. Identify where disk space is actually being used.
2. Remove common leftovers in a safe-first, aggressive-later order.
3. Return `container system` to a usable development state after cleanup.

This guide assumes you run commands from the repository root and use build artifacts from the current checkout to manage `container system`.

## 1. Use One Consistent Command Entry Point

During branch development, use the same binary and the same arguments for `system stop`, `system start`, and `system status`. Do not mix debug, release, and separately installed builds.

Recommended local setup:

```bash
export REPO_ROOT="${REPO_ROOT:-$PWD}"
cd "$REPO_ROOT"

export SYSTEM_BIN="$REPO_ROOT/.build/debug/container"
export DATA_ROOT="$HOME/Library/Application Support/com.apple.container"
export CACHE_ROOT="$HOME/Library/Caches/com.apple.container"
export TMP_ROOT="${TMPDIR%/}"
```

If you normally start `container system` in a different way, change `SYSTEM_BIN` to match your environment. The important part is to keep `stop`, `start`, and `status` on the same binary and install root.

A common failure mode is starting the service from a debug build and later running `system start` from a different release or installed binary. That can lead to errors such as `cannot find network plugin`, or leave launchd pointing at an outdated install root.

## 2. Check Where the Space Went

Prefer checking the Data volume instead of only `/`:

```bash
df -h /System/Volumes/Data
"$SYSTEM_BIN" system df

find "$DATA_ROOT" -mindepth 1 -maxdepth 1 -exec du -sh {} + 2>/dev/null | sort -h
find "$CACHE_ROOT" -mindepth 1 -maxdepth 1 -exec du -sh {} + 2>/dev/null | sort -h
find "$TMP_ROOT" -maxdepth 1 -name 'macos-oci-layout-*' -exec du -sh {} + 2>/dev/null | sort -h
du -sh /private/tmp/macos-image-base 2>/dev/null
```

The most common large consumers are:

- stopped containers: `container prune`
- local images: `container image delete --all --force`
- `macos-guest-disk-cache`
- `rebuild-cache`
- `macos-oci-layout-*` under `TMPDIR`
- `/private/tmp/macos-image-base`

`/private/tmp/macos-image-base` is often a manually maintained image directory. If you are not sure whether you still need it, leave it alone.

## 3. Recommended Cleanup Order

### 3.1 Remove Stopped Containers First

```bash
"$SYSTEM_BIN" prune
```

This only removes stopped containers. It does not touch images or caches.

### 3.2 Remove Local Images When You Do Not Need to Keep Them

```bash
"$SYSTEM_BIN" image list
"$SYSTEM_BIN" image delete --all --force
```

`image delete` and `image prune` already clean up `rebuild-cache` entries that are no longer referenced by any local image. Cache entries still referenced by current images are not removed automatically.

If you still want to reuse a base image, skip this step or delete only the tags you no longer need.

### 3.3 Remove `macos-oci-layout-*` Temporary Directories

`container macos package` may leave large temporary OCI layout directories under `TMPDIR`.

Inspect them first:

```bash
find "$TMP_ROOT" -maxdepth 1 -name 'macos-oci-layout-*' -print
```

Delete them after confirmation:

```bash
find "$TMP_ROOT" -maxdepth 1 -name 'macos-oci-layout-*' -exec rm -rf {} +
```

### 3.4 Skip `macos-image-base` If You Still Need It

If you are still using the same image directory for testing, do not remove:

```bash
/private/tmp/macos-image-base
```

Delete it manually only after you confirm it is no longer needed:

```bash
rm -rf /private/tmp/macos-image-base
```

## 4. Clean macOS Guest Caches

These two caches can free a large amount of space, but stop the service before removing them:

- `"$DATA_ROOT/macos-guest-disk-cache"`
- `"$CACHE_ROOT/rebuild-cache"`

Both caches are regenerated on demand the next time you run `run --os darwin`.

### 4.1 Stop the Service

```bash
"$SYSTEM_BIN" system stop
```

### 4.2 Remove `macos-guest-disk-cache`

```bash
du -sh "$DATA_ROOT/macos-guest-disk-cache" 2>/dev/null
find "$DATA_ROOT/macos-guest-disk-cache" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null
du -sh "$DATA_ROOT/macos-guest-disk-cache" 2>/dev/null
```

### 4.3 Remove `rebuild-cache`

```bash
du -sh "$CACHE_ROOT/rebuild-cache" 2>/dev/null
find "$CACHE_ROOT/rebuild-cache" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null
du -sh "$CACHE_ROOT/rebuild-cache" 2>/dev/null
```

### 4.4 Restart the Service

For local development from this repository:

```bash
"$SYSTEM_BIN" system start --install-root "$REPO_ROOT" --disable-kernel-install
"$SYSTEM_BIN" system status
```

If you normally start the service differently, use your standard startup command. The key requirement is still the same: `stop`, `start`, and `status` must use the same binary and install root.

## 5. Minimal Cleanup Path

If you just want a single sequence to run end to end, this is the most commonly used baseline:

```bash
export REPO_ROOT="${REPO_ROOT:-$PWD}"
cd "$REPO_ROOT"

export SYSTEM_BIN="$REPO_ROOT/.build/debug/container"
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
"$SYSTEM_BIN" system start --install-root "$REPO_ROOT" --disable-kernel-install
"$SYSTEM_BIN" system status

df -h /System/Volumes/Data
"$SYSTEM_BIN" system df
```

If you do not need to keep any local images for this cleanup, add:

```bash
"$SYSTEM_BIN" image delete --all --force
```

after `prune`.

## 6. Post-Cleanup Checks

At minimum, verify:

```bash
df -h /System/Volumes/Data
"$SYSTEM_BIN" system df

du -sh "$DATA_ROOT"/macos-guest-disk-cache 2>/dev/null
du -sh "$CACHE_ROOT"/rebuild-cache 2>/dev/null
find "$TMP_ROOT" -maxdepth 1 -name 'macos-oci-layout-*' -print
```

If `df -h /` and `df -h /System/Volumes/Data` do not match, do not over-interpret `/`. On APFS, the Data volume is the one that matters.

## 7. Typical High-Impact Space Consumers

In one representative cleanup, the largest reclaimable categories were:

- stopped containers: about `200+ GB`
- `macos-oci-layout-*` under `TMPDIR`: about `50 GB`
- `macos-guest-disk-cache`: about `27 GB`
- `rebuild-cache`: about `83 GB`

These directories can grow quickly after repeated `prepare`, `package`, `load`, and `run --os darwin` cycles.

## 8. When Not to Delete Things

Pause before cleanup in the following cases:

- You still need `/private/tmp/macos-image-base` for manual VM use or another `package` run.
- You still need a local base image.
- You currently have `container run --os darwin` running.
- You are not sure which binary started the current `container system`.

The last case is the easiest way to create an inconsistent environment. Check first:

```bash
"$SYSTEM_BIN" system status
```

Make sure the running service matches the binary you are using before you continue.
