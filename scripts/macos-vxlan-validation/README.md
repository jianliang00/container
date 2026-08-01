# macOS VXLAN Validation

This directory contains isolated validation harnesses for the IPv4 macOS
Flannel VXLAN design. The harnesses do not access a Kubernetes cluster or
production node.

## Host forwarding validation

`host_forwarding.c` creates:

- an isolated `VMNET_HOST_MODE` network with a native host gateway;
- a synthetic guest vmnet endpoint with a static IPv4 address;
- a `utun` interface representing the userspace VXLAN data path;
- a route from the host-only network to the tunnel.

The test sends a packet from the vmnet endpoint through native macOS IP
forwarding into `utun`, verifies that the source address is preserved, then
injects the reverse packet through `utun` and verifies delivery to the vmnet
endpoint. It restores the original forwarding setting and removes its route on
exit.

The test must run as root and the binary must carry the virtualization
entitlement used by the project's vmnet network helper.

## VXLAN benchmark

`vxlan_benchmark.c` sends complete VXLAN datagrams through a loopback UDP
socket while validating the VXLAN header, VNI, inner Ethernet header, and
payload on receive. It reports delivered packets per second, inner payload
throughput, datagram throughput, packet loss, invalid packets, and total CPU
cores consumed by the sender and receiver threads. The short runs measure
saturation capacity. The soak run is rate-limited and fails if packet loss
exceeds its configured threshold.

The benchmark is a userspace encapsulation feasibility measurement. It does
not replace an end-to-end benchmark on the target macOS node hardware.

## Run

```bash
./scripts/macos-vxlan-validation/run.sh all
./scripts/macos-vxlan-validation/run.sh forwarding
./scripts/macos-vxlan-validation/run.sh benchmark
```

The GitHub Actions workflow runs three independent trials on isolated
`macos-26` runners. Each trial runs the three packet-size saturation benchmarks
for five seconds each and a 60-second, 500 Mbps 1400-byte soak test with a
0.01% maximum loss threshold.
