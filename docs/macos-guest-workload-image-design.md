# macOS Guest Workload Image Design

This document defines the minimum design needed to add macOS `workload image`
support without blurring the boundary between VM state and workload payload.

Related documents:

- [`macos-guest-core-design.md`](./macos-guest-core-design.md)
- [`macos-guest-dockerfile-build-design.md`](./macos-guest-dockerfile-build-design.md)

## 1. Core Decisions

### 1.1 Image roles

The system must support two explicit image roles:

- `sandbox image`
  - boots the macOS VM
  - contains VM base artifacts and machine-global state
- `workload image`
  - contains only workload payload and startup metadata
  - never boots a VM

Recommended annotations:

- `org.apple.container.macos.image.role=sandbox`
- `org.apple.container.macos.image.role=workload`
- `org.apple.container.macos.workload.format=v1`

### 1.2 Build modes

macOS build must split into two modes:

- `sandbox build`
  - commits the whole modified VM disk
  - supports unrestricted `RUN`
- `workload build`
  - commits only an explicit payload root
  - never captures arbitrary guest writes outside that root

### 1.3 Payload boundary

`workload build` must define a payload boundary before execution starts.

Recommended guest payload root:

- `/var/lib/container/build/payload`

Only files under `payloadRoot` become workload payload.

## 2. Workload Image Format

Recommended first version:

- standard OCI manifest
- standard OCI image config for:
  - `entrypoint`
  - `cmd`
  - environment
  - user
  - working directory
- ordinary filesystem payload layers

Guest layout:

- `/var/lib/container/workloads/<id>/rootfs`
- `/var/lib/container/workloads/<id>/meta.json`

`meta.json` must include:

- workload image digest
- effective process metadata
- creation timestamp

## 3. Runtime Rules

### 3.1 Create and start workload

Runtime flow:

1. resolve workload image
2. validate image role is `workload`
3. unpack layers on the host
4. inject into guest `rootfs` and `meta.json`
5. start process from workload metadata plus runtime overrides

Injection should reuse the existing sidecar and guest-agent filesystem path.

### 3.2 Persistence

`WorkloadConfiguration` must persist at least:

- workload image reference and digest
- guest payload path
- guest metadata path
- injection state

This is required for restart recovery and stable inspection.

### 3.3 Cleanup

Separate:

- host unpack cache keyed by workload image digest
- guest instance directory keyed by workload ID

Removing a workload removes its guest instance directory. Stopping a sandbox removes
all workload instance directories in that sandbox.

## 4. Build Rules

### 4.1 Sandbox build

Use `sandbox build` when the result should modify guest machine state.

Examples:

- Xcode
- Command Line Tools
- Homebrew
- machine-global Ruby
- machine-global Python
- anything installed into `/Applications`, `/Library`, `/usr/local`, or
  `/opt/homebrew`

### 4.2 Workload build

Use `workload build` when the result should be a portable payload.

Builder contract:

- `COPY` and `ADD(local)` write into `payloadRoot`
- `WORKDIR` is tracked relative to `payloadRoot`
- `ENV`, `USER`, `CMD`, and `ENTRYPOINT` update workload image config
- `RUN` may use tools from the build sandbox, but only writes under `payloadRoot`
  are committed
- the first version uses `FROM scratch` for the workload image itself and selects
  the runtime build environment explicitly with `--build-sandbox-image <sandbox-ref>`

Path rule:

- `COPY . /app` -> `<payloadRoot>/app`
- `WORKDIR /app` -> `<payloadRoot>/app`
- `RUN` with `WORKDIR /app` sees `/app` as `<payloadRoot>/app`, so relative writes
  are captured in the workload image
- absolute guest-global writes such as `/usr/local/bin/tool`, `/Library/...`, or
  `/Applications/...` execute in the build sandbox and are not committed into the
  workload image

### 4.3 Unsupported workload-build cases

Reject or clearly document:

- installers that require guest-global writes to be captured as workload payload
- `pkg`-driven system installs intended to become workload payload
- whole-guest diff capture

Current first-version rule:

- if the desired result must be captured from whole-guest filesystem mutations,
  use `sandbox build`
- if the desired result is a portable payload rooted under `payloadRoot`, use
  `workload build`
- commands that only use machine-global tools from the sandbox image are supported
  as long as their committed outputs land under `payloadRoot`

Examples:

- supported: `RUN python3 -m venv ./venv` with `WORKDIR /app`
- supported: `RUN /bin/chmod 755 ../bin/hello` after `WORKDIR /workspace`
- unsupported as workload payload capture: `RUN installer -pkg tool.pkg -target /`
- unsupported as workload payload capture: `RUN brew install foo` when the intent is
  to package `/opt/homebrew` into one workload image

## 5. Globally Available Tools

Machine-global tools belong in the `sandbox image`, not in the `workload image`.

Build flow:

1. start from a sandbox image
2. run unrestricted install steps
3. commit the whole disk as a new sandbox image
4. use that sandbox image as the build environment for later workload builds

This lets workload builds use global tools without copying them into every workload
image.

## 6. Ruby and Python Rule

If all workloads in the VM should be able to run `python3` or `ruby`, install them
into the `sandbox image`.

If the runtime should travel with one workload, install it into `payloadRoot`.

Recommended workload-local patterns:

- Python virtual environment under `payloadRoot`
- `pip install --target` under `payloadRoot`
- custom-prefix Python under `payloadRoot/opt/python`
- Bundler `vendor/bundle` under `payloadRoot`
- custom-prefix Ruby under `payloadRoot/opt/ruby`

Rule:

- visible to all workloads in the VM -> `sandbox image`
- travels with one workload -> `workload image`

## 7. Builder Inputs

`workload build` needs two distinct inputs:

- a `sandbox image` used as the build environment
- a build context used to populate `payloadRoot`

First version recommendation:

- select build sandbox explicitly with a host-side input such as
  `--build-sandbox-image <sandbox-ref>`
- do not overload `FROM` with both sandbox-base and workload-parent semantics

## 8. Implementation Work

### 8.1 Resource model

1. extend workload metadata to include workload image source and injection state
2. add guest paths for workload `rootfs` and `meta.json`
3. make workload creation reference a workload image, not only a process

### 8.2 Image validation and store

1. add role-aware validation
2. keep current VM-layer validation for `sandbox image`
3. add workload-image validation for filesystem payload layers

### 8.3 Packager

1. add `MacOSWorkloadPackager`
2. walk a host payload root and emit OCI filesystem layers
3. encode startup metadata into OCI config and workload annotations

### 8.4 Runtime injection

1. unpack workload layers on the host
2. reuse existing sidecar file transfer for guest injection
3. persist guest `meta.json`
4. reuse existing process-start path for workload execution

### 8.5 Builder

1. split macOS build into `sandbox` and `workload`
2. add explicit `payloadRoot`
3. route `COPY` and `ADD` into `payloadRoot`
4. narrow workload-build `RUN` semantics to "commit only `payloadRoot`"
5. add explicit build-sandbox selection

## 9. Acceptance Criteria

This design is acceptable when:

1. one sandbox image can host multiple workload images
2. workload images can be packed, pushed, pulled, validated, and injected
3. workload builds never depend on whole-guest diff detection
4. machine-global tools can be installed through sandbox builds and used by
   workload builds
5. workload-local Ruby and Python runtimes can be built entirely under
   `payloadRoot`

## 10. Final Rule

Keep this rule explicit everywhere:

- `sandbox image` is whole-machine state
- `workload image` is explicit payload state

That boundary is what keeps both the runtime and the builder predictable.
