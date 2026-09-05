# Native dual-stack vmnet attachment probe

This standalone macOS 26 diagnostic creates one temporary host-only reservation
and tests its use in the creating process, after same-process serialization and
import, and after XPC transfer to a second process. Each topology is exercised
with both `vmnet_interface_start_with_network` and
`VZVmnetNetworkDeviceAttachment`. It does not connect to the container runtime,
change an existing network, configure Flannel, log in remotely, or restart a host
service. No NAT or IPv4-only fallback is provided.

Both an unused RFC1918 IPv4 `/24` and an unused locally assigned ULA IPv6 `/64`
are required. DHCP is disabled, matching the reserved host-only backend. By default, other
documented native defaults (NAT44, NAT66, DNS proxy and router advertisement)
remain unchanged. The plan identifies these as SDK defaults, not daemon
readback. The explicit prefix replaces the configuration's default random ULA;
there is no second documented host-only IPv6 prefix to override. The operator must check both prefixes
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
runner creates separate private APFS clones for every VZ case, never boots
the source disk, and shares one ephemeral machine identifier across the cases. Repeated
VZ cases also get separate clones; no case boots a disk used by an earlier case. Each VM has
4 CPUs, 8 GiB RAM, one local block device, one virtio socket device, a macOS
graphics device with a 1440×900 display at 80 PPI, and one native vmnet network
device with a fixed test MAC. The graphics device is configured even though no
GUI window is opened; an incomplete boot fixture can reset devices without
providing a stable network observation. This is an attachment control, not
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
PID, failed direct baseline or unconfirmed cleanup stops the matrix. A successful
configuration query and an unchanged owner PID do not establish that the daemon
still has a live reservation after a failed start. Ordinary signals initiate bounded
cleanup; a kill signal or host crash cannot provide an orderly-cleanup receipt.
An interrupted or timed-out client receives termination, followed by forced
termination after two seconds if necessary and up to three seconds for process
reaping. Its partial output and separate cancellation receipt are retained.
Client process exit never establishes that native cleanup completed.

`--matrix all` preserves the combined twelve-case order. To keep native API
failure from contaminating VZ observations, select `--matrix native` or
`--matrix vz` in separate invocations, each with independently checked unused
dual-stack prefixes. Each family runs its direct baseline twice, same-process
import, direct recheck, cross-process import, and a final direct recheck. Every
invocation creates a fresh owner and reservation. Failure of a direct baseline
sets `stopReason.code` to `baselineFailed` and `comparisonValid` to false; later
topologies are not executed. An import rejection with confirmed cleanup can be
compared only if the following direct recheck succeeds.

## Single-variable native diagnostics

`--diagnostic-default` selects at most one changed default for the temporary
reservation. Only `--matrix native` accepts a non-baseline value. Unknown,
repeated or incompatible selections fail before creating a job or reservation.
The operating mode, explicit IPv4 subnet, explicit IPv6 prefix, DHCP setting
and native interface settings remain unchanged by this option.

| Value | Configuration change | Allowed matrix |
| --- | --- | --- |
| `baseline` (default) | None | `all`, `native`, `vz` |
| `disable-nat66` | Call `vmnet_network_configuration_disable_nat66` | `native` |
| `disable-router-advertisement` | Call `vmnet_network_configuration_disable_router_advertisement` | `native` |

For example, using the explicit variables and isolation checks above:

```sh
python3 scripts/vmnet-native-probe/run.py \
  --binary "$probe_binary" --seed "$probe_seed" \
  --ipv4 "$probe_ipv4" --ipv6 "$probe_ipv6" \
  --bootstrap-domain "$probe_domain" --matrix native \
  --diagnostic-default disable-nat66 --dry-run
```

Choose `baseline` or `disable-router-advertisement` for a separate group. Each
invocation creates one fresh owner and reservation, executes each planned case
once, and stops on a failed baseline without retrying. Inspect cleanup before
another invocation and recheck the chosen prefixes; any necessary change to
other inputs must remain visible in the plans and limits causal comparison.
No option disables IPv6, changes the running container service or constitutes
a production recommendation. A changed result is diagnostic evidence, not
proof that NAT66 or router advertisement caused an existing failure.

`requestedNativeConfiguration` in the plan records requested settings plus
documented defaults, with `readBack: false`. Public setters for these flags
return no status and expose no corresponding getter. The owner identifies its
selected `diagnosticDefault` with `configurationReadBack: false`; the runner
requires that receipt before the first case, separately from actual public
IPv4/IPv6 prefix readback. Use the matching version-2 probe binary and runner;
a missing or mismatched receipt stops execution. Native-only variants reject
VZ consumers, including VZ-oriented export; native export remains available.

## Interpret the evidence

| Stage | What success establishes | What it does not establish |
| --- | --- | --- |
| Configuration setters | Native APIs accepted both requested prefixes | A daemon reservation or interface exists |
| Reservation create/query | A native handle was returned with the requested dual-stack configuration | The daemon can still find the reservation during interface creation |
| Native interface cases | The native start callback succeeded and the returned handle was stopped | A guest can exchange packets |
| VZ cases | Configuration validated, VM started, its runtime attachment remained present for five seconds without a reported disconnect, a unique matching host bridge was observed before stop, and stop succeeded | The host bridge proves attachment of this VM or a guest can exchange packets |
| Direct / same-import / cross-import controls | The selected observation succeeded in the owner, after same-process import, or after same-UID XPC import, respectively | Production topology, guest readiness, IPv6 routing, Services or warm restore work |

If a direct check initially passes but fails after the last interface is
removed, the same-PID sequence narrows investigation to reservation/interface
lifetime. If direct and same-process VZ pass but cross-process VZ fails, the
cross-process native result helps distinguish an import problem from a VZ
handoff issue only when their own direct baselines remain valid. A failed first
direct start invalidates all later results from that reservation; those later
results must not be used to conclude that cross-process import is unsupported.
Native vmnet and VZ may enforce different access checks;
retain their distinct error namespaces. A private daemon `netrb` error number
must not be interpreted as a public `vmnet_return_t` value.

VZ does not expose its underlying native interface handle or a native-start
completion receipt. Read-only host snapshots identify bridge interfaces owning
the exact requested IPv4 gateway before start, during observation and after the
stop attempt. `uniqueBridgeObserved` reports existence only: a bridge can serve
another interface, and neither its presence nor VZ's attachment property proves
VM traffic works. `attachmentObservationPassed` records the VZ-property
observation independently. `nativeRealizationStatus` is `hostBridgeObserved`
only for an unambiguous matching bridge before stop; absent or ambiguous
evidence is `unobserved`, and inspection failure is `inspectionFailed`.
Unobserved or failed inspection makes the case fail and stops the whole group,
including after an import case. The runner also rejects missing legacy
receipts; a successful VZ property observation or cleanup cannot override this
gate. The five-second observation window is unchanged. A pre-existing matching
bridge establishes only host-network existence, not attachment of the new VM.
VZ case results use `evidenceScope: vz-control-plane-observation`;
all summaries retain `nativeDataplaneValidated: false` and
`guestConnectivityValidated: false`. The native API allocates a MAC and uses
explicit offload settings, while VZ uses the configured fixed MAC and its own
internal interface settings; these API paths are not identical parameter tests.

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
records, cleanup targeting and timeout evidence. Swift self-tests create and
remove private dummy seed fixtures under `/private/var/tmp`, accepting physical
paths while rejecting traversal, symbolic links and hardlinks without relying
on Foundation URL spelling. Compilation and those tests do
not execute native networking or prove any macOS-specific topology result.
