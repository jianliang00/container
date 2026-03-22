# macOS Guest Dockerfile Build TODO

This document summarizes the current code state and breaks the work in
[`docs/macos-guest-dockerfile-build-design.md`](docs/macos-guest-dockerfile-build-design.md)
into an executable checklist. It highlights what is already done and what still remains.

## 1. Status Overview

### 1.1 Existing Foundation (Prerequisites, Not New in This Work)

- [x] macOS guest runtime can already boot and execute processes
  - `container run --os darwin`
  - sidecar + guest-agent path
- [x] macOS bundle packaging already exists
  - `container macos package`
  - v1 chunked OCI format
- [x] chunk rebuild before run already exists
  - `Disk.img` can be rebuilt from layout + chunks
- [x] the existing Linux `container build` path is still intact
  - BuildKit continues to own it

### 1.2 Implemented in the Current State

- [x] defined and implemented the `fs.begin / fs.chunk / fs.end` protocol payloads
- [x] added `fsBegin / fsChunk / fsEnd` methods to the sidecar control protocol
- [x] added file transaction APIs on the host side in `MacOSSidecarClient`
- [x] added `fsBegin / fsChunk / fsEnd` routes to the sandbox XPC path
- [x] guest-agent supports `write_file / mkdir / symlink`
- [x] `write_file` uses temporary file + atomic rename on commit
- [x] commit and abort are supported
- [x] small-file inline data is supported
- [x] large-file chunked write by offset is supported
- [x] optional digest verification is supported
- [x] protocol, client, and guest-side write tests are in place
- [x] `BuildCommand` dispatches darwin before any builder dial
- [x] `darwin/arm64` validation and mixed-platform rejection are wired in
- [x] the minimal `MacOSBuildEngine` path is integrated into `container build`
- [x] minimal Dockerfile planner, build context handling, `.dockerignore`, and host-side orchestration for `COPY/ADD(local)` are implemented
- [x] single-stage execution semantics for `RUN / WORKDIR / ENV / LABEL / CMD / ENTRYPOINT / USER` are integrated
- [x] per-stage temporary macOS build container creation, execution, and cleanup are connected in `--target` order
- [x] stage stop + package/export + `type=oci|tar|local` export are connected
- [x] `type=local` exports a macOS image directory on the darwin build path
- [x] `ContainerCommandsTests` and `CLITests` now cover darwin build dispatch, planner behavior, context handling, `COPY` destination semantics, error classification, and CLI rejection paths

### 1.3 Core Goals Already Completed

- [x] real darwin base image CLI and end-to-end acceptance coverage
- [x] integration test matrix for darwin build
- [x] finer-grained `COPY` destination semantics when the destination already exists as a file or directory
- [x] stronger host-side error classification for invalid symlinks and related cases
- [x] end-to-end CLI and E2E acceptance for phase 1

## 2. Detailed Work Already Completed

### 2.1 Protocol Definitions

- [x] added shared filesystem protocol types
  - file: `Sources/Helpers/RuntimeMacOSSidecarShared/SidecarFileSystemProtocol.swift`
  - contents:
    - `MacOSSidecarFSOperation`
    - `MacOSSidecarFSEndAction`
    - `MacOSSidecarFSBeginRequestPayload`
    - `MacOSSidecarFSChunkRequestPayload`
    - `MacOSSidecarFSEndRequestPayload`
- [x] extended the sidecar control request
  - file: `Sources/Helpers/RuntimeMacOSSidecarShared/SidecarControlProtocol.swift`
  - added:
    - `MacOSSidecarMethod.fsBegin`
    - `MacOSSidecarMethod.fsChunk`
    - `MacOSSidecarMethod.fsEnd`
    - `fsBegin / fsChunk / fsEnd` payloads on the request envelope

### 2.2 Host-Side Entry Points

- [x] `MacOSSidecarClient` now exposes file transaction APIs
  - file: `Sources/Helpers/RuntimeMacOS/MacOSSidecarClient.swift`
  - added:
    - `fsBegin(port:request:)`
    - `fsChunk(request:)`
    - `fsEnd(request:)`
- [x] sandbox client now wraps file-system routes over XPC
  - file: `Sources/Services/ContainerSandboxService/Client/SandboxClient+FileSystem.swift`
  - added:
    - `SandboxClient.fsBegin`
    - `SandboxClient.fsChunk`
    - `SandboxClient.fsEnd`
- [x] sandbox routes and keys registered
  - files:
    - `Sources/Services/ContainerSandboxService/Client/SandboxRoutes.swift`
    - `Sources/Services/ContainerSandboxService/Client/SandboxKeys.swift`
  - added:
    - `fsBegin`
    - `fsChunk`
    - `fsEnd`
    - `fsPayload`
- [x] runtime helper exposes the corresponding route
  - file: `Sources/Helpers/RuntimeMacOS/RuntimeMacOSHelper+Start.swift`

### 2.3 Sidecar Forwarding Implementation

- [x] added file transaction frame types to the guest-agent protocol stream
  - file: `Sources/Helpers/RuntimeMacOSSidecar/RuntimeMacOSSidecar.swift`
  - added:
    - frame types: `fsBegin / fsChunk / fsEnd / ack`
    - payload field mapping
- [x] sidecar now manages file transaction sessions
  - keyed by `txID`
  - separated from process stream sessions
- [x] sidecar supports:
  - opening a new vsock connection on `fs.begin`
  - waiting for guest readiness
  - forwarding the begin request
  - waiting for guest ack
  - closing immediately when `autoCommit=true`
  - keeping the transaction connection open when `autoCommit=false`
- [x] sidecar supports:
  - `fs.chunk` writes plus ack handling
  - `fs.end` commit or rollback plus ack handling
  - cleaning up transactions when the client disconnects
  - closing all filesystem sessions on `vm.stop` or `sidecar.quit`

### 2.4 Guest-Side File Materialization

- [x] guest-agent main loop handles filesystem transactions
  - file: `Sources/Helpers/MacOSGuestAgent/MacOSGuestAgent.swift`
  - added:
    - `beginFileTransaction`
    - `appendFileTransaction`
    - `finishFileTransaction`
- [x] extracted a standalone transaction type
  - file: `Sources/Helpers/MacOSGuestAgent/FileTransferTransaction.swift`
- [x] `write_file` semantics
  - create a temporary file
  - support inline data
  - support chunk writes by offset
  - optionally verify sha256 at commit
  - atomically rename to the final path on commit
  - clean up temporary files on failure or abort
- [x] `mkdir` semantics
  - create directories
  - allow metadata updates when the directory already exists
  - honor `overwrite` when the existing path is not a directory
- [x] `symlink` semantics
  - create symbolic links
  - honor `overwrite` when the destination already exists
- [x] metadata support
  - `mode`
  - `uid/gid`
  - `mtime`

### 2.5 Tests and Validation

- [x] protocol round-trip tests
  - file: `Tests/RuntimeMacOSSidecarSharedTests/SidecarControlProtocolTests.swift`
- [x] sidecar client request tests
  - file: `Tests/RuntimeMacOSSidecarClientTests/MacOSSidecarClientTests.swift`
- [x] guest file transaction materialization tests
  - file: `Tests/MacOSGuestAgentTests/GuestAgentFileTransferTransactionTests.swift`
- [x] verified commands
  - `xcrun swift build --product container-macos-guest-agent`
  - `xcrun swift test --filter RuntimeMacOSSidecarSharedTests`
  - `xcrun swift test --filter RuntimeMacOSSidecarClientTests`
  - `xcrun swift test --filter MacOSGuestAgentTests`
  - `xcrun swift test --filter MacOSBuildEngineTests`
  - `xcrun swift test --filter CLIMacOSBuildFailureTest`
  - `CONTAINER_ENABLE_MACOS_BUILD_E2E=1 CONTAINER_MACOS_BASE_REF=local/macos-base:agent-new xcrun swift test --filter CLIMacOSBuildE2ETest`
    - includes a positive `USER nobody` acceptance case

### 2.6 Build Mainline Integration

- [x] `BuildCommand` dispatches darwin before any builder dial
  - file: `Sources/ContainerCommands/BuildCommand.swift`
- [x] platform validation is now early
  - `darwin` only allows `arm64`
  - mixed and multi-target platforms are rejected
- [x] added `MacOSBuildEngine`
  - file: `Sources/ContainerCommands/MacOS/MacOSBuildEngine.swift`
- [x] added a minimal Dockerfile planner
  - supports: `FROM / ARG / ENV / WORKDIR / RUN / COPY / ADD(local) / LABEL / CMD / ENTRYPOINT / USER`
  - still rejects `ADD URL` explicitly
- [x] added build context and `.dockerignore` handling
  - enforces context-local paths, sorted enumeration, and traversal of directories, files, and symlinks
- [x] added host-side file transfer orchestration
  - maps `COPY/ADD(local)` to `mkdir / write_file / symlink`
  - small files use `inlineData + autoCommit`
  - large files use `begin -> chunk* -> end(commit)`
  - default chunk size is `256 KiB`
- [x] added the single-stage build runtime path
  - create a temporary macOS build container
  - keep the guest alive during the stage
  - execute `RUN` via the current sidecar + guest-agent path
- [x] packager now writes post-build image config
  - file: `Sources/ContainerCommands/MacOS/MacOSTemplatePackager.swift`
  - injected fields:
    - `ENV`
    - `WORKDIR`
    - `LABEL`
    - `CMD`
    - `ENTRYPOINT`
    - `USER`
- [x] `type=oci|tar|local` export paths are connected
- [x] added unit tests
  - file: `Tests/ContainerCommandsTests/MacOSBuildEngineTests.swift`

## 3. Phase 1 Checklist (Completed)

### 3.1 CLI Dispatch and Platform Validation

- [x] dispatch darwin in `BuildCommand` before any builder dial
- [x] validate that `darwin` only supports `arm64`
- [x] reject mixed and multi-target platforms
  - examples:
    - `linux/amd64,darwin/arm64`
    - `darwin/amd64`
- [x] keep Linux behavior unchanged
  - Linux still uses the existing BuildKit path
  - `ContainerCommandsTests` were run, and Linux build CLI/E2E coverage remains under the existing matrix

### 3.2 `MacOSBuildEngine`

- [x] added `Sources/ContainerCommands/MacOS/MacOSBuildEngine.swift`
- [x] defined engine inputs
  - context directory
  - Dockerfile data or path
  - build args
  - target stage
  - no-cache
  - output config
  - tags
- [x] defined engine outputs
  - the minimal output is an archive path
  - image load and tag finalization remain owned by `BuildCommand`
- [x] kept the engine independent from the Linux builder

### 3.3 Dockerfile Parsing and Planning

- [x] chose the parser or front-end reuse path
  - current implementation uses a minimal subset parser
  - reuse of an existing front-end can still be revisited later
- [x] supports the allowed phase-1 instructions
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
- [x] completed `USER`
  - the planner accepts `USER <name|uid[:gid]>`
  - `RUN` executes under the current stage user
  - the final image config writes `config.user`
- [x] explicitly rejects unsupported phase-1 syntax
  - `ADD URL`
  - `FROM <previous-stage>`
  - other unsupported advanced syntax
- [x] defined variable expansion rules
  - `ARG`
  - `ENV`
  - instruction argument substitution

### 3.4 Build Context and `.dockerignore`

- [x] added `BuildContextProvider`
- [x] reads and applies `.dockerignore`
- [x] ensures all host paths stay inside the build context
- [x] normalizes source enumeration and ordering
- [x] handles directories, regular files, and symlinks
- [x] defines `COPY` destination semantics
  - trailing `/`
  - destination exists vs does not exist
  - single file to file
  - multiple sources to directory
- [x] defines `ADD(local)` extraction behavior
  - unpack into a host staging directory
  - then reuse the same `fs` send path
- [x] expanded host-side error classification
  - escaped paths
  - missing files
  - invalid symlinks
  - no matches after ignore filtering

### 3.5 `COPY / ADD(local)` Integration with `fs`

- [x] added host-side transport orchestration
  - for example `MacOSBuildFileTransport`
- [x] maps directories to `mkdir`
- [x] maps regular files to `write_file`
- [x] maps symlinks to `symlink`
- [x] small files use `inlineData + autoCommit`
- [x] large files use `begin -> chunk* -> end(commit)`
- [x] defined the default chunk size
  - current default: `256 KiB`
- [x] rollback on failure
  - send `end(abort)` if a failure occurs after `begin`
- [x] digest strategy is in place
  - large files include sha256 on commit
  - small files use `autoCommit` and do not send a separate `fs.end`

### 3.6 Stage Execution Model

- [x] each stage creates a temporary macOS build container
  - current implementation creates, executes, and cleans them up stage by stage in `--target` order
  - current scope already supports cross-stage file reuse through `COPY --from`; `FROM <previous-stage>` remains later work
- [x] the guest stays alive for the lifetime of the stage
- [x] `FROM` resolves the base image
  - limited to `darwin/arm64`
- [x] `RUN` executes through the existing sidecar + guest-agent path
- [x] `WORKDIR`
  - ensures the directory exists in the guest
  - updates later default cwd
- [x] `ENV`
  - updates stage environment
  - passes into later `RUN`
  - persists to the final image config
- [x] `LABEL / CMD / ENTRYPOINT`
  - update the final image config
- [x] `ARG`
  - distinguished between parse-time and execution-time scope
- [x] target stage support
  - `--target`

### 3.7 Image Commit and Export

- [x] stop the stage build container
- [x] collect the three bundle files
  - `Disk.img`
  - `AuxiliaryStorage`
  - `HardwareModel.bin`
- [x] extend the packager so it can write post-build image config
  - `ENV`
  - `WORKDIR`
  - `LABEL`
  - `CMD`
  - `ENTRYPOINT`
- [x] `--output type=tar`
  - directly outputs macOS OCI tar
- [x] `--output type=oci`
  - generates tar
  - reuses existing `image load`
  - reuses existing `tag`
- [x] `--output type=local`
  - exports a macOS image directory
  - includes `Disk.img`
  - includes `AuxiliaryStorage`
  - includes `HardwareModel.bin`
- [x] defined behavior when `dest` is omitted

### 3.8 CLI and Integration Tests

- [x] added darwin build CLI tests
  - platform validation
  - unsupported syntax errors
  - `type=local` exported directory contents
- [x] added end-to-end tests for `COPY` and `ADD(local)`
  - covered in `CLITests`, gated by `CONTAINER_ENABLE_MACOS_BUILD_E2E=1`
  - default base image reference: `CONTAINER_MACOS_BASE_REF` or `local/macos-base:latest`
- [x] added `.dockerignore` coverage
  - uses the same env-gated darwin E2E path
- [x] added a basic `RUN sw_vers` build test
  - uses the same env-gated darwin E2E path
- [x] added `type=tar` export coverage
  - uses the same env-gated darwin E2E path
- [x] added `type=oci` import and tag coverage
  - uses the same env-gated darwin E2E path
- [x] added cleanup-on-failure coverage
  - [x] temporary container cleanup after interruption
  - [x] staging directory cleanup after interruption
  - [x] filesystem transaction cleanup after interruption in guest-agent unit tests
- [x] added non-CLI unit coverage
  - darwin dispatch in `BuildCommand`
  - minimal Dockerfile planner
  - build context and `.dockerignore`
  - `COPY/ADD(local)` destination resolution
  - invalid symlink and escaped source error classification
  - darwin build CLI rejection paths

## 4. Items Completed but Still Being Hardened

These are not missing features. They are engineering follow-up tasks on top of already integrated functionality.

### 4.1 `fs` Protocol Layer Enhancements

- [x] clearer file transaction logs in sidecar and guest-agent
  - `txID`
  - path
  - operation
  - commit or abort
- [x] clarified digest behavior on auto-commit paths
  - the host now sends sha256 even for small files using `inlineData + autoCommit`
  - the guest verifies the digest directly on the auto-commit path
- [x] tightened error code and message behavior
  - sidecar response codes now collapse into known `ContainerizationError` categories
  - `MacOSSidecarClient` and `SandboxClient+FileSystem` now preserve the original error category while adding container and transaction context

### 4.2 Test Coverage Hardening

- [x] added `mkdir` metadata tests
- [x] added digest mismatch tests
- [x] added `overwrite=false` tests
- [x] added sidecar transaction cleanup tests
  - `RuntimeMacOSSidecarTests` now covers owner client disconnect and chunk-ack failures
- [x] added temporary-file cleanup tests when the guest connection closes
- [x] added guest-agent malformed-frame coverage
  - invalid JSON frames now return `error + exit` and are covered in `MacOSGuestAgentTests`
- [x] added guest-agent TTY stdin-close EOF coverage
  - both the default TTY exec path and explicit-identity TTY exec path are covered in `MacOSGuestAgentTests`

### 4.3 `zstd` Dependency Cleanup

- [x] removed the runtime and helper dependency on an external `zstd` command and `PATH`
  - preferred path is now builtin or `libzstd` in `MacOSDiskRebuilder`
  - goal: `container run --os darwin` and pre-run chunk rebuild no longer depend on host shell environment
  - compatibility with existing `disk-chunk.v1.tar+zstd` images is preserved
- [x] removed the packaging and build dependency on an external `zstd` command
  - `MacOSDiskChunker` compression now uses builtin or `libzstd`
  - goal: `container macos package` and darwin `container build` do not require a separately installed host `zstd`
- [x] introduced a shared `zstd` codec and locator layer
  - avoids two separate behaviors and error models for compression and decompression
  - defines override, fallback, and diagnostics conventions
- [x] added `zstd` compatibility and regression tests
  - older chunk formats can be decompressed with the builtin path
  - builtin compressed output can be decompressed with the builtin path
  - corrupted frames and missing dependency paths now produce readable errors

### 4.4 Issues Already Resolved

- [x] after `image load`, the first `"$CONTAINER_BIN" run --os darwin --rm "$NEW_BASE_REF" /bin/ls /` used to produce no output
  - fixed by delivering `stdout`, `stderr`, and `exit` in sidecar event order
  - newly built images now produce output on the first `run --os darwin`

## 5. Deferred Phase 2 Work

- already completed early: `USER`
  - implemented through sidecar exec payload + guest-agent child-process identity switching
- [ ] continue stabilizing darwin runtime and guest-agent startup behavior
  - already reduced:
    - `containerCreate` and CLI hangs caused by APIServer `ContainersService` holding a lock across `await`; fixed
    - `macos start-vm --agent-probe` crash caused by calling `VZVirtioSocketDevice.connect(toPort:)` off the main thread; fixed
  - remaining:
    - pure `container macos start-vm --headless --agent-probe/--agent-repl` may still hit repeated `Code=54 Connection reset by peer`
    - the same image works under `--headless-display`, so the primary runtime path and the pure headless debug path should be evaluated separately
  - impact:
    - this still makes it harder to distinguish "pure headless debug tools are unstable" from "the main darwin runtime path is unstable"
  - next decision:
    - decide whether pure headless remains a reproduction mode only, or gains explicit failure or fallback behavior
- [ ] keep explicit `--runtime` override support so clients do not hard-code runtime names from platform inference
  - current issue: clients still require explicit `--runtime` to match the inferred built-in runtime
  - target: move platform compatibility and plugin capability checks into server-side or runtime metadata instead of blocking third-party runtimes
  - do not relax the current client-side conflict check before runtime capability metadata or equivalent server-side validation exists
- [x] fixed waiter lifecycle in `MacOSSandboxService.waitForProcess(timeout:)`
  - `wait` now returns `notFound` immediately when the process does not exist
  - timeout, `stop`, `shutdown`, and `closeAllSessions()` now clean up and wake outstanding waiters
  - covered by `MacOSSandboxServiceWaiterTests`
- [x] ignore `SIGPIPE` in `container-macos-guest-agent`
  - startup now sets `signal(SIGPIPE, SIG_IGN)`
  - prevents guest-agent from being killed when the host disconnects before `stdout`, `stderr`, or `exit` is written back
- [x] tightened guest-agent and shared frame parser robustness
  - shared, guest-agent, and VM-manager debugger paths now all use unaligned-safe frame length reads
  - guest-agent now reuses the shared `maxFrameSize` limit
  - oversized frame tests have been added
- [x] implement TTY `stdin close` semantics
  - host EOF continues to trigger `process.close`
  - the guest PTY path now propagates terminal EOF semantics on close without tearing down stdout or stderr early
  - guest-agent tests now cover the default TTY exec path and explicit-identity TTY exec path so interactive commands do not hang after input ends
- [ ] continue expanding automated tests for guest-agent and protocol failure paths
  - disconnect, EOF, request matching, and session cleanup are already covered in sidecar/shared/client tests
  - newly covered in guest-agent tests: malformed frames and TTY close / EOF handling
  - newly covered in sidecar client tests: pending request failure when the control connection closes before the response arrives
  - next focus: SIGPIPE and any remaining disconnect races outside the current guest-agent and sidecar coverage
- [ ] investigate intermittent darwin build hang after the guest `RUN` step completes
  - observed locally on 2026-03-21 while building from `ghcr.io/jianliang00/macos-base:26.3`
  - the stage container stopped, `container-runtime-macos-sidecar` logged `sidecar control reader failed: unexpected EOF`, and the host `container build` process remained stuck instead of surfacing success or failure
  - darwin build export now emits explicit packaging and chunk/tar progress so a long post-build package step is distinguishable from a real hang
  - check whether this is a post-build packaging stall, a missed sidecar EOF/error propagation path, or a cleanup ordering race in the darwin build engine
- [ ] `ADD URL`
  - host download
  - checksum and policy
  - blocked on defining checksum and policy semantics first; do not implement as an unchecked best-effort download
- [x] multi-stage `COPY --from`
  - current scope: supports copying files, directories, and symlinks from earlier stages by alias or index
  - current limitation: still does not support `FROM <previous-stage>` or wildcard sources in `COPY --from`
- [ ] stage-level cache
- [ ] export-path performance optimization
  - [ ] reuse parent-image chunk `rawDigest` at the same index
  - [ ] write `type=oci` directly into the content store and remove tar round-trips
  - [ ] replace repeated `/usr/bin/tar -rf` with a single tar writer or streaming writer
  - [ ] turn `Disk.img -> tar -> zstd -> sha256/size` into a single-pass streaming pipeline
  - [ ] avoid extra cross-volume copies between staging tar and final path for `type=tar`
  - [x] add progress reporting for the post-build packaging/compression phase so long chunking work does not look stalled
- [x] formal darwin semantics for `type=local`
- [ ] extend `fs` metadata operations
  - `chmod`
  - `chown`
  - `utime`
  - `rename`
  - `remove`

## 6. Recommended Implementation Order

### 6.1 Recommended Next Batch

- [x] `BuildCommand` darwin dispatch
- [x] `MacOSBuildEngine` framework
- [x] minimal Dockerfile planner
- [x] host orchestration for `COPY / ADD(local)`
- [x] single-stage `FROM + COPY + RUN + commit`
- [x] first make `zstd` decompression builtin in the runtime path so `container run --os darwin` no longer depends on host `PATH` or an external command
- [x] real darwin base image CLI and E2E build acceptance
- [x] continue aligning `COPY` destination-existing semantics
- [x] complete host-side invalid symlink and error classification coverage

### 6.2 Second Batch

- [x] image config injection
- [x] `type=oci / type=tar / type=local`
- [x] `.dockerignore`
- [x] `--target`
- [x] end-to-end CLI tests

### 6.3 Third Batch

These are still backlog themes rather than ready-to-code tasks. Split them into narrower acceptance-driven items before implementation.

- [ ] parser or front-end completeness
- [ ] multi-stage planning interfaces
- [ ] cache infrastructure hooks
- [ ] split out phase-2 capabilities

## 7. Phase 1 Completion Criteria

Note:

- This section is based on integration acceptance, not only code landing.
- Cleanup around `fs` protocol error codes and sidecar exception handling is still ongoing, but it no longer blocks phase-1 mainline acceptance.

Phase 1 can be considered complete when all of the following are true:

- [x] `container build --platform darwin/arm64` bypasses the Linux builder
- [x] supports `FROM / ARG / ENV / WORKDIR / RUN / COPY / ADD(local) / LABEL / CMD / ENTRYPOINT`
- [x] all `COPY / ADD(local)` materialization goes through the `fs` protocol
- [x] the guest does not rely on shared directories or guest-side `tar`
- [x] a new image can be built and committed from a base macOS image
- [x] `--output type=oci` imports into the local image store and can be tagged
- [x] `--output type=tar` exports a tar
- [x] `--output type=local` exports a macOS image directory suitable for `start-vm` and `macos package`
- [x] the core E2E test set passes reliably
