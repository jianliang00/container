//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the container project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//   https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

#ifndef CONTAINER_K8S_FLANNEL_VXLAN_MACOS_H
#define CONTAINER_K8S_FLANNEL_VXLAN_MACOS_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct container_vxlan_tunnel container_vxlan_tunnel_t;
typedef struct container_vxlan_tunnel_v6 container_vxlan_tunnel_v6_t;

// IPv4 fields are in network byte order.
typedef struct container_vxlan_tunnel_config {
    uint32_t vni;
    uint16_t port;
    uint16_t mtu;
    uint32_t bind_ip;
    uint32_t local_network;
    uint32_t local_netmask;
    uint8_t local_vtep_mac[6];
} container_vxlan_tunnel_config_t;

// IPv4 fields are in network byte order.
typedef struct container_vxlan_peer {
    uint32_t pod_network;
    uint32_t pod_netmask;
    uint32_t public_ip;
    uint8_t vtep_mac[6];
    // Windows HCN uses the container endpoint MAC, rather than the Node's
    // published VTEP MAC, as the inner Ethernet source for routed VXLAN frames.
    bool allow_endpoint_source_mac;
} container_vxlan_peer_t;

// All IPv6 address fields contain 16 bytes in network byte order. The prefix
// length must be in 1...128. Callers must set abi_version and struct_size before
// passing these structures to the API.
typedef struct container_vxlan_tunnel_config_v6 {
    uint32_t abi_version;
    uint32_t struct_size;
    uint32_t vni;
    uint16_t port;
    uint16_t mtu;
    uint8_t bind_ip[16];
    uint8_t local_network[16];
    uint8_t prefix_length;
    uint8_t local_vtep_mac[6];
} container_vxlan_tunnel_config_v6_t;

// All IPv6 address fields contain 16 bytes in network byte order. The prefix
// length must be in 1...128. Callers must set abi_version and struct_size before
// passing these structures to the API.
typedef struct container_vxlan_peer_v6 {
    uint32_t abi_version;
    uint32_t struct_size;
    uint8_t pod_network[16];
    uint8_t prefix_length;
    uint8_t public_ip[16];
    uint8_t vtep_mac[6];
} container_vxlan_peer_v6_t;

typedef struct container_vxlan_tunnel_stats {
    uint64_t transmitted_packets;
    uint64_t transmitted_bytes;
    uint64_t received_packets;
    uint64_t received_bytes;
    uint64_t unknown_peer_packets;
    uint64_t invalid_packets;
    uint64_t oversized_packets;
    uint64_t source_cidr_mismatches;
} container_vxlan_tunnel_stats_t;

enum {
    CONTAINER_VXLAN_HEADER_LENGTH = 8,
    CONTAINER_VXLAN_ETHERNET_HEADER_LENGTH = 14,
    CONTAINER_VXLAN_IPV6_ADDRESS_LENGTH = 16,
    CONTAINER_VXLAN_V6_ABI_VERSION = 1,
};

typedef enum container_vxlan_wire_status {
    CONTAINER_VXLAN_WIRE_SUCCESS = 0,
    CONTAINER_VXLAN_WIRE_INVALID_ARGUMENT = 1,
    CONTAINER_VXLAN_WIRE_INVALID_PACKET = 2,
    CONTAINER_VXLAN_WIRE_OVERSIZED_PACKET = 3,
    CONTAINER_VXLAN_WIRE_UNKNOWN_PEER = 4,
    CONTAINER_VXLAN_WIRE_OUTPUT_TOO_SMALL = 5,
    CONTAINER_VXLAN_WIRE_SOURCE_CIDR_MISMATCH = 6,
} container_vxlan_wire_status_t;

typedef struct container_vxlan_encoded_packet {
    size_t datagram_length;
    size_t inner_packet_length;
    // IPv4 address is in network byte order; port is in host byte order.
    uint32_t destination_ip;
    uint16_t destination_port;
} container_vxlan_encoded_packet_t;

typedef struct container_vxlan_decoded_packet {
    size_t inner_packet_length;
    bool source_cidr_mismatch;
} container_vxlan_decoded_packet_t;

typedef struct container_vxlan_encoded_packet_v6 {
    size_t datagram_length;
    size_t inner_packet_length;
    // IPv6 address contains 16 bytes in network byte order; port is in host
    // byte order.
    uint8_t destination_ip[16];
    uint16_t destination_port;
} container_vxlan_encoded_packet_v6_t;

// Pure wire codec used by the live tunnel data path. The encoder selects the
// peer whose PodCIDR contains the inner IPv4 destination.
container_vxlan_wire_status_t container_vxlan_encode_ipv4(
    const container_vxlan_tunnel_config_t *config,
    const container_vxlan_peer_t *peers,
    size_t peer_count,
    const uint8_t *inner_packet,
    size_t inner_packet_available,
    uint8_t *datagram,
    size_t datagram_capacity,
    container_vxlan_encoded_packet_t *encoded
);

// Pure wire codec used by the live tunnel data path. outer_source_ip is in
// network byte order. The decoder authenticates the outer source IP together
// with the Ethernet source VTEP MAC, except that a peer explicitly marked for
// Windows HCN may use a unicast endpoint source MAC. It only accepts an inner
// source from that peer's PodCIDR or the peer's public IP before returning the
// IPv4 packet.
container_vxlan_wire_status_t container_vxlan_decode_ipv4(
    const container_vxlan_tunnel_config_t *config,
    const container_vxlan_peer_t *peers,
    size_t peer_count,
    uint32_t outer_source_ip,
    const uint8_t *datagram,
    size_t datagram_length,
    uint8_t *inner_packet,
    size_t inner_packet_capacity,
    container_vxlan_decoded_packet_t *decoded
);

// Pure IPv6 wire codec used by the independent IPv6 live tunnel. The encoder
// authenticates the inner source against the local network and selects a peer
// whose PodCIDR contains the inner destination.
container_vxlan_wire_status_t container_vxlan_encode_ipv6(
    const container_vxlan_tunnel_config_v6_t *config,
    const container_vxlan_peer_v6_t *peers,
    size_t peer_count,
    const uint8_t *inner_packet,
    size_t inner_packet_available,
    uint8_t *datagram,
    size_t datagram_capacity,
    container_vxlan_encoded_packet_v6_t *encoded
);

// outer_source_ip contains 16 bytes in network byte order. The decoder matches
// the outer IPv6 address and Ethernet source VTEP MAC to one allowlisted peer,
// then only accepts an inner source from that peer's PodCIDR or its exact public
// IPv6 address and an inner destination from the local PodCIDR.
container_vxlan_wire_status_t container_vxlan_decode_ipv6(
    const container_vxlan_tunnel_config_v6_t *config,
    const container_vxlan_peer_v6_t *peers,
    size_t peer_count,
    const uint8_t outer_source_ip[16],
    const uint8_t *datagram,
    size_t datagram_length,
    uint8_t *inner_packet,
    size_t inner_packet_capacity,
    container_vxlan_decoded_packet_t *decoded
);

int container_vxlan_tunnel_create(
    const container_vxlan_tunnel_config_t *config,
    container_vxlan_tunnel_t **tunnel,
    char *interface_name,
    size_t interface_name_capacity,
    char *error_message,
    size_t error_message_capacity
);

int container_vxlan_tunnel_set_peers(
    container_vxlan_tunnel_t *tunnel,
    const container_vxlan_peer_t *peers,
    size_t peer_count,
    char *error_message,
    size_t error_message_capacity
);

int container_vxlan_tunnel_start(
    container_vxlan_tunnel_t *tunnel,
    char *error_message,
    size_t error_message_capacity
);

void container_vxlan_tunnel_get_stats(
    const container_vxlan_tunnel_t *tunnel,
    container_vxlan_tunnel_stats_t *stats
);

bool container_vxlan_tunnel_is_running(const container_vxlan_tunnel_t *tunnel);

void container_vxlan_tunnel_stop(container_vxlan_tunnel_t *tunnel);
void container_vxlan_tunnel_destroy(container_vxlan_tunnel_t *tunnel);

int container_vxlan_tunnel_v6_create(
    const container_vxlan_tunnel_config_v6_t *config,
    container_vxlan_tunnel_v6_t **tunnel,
    char *interface_name,
    size_t interface_name_capacity,
    char *error_message,
    size_t error_message_capacity
);

int container_vxlan_tunnel_v6_set_peers(
    container_vxlan_tunnel_v6_t *tunnel,
    const container_vxlan_peer_v6_t *peers,
    size_t peer_count,
    char *error_message,
    size_t error_message_capacity
);

int container_vxlan_tunnel_v6_start(
    container_vxlan_tunnel_v6_t *tunnel,
    char *error_message,
    size_t error_message_capacity
);

void container_vxlan_tunnel_v6_get_stats(
    const container_vxlan_tunnel_v6_t *tunnel,
    container_vxlan_tunnel_stats_t *stats
);

bool container_vxlan_tunnel_v6_is_running(const container_vxlan_tunnel_v6_t *tunnel);

void container_vxlan_tunnel_v6_stop(container_vxlan_tunnel_v6_t *tunnel);
void container_vxlan_tunnel_v6_destroy(container_vxlan_tunnel_v6_t *tunnel);

// Configure the deterministic IPv6 gateway on a materialized vmnet bridge.
// These functions return zero on success or an errno value on failure.
int container_flannel_ipv6_gateway_add(
    const char *interface_name,
    const uint8_t address[CONTAINER_VXLAN_IPV6_ADDRESS_LENGTH],
    uint8_t prefix_length
);

int container_flannel_ipv6_gateway_remove(
    const char *interface_name,
    const uint8_t address[CONTAINER_VXLAN_IPV6_ADDRESS_LENGTH]
);

int container_flannel_ipv6_gateway_flags(
    const char *interface_name,
    const uint8_t address[CONTAINER_VXLAN_IPV6_ADDRESS_LENGTH],
    uint32_t *flags
);

bool container_flannel_ipv6_gateway_is_tentative(uint32_t flags);
bool container_flannel_ipv6_gateway_is_duplicated(uint32_t flags);

#if defined(CONTAINER_VXLAN_TEST_HOOKS)
int container_vxlan_debug_v6_idle_stop(void);
int container_vxlan_debug_v6_inbound_start_failure(void);
#endif

#ifdef __cplusplus
}
#endif

#endif
