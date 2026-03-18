# Volume Mapping Based on macOS Guest Automount

The recommended approach is to use the default automount tag, `com.apple.virtio-fs.automount`, as the single entry point for all `hostPath` volumes in the macOS guest. The older approach of assigning a custom tag per volume and mounting each one manually under `/Users/...` should not be the primary path.

## Core Idea

- Aggregate multiple `Filesystem.virtiofs` entries into one `VZMultipleDirectoryShare` on the host.
- Access all shared directories from `/Volumes/My Shared Files/<share-id>` inside the guest.
- Do not mount `guestPath` from `-v hostPath:guestPath[:opts]` directly to an arbitrary location with `mount_virtiofs`; let the guest runtime provide a controlled mapping layer instead.

This approach is preferred because the default automount path is already known to be treated by the system as `local, automounted`, and the system guest-agent can read it even when no user is logged in. Custom tags plus mount points outside `/Volumes` are a known high-risk area.

## How `-v` Should Map

Treat each `-v` as two separate paths:

- Real shared path: `/Volumes/My Shared Files/<share-id>`
- Workload-facing path: `guestPath`

Example:

- `-v /host/work:/Users/Shared/workspace`
- Host-side share name: `v-workspace`
- Real data path in the guest: `/Volumes/My Shared Files/v-workspace`
- Runtime mapping: `/Users/Shared/workspace` points to that real path

`<share-id>` should satisfy two requirements:

- It is stable and can be regenerated from the mount configuration.
- It contains no spaces, so path handling complexity does not spread beyond `My Shared Files`.

## Mapping Strategy Inside the Guest

The first version should use symlinks directly instead of trying to fully match Linux bind-mount semantics.

Suggested behavior:

- Read `config.mounts` before starting the workload in the guest.
- For each `virtiofs` mount, verify that `/Volumes/My Shared Files/<share-id>` exists.
- If `guestPath` does not exist, create the parent directory and create a symlink.
- If `guestPath` already exists, only accept cases that are safe to take over, such as a missing path or an empty directory. Fail for all other cases.
- Restrict `guestPath` to stable writable prefixes in the macOS guest, such as `/Users/...`, `/private/...`, `/tmp/...`, `/var/...`, `/usr/local/...`, `/opt/...`.

This keeps the main path working without reintroducing custom tags or extra mount operations.

## Read/Write Modes and Options

- `rw`: default read-write mode
- `ro`: use a read-only `VZSharedDirectory` for the corresponding host directory

In other words, `-v /host/cache:/cache:ro` still resolves to `/Volumes/My Shared Files/<share-id>`, but the share itself is read-only.

## Implementation Order

Recommended sequence:

1. Make the macOS runtime consume `Filesystem.virtiofs` entries from `config.mounts`.
2. Upgrade the current single-directory share to `VZMultipleDirectoryShare`.
3. Add a volume-mapping step before workload startup in the guest-agent or sidecar.
4. Support only `hostPath:absGuestPath[:ro]` in the first version.
5. Consider named volumes, `tmpfs`, and ConfigMap/Secret-style injection later.

## Boundaries

The first version should explicitly limit the scope:

- Do not guarantee overlaying existing non-empty directories.
- Do not support mapping volumes onto protected system paths.
- Do not support creating new top-level paths such as `/workspace` on a sealed system volume.
- Do not try to fully replicate Linux bind-mount semantics.
- Keep custom `--share-tag` support only for manual debugging, not for the main `-v` flow.

The point of this design is not to mount `virtiofs` anywhere. The point is to stay inside the default automount path and let the runtime expose a stable mapping layer on top of it.
