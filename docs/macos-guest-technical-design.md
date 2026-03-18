# macOS Guest Runtime Technical Design (Current Implementation)

This document is for developers who need to maintain or extend the macOS guest feature set. It explains the current architecture, main data flows, control protocols, concurrency model, and known constraints.

This document focuses on technical design details. For image creation and day-to-day troubleshooting workflows, see:

- `docs/macos-guest-local-validation-guide.md`
- `docs/macos-guest-development-debugging.md`

## 1. Goals and Background

### 1.1 Goals

For `container run --os darwin`, provide a stable implementation for:

- VM start and stop
- guest process execution, both TTY and non-TTY
- stdio streaming
- signal, resize, and close handling
- `dial`, meaning guest connections over vsock

### 1.2 Background Problem: Why a Sidecar Was Needed

In earlier implementations, the `container-runtime-macos` helper process hosted `VZVirtualMachine` directly and connected to the guest-agent over vsock from inside the helper. In real deployment environments, especially XPC helper and background launch contexts, this led to stability problems:

- `VZVirtioSocketDevice.connect(toPort:)` callbacks could fail or behave inconsistently
- a common error was `NSPOSIXErrorDomain Code=54 "Connection reset by peer"`
- purely headless startup paths noticeably affected guest-agent availability

After several rounds of experiments, the project converged on:

- a **GUI-domain LaunchAgent sidecar that hosts the VM**
- **no local window, but a graphics device remains present** (`headless-display`)
- a `container-runtime-macos` helper that keeps only XPC and container session management responsibilities

## 2. Implementation Overview

### 2.1 Component Split

The current implementation has three layers:

1. `container-runtime-macos`
   - helper process and XPC `SandboxService` implementation
2. `container-runtime-macos-sidecar`
   - GUI-domain LaunchAgent that hosts `VZVirtualMachine`
3. `container-macos-guest-agent`
   - LaunchDaemon running inside the guest

### 2.2 Key Code Locations

- helper routes and session management:
  `Sources/Helpers/RuntimeMacOS/MacOSSandboxService.swift`
- helper-side sidecar lifecycle and LaunchAgent management:
  `Sources/Helpers/RuntimeMacOS/MacOSSandboxService+Sidecar.swift`
- helper-side sidecar control client:
  `Sources/Helpers/RuntimeMacOS/MacOSSidecarClient.swift`
- sidecar process main entry, control server, VM management, and guest-agent adapter:
  `Sources/Helpers/RuntimeMacOSSidecar/RuntimeMacOSSidecar.swift`
- shared helper/sidecar control protocol and socket I/O:
  `Sources/Helpers/RuntimeMacOSSidecarShared/SidecarControlProtocol.swift`
- SwiftPM target definitions:
  `Package.swift`

### 2.3 Design Principles

- keep helper behavior stable at the upper XPC API boundary, meaning the `SandboxService` routes do not change
- expose a high-level process control protocol from the sidecar to the helper, rather than leaking guest-agent protocol details
- keep `dial` compatible by still returning `FileHandle`, with file descriptors transferred via `SCM_RIGHTS`
- run the sidecar in the GUI domain with an `NSApplication` run loop, but without showing a local window

## 3. Why GUI Sidecar + Headless Display

### 3.1 Main Practical Findings

Repeated testing showed:

- pure `headless`, meaning no graphics device, can cause guest-agent vsock connection resets for some images
- "no visible window, but keep a graphics device" is materially more stable
- even if a helper or XPC context keeps a graphics device, hosting the VM directly there can still behave differently from `container macos start-vm`

The current design therefore fixes the startup model to:

- start the sidecar in the GUI domain, `gui/<uid>`
- use `NSApplication.shared` with `.prohibited`
- always include `graphicsDevices` in the VM configuration

### 3.2 Runtime Modes

- `container-runtime-macos-sidecar`: default runtime path, using headless-display
- `container macos start-vm --headless-display`: reproduction and validation path
- `container macos start-vm --headless`: kept as a debugging and reproduction tool, not a recommended runtime path

## 4. Build and Packaging Integration

### 4.1 SwiftPM Targets

Relevant targets include:

- `container-runtime-macos-sidecar` (executable)
- `RuntimeMacOSSidecarShared` (internal shared target)

See `Package.swift` for the target definitions.

### 4.2 Deployment Paths

The runtime binaries actually loaded at run time live under:

- `libexec/container/plugins/container-runtime-macos/bin/container-runtime-macos`
- `libexec/container/plugins/container-runtime-macos/bin/container-runtime-macos-sidecar`

Updating only `.build/...` is not enough. The binaries must be copied into the plugin directory, re-signed, and then `container system` must be restarted.

## 5. Helper (`MacOSSandboxService`) Responsibilities and State Model

### 5.1 External Interface (XPC Routes)

`MacOSSandboxService` continues implementing the `SandboxService` routes, including:

- `bootstrap`
- `createProcess`
- `startProcess`
- `wait`
- `kill`
- `resize`
- `stop`
- `shutdown`
- `state`
- `dial`
- `statistics`

The route implementations live in `Sources/Helpers/RuntimeMacOS/MacOSSandboxService.swift`.

### 5.2 Helper Internal State

`MacOSSandboxService` is an actor and uses `State` to manage container lifecycle:

- `created`
- `booted`
- `running`
- `stopping`
- `stopped(Int32)`
- `shuttingDown`

This is distinct from the sidecar VM state. The sidecar only manages VM lifecycle, while the helper also owns container session semantics and XPC behavior.

### 5.3 Session Model

Each process session in the helper stores host-visible state:

- `processID`
- `ProcessConfiguration`
- `stdio`, as a triple of optional host `FileHandle`
- `stdinClosed`, to prevent duplicate `process.close`
- `started`
- `exitStatus`
- `lastAgentError`

The helper no longer holds guest-agent vsock file descriptors, read loops, or frame buffers directly.

### 5.4 `wait` and `completeProcess` Consistency

The helper maintains:

- `sessions: [String: Session]`
- `waiters: [String: [CheckedContinuation<ExitStatus, Never>]]`

When a sidecar `process.exit` event arrives, the helper:

1. updates `session.exitStatus`
2. closes stdio handles for that session
3. resumes all waiting continuations

This avoids race conditions for short-lived commands such as `ls` or `echo`.

## 6. Sidecar Startup and LaunchAgent Lifecycle

### 6.1 Sidecar Launch Domain

The helper explicitly chooses the GUI domain:

- `gui/\(getuid())`

It does not rely on implicit launchd context inference.

### 6.2 LaunchAgent Metadata

The helper writes a sidecar plist under the container root. Typical fields include:

- `Label`: `com.apple.container.runtime.container-runtime-macos-sidecar.<sandbox-id>`
- `ProgramArguments`: sidecar path plus `--uuid`, `--root`, and `--control-socket`
- `LimitLoadToSessionType = Aqua`
- `ProcessType = Interactive`
- `StandardOutPath`
- `StandardErrorPath`

Relevant implementation:

- `writeSidecarLaunchAgentPlist(...)` in `MacOSSandboxService+Sidecar.swift`

### 6.3 Socket and Log Paths

Current paths:

- control socket: `/tmp/ctrm-sidecar-<sandbox-id>.sock`
- sidecar stdout and stderr: log files under the container root

### 6.4 Startup Sequence (`helper -> sidecar`)

High-level `bootstrap` flow:

1. helper prepares the container bundle, including cloned or copied image files plus config
2. helper opens container `stdio.log` and `vminitd.log`
3. helper writes the sidecar LaunchAgent plist
4. helper performs best-effort cleanup of any old unit via `bootout` and removes any stale socket
5. helper runs `launchctl bootstrap gui/<uid> ...`
6. helper creates `MacOSSidecarClient`
7. helper connects to the control socket and sends `vm.bootstrapStart`
8. sidecar starts the VM and returns `ok`
9. helper moves the container state to `booted`

### 6.5 Stop Sequence (`helper -> sidecar`)

`stop` and `shutdown` perform the following:

1. if the init process is still running, send a signal and wait for exit
2. call `stopAndQuitSidecarIfPresent()`, which runs:
   - `vm.stop`
   - `sidecar.quit`
   - `launchctl bootout gui/<uid>/<label>`
   - close the helper-side control connection
3. close stdio for all sessions and clear the session map

## 7. Sidecar Control Protocol (`helper <-> sidecar`)

Shared definitions live in:

- `Sources/Helpers/RuntimeMacOSSidecarShared/SidecarControlProtocol.swift`

### 7.1 Transport Layer

- Unix domain stream socket
- frame format: `uint32(big-endian length)` followed by JSON payload
- the main control connection is persistent and owned by `MacOSSidecarClient`
- `vm.connectVsock` uses a short-lived dedicated connection and returns file descriptors via `SCM_RIGHTS`

### 7.2 Envelope Model

All JSON payloads are wrapped in `MacOSSidecarEnvelope` with:

- `kind = request`
- `kind = response`
- `kind = event`

### 7.3 Request Model

Important `MacOSSidecarRequest` fields include:

- `requestID`
- `method`
- `port`
- `processID`
- `exec`
- `data`
- `signal`
- `width`
- `height`

The protocol currently uses a sparse-field model. Different methods consume different subsets of fields.

### 7.4 Response Model

`MacOSSidecarResponse` contains:

- `requestID`
- `ok`
- `fdAttached`
- `error { code, message, details }`

Notes:

- the protocol no longer uses `vm.state`
- responses no longer carry a `state` field

### 7.5 Event Model

The current `MacOSSidecarEventType` set includes:

- `process.stdout`
- `process.stderr`
- `process.exit`
- `process.error`

These events are carried by `MacOSSidecarEvent`, with:

- `processID`
- `data` for stdout or stderr
- `exitCode`
- `message`

### 7.6 Supported Helper-Visible Methods

- `vm.bootstrapStart`
- `vm.connectVsock`
- `process.start`
- `process.stdin`
- `process.signal`
- `process.resize`
- `process.close`
- `vm.stop`
- `sidecar.quit`

## 8. `SCM_RIGHTS` File Descriptor Passing (`dial` and `vm.connectVsock`)

### 8.1 Goal

Keep the helper-side `dial` contract unchanged, still returning `FileHandle`, while moving the actual VM vsock connection into the sidecar.

### 8.2 Implementation

Shared `MacOSSidecarSocketIO` implements:

- `sendFileDescriptorMarker(...)`
- `sendNoFileDescriptorMarker(...)`
- `receiveOptionalFileDescriptorMarker(...)`

Protocol behavior:

1. the sidecar sends a 1-byte marker on the control socket indicating whether an fd is attached
2. when present, the fd is attached with `SCM_RIGHTS`
3. the sidecar then sends the JSON response envelope

`MacOSSidecarClient.connectVsock(port:)` works as follows:

1. open a temporary control socket connection
2. send a `vm.connectVsock` request
3. receive the fd marker and optional file descriptor first
4. receive the JSON response
5. validate `requestID` and `ok`
6. wrap the fd as `FileHandle` and return it

### 8.3 Why `vm.connectVsock` Uses a Separate Connection

`SCM_RIGHTS` plus response pairing is simpler and less error-prone on a one-request-per-connection path than on a persistent connection that is also carrying event traffic.

## 9. Sidecar Internal Structure

`container-runtime-macos-sidecar` has two main layers:

1. `MacOSSidecarService`
   - actor that manages VM lifecycle
2. `SidecarControlServer`
   - multi-threaded Unix socket server that handles the control protocol and process streams

### 9.1 Entry Point and Runtime Environment

Entry point:

- `@MainActor @main struct RuntimeMacOSSidecar`

Behavior:

- parses `--uuid`, `--root`, and `--control-socket` with `ArgumentParser`
- initializes `NSApplication.shared`
- sets `activationPolicy = .prohibited`
- starts the control server on the main thread
- enters the `NSApplication` run loop

The sidecar logs host context information such as screens, session, and launch label to help diagnose GUI-domain issues.

### 9.2 `MacOSSidecarService` (VM Actor)

Responsibilities:

- load `config.json`
- build `VZVirtualMachineConfiguration`
- create, start, and stop `VZVirtualMachine` on the main thread
- execute `connectVsock(port:)`

State:

- `created`
- `running`
- `stopped`

### 9.3 VM Configuration

The sidecar uses the image files under the container root:

- `Disk.img`
- `AuxiliaryStorage`
- `HardwareModel.bin`
- `MachineIdentifier.bin`, created if missing

The VM configuration includes:

- `VZMacOSBootLoader`
- `VZMacPlatformConfiguration`
- `VZVirtioBlockDeviceConfiguration`
- `VZNATNetworkDeviceAttachment`
- `VZVirtioSocketDeviceConfiguration`
- `VZMacGraphicsDeviceConfiguration`

Key points:

- `graphicsDevices` are always configured
- `createGraphicsDevice()` prefers `NSScreen.main` and then `NSScreen.screens.first`
- if no screen exists, a fixed-pixel fallback configuration is used

### 9.4 `connectVsock` Timeout Guard

Inside the sidecar, `connectVsock(port:)` calls:

- `connectSocketOnMainWithTimeout(... timeoutSeconds: 3)`

Why:

- `VZVirtioSocketDevice.connect(toPort:)` callbacks may never return in some failure modes
- without a timeout guard, one failed `process.start` attempt can hang forever and block `containerCreate`

Implementation notes:

- `CompletionGate` ensures only one completion wins, whether it is the callback or the timeout
- timeout returns `ContainerizationError(.timeout, ...)`
- if the callback succeeds after timeout, the late connection is closed immediately to avoid fd leaks

## 10. `SidecarControlServer`: Control Protocol and Process Stream Bridge

### 10.1 Why Not Handle All Socket I/O in an Actor

The current model is intentionally mixed:

- VM lifecycle uses an actor: `MacOSSidecarService`
- control sockets and process stream sockets use threads plus locks

Reasons:

- the control protocol needs synchronous request/response behavior and fd passing via `SCM_RIGHTS`
- guest-agent process streams need their own blocking reads
- this maps naturally onto the existing helper model that synchronously waits for results

### 10.2 Basic Control Server Structure

`SidecarControlServer` maintains:

- `listenFD`
- `eventClientFD`, the current event receiver
- `processSessions: [processID: ProcessStreamSession]`
- several locks around listener state, event state, process state, and writes

### 10.3 `eventClientFD` Semantics

The current design uses a single event subscriber:

- when a non-`vm.connectVsock` request arrives, that `clientFD` becomes `eventClientFD`
- `process.stdout`, `process.stderr`, `process.exit`, and `process.error` events are always sent to `eventClientFD`

This works with the current helper implementation because the helper keeps one persistent control connection that handles both requests and events.

### 10.4 `process.start` Bridging to guest-agent

The sidecar handles `process.start` as follows:

1. obtain a guest-agent vsock fd through `MacOSSidecarService.connectVsock(port:)`
2. wait for the guest-agent `ready` frame, with a 3-second timeout
3. send the internal `exec` frame (`SidecarGuestAgentFrame.exec`)
4. register a `ProcessStreamSession`
5. launch a dedicated `processReadLoop` thread

If any step fails:

- the fd is closed
- an error response is returned to the helper

### 10.5 Process Stream Event Emission

`processReadLoop` continuously reads `SidecarGuestAgentFrame` values from the guest-agent fd:

- `stdout` -> emit `process.stdout`
- `stderr` -> emit `process.stderr`
- `error` -> emit `process.error`
- `exit` -> emit `process.exit` and stop the loop

On unexpected EOF or read errors:

- a `process.error` event may be emitted
- in a `defer` block, if no exit event has been sent yet, synthesize `process.exit(code=1)`

This guarantees that helper-side `wait` will not hang forever.

### 10.6 Process Control Bridging

`process.stdin`, `process.signal`, `process.resize`, and `process.close` all:

- look up `processSessions[processID]`
- acquire the session `writeLock`
- write the corresponding internal `SidecarGuestAgentFrame`

## 11. Helper <-> Sidecar Timing on Critical Paths

### 11.1 High-Level `container run --os darwin ...` Flow

Simplified sequence:

1. API server calls helper `bootstrap`
2. helper prepares the container root and image files
3. helper starts the sidecar LaunchAgent
4. helper sends `vm.bootstrapStart`
5. API server calls `createProcess` for the init process
6. API server calls `startProcess`
7. helper sends sidecar `process.start`, with retries
8. sidecar connects to guest-agent, waits for `ready`, and sends `exec`
9. sidecar emits `process.stdout`, `process.stderr`, and `process.exit`
10. helper writes to host stdio and resumes `wait` when `process.exit` arrives

### 11.2 Simplified `dial` Flow

1. API server calls helper `dial`
2. helper sends sidecar `vm.connectVsock`
3. sidecar connects to the requested vsock port inside the VM
4. sidecar returns the fd to the helper via `SCM_RIGHTS`
5. helper wraps the fd in `FileHandle` and returns it to the caller

## 12. Retries, Timeouts, and Error Propagation

### 12.1 Helper `process.start` Retry Policy

The helper retries sidecar `process.start` in `startProcessViaSidecarWithRetries(...)`:

- max attempts: 240
- interval: 500 ms
- total window: about 120 seconds

This is mainly for the period right after guest boot, while guest-agent is not ready yet.

### 12.2 Sidecar Single-Attempt Timeout Policy

Sidecar uses separate timeouts for one attempt:

- `vsock connect callback` timeout: 3 seconds
- guest-agent `ready` frame timeout: 3 seconds

This keeps one bad callback from blocking the entire helper flow and allows retries to continue.

### 12.3 Error Propagation Chain

Typical path:

sidecar internal error -> sidecar `response.error` -> helper `MacOSSidecarClient.validate(...)` -> `ContainerizationError(.internalError, ...)` -> XPC reply -> CLI

For `startProcess`, the helper further enriches the error with:

- the guest-agent vsock port
- a hint to inspect guest logs under `/var/log/container-macos-guest-agent.log`

## 13. Concurrency Model and Synchronization

### 13.1 Helper: Actor-Led

`MacOSSandboxService` is an actor:

- `sessions`, `waiters`, and sandbox state are actor-isolated
- host stdin `readabilityHandler` callbacks call back into the actor with `Task { await service.forwardHostStdin(...) }`

### 13.2 Sidecar Client: Threads and Locks

`MacOSSidecarClient` uses:

- one reader thread that continuously reads envelopes
- `stateLock` to protect `controlFD`, `pending`, and `eventHandler`
- `writeLock` to serialize writes on the control connection
- `PendingResponse` plus `DispatchSemaphore` for synchronous request/response waits

### 13.3 Sidecar Control Server: Threads and Locks plus VM Actor

`SidecarControlServer` uses:

- one accept loop thread
- one handler thread per client
- one read thread per process stream
- VM operations bridged into `MacOSSidecarService` through `sync` and `syncValue`

Benefits:

- guest-agent fd stream handling stays straightforward
- works naturally with `SCM_RIGHTS` and synchronous control requests

Trade-off:

- there are more locks, so consistency around `eventClientFD` and `processSessions` needs care

## 14. Compatibility and Constraints

### 14.1 Current Assumptions

- one container corresponds to one sidecar process
- the helper uses one primary persistent control connection for request, response, and event traffic
- `eventClientFD` is a single event subscriber, not a multicast bus

### 14.2 Known Limitations

- the sidecar still has some Swift 6 concurrency warnings around `Virtualization` object capture on main-thread closures
- the protocol is internal and has no version negotiation
- the `eventClientFD` model is not suitable for future multi-client event observation
- the sidecar control server still uses a thread model instead of a pure actor architecture

### 14.3 Explicit Non-Goals of the Current Version

- exposing the sidecar control protocol publicly
- supporting multiple helpers sharing one sidecar
- promising a stable pure-headless runtime mode

## 15. Key Failure Scenarios and How to Investigate Them

### 15.1 `containerCreate` XPC Timeout

Common causes:

- an old sidecar is stuck in `process.start`, for example because a `connect` callback never returns
- helper or API server requests are blocked behind that stuck state

Useful signals:

- container `stdio.log` stalls at `sidecar process.start attempt N/...`
- sidecar logs show `control request received [method=process.start]` with no matching completion log

### 15.2 `Code=54 reset by peer`

First classify the layer where it happens:

- sidecar `vm.connectVsock` callback failure
- sidecar connects successfully, but guest-agent `ready` times out
- helper-side control connection to the sidecar fails, which is not a guest-agent problem

Useful logs:

- helper `stdio.log`
- sidecar stdout and stderr logs
- guest `/var/log/container-macos-guest-agent.log`

## 16. Extension Guide

### 16.1 Adding a New Sidecar Control Method

Example: if a new `process.killGroup` method is needed:

1. add a new `MacOSSidecarMethod` in `RuntimeMacOSSidecarShared/SidecarControlProtocol.swift`
2. extend `MacOSSidecarRequest` or `MacOSSidecarEvent` if new fields are needed
3. add a helper wrapper in `MacOSSidecarClient.swift`
4. add a new branch in `perform(request:clientFD:)` in `RuntimeMacOSSidecar.swift`
5. wire it into helper routing or helper internals in `MacOSSandboxService.swift`
6. update logs and error text
7. validate non-TTY, TTY, and failure paths

### 16.2 Boundaries When Changing guest-agent Protocol

The sidecar currently uses `SidecarGuestAgentFrame` as an adapter layer over the guest-agent protocol:

- the helper should not depend directly on guest-agent frame details
- when the guest-agent protocol changes, absorb those changes in the sidecar whenever possible

That keeps helper complexity stable.

## 17. Recommended Reading Order for New Maintainers

Suggested source-reading order:

1. `Sources/Helpers/RuntimeMacOS/MacOSSandboxService.swift`
   - XPC routes and helper session semantics
2. `Sources/Helpers/RuntimeMacOS/MacOSSandboxService+Sidecar.swift`
   - LaunchAgent lifecycle and retry policy
3. `Sources/Helpers/RuntimeMacOS/MacOSSidecarClient.swift`
   - control protocol client implementation, including persistent connections and events
4. `Sources/Helpers/RuntimeMacOSSidecarShared/SidecarControlProtocol.swift`
   - protocol structures plus socket and fd transfer helpers
5. `Sources/Helpers/RuntimeMacOSSidecar/RuntimeMacOSSidecar.swift`
   - sidecar VM lifecycle and guest-agent bridging

Then pair those with:

- `docs/macos-guest-development-debugging.md`
- `docs/macos-guest-local-validation-guide.md`

## 18. Summary

The central idea of the current macOS guest runtime is:

- **the helper keeps the external interface and container session semantics**
- **the sidecar hosts the VM in the GUI domain and bridges to the guest-agent**
- **a higher-level internal protocol, JSON over Unix sockets plus fd passing, decouples the runtime from VM-hosting environment differences**

This design has already been validated for:

- non-interactive execution such as `/bin/ls /`
- streamed stdin, such as `-i ... /bin/cat`
- TTY interaction, such as `-it /bin/bash`
- stdout and stderr event forwarding
- `dial` with file descriptor passing

The main follow-up areas are:

- cleaning up sidecar concurrency warnings
- defining a protocol evolution and versioning strategy if the protocol needs to grow
- adding more systematic automated tests and fault injection
