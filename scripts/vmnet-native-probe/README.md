# Native dual-stack vmnet attachment probe

This standalone macOS 26 diagnostic creates one temporary host-only reservation
and tests its use in the creating process, after same-process serialization and
import, and after XPC transfer to a second process. Each topology is exercised
with both `vmnet_interface_start_with_network` and
`VZVmnetNetworkDeviceAttachment`. It does not connect to the container runtime,
change an existing network, configure Flannel, log in remotely, or restart a host
service. No NAT or IPv4-only fallback is provided.

Both an unused RFC1918 IPv4 `/24` and an unused locally assigned ULA IPv6 `/64`
are required. DHCP is disabled, matching the reserved host-only backend. Other
native network defaults remain enabled. The operator must check both prefixes
against existing network reservations and host/cluster routes before execution;
an absent bridge does not establish that a prefix is unused.

## Build and offline checks

From the repository root, using Xcode 26 or newer:

```sh
export DEVELOPER_DIR=/Applications/Xcode-26.3.app/Contents/Developer
probe_build_dir=$(mktemp -d /private/tmp/container-vmnet-probe-build.XXXXXX)
xcrun swiftc -swift-version 5 -O scripts/vmnet-native-probe/Probe.swift \
  -framework Virtualization -framework vmnet -o "$probe_build_dir/probe"
codesign --force --sign - --entitlements signing/container-network-vmnet.entitlements \
  "$probe_build_dir/probe"
codesign --verify --strict "$probe_build_dir/probe"
shasum -a 256 "$probe_build_dir/probe"
"$probe_build_dir/probe" version
"$probe_build_dir/probe" self-test
python3 -m unittest discover -s scripts/vmnet-native-probe -p 'test_*.py' -v
```

The example creates a local ad-hoc-signed diagnostic, not a Developer ID signed
or notarized node release. Use the same effective UID and bootstrap domain as
the reservation owner under investigation. The runner never uses `sudo` or adds
restricted entitlements. A native permission rejection is a separate result,
not evidence that an import topology is unsupported. Record actual signing
entitlements and identity when comparing different binaries.

## Run on an isolated Mac

Supply a stopped, internally consistent macOS VM seed directory with three
regular, non-hardlinked files: `HardwareModel.bin`, `AuxiliaryStorage`, and
`Disk.img`. Paths containing symlinks are rejected; use canonical paths. The
runner creates separate private APFS clones for the three VZ cases, never boots
the source disk, and shares one ephemeral machine identifier across the cases. Each VM has
4 CPUs, 8 GiB RAM, one local block device, one virtio socket device and one native
vmnet network device with a fixed test MAC. This is an attachment control, not
an exact recreation of a production VM configuration or a machine-state restore.

Set the following variables explicitly. `probe_domain` is `system` when already
running as UID 0, otherwise `gui/` followed by the current effective UID. Do not
switch identity solely to make a failing comparison pass.

```sh
probe_binary="$probe_build_dir/probe"
probe_seed=/absolute/canonical/path/to/stopped-test-seed
probe_ipv4=192.168.247.0/24
probe_ipv6=fdab:1234:5678:9::/64
probe_domain="gui/$(id -u)"

python3 scripts/vmnet-native-probe/run.py \
  --binary "$probe_binary" --seed "$probe_seed" \
  --ipv4 "$probe_ipv4" --ipv6 "$probe_ipv6" \
  --bootstrap-domain "$probe_domain" --dry-run
```

The example prefixes are placeholders, not certified unused ranges. After
confirming isolation, unused prefixes and a stopped seed, execute the same
command without `--dry-run`, adding
`--confirm-unused-subnets --confirm-stopped-seed`.

The runner creates only a unique `com.apple.container.vmnet-probe.UUID` launchd
job. It preserves the same owner PID and reservation across all cases and
disables job respawning. The first direct interface is repeated after teardown;
an additional direct check follows each import/VZ case. A changed/missing owner
PID or unconfirmed cleanup stops the matrix. Ordinary signals initiate bounded
cleanup; a kill signal or host crash cannot provide an orderly-cleanup receipt.
An interrupted or timed-out client receives termination, followed by forced
termination after two seconds if necessary and up to three seconds for process
reaping. Its partial output and separate cancellation receipt are retained.
Client process exit never establishes that native cleanup completed.

## Interpret the evidence

| Stage | What success establishes | What it does not establish |
| --- | --- | --- |
| Configuration setters | Native APIs accepted both requested prefixes | A daemon reservation or interface exists |
| Reservation create/query | A native handle was returned with the requested dual-stack configuration | The daemon can still find the reservation during interface creation |
| `direct` / `direct-vz` | The creating process can attach through the indicated API | Imported references work |
| `same-import` / `same-import-vz` | Serialization/import within the owner still permits attachment | Another process can attach |
| `cross-native` / `cross-vz` | Another same-UID process imports and attaches via the indicated API | Production runtime topology, guest readiness, IPv6 routing, Services or warm restore work |

If a direct check initially passes but fails after the last interface is
removed, the same-PID sequence narrows investigation to reservation/interface
lifetime. If direct and same-process VZ pass but cross-process VZ fails, the
cross-process native result helps distinguish an import problem from a VZ
handoff restriction. Native vmnet and VZ may enforce different access checks;
retain their distinct error namespaces. A private daemon `netrb` error number
must not be interpreted as a public `vmnet_return_t` value.

VZ configuration validation, VM start, the five-second observation of the
connected runtime attachment, and native disconnect callbacks are separate
events. Start success alone is insufficient. The probe does not provision guest
addresses or a host IPv6 gateway, weaken runtime gateway readiness, or claim
full network connectivity. Dual-stack configuration remains present in every
case; full Pod/Service acceptance requires its own unchanged integration suite.

A VZ start still pending after 20 seconds fails the case. Because VZ does not
allow stop during start, the probe retains the VM and network reference and
stops a late successful start. The overall VZ operation budget is 35 seconds;
expiry reports unconfirmed cleanup and stops the matrix. Pending or uncertain
native resources remain retained until confirmed cleanup or process exit.
Errors received during stop are included in the final result, independently of
whether stop itself succeeds.

All JSONL events, command stderr, host build, entitlement readback, binary
SHA-256, plan and summary stay in the printed mode-0700 evidence directory.
Only public prefix summaries and bounded error domain/code fields are emitted;
opaque XPC references and private native identifiers are never dumped. Use event
timestamps and PIDs to collect a bounded native log window separately.

Every returned native interface handle is stopped, including failed starts;
normal owner shutdown explicitly releases its reference before the temporary
job is removed. `ownerReleaseConfirmed`, each case's `cleanupConfirmed`, and
`jobAbsent` are independent. Failure
retains cloned disks as well as evidence, but still attempts temporary-job
cleanup. A timeout is never a pass; do not reuse a reservation after unconfirmed
cleanup. On complete success only the explicitly created clone files are
deleted, while evidence remains. Reference release does not prove private
daemon registry removal; inspect the retained cleanup record before another run.

Offline tests cover argument/path isolation, matrix interpretation, response
records, cleanup targeting and timeout evidence. Compilation and those tests do
not execute native networking or prove any macOS-specific topology result.
