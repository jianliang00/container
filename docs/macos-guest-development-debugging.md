# macOS Guest Development and Debugging Guide

This document collects the main findings, debugging methods, common failures, and repair workflows that came out of several rounds of macOS guest development and troubleshooting. The goal is to help future iterations converge quickly instead of rediscovering the same failure modes.

Scope:

- `container run --os darwin ...`
- `container-runtime-macos` and `container-runtime-macos-sidecar`
- `container-macos-guest-agent`
- image VMs generated from `prepare-base`
- manual debugging tools such as `container macos start-vm`

Related document:

- image creation, base image refresh, and local validation workflow:
  `docs/macos-guest-local-validation-guide.md`

It is recommended to reuse the environment variable conventions from
`docs/macos-guest-local-validation-guide.md`, such as `CONTAINER_BIN`,
`BASE_REF`, `IMAGE_DIR`, `SEED_DIR`, `OCI_TAR`, and `WORKROOT`.

Unless you intentionally use a custom tag for manual debugging, this document assumes seed injection goes through `com.apple.virtio-fs.automount`, and the guest sees it at `/Volumes/My Shared Files/seed`.

## 1. Current Architecture

The default path no longer hosts `VZVirtualMachine` directly inside the `container-runtime-macos` helper process. Instead:

1. `container-runtime-macos` (helper) is responsible for:
   - XPC `SandboxService` routes
   - container root and image file preparation
   - starting and managing the sidecar LaunchAgent
   - forwarding higher-level operations such as stdio, `wait`, `signal`, and `resize`
2. `container-runtime-macos-sidecar` (GUI-domain LaunchAgent) is responsible for:
   - hosting `VZVirtualMachine`
   - starting the macOS VM in "no window, but keep a graphics device" mode
   - connecting to `container-macos-guest-agent` over vsock
   - handling `process.start`, `stdin`, `signal`, `resize`, and `close`
   - sending `stdout`, `stderr`, and `exit` events back to the helper

This architecture exists to avoid the frequent `Code=54 Connection reset by peer` failures seen when the helper or XPC context called `VZVirtioSocketDevice.connect(toPort:)` directly.

## 2. Main Conclusions

### 2.1 The Difference Between Pure `headless` and `headless-display` Matters

Observed results:

- `container macos start-vm --headless`: common `vsock Code=54 reset by peer`
- `container macos start-vm --headless-display`: guest-agent usually works
- hosting the VM directly inside `container-runtime-macos` can still fail even when no window is shown but a graphics device is present
- moving VM ownership into a GUI-domain sidecar improves stability substantially

Conclusion:

- pure `headless` is not a reliable default startup mode for the current guest image and agent combination
- "no window, but keep a graphics device" is the stable default

### 2.2 A Healthy Manual VM Does Not Automatically Mean `container run` Will Work

You may encounter cases where:

- `start-vm` works and the agent is healthy
- `container run` still fails with `failed to connect to guest agent ... Code=54`

These are not contradictory. Common causes are:

- the VM was not shut down before packaging, so `container run` still uses stale disk contents
- the plugin directory still contains old `container-runtime-macos` or sidecar binaries, while only `.build` was updated
- `container system` was not restarted and is still using old plugin processes
- an old container or sidecar is hung, blocking APIServer and causing later `containerCreate` XPC timeouts

### 2.3 Do Not Patch `.build` Outputs in Place

`.build` is only the compilation output directory. The correct workflow is:

- change source files under `Sources/...` or `scripts/...`
- rebuild
- deploy binaries into the real runtime path, such as the plugin directory
- re-sign with the required entitlements for Virtualization.framework
- restart `container system`

## 3. Common Environment Variables and Paths

Suggested environment:

```bash
export CONTAINER_BIN="$PWD/.build/release/container"
export IMAGE_DIR="/tmp/macos-image-base"
export SEED_DIR="/tmp/macos-agent-seed"
export OCI_TAR="/tmp/macos-image-base-oci.tar"
export LOCAL_REF="local/macos-image:base"
```

Key paths:

- plugin helper:
  `libexec/container/plugins/container-runtime-macos/bin/container-runtime-macos`
- plugin sidecar:
  `libexec/container/plugins/container-runtime-macos/bin/container-runtime-macos-sidecar`
- manual debugging VM helper from the installed package:
  `/usr/local/libexec/container/macos-vm-manager/bin/container-macos-vm-manager`
- guest-agent log inside the guest:
  `/var/log/container-macos-guest-agent.log`
- mirrored guest-agent log on the host inside the container root:
  `<container-root>/guest-agent.log`
- mirrored guest-agent log follower stderr on the host:
  `<container-root>/guest-agent.stderr.log`
- helper log on the host inside the container root:
  `<container-root>/stdio.log`

## 4. Build, Deploy, and Re-Sign

### 4.1 Build the Relevant Binaries

```bash
xcrun swift build -c release --product container
xcrun swift build -c release --product container-runtime-macos
xcrun swift build -c release --product container-runtime-macos-sidecar
xcrun swift build -c release --product container-macos-guest-agent
```

### 4.2 Deploy Runtime Helper and Sidecar to the Plugin Directory

Building under `.build` does not replace the binaries used by the running system. Copy them explicitly:

```bash
cp .build/arm64-apple-macosx/release/container-runtime-macos \
  libexec/container/plugins/container-runtime-macos/bin/container-runtime-macos

cp .build/arm64-apple-macosx/release/container-runtime-macos-sidecar \
  libexec/container/plugins/container-runtime-macos/bin/container-runtime-macos-sidecar
```

### 4.3 Re-Sign Both Binaries

```bash
codesign --force --sign - \
  --entitlements signing/container-runtime-macos.entitlements \
  libexec/container/plugins/container-runtime-macos/bin/container-runtime-macos

codesign --force --sign - \
  --entitlements signing/container-runtime-macos.entitlements \
  libexec/container/plugins/container-runtime-macos/bin/container-runtime-macos-sidecar
```

Validation should show `com.apple.security.virtualization`:

```bash
codesign -d --entitlements :- \
  libexec/container/plugins/container-runtime-macos/bin/container-runtime-macos 2>&1 | \
  grep com.apple.security.virtualization

codesign -d --entitlements :- \
  libexec/container/plugins/container-runtime-macos/bin/container-runtime-macos-sidecar 2>&1 | \
  grep com.apple.security.virtualization
```

### 4.4 Restart the Service

```bash
"$CONTAINER_BIN" system stop
"$CONTAINER_BIN" system start --install-root "$PWD" --disable-kernel-install
```

Notes:

- `--install-root "$PWD"` makes sure the current repository's plugin path is used
- without it, the system may still pick an old install root
- if `system stop` encounters a hung old container, the logs may show an XPC timeout for a runtime helper, but the later `bootout` step usually still removes the launchd unit

## 5. Debugging the Image VM Without `container run`

This is the most effective way to isolate whether the problem is in:

- the guest-agent protocol
- guest daemon startup
- host vsock connectivity
- runtime or helper context differences

### 5.1 Start a Manual VM with `container macos start-vm`

### 5.2 Three Startup Modes

To simplify the workflow, you can use `--auto-seed` instead of preparing `$SEED_DIR` manually. The temporary share will appear inside the guest at `/Volumes/My Shared Files/seed`:

```bash
"$CONTAINER_BIN" macos start-vm \
  --image "$IMAGE_DIR" \
  --auto-seed \
  --cpus 4 \
  --memory-mib 8192
```

#### GUI Mode

```bash
"$CONTAINER_BIN" macos start-vm \
  --image "$IMAGE_DIR" \
  --share "$SEED_DIR" \
  --cpus 4 \
  --memory-mib 8192
```

#### Pure `headless`

Use this to reproduce failures, not as the default path:

```bash
"$CONTAINER_BIN" macos start-vm \
  --image "$IMAGE_DIR" \
  --share "$SEED_DIR" \
  --cpus 4 \
  --memory-mib 8192 \
  --headless
```

#### `headless-display`

No visible window, but keeps a graphics device. This is closer to the stable production path:

```bash
"$CONTAINER_BIN" macos start-vm \
  --image "$IMAGE_DIR" \
  --share "$SEED_DIR" \
  --cpus 4 \
  --memory-mib 8192 \
  --headless-display
```

### 5.3 Talk to guest-agent Directly: REPL over vsock

Start the manual VM with `--agent-repl`:

```bash
"$CONTAINER_BIN" macos start-vm \
  --image "$IMAGE_DIR" \
  --share "$SEED_DIR" \
  --cpus 4 \
  --memory-mib 8192 \
  --agent-repl \
  --agent-port 27000 \
  --agent-connect-retries 240
```

Useful commands:

```text
connect
connect-wait
sh /bin/ls /
exec /bin/echo hello
exec-tty /bin/sh
stdin echo hello
close
signal 15
resize 120 40
quit
```

Key signals to look for:

- `[agent-repl] vsock connect callback succeeded; waiting for ready frame...`
- `[ready] guest-agent is ready`
- `[stdout] ...`
- `[exit] code=0`

If you only see `connect callback succeeded` but never `[ready]`, the likely causes are:

- the guest did not send a `ready` frame
- or the host REPL read path is broken; this happened previously and was fixed by switching to `Darwin.read/write`

### 5.4 Non-Interactive Probe

Useful for scripts:

```bash
"$CONTAINER_BIN" macos start-vm ... --agent-probe --agent-port 27000
```

Expected behavior:

- success: `[agent-probe] success: guest-agent ready on port 27000`
- failure: the tool prints the stage where connection failed, for example `Code=54` or `ready timeout`
- exit code: `0` on success, non-zero on failure

Notes:

- with explicit pure `--headless`, the current image and agent combination may still hit repeated `Code=54`
- the same image usually works with `--headless-display`, which is the recommended mode for automated validation

### 5.5 Unix Socket Control Server

`start-vm` can start a control server with `--control-socket` for script-driven validation:

```bash
"$CONTAINER_BIN" macos start-vm \
  --image "$IMAGE_DIR" \
  --share "$SEED_DIR" \
  --cpus 4 \
  --memory-mib 8192 \
  --headless-display \
  --control-socket /tmp/macos-vm-manager.sock
```

Control commands sent over the Unix socket:

- `help`
- `probe`
- `exec <path> [args...]`
- `sh <command>`
- `quit`

This path is useful to prove:

- a GUI-domain sidecar can host the VM successfully
- the host can execute `probe` and `exec` over a control plane without depending on `container run`

## 6. Installing and Validating guest-agent Inside the Image

### 6.1 Install from the Seed Directory

```bash
sudo bash '/Volumes/My Shared Files/seed/install-in-guest-from-seed.sh'
```

### 6.2 Validate the Daemon and Logs

```bash
sudo launchctl print system/com.apple.container.macos.guest-agent | head -n 80
sudo tail -n 120 /var/log/container-macos-guest-agent.log
```

After a sandbox boots successfully through `container-runtime-macos`, the helper also starts a host-side mirror of the guest-agent log at:

- `<container-root>/guest-agent.log`

That mirror is best-effort. If bootstrap fails before the helper can start the background log follower, fall back to the in-guest path.

### 6.3 Run the Agent in the Foreground

This is the strongest isolation technique for debugging `ready` frame and daemon startup issues:

```bash
sudo launchctl bootout system/com.apple.container.macos.guest-agent || true
sudo /usr/local/bin/container-macos-guest-agent --port 27001
```

Then connect from the host-side REPL to port `27001`:

```text
connect
exec /bin/echo hello
```

If the foreground guest-agent logs show:

- `sending ready frame`
- `ready frame sent`
- `peer closed stream`

while the host still never sees `[ready]`, the host read path is the more likely problem.

## 7. Recommended `container run` Debugging Order

When `container run --os darwin` fails, do not immediately keep retrying `run`. This order narrows the issue quickly:

1. confirm that `container system` starts cleanly
2. validate guest-agent and REPL on a manual VM in GUI mode
3. run an A/B comparison between `headless` and `headless-display`
4. make sure the guest disk changes were flushed by a real shutdown, then re-run `package + image load`
5. verify that the plugin directory contains the updated binaries, not just `.build`
6. restart `container system`
7. retry `container run`

## 8. Common Errors and How to Locate Them

### 8.1 `container system start` Stuck on `Verifying apiserver is running...`

Possible causes:

- `launchctl bootstrap` used the wrong or outdated install path
- stale launchd units or mismatched plugin paths remain

Observed error:

```text
launchctl bootstrap gui/<uid> .../apiserver.plist failed with status 5
```

Recommendations:

- explicitly pass `--install-root "$PWD"`
- when needed, run `system stop` first and then `system start --disable-kernel-install`

### 8.2 `image load` Fails with `XPC connection error: Connection interrupted`

Usually means `container system` is not running or crashed mid-operation:

```text
Ensure container system service has been started with `container system start`.
```

Fix `container system start` first, then retry `image load`.

### 8.3 `image load` Fails with `failed to extract archive: failed to write data for ...`

Common causes:

- not enough disk space
- temporary directory or local storage corruption

Suggested response:

- clean up images first, for example with `image prune` or by deleting unused local tags
- remove unneeded OCI tar files such as `/tmp/macos-image-base-oci.tar`
- re-run `package` and `image load`

### 8.4 `container run` Fails with `Code=54 Connection reset by peer`

This is one of the most common failures. First classify the layer:

#### Case A: Manual VM + REPL Also Reproduces `Code=54`

Check:

- whether guest-agent is really listening on the target port
- whether the failure is in the connect callback or in `ready` timeout
- whether you are using `--headless`; pure headless frequently triggers this class of reset

#### Case B: Manual VM Works, but `container run` Fails

Check, in order:

1. the guest disk was shut down cleanly and repackaged
2. the image tag or digest used by `container run` really points at the latest packaged image
3. the plugin directory binaries were replaced and re-signed
4. `container system` was restarted

A common real-world failure mode is validating a new disk with a manual VM while `container run` still uses an older packaged image or older plugin binaries.

### 8.5 `containerCreate` XPC Timeout

Typical symptom:

```text
failed to create container
XPC timeout for request to com.apple.container.apiserver/containerCreate
```

One confirmed root cause:

- an old runtime or sidecar process is hung, for example in `process.start attempt 2`
- APIServer requests are blocked behind it, and later `containerCreate` calls time out

Recommended recovery:

1. update `container-runtime-macos` and `container-runtime-macos-sidecar` in the plugin directory
2. re-sign entitlements
3. run `container system stop`
4. run `container system start --install-root "$PWD" --disable-kernel-install`
5. retry `container run`

## 9. Log Collection Checklist

### 9.1 Unified Host Logs

```bash
"$CONTAINER_BIN" system logs --last 5m
```

Useful search terms:

- `container-runtime-macos`
- `RuntimeMacOSSidecar`
- `vm.connectVsock`
- `callback timed out`
- `process.start attempt`
- `containerCreate`

### 9.2 Helper Local Log (`stdio.log`)

Inspect the latest container directory:

```bash
d=$(ls -td "$HOME/Library/Application Support/com.apple.container/containers"/* | head -n 1)
echo "$d"
tail -n 200 "$d/stdio.log"
```

This typically shows:

- sidecar startup logs
- `process.start` retry progression
- wait and exit handling

### 9.3 Sidecar Logs

The sidecar's stdout and stderr are redirected by LaunchAgent into files under the container root, usually:

- `sidecar.stdout.log`
- `sidecar.stderr.log`

The container root is typically:

- `~/Library/Application Support/com.apple.container/containers/<container-id>/`

### 9.4 guest Logs

Check the host-side mirror first:

```bash
d=$(ls -td "$HOME/Library/Application Support/com.apple.container/containers"/* | head -n 1)
echo "$d"
tail -n 200 "$d/guest-agent.log"
tail -n 200 "$d/guest-agent.stderr.log"
```

The mirror is populated by a background `tail -F` process started by the helper after the VM boots and the guest-agent is reachable. It is the fastest way to inspect guest-agent output from the host without logging into the guest.

If the mirror is missing, empty, or bootstrap failed before the helper reached the log-follow step, inspect the canonical in-guest log directly:

```bash
sudo launchctl print system/com.apple.container.macos.guest-agent | head -n 80
sudo tail -n 200 /var/log/container-macos-guest-agent.log
```

Be careful not to misread stale logs:

- an older `Operation not supported by device` entry may still be present from a previous run
- if there is no new error after restart, only the latest time window matters

## 10. Packaging and Update Safety

### 10.1 Always Shut Down Before Packaging

If the VM is still running when `package` is executed, it is very easy to capture stale contents, especially for `Disk.img` and `AuxiliaryStorage`.

Correct order:

1. run `sudo shutdown -h now` inside the guest
2. confirm the VM process exits
3. then run `container macos package`

### 10.2 Verify That Repackaging Really Produced New Artifacts

Useful cross-checks:

- `OCI tar` modification time
- `IMAGE_DIR/Disk.img` modification time
- `IMAGE_DIR/AuxiliaryStorage` modification time
- compare digests if necessary

## 11. Disk Space Cleanup

When `image load` or packaging behaves unexpectedly, confirm disk space first.

For a full cleanup workflow, see:

- [`docs/macos-guest-space-cleanup.md`](docs/macos-guest-space-cleanup.md)

The minimum recommended order is still:

1. remove old OCI tar files first because they are easy to regenerate
2. then remove stopped containers and unused local images
3. only then remove `macos-guest-disk-cache`, `rebuild-cache`, and `macos-oci-layout-*` under `TMPDIR`

## 12. Representative Troubleshooting Timeline

The following sequence proved reusable in practice:

1. `container run` failed to connect to guest-agent with `Code=54`
2. a manual VM was used to validate the in-guest agent, and foreground agent logs looked healthy
3. suspicion moved to the protocol layer, so `container macos start-vm --agent-repl` was added for direct vsock access
4. a reconnect race and read/write path issue were found in the REPL and fixed by using `Darwin.read/write`
5. guest-agent dropped `stdout` and `exit` for short-lived commands such as `ls` and `echo`; fixed by installing callbacks before `process.run()`
6. pure `headless` proved unstable with `Code=54`, while `headless-display` worked
7. a GUI-domain sidecar experiment was built in `macos-vm-manager` using `control-socket`, and `probe` and `exec` succeeded
8. VM ownership moved into `container-runtime-macos-sidecar`
9. the process protocol was gradually migrated into higher-level sidecar methods: `process.start`, `stdin`, `signal`, `resize`, `close`, plus `stdout`, `stderr`, and `exit`
10. the older helper-side local VM and guest-agent frame handling code was removed
11. `containerCreate` later timed out again, and the root cause turned out to be an old sidecar still running from the plugin directory plus a stuck old container
12. deploying the new plugins, re-signing, and restarting `container system` restored the path

## 13. Fast Regression Checklist After Code Changes

### 13.1 Non-Interactive Run

```bash
"$CONTAINER_BIN" run --os darwin --rm "$LOCAL_REF" /bin/ls /
```

### 13.2 Streamed stdin

```bash
printf "hello-sidecar-stream\n" | \
  "$CONTAINER_BIN" run -i --os darwin --rm "$LOCAL_REF" /bin/cat
```

### 13.3 TTY Interaction

```bash
"$CONTAINER_BIN" run --os darwin -it --rm "$LOCAL_REF" /bin/bash
```

Inside the shell:

```bash
echo tty-ok
pwd
exit
```

### 13.4 stdout and stderr

```bash
"$CONTAINER_BIN" run --os darwin --rm "$LOCAL_REF" /bin/sh -lc 'echo out; echo err >&2'
```

## 14. Common Command Reference

### 14.1 Rebuild and Deploy the Runtime Plugins

```bash
xcrun swift build -c release --product container-runtime-macos --product container-runtime-macos-sidecar

cp .build/arm64-apple-macosx/release/container-runtime-macos \
  libexec/container/plugins/container-runtime-macos/bin/container-runtime-macos
cp .build/arm64-apple-macosx/release/container-runtime-macos-sidecar \
  libexec/container/plugins/container-runtime-macos/bin/container-runtime-macos-sidecar

codesign --force --sign - \
  --entitlements signing/container-runtime-macos.entitlements \
  libexec/container/plugins/container-runtime-macos/bin/container-runtime-macos
codesign --force --sign - \
  --entitlements signing/container-runtime-macos.entitlements \
  libexec/container/plugins/container-runtime-macos/bin/container-runtime-macos-sidecar

"$CONTAINER_BIN" system stop
"$CONTAINER_BIN" system start --install-root "$PWD" --disable-kernel-install
```

### 14.2 Incrementally Update guest-agent Inside the Image

```bash
xcrun swift build -c release --product container-macos-guest-agent
CONTAINER_MACOS_GUEST_AGENT_BIN="$PWD/.build/release/container-macos-guest-agent" \
CONTAINER_MACOS_GUEST_AGENT_SCRIPTS_DIR="$PWD/scripts/macos-guest-agent" \
"$CONTAINER_BIN" macos guest-agent prepare -o "$SEED_DIR" --overwrite

# Start a manual VM, then run inside the guest:
sudo bash '/Volumes/My Shared Files/seed/install-in-guest-from-seed.sh'
sudo shutdown -h now
```

### 14.3 Repackage and Reload the Image

```bash
"$CONTAINER_BIN" macos package \
  --input "$IMAGE_DIR" \
  --output "$OCI_TAR" \
  --reference "$LOCAL_REF"

"$CONTAINER_BIN" image load -i "$OCI_TAR"
```

## 15. Further Improvements

The current feature set is usable, but a few engineering items still remain:

- Swift 6 concurrency warnings in the sidecar around some `Virtualization` object captures on `DispatchQueue.main`
- log noise reduction while preserving important retry and failure information
- more test automation around manual debugging flows, such as scripted `headless` vs `headless-display` A/B checks

---

If you see `Code=54` or `containerCreate` XPC timeouts again, start with sections 4, 7, 8, 9, and 13 of this document. In most cases that is enough to identify whether the problem is in the image, plugin deployment, service state, guest-agent, or runtime context.
