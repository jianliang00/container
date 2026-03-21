# macOS Guest Dockerfile Image Build Design (Based on the Current `container` Project)

This document proposes an implementation that allows the current project to build macOS images incrementally from Dockerfiles, much like Linux images, on top of the existing macOS guest runtime and chunked OCI image support. The input is a base image and a Dockerfile. The output is a new image.

Target scenarios include:

- continuing a build from an existing `darwin/arm64` base image
- installing tools such as Xcode and Homebrew
- creating users and switching users for later build steps
- reusing the result through standard image flows such as `load`, `push`, `pull`, and `run`

## 1. Background and Current State

Current capabilities relevant to this design:

- `container build` is currently centered on BuildKit and is positioned as the Linux build path.
- The macOS guest path already has:
  - `container run --os darwin` for boot and process execution
  - the sidecar + guest-agent protocol
  - `container macos package` for packaging `Disk.img`, `AuxiliaryStorage`, and `HardwareModel.bin` as OCI
  - the `disk-layout.v1 + disk-chunk.v1.tar+zstd` chunked format
  - runtime rebuild of chunks before startup

Current gaps:

- no Dockerfile-based macOS build executor
- no integrated "commit image from a modified running disk" flow
- no formal file injection protocol and guest-side executor for `COPY` and `ADD`

## 2. Goals and Non-Goals

### 2.1 Goals

1. Support `--platform darwin/arm64` in `container build`.
2. Use Dockerfile as the single build input, without introducing a new DSL.
3. Resolve `FROM` from an existing macOS OCI image, execute instructions, and commit the result as a new image.
4. Prioritize the following instruction subset in phase 1:
   - `FROM`, `ARG`, `ENV`, `WORKDIR`, `RUN`, `COPY`, `ADD(local)`, `USER`, `LABEL`, `CMD`, `ENTRYPOINT`
5. Add more complex instructions and semantics in phase 2:
   - `ADD(URL)` and multi-stage `COPY --from`
6. Support local `COPY` and `ADD` injection through a unified `fs` protocol instead of shared directories or guest-side tooling.
7. Support long-term incremental reuse:
   - stage-level cache
   - later evolution toward instruction-level cache
   - chunk blob reuse based on `rawDigest`

### 2.2 Non-Goals for the First Phase

1. Do not support the full BuildKit feature set in the first version, such as `RUN --mount=type=secret` or complete inline-cache semantics.
2. Do not support cross-platform or multi-architecture merged builds in the first version. Only `darwin/arm64` is supported.
3. Do not change the behavior of the existing Linux BuildKit path.
4. Do not support `ADD URL` or multi-stage `COPY --from` in the first version.
5. Do not promise fine-grained build cache in the first version. The first priority is a working end-to-end build flow.
6. Do not target headless CI in the first version. The current execution model still assumes a logged-in development machine.
7. Do not use shared directories or `virtiofs` as the build input path for `COPY` and `ADD`.

## 3. Overall Architecture

### 3.1 Build Entry Strategy

Keep a single entry point: `container build`.

- After `BuildCommand` parses `--platform`, `--os`, and `--arch`, dispatch immediately, before dialing or starting any BuildKit builder.
- `linux/*`: continue using the existing BuildKit path.
- `darwin/arm64` as a single target: dispatch to a new `MacOSBuildEngine`.
- Mixed or multi-target platform builds, for example `linux/amd64,darwin/arm64`: return an explicit error in the first phase rather than silently splitting the build.

This avoids making users learn a new command while preserving the Linux path.

### 3.2 Dockerfile Parsing Strategy

The first phase should avoid hand-writing a full Dockerfile parser or front-end.

1. Prefer reusing the existing Dockerfile parser or front-end, or at least an AST or expansion result compatible with it, rather than reimplementing syntax, variable expansion, and escaping rules.
2. Only guarantee support for the instructions listed in the matrix below. Return `unsupported` during parsing or planning for anything else.
3. Fall back to a minimal parser only if reuse is not available. Treat that implementation as phase-1-only, not a long-term direction.

### 3.3 New Core Components

1. `MacOSBuildEngine`
   - owns Dockerfile parsing, stage execution, and final commit
2. `MacOSDockerfileExecutor`
   - maps Dockerfile instructions to operations against a temporary macOS build container
3. `MacOSImageCommitter`
   - produces OCI output from the build container's disk artifacts by reusing the current packager and chunker
4. `MacOSBuildCache`
   - later manages stage-level cache and chunk reuse indexes
5. `BuildContextProvider`
   - normalizes the build context, after `.dockerignore`, into a transferable input set
6. `MacOSBuildFileTransport`
   - handles file transfer from host -> sidecar -> guest-agent using `fs.begin` / `fs.chunk` / `fs.end`

### 3.4 Runtime Object Relationships

1. Each Dockerfile stage corresponds to one temporary macOS build container running under `container-runtime-macos`.
2. Keep the VM alive for the lifetime of the stage to avoid cold-starting for every `RUN`.
3. In phase 1, commit only once at the end of the stage and use that as the stage output. Fine-grained instruction checkpoints are out of scope.
4. In phase 2, reuse stage outputs for multi-stage `FROM` and `COPY --from`.

For networking, these temporary build VMs stay on the compatibility backend (`virtualizationNAT`) in phase 1. They do not opt into `vmnetShared` until guest-side static networking exists independently of the runtime guest-agent path.

## 4. Instruction Semantics and Support Matrix

| Instruction | Phase 1 | Handling |
| --- | --- | --- |
| `FROM` | Yes | pull or resolve a `darwin/arm64` base image and create the stage root disk |
| `ARG` | Yes | maintain parse-time and execution-time variable tables |
| `ENV` | Yes | update stage environment and persist to later `RUN` steps and the image config |
| `WORKDIR` | Yes | ensure the directory exists in the guest and update the stage default cwd |
| `RUN` | Yes | execute through sidecar + guest-agent and capture exit status and logs |
| `COPY` | Yes | transfer over `fs` and materialize to the destination path using Dockerfile semantics |
| `ADD` (local) | Yes | unpack on the host and then transfer over `fs` |
| `ADD` (URL) | Phase 2 | download to a host temporary directory first so the operation stays auditable |
| `USER` | Yes | update the stage default user for later `RUN` steps and persist it into the image config |
| `LABEL` | Yes | write to the image config |
| `CMD` / `ENTRYPOINT` | Yes | write to the image config |
| Multi-stage `COPY --from` | Phase 2 | reserve the interface now and add it later |

## 5. `COPY` and `ADD` Input Injection (`fs` Protocol Only)

Decision: make `COPY` and `ADD` use the host <-> sidecar <-> guest-agent `fs` protocol as the single official path. Shared directories and guest-side `tar` extraction are not retained as supported solutions.

### 5.1 Design Decisions

1. Shared directories and `virtiofs` are not part of this design because they depend on guest-side access assumptions and interactive environments, which are a poor fit for the main non-interactive build path.
2. Guest-side `tar` extraction is not part of this design because it depends on guest image tooling and is difficult to stabilize as long-term behavior.
3. Therefore, protocol-driven file writes are the only supported path for `COPY` and `ADD(local)`.

### 5.2 Design Principles

1. Resolve paths, enforce whitelists, and reject path escapes on the host. The guest performs only controlled file operations.
2. The protocol is stream-oriented by default so it can support large files, retries, and backpressure.
3. Small files may be inlined to reduce round trips.
4. Use "temporary file + atomic rename" for writes so interrupted transfers do not leave partial results.
5. In phase 1, implement only the minimal operations required for `COPY` and `ADD(local)`. Do not turn this into a general-purpose filesystem RPC up front.

### 5.3 Protocol Model (Three Basic Operations)

1. `fs.begin`
   - input: `txId`, `op`, `path`, `mode`, optional `uid/gid`, optional `mtime`, optional `linkTarget`, `overwrite`, optional `inlineData`, optional `autoCommit` (default `false`), and related metadata
   - purpose: declare a filesystem transaction such as `write_file`, `mkdir`, or `symlink`. If `autoCommit=true` and no later chunks are needed, the operation may complete in a single request.
2. `fs.chunk`
   - input: `txId`, `offset`, `data`
   - purpose: stream data when needed, typically for `write_file` with `autoCommit=false`
3. `fs.end`
   - input: `txId`, `commit|abort`, optional `digest`
   - purpose: commit or roll back the transaction, with optional integrity verification on commit. Transactions with `autoCommit=true` may omit `fs.end`.

Required phase-1 operations: `write_file`, `mkdir`, `symlink`.

Possible later additions: `chmod`, `chown`, `utime`, `rename`, `remove`.

### 5.4 Transfer Strategy

1. Metadata-only operations, which means `mkdir` and `symlink` in phase 1, should default to a single `fs.begin(autoCommit=true)` request.
2. Small files, for example `<=256 KiB`, can use `inlineData` on `fs.begin`, ideally together with `autoCommit=true`, and skip `fs.chunk` and `fs.end`.
3. Large files should stream through `fs.chunk` with a suggested block size between `64 KiB` and `1 MiB`, defaulting to `256 KiB`, using the flow `fs.begin(autoCommit=false) -> fs.chunk* -> fs.end(commit)`.
4. Failed chunk writes should be retryable. Failed streamed transactions should use `fs.end(abort)` and clean up temporary files.

### 5.5 Instruction Mapping

1. `COPY`
   - expand and sort source files on the host
   - map directories, regular files, and symlinks to `fs` operations
   - materialize them according to Dockerfile destination semantics
2. `ADD` from a local tar archive
   - unpack into a temporary staging directory on the host
   - then reuse the same `fs` operation sequence
3. `ADD URL`
   - download and validate on the host
   - then feed the result through the same path as a regular file or archive

### 5.6 Phase 1 Scope

Phase 1 must deliver:

1. `RuntimeMacOSSidecarShared`
   - new `fs.begin`, `fs.chunk`, and `fs.end` methods and payload structures
2. `RuntimeMacOSSidecar`
   - new `fs` request dispatch and vsock forwarding
3. `MacOSGuestAgent`
   - support for `write_file`, `mkdir`, and `symlink`, including temporary writes, commit, and rollback
4. `MacOSSidecarClient` and `MacOSSandboxService`
   - an `fs` sending interface that reuses the current connection and error handling path
5. `MacOSBuildEngine`
   - unified `COPY` and `ADD(local)` transport over the `fs` protocol

### 5.7 Later Extensions

1. `RuntimeMacOSSidecarShared`
   - more metadata fields and operation kinds
2. `RuntimeMacOSSidecar`
   - concurrent windows, backpressure, and diagnostics
3. `MacOSGuestAgent`
   - `chmod`, `chown`, `utime`, `rename`, `remove`, and other extended operations
4. `MacOSSidecarClient` and `MacOSSandboxService`
   - stronger error classification and retry policy
5. `MacOSBuildEngine`
   - `ADD(URL)`, caching, and performance optimization on top of the protocol

## 6. User and Permission Model (`USER`)

The current implementation already wires `USER` semantics into the macOS build path:

1. The sidecar exec payload now includes `user`, `uid`, `gid`, and `supplementalGroups`.
2. Each build stage tracks the current default user. `USER <name|uid[:gid]>` updates the identity used by later `RUN` steps.
3. The guest-agent uses a child-process-only model that does not mutate daemon privileges. Before launching the child process it applies:
   - `setgid`
   - `setgroups` and supplemental group resolution
   - `setuid`
4. The final image config writes `config.user`, so a later `container run --os darwin` also inherits the same default user.

Current limitations:

1. Phase 1 supports `USER` execution semantics and image config persistence only. It does not provide wrappers such as `useradd` or `dscl`; user creation still belongs in earlier `RUN` steps.
2. `ADD URL` and multi-stage `COPY --from` remain later-phase work.

## 7. Image Commit and Format Reuse

### 7.1 Commit Target

Commit the current stage disk state, meaning `Disk.img`, `AuxiliaryStorage`, and `HardwareModel.bin`, as a new OCI image.

### 7.2 Commit Flow

1. Stop the stage build container.
2. Read the three bundle files from the container bundle.
3. Reuse the existing `MacOSImagePackager` and chunker to generate OCI tar, extending the packager if needed so it can accept image config metadata.
4. Write the image config, which in phase 1 includes `ENV`, `CMD`, `ENTRYPOINT`, `LABEL`, `WORKDIR`, and `USER`.
5. Reuse the current `image load` and `tag` flow to import into the local image store rather than introducing a standalone `commit` API up front.
6. If commit later needs to be shared by the API server or remote clients, factor it into an internal interface or add a dedicated route then.

### 7.3 Relationship to the Existing Chunked OCI Format

Reuse the current `disk-layout.v1 + disk-chunk.v1.tar+zstd` design directly. No new image format is introduced.

## 8. Cache and Incremental Build

### 8.1 Phase 1 Behavior

The first phase prioritizes a working end-to-end flow over fine-grained cache:

1. Keep only in-memory stage execution state within a single build. Do not persist instruction-level cache.
2. Repeated builds mainly reuse the existing base image, local image store, and OCI blob deduplication.
3. Keep `--no-cache` for CLI compatibility. On the darwin path in phase 1, it is equivalent to forcing a full rebuild.

### 8.2 Phase 2: Stage-Level Cache

Suggested cache key inputs:

- `FROM` digest
- normalized results of all supported instructions in the stage
- digests of related context files for `COPY` and `ADD(local)`
- relevant `ARG`, `ENV`, and `WORKDIR` state

When the key matches, skip the entire stage and reuse a previously committed stage image.

### 8.3 Phase 2: Chunk-Level Reuse

Add a "compare with parent layout" mode to `MacOSDiskChunker`:

1. compute `rawDigest` for the current chunk
2. if the current chunk matches the parent image chunk at the same index, reuse the parent's `layerDigest/layerSize`
3. only re-run tar + zstd for changed chunks

Benefit: pushing uploads only changed chunks, which matters for large iterative images such as Xcode and Homebrew environments.

### 8.4 Phase 3: Instruction-Level Cache

Instruction-level cache depends on indexing intermediate checkpoints after each cacheable instruction. That should not be promised in phase 1. Add it only after stage-level cache is stable.

## 9. Integration with Existing Commands and Services

### 9.1 CLI

Keep `container build`.

- add validation that `darwin` only supports `arm64`
- perform darwin dispatch before any BuildKit builder dial
- in phase 1 continue supporting `-f`, `-t`, `--build-arg`, `--target`, `--no-cache`, and `--output`
- define phase-1 `--output` behavior as follows:
  - `type=oci`: supported; `MacOSBuildEngine` generates OCI tar and then reuses the current `image load` and `tag` path
  - `type=tar`: supported; outputs the packager tar directly
  - `type=local`: supported; exports a macOS image directory containing at least `Disk.img`, `AuxiliaryStorage`, and `HardwareModel.bin`, suitable for `container macos start-vm` and `container macos package`

### 9.2 API Server and Images Service

Do not require a new `commit` route in phase 1.

1. `MacOSBuildEngine` can close the loop by reusing the packager and current `image load` and `tag` flows.
2. Only factor out a reusable commit interface or add a route if the API server later needs to commit a running macOS container.

### 9.3 Compatibility

Continue reading both existing image shapes:

- v0: a single `disk-image` layer
- v1: chunked layout

Build output should standardize on v1.

## 10. Reliability, Security, and Runtime Assumptions

### 10.1 Runtime Assumptions

1. The host must be Apple Silicon, and the image target stays fixed at `darwin/arm64`.
2. The current macOS sidecar execution model depends on a logged-in GUI or Aqua session. The first-phase target environment is a local development machine, not headless CI.
3. If unattended build support becomes necessary later, it should come from a separate sidecar and VM startup design, not by silently stretching the current interactive LaunchAgent model.

### 10.2 Reliability

1. If the stage VM crashes, fail the build and retain diagnostic logs.
2. Clean up temporary containers and mount directories after interruption.
3. Support timeout parameters for long-running steps such as Xcode extraction.

### 10.3 Security

1. `COPY` and `ADD(local)` must use the `fs` protocol as the default and only input path.
2. The host must apply build context allowlists, `.dockerignore`, and path escape validation before sending data.
3. The guest should perform only controlled write operations and should not expose shared directories as a build input surface.
4. Host paths must stay strictly inside the build context.
5. `ADD URL` should later enforce a configurable protocol and domain policy.

## 11. Phased Implementation Plan

### Phase 1 (MVP)

1. Dispatch `container build --platform darwin/arm64` to `MacOSBuildEngine` before any builder dial.
2. Support only the controlled Dockerfile subset:
   `FROM`, `ARG`, `ENV`, `WORKDIR`, `RUN`, `COPY`, `ADD(local)`, `USER`, `CMD`, `ENTRYPOINT`, `LABEL`.
3. Fail unsupported syntax, including `ADD URL` and `COPY --from`, during parsing or planning.
4. Implement the baseline `fs` protocol: `fs.begin`, `fs.chunk`, `fs.end`.
5. Implement guest-side `write_file`, `mkdir`, and `symlink`.
6. Route all `COPY` and `ADD(local)` writes through `fs`, with no shared-directory or `tar+stdin` fallback.
7. Commit a new image that can be `run` and `push`ed.
8. Support `--output type=oci|tar|local`, where `type=local` exports a runnable macOS image directory.

### Phase 2 (Enhancements)

1. multi-stage `COPY --from`
2. policy-controlled `ADD URL`
3. stage-level cache
4. chunk `rawDigest` reuse
5. expanded `fs` operation types and error model
6. improvements to `type=local` output semantics as needed

### Phase 3 (Optimization)

1. parallel chunk compression
2. build failure recovery and partial reuse
3. `fs` transfer performance optimization with concurrent windows, backpressure, and adaptive chunks
4. instruction-level cache
5. broader Dockerfile feature parity based on priority

## 12. Acceptance Criteria

### 12.1 Phase 1 Acceptance

The following scenarios must pass:

1. Basic build
   - `FROM local/macos-base:latest`
   - `RUN sw_vers`
   - the output image runs successfully with `container run --os darwin`
2. Tool installation
   - a Dockerfile installs Homebrew and `brew --version` succeeds
3. Context copy
   - `COPY` and `ADD(local)` materialize correctly through the `fs` protocol
   - `.dockerignore` is enforced
   - guest-side `tar` or shared directories are not required
4. User switching
   - `USER nobody`
   - a later `RUN id -un` prints `nobody`
   - the final image config stores the correct `User`
5. Output contract
   - `--output type=oci` imports successfully and can be tagged
   - `--output type=tar` exports a valid tar

### 12.2 Additional Phase 2 Acceptance

1. Remote input
   - `ADD URL` obeys policy control and remains verifiable
2. Multi-stage copy
   - `COPY --from` retrieves files correctly from previous stages
3. Incremental reuse
   - after changing a small number of files, a rebuild changes only a small number of chunks

## 13. Example Dockerfile

```dockerfile
FROM local/macos-base:latest

ENV HOMEBREW_NO_ANALYTICS=1
WORKDIR /opt/setup

COPY scripts/ /opt/setup/scripts/
RUN /bin/bash /opt/setup/scripts/install-homebrew.sh

RUN brew --version
CMD ["/bin/zsh"]
```

## 14. Risks and Open Questions

1. `USER` depends on the new guest child-process launch model; future changes must keep daemon privilege state isolated.
2. Reproducible `ADD URL` semantics require a checksum strategy to handle content drift.
3. If the Dockerfile parser cannot reuse an existing front-end, phase-1 implementation cost rises substantially.
4. The current sidecar still depends on a logged-in GUI or Aqua session. Headless CI support remains a separate problem.
5. Moving the baseline `fs` protocol earlier in the architecture means throughput, transaction overhead, and failure recovery need early validation.
6. Xcode install time and license-handling should be standardized through scripts.
7. macOS builds are resource-intensive, so default CPU, memory, and concurrency limits need to be defined.

---

This design aims for minimal disruption to the current codebase: Linux BuildKit stays unchanged, the macOS incremental engine evolves independently, and the image format keeps using the current chunked OCI layout for faster delivery and compatibility.
