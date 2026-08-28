# macOS Kubernetes full dual-stack deployment

## Scope

This document defines the deployment and acceptance contract for macOS Kubernetes nodes running the `full` network mode. The target data plane provides IPv4 and IPv6 Pod addresses, cross-node VXLAN routing, ClusterIP access, and controlled IPv6 egress.

All addresses and names in this document are examples. Deployment-specific node names, image references, credentials, endpoints, and routing prefixes must be supplied through the private deployment configuration.

## Required contracts

- Kubernetes assigns one IPv4 and one IPv6 PodCIDR to every macOS node.
- The CRI runtime receives both PodCIDRs and persists them as one atomic network configuration.
- `container-cni-macvmnet` allocates one address and gateway from each family.
- The host-only vmnet network is created with explicit IPv4 and IPv6 subnets; an automatically generated IPv6 subnet is not accepted.
- The guest agent configures both addresses, connected routes, and default routes before the Pod is reported ready.
- The host owns the IPv6 gateway address, enables forwarding, and applies the configured egress policy.
- Flannel programs IPv4 and IPv6 VXLAN peers and routes from the Node API.
- kube-proxy programs IPv4 and IPv6 Service rules and uses EndpointSlice addresses of the matching family.
- The installer package and sandbox image contain the same guest-agent binary and required protocol capabilities.

Example addressing used below:

| Purpose | IPv4 | IPv6 |
| --- | --- | --- |
| Cluster Pod network | `10.250.0.0/16` | `fd42:10:244::/56` |
| Node Pod network | `10.250.22.0/24` | `fd42:10:244:22::/64` |
| Pod gateway | `10.250.22.1` | `fd42:10:244:22::1` |
| Pod address | `10.250.22.2` | `fd42:10:244:22::2` |
| Underlay node address | `192.0.2.10` | `2001:db8:100::10` |
| External validation target | n/a | `2001:db8:200::1` |

## Release inputs

The public Release contains the signed and notarized node package, checksum, SBOM, package attestations, and a public release manifest. It does not contain private registry or deployment topology data.

The release workflow reads the deployment pairing from the protected `MACOS_NODE_RELEASE_PAIRING_BASE64` secret. The decoded manifest is held only in the runner temporary directory. The public release manifest records its SHA-256 digest and the required guest-agent capabilities, but not its contents.

The private pairing manifest must pin:

- sandbox repository, tag, index digest, platform manifest digest, configuration digest, and auxiliary-storage digest;
- sandbox source commit and base-image digest;
- sandbox guest-agent SHA-256 and required capabilities;
- workload image index and platform manifest digests.

The deployment system must verify the private manifest against the SHA-256 published in the Release before passing image references to `container-macos-kubeadm join` and RuntimeClass configuration.

## Deployment order

1. Confirm that the control plane allocates dual-stack PodCIDRs and that the flannel network configuration enables IPv6.
2. Publish a signed node package from the exact source commit to be deployed.
3. Build the sandbox image from that package, then record its immutable digests and guest-agent SHA-256 in the private pairing manifest.
4. Promote the package only after package and sandbox guest-agent hashes match and all required capabilities are present.
5. Select a cordoned macOS canary node and add `node.kubernetes.io/macos-experimental=true:NoSchedule`.
6. Install the package and join the node with the digest-pinned sandbox image from the verified private pairing.
7. Verify node configuration before uncordoning: runtime version, PodCIDRs, vmnet subnets, host gateways, forwarding state, Flannel peer state, kube-proxy state, and sandbox digest.
8. Run the acceptance matrix on the first canary. Repeat on a second canary before enabling cross-node tests.
9. Expand one node at a time. Stop if any mandatory gate fails.

The experimental taint remains until the implementation and operational gates are complete. Workloads must use an explicit toleration during the canary phase.

## Node configuration gates

The following checks are mandatory before a node accepts general workloads:

- `.spec.podCIDRs` contains exactly one IPv4 CIDR and one IPv6 CIDR.
- The host-only network configuration and runtime status report the same explicit IPv4 and IPv6 subnets.
- The guest address is within the node PodCIDR and is not the network or gateway address.
- The guest has one IPv4 and one IPv6 default route through the expected gateways.
- The host owns both gateways on the vmnet bridge and neither address is tentative or duplicated.
- IPv4 and IPv6 forwarding are enabled.
- Flannel publishes usable underlay addresses for every enabled family and has one route per remote PodCIDR.
- The configured MTU accounts for VXLAN overhead and matches the value used by the CNI and guest.
- kube-proxy has separate IPv4 and IPv6 rule sets and does not mix endpoint families.
- The running sandbox image matches the private pairing by immutable digest.

## Acceptance matrix

Run every test with DNS bypassed where an exact destination is being validated. Record source and destination addresses, selected route, interface, MTU, and failure reason.

| Area | Required checks |
| --- | --- |
| Same-node Pods | IPv4 and IPv6 TCP in both directions; multiple Pods receive unique addresses; Pod deletion releases both leases. |
| Cross-node macOS Pods | IPv4 and IPv6 TCP in both directions through VXLAN; verify routes and peer state on both hosts. |
| Linux and macOS | Pod-to-Pod IPv4 and IPv6 in both directions; verify source addresses are preserved. |
| Windows and macOS | Run when the Windows data plane advertises a compatible IPv6 route; otherwise record as outside the macOS release gate. |
| External IPv6 | Connect from each macOS Pod to a routed IPv6 TCP endpoint; verify the intended source-address or translation policy. |
| Services | IPv4 and IPv6 ClusterIP with same-node and remote EndpointSlices; add and remove endpoints while traffic is active. |
| DNS | A-only, AAAA-only, dual-answer, CNAME-to-AAAA, NXDOMAIN, and NOERROR/NODATA behavior. DNS success alone is not data-plane success. |
| MTU | Maximum non-fragmenting payload, TCP transfer, and VXLAN encapsulation with the configured MTU. |
| Lifecycle | Runtime restart, host reboot, kubelet restart, controller restart, Pod recreation, and stale-route cleanup. |
| Scale | Concurrent creation and deletion of multiple Pods; confirm unique leases, stable peer programming, and bounded convergence. |

For an exact IPv6 endpoint, the basic Pod-side checks are:

```sh
route -n get -inet6 2001:db8:200::1
nc -6 -vz -w 5 2001:db8:200::1 443
```

For an IPv6 Service, verify all three layers independently:

```sh
kubectl get service SERVICE_NAME -o wide
kubectl get endpointslice -l kubernetes.io/service-name=SERVICE_NAME -o yaml
kubectl exec POD_NAME -- nc -6 -vz -w 5 SERVICE_IPV6 443
```

## Failure and rollback

Keep the node cordoned when any mandatory gate fails. Capture the runtime status, network configuration, routes, forwarding state, Flannel status, kube-proxy status, and sandbox digest before rollback.

Rollback is node-local:

1. Drain canary workloads without deleting application data outside the node.
2. Cordon the node and stop the macOS Kubernetes services.
3. Restore the last accepted package and its matching private image pairing.
4. Remove only routes, peers, gateway addresses, packet-filter anchors, and leases owned by the failed version.
5. Restart services and rerun IPv4 regression checks before allowing workloads again.

Do not roll back cluster-wide dual-stack allocation while unaffected nodes are using it. A failed canary must not change control-plane PodCIDRs or shared Service ranges.

## Completion criteria

The full dual-stack implementation is ready for non-experimental scheduling only when:

- every mandatory acceptance row passes on two macOS nodes;
- Linux-to-macOS and macOS-to-Linux IPv6 paths pass;
- external IPv6 egress uses a documented, routable source policy;
- Service and EndpointSlice updates converge for both families;
- MTU, restart, cleanup, and multi-Pod tests pass without stale state;
- release artifacts contain no private deployment data and the private pairing digest matches the public Release manifest;
- rollback has been exercised on a canary without modifying cluster-wide networking.
