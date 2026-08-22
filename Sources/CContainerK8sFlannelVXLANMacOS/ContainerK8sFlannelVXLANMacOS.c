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

#include "ContainerK8sFlannelVXLANMacOS.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <net/if.h>
#include <net/if_utun.h>
#include <netinet/in.h>
#include <netinet6/in6_var.h>
#include <netinet6/nd6.h>
#include <poll.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/kern_control.h>
#include <sys/socket.h>
#include <sys/sys_domain.h>
#include <sys/time.h>
#include <unistd.h>

#define VXLAN_HEADER_LENGTH ((size_t)CONTAINER_VXLAN_HEADER_LENGTH)
#define ETHERNET_HEADER_LENGTH ((size_t)CONTAINER_VXLAN_ETHERNET_HEADER_LENGTH)
#define UTUN_FAMILY_LENGTH 4U
#define MINIMUM_IPV4_HEADER_LENGTH 20U
#define MINIMUM_IPV6_HEADER_LENGTH 40U
#define MAXIMUM_TUNNEL_MTU 9000U
#define SOCKET_BUFFER_SIZE (8 * 1024 * 1024)
#define SOCKET_RECEIVE_TIMEOUT_SECONDS 1

static int ipv6_gateway_socket(void) {
    return socket(AF_INET6, SOCK_DGRAM, 0);
}

static void ipv6_gateway_sockaddr(struct sockaddr_in6 *destination, const uint8_t address[16]) {
    memset(destination, 0, sizeof(*destination));
    destination->sin6_len = sizeof(*destination);
    destination->sin6_family = AF_INET6;
    memcpy(&destination->sin6_addr, address, 16);
}

int container_flannel_ipv6_gateway_add(
    const char *interface_name,
    const uint8_t address[CONTAINER_VXLAN_IPV6_ADDRESS_LENGTH],
    uint8_t prefix_length
) {
    if (interface_name == NULL || address == NULL || prefix_length > 128 || strlen(interface_name) >= IFNAMSIZ) {
        return EINVAL;
    }
    int fd = ipv6_gateway_socket();
    if (fd < 0) {
        return errno;
    }
    struct in6_aliasreq request = {0};
    strlcpy(request.ifra_name, interface_name, sizeof(request.ifra_name));
    ipv6_gateway_sockaddr(&request.ifra_addr, address);
    request.ifra_prefixmask.sin6_len = sizeof(request.ifra_prefixmask);
    request.ifra_prefixmask.sin6_family = AF_INET6;
    uint8_t *mask = (uint8_t *)&request.ifra_prefixmask.sin6_addr;
    size_t complete_bytes = prefix_length / 8U;
    uint8_t remaining_bits = prefix_length % 8U;
    memset(mask, 0xff, complete_bytes);
    if (remaining_bits != 0) {
        mask[complete_bytes] = (uint8_t)(0xffU << (8U - remaining_bits));
    }
    request.ifra_lifetime.ia6t_vltime = ND6_INFINITE_LIFETIME;
    request.ifra_lifetime.ia6t_pltime = ND6_INFINITE_LIFETIME;
    int result = ioctl(fd, SIOCAIFADDR_IN6, &request);
    int error = result == 0 ? 0 : errno;
    close(fd);
    return error;
}

int container_flannel_ipv6_gateway_remove(
    const char *interface_name,
    const uint8_t address[CONTAINER_VXLAN_IPV6_ADDRESS_LENGTH]
) {
    if (interface_name == NULL || address == NULL || strlen(interface_name) >= IFNAMSIZ) {
        return EINVAL;
    }
    int fd = ipv6_gateway_socket();
    if (fd < 0) {
        return errno;
    }
    struct in6_ifreq request = {0};
    strlcpy(request.ifr_name, interface_name, sizeof(request.ifr_name));
    ipv6_gateway_sockaddr(&request.ifr_ifru.ifru_addr, address);
    int result = ioctl(fd, SIOCDIFADDR_IN6, &request);
    int error = result == 0 ? 0 : errno;
    close(fd);
    return error;
}

int container_flannel_ipv6_gateway_flags(
    const char *interface_name,
    const uint8_t address[CONTAINER_VXLAN_IPV6_ADDRESS_LENGTH],
    uint32_t *flags
) {
    if (interface_name == NULL || address == NULL || flags == NULL || strlen(interface_name) >= IFNAMSIZ) {
        return EINVAL;
    }
    int fd = ipv6_gateway_socket();
    if (fd < 0) {
        return errno;
    }
    struct in6_ifreq request = {0};
    strlcpy(request.ifr_name, interface_name, sizeof(request.ifr_name));
    ipv6_gateway_sockaddr(&request.ifr_ifru.ifru_addr, address);
    int result = ioctl(fd, SIOCGIFAFLAG_IN6, &request);
    int error = result == 0 ? 0 : errno;
    if (result == 0) {
        *flags = (uint32_t)request.ifr_ifru.ifru_flags6;
    }
    close(fd);
    return error;
}

bool container_flannel_ipv6_gateway_is_tentative(uint32_t flags) {
    return (flags & IN6_IFF_TENTATIVE) != 0;
}

bool container_flannel_ipv6_gateway_is_duplicated(uint32_t flags) {
    return (flags & IN6_IFF_DUPLICATED) != 0;
}

struct container_vxlan_tunnel {
    container_vxlan_tunnel_config_t config;
    int udp_fd;
    int utun_fd;
    char interface_name[IFNAMSIZ];
    pthread_t outbound_thread;
    pthread_t inbound_thread;
    bool outbound_thread_created;
    bool inbound_thread_created;
    atomic_bool running;
    pthread_mutex_t peers_lock;
    container_vxlan_peer_t *peers;
    size_t peer_count;
    atomic_uint_fast64_t transmitted_packets;
    atomic_uint_fast64_t transmitted_bytes;
    atomic_uint_fast64_t received_packets;
    atomic_uint_fast64_t received_bytes;
    atomic_uint_fast64_t unknown_peer_packets;
    atomic_uint_fast64_t invalid_packets;
    atomic_uint_fast64_t oversized_packets;
    atomic_uint_fast64_t source_cidr_mismatches;
};

static void set_error(char *message, size_t capacity, const char *format, ...) {
    if (message == NULL || capacity == 0) {
        return;
    }
    va_list arguments;
    va_start(arguments, format);
    vsnprintf(message, capacity, format, arguments);
    va_end(arguments);
}

static bool mac_is_unicast(const uint8_t mac[6]) {
    static const uint8_t zero[6] = {0};
    return memcmp(mac, zero, sizeof(zero)) != 0 && (mac[0] & 1U) == 0;
}

static bool address_in_network(uint32_t address, uint32_t network, uint32_t netmask) {
    return (address & netmask) == network;
}

static int set_socket_buffer(int socket_fd, int option) {
    int value = SOCKET_BUFFER_SIZE;
    return setsockopt(socket_fd, SOL_SOCKET, option, &value, sizeof(value));
}

static int set_receive_timeout(int socket_fd) {
    struct timeval timeout = {
        .tv_sec = SOCKET_RECEIVE_TIMEOUT_SECONDS,
        .tv_usec = 0,
    };
    return setsockopt(socket_fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
}

static int open_utun(char interface_name[IFNAMSIZ]) {
    int fd = socket(PF_SYSTEM, SOCK_DGRAM, SYSPROTO_CONTROL);
    if (fd < 0) {
        return -1;
    }

    struct ctl_info control_info = {0};
    strlcpy(control_info.ctl_name, UTUN_CONTROL_NAME, sizeof(control_info.ctl_name));
    if (ioctl(fd, CTLIOCGINFO, &control_info) != 0) {
        close(fd);
        return -1;
    }

    struct sockaddr_ctl address = {0};
    address.sc_len = sizeof(address);
    address.sc_family = AF_SYSTEM;
    address.ss_sysaddr = AF_SYS_CONTROL;
    address.sc_id = control_info.ctl_id;
    address.sc_unit = 0;
    if (connect(fd, (struct sockaddr *)&address, sizeof(address)) != 0) {
        close(fd);
        return -1;
    }

    socklen_t length = IFNAMSIZ;
    if (getsockopt(fd, SYSPROTO_CONTROL, UTUN_OPT_IFNAME, interface_name, &length) != 0) {
        close(fd);
        return -1;
    }
    if (set_receive_timeout(fd) != 0) {
        close(fd);
        return -1;
    }
    return fd;
}

static int open_udp_socket(const container_vxlan_tunnel_config_t *config) {
    int fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (fd < 0) {
        return -1;
    }

    int enabled = 1;
    if (setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &enabled, sizeof(enabled)) != 0 ||
        set_socket_buffer(fd, SO_RCVBUF) != 0 ||
        set_socket_buffer(fd, SO_SNDBUF) != 0 ||
        set_receive_timeout(fd) != 0)
    {
        close(fd);
        return -1;
    }

    struct sockaddr_in address = {0};
    address.sin_len = sizeof(address);
    address.sin_family = AF_INET;
    address.sin_port = htons(config->port);
    address.sin_addr.s_addr = config->bind_ip;
    if (bind(fd, (struct sockaddr *)&address, sizeof(address)) != 0) {
        close(fd);
        return -1;
    }
    return fd;
}

static const container_vxlan_peer_t *peer_for_destination(
    const container_vxlan_peer_t *peers,
    size_t peer_count,
    uint32_t destination
) {
    for (size_t index = 0; index < peer_count; ++index) {
        if (address_in_network(destination, peers[index].pod_network, peers[index].pod_netmask)) {
            return &peers[index];
        }
    }
    return NULL;
}

static const container_vxlan_peer_t *peer_for_source(
    const container_vxlan_peer_t *peers,
    size_t peer_count,
    uint32_t public_ip,
    const uint8_t source_mac[6]
) {
    for (size_t index = 0; index < peer_count; ++index) {
        if (peers[index].public_ip == public_ip && memcmp(peers[index].vtep_mac, source_mac, 6) == 0) {
            return &peers[index];
        }
    }
    if (!mac_is_unicast(source_mac)) {
        return NULL;
    }
    for (size_t index = 0; index < peer_count; ++index) {
        if (peers[index].public_ip == public_ip && peers[index].allow_endpoint_source_mac) {
            return &peers[index];
        }
    }
    return NULL;
}

static container_vxlan_wire_status_t ipv4_packet_length(
    const uint8_t *packet,
    size_t available,
    size_t mtu,
    size_t *packet_length
) {
    if (available < MINIMUM_IPV4_HEADER_LENGTH || (packet[0] >> 4) != 4) {
        return CONTAINER_VXLAN_WIRE_INVALID_PACKET;
    }
    size_t header_length = (size_t)(packet[0] & 0x0fU) * 4U;
    if (header_length < MINIMUM_IPV4_HEADER_LENGTH || header_length > available) {
        return CONTAINER_VXLAN_WIRE_INVALID_PACKET;
    }
    uint16_t network_length;
    memcpy(&network_length, packet + 2, sizeof(network_length));
    size_t value = ntohs(network_length);
    if (value > mtu) {
        return CONTAINER_VXLAN_WIRE_OVERSIZED_PACKET;
    }
    if (value < header_length || value > available) {
        return CONTAINER_VXLAN_WIRE_INVALID_PACKET;
    }
    *packet_length = value;
    return CONTAINER_VXLAN_WIRE_SUCCESS;
}

static uint32_t ipv4_source(const uint8_t *packet) {
    uint32_t address;
    memcpy(&address, packet + 12, sizeof(address));
    return address;
}

static uint32_t ipv4_destination(const uint8_t *packet) {
    uint32_t address;
    memcpy(&address, packet + 16, sizeof(address));
    return address;
}

static bool valid_vxlan_header(const container_vxlan_tunnel_config_t *config, const uint8_t *packet) {
    if (packet[0] != 0x08U || packet[1] != 0 || packet[2] != 0 || packet[3] != 0 || packet[7] != 0) {
        return false;
    }
    uint32_t vni = ((uint32_t)packet[4] << 16) | ((uint32_t)packet[5] << 8) | packet[6];
    return vni == config->vni;
}

container_vxlan_wire_status_t container_vxlan_encode_ipv4(
    const container_vxlan_tunnel_config_t *config,
    const container_vxlan_peer_t *peers,
    size_t peer_count,
    const uint8_t *inner_packet,
    size_t inner_packet_available,
    uint8_t *datagram,
    size_t datagram_capacity,
    container_vxlan_encoded_packet_t *encoded
) {
    if (encoded != NULL) {
        memset(encoded, 0, sizeof(*encoded));
    }
    if (config == NULL || inner_packet == NULL || datagram == NULL || encoded == NULL ||
        (peer_count > 0 && peers == NULL))
    {
        return CONTAINER_VXLAN_WIRE_INVALID_ARGUMENT;
    }

    size_t inner_packet_length = 0;
    container_vxlan_wire_status_t status =
        ipv4_packet_length(inner_packet, inner_packet_available, config->mtu, &inner_packet_length);
    if (status != CONTAINER_VXLAN_WIRE_SUCCESS) {
        return status;
    }

    const container_vxlan_peer_t *peer =
        peer_for_destination(peers, peer_count, ipv4_destination(inner_packet));
    if (peer == NULL) {
        return CONTAINER_VXLAN_WIRE_UNKNOWN_PEER;
    }

    size_t datagram_length = VXLAN_HEADER_LENGTH + ETHERNET_HEADER_LENGTH + inner_packet_length;
    if (datagram_capacity < datagram_length) {
        return CONTAINER_VXLAN_WIRE_OUTPUT_TOO_SMALL;
    }

    memset(datagram, 0, VXLAN_HEADER_LENGTH + ETHERNET_HEADER_LENGTH);
    datagram[0] = 0x08;
    datagram[4] = (uint8_t)((config->vni >> 16) & 0xffU);
    datagram[5] = (uint8_t)((config->vni >> 8) & 0xffU);
    datagram[6] = (uint8_t)(config->vni & 0xffU);
    uint8_t *ethernet = datagram + VXLAN_HEADER_LENGTH;
    memcpy(ethernet, peer->vtep_mac, 6);
    memcpy(ethernet + 6, config->local_vtep_mac, 6);
    ethernet[12] = 0x08;
    ethernet[13] = 0x00;
    memcpy(ethernet + ETHERNET_HEADER_LENGTH, inner_packet, inner_packet_length);

    encoded->datagram_length = datagram_length;
    encoded->inner_packet_length = inner_packet_length;
    encoded->destination_ip = peer->public_ip;
    encoded->destination_port = config->port;
    return CONTAINER_VXLAN_WIRE_SUCCESS;
}

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
) {
    if (decoded != NULL) {
        memset(decoded, 0, sizeof(*decoded));
    }
    if (config == NULL || datagram == NULL || inner_packet == NULL || decoded == NULL ||
        (peer_count > 0 && peers == NULL))
    {
        return CONTAINER_VXLAN_WIRE_INVALID_ARGUMENT;
    }
    if (datagram_length < VXLAN_HEADER_LENGTH + ETHERNET_HEADER_LENGTH + MINIMUM_IPV4_HEADER_LENGTH ||
        !valid_vxlan_header(config, datagram))
    {
        return CONTAINER_VXLAN_WIRE_INVALID_PACKET;
    }

    const uint8_t *ethernet = datagram + VXLAN_HEADER_LENGTH;
    if (memcmp(ethernet, config->local_vtep_mac, 6) != 0 || ethernet[12] != 0x08 || ethernet[13] != 0x00) {
        return CONTAINER_VXLAN_WIRE_INVALID_PACKET;
    }

    const container_vxlan_peer_t *peer = peer_for_source(peers, peer_count, outer_source_ip, ethernet + 6);
    if (peer == NULL) {
        return CONTAINER_VXLAN_WIRE_UNKNOWN_PEER;
    }

    const uint8_t *inner = ethernet + ETHERNET_HEADER_LENGTH;
    size_t available = datagram_length - VXLAN_HEADER_LENGTH - ETHERNET_HEADER_LENGTH;
    size_t inner_packet_length = 0;
    container_vxlan_wire_status_t status =
        ipv4_packet_length(inner, available, config->mtu, &inner_packet_length);
    if (status != CONTAINER_VXLAN_WIRE_SUCCESS) {
        return status;
    }
    if (!address_in_network(ipv4_destination(inner), config->local_network, config->local_netmask)) {
        return CONTAINER_VXLAN_WIRE_INVALID_PACKET;
    }
    uint32_t inner_source = ipv4_source(inner);
    decoded->source_cidr_mismatch =
        inner_source != peer->public_ip &&
        !address_in_network(inner_source, peer->pod_network, peer->pod_netmask);
    if (decoded->source_cidr_mismatch) {
        return CONTAINER_VXLAN_WIRE_SOURCE_CIDR_MISMATCH;
    }
    if (inner_packet_capacity < inner_packet_length) {
        return CONTAINER_VXLAN_WIRE_OUTPUT_TOO_SMALL;
    }

    memcpy(inner_packet, inner, inner_packet_length);
    decoded->inner_packet_length = inner_packet_length;
    return CONTAINER_VXLAN_WIRE_SUCCESS;
}

static void *run_outbound(void *context) {
    container_vxlan_tunnel_t *tunnel = context;
    size_t packet_capacity = UTUN_FAMILY_LENGTH + tunnel->config.mtu;
    size_t datagram_capacity = VXLAN_HEADER_LENGTH + ETHERNET_HEADER_LENGTH + tunnel->config.mtu;
    uint8_t *packet = malloc(packet_capacity);
    uint8_t *datagram = malloc(datagram_capacity);
    if (packet == NULL || datagram == NULL) {
        free(packet);
        free(datagram);
        atomic_store(&tunnel->running, false);
        return NULL;
    }

    while (atomic_load(&tunnel->running)) {
        ssize_t read_length = read(tunnel->utun_fd, packet, packet_capacity);
        if (read_length < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)) {
            continue;
        }
        if (read_length <= 0) {
            break;
        }
        if ((size_t)read_length <= UTUN_FAMILY_LENGTH) {
            atomic_fetch_add(&tunnel->invalid_packets, 1);
            continue;
        }

        uint32_t family;
        memcpy(&family, packet, sizeof(family));
        if (ntohl(family) != AF_INET) {
            atomic_fetch_add(&tunnel->invalid_packets, 1);
            continue;
        }

        container_vxlan_encoded_packet_t encoded;
        pthread_mutex_lock(&tunnel->peers_lock);
        container_vxlan_wire_status_t status = container_vxlan_encode_ipv4(
            &tunnel->config,
            tunnel->peers,
            tunnel->peer_count,
            packet + UTUN_FAMILY_LENGTH,
            (size_t)read_length - UTUN_FAMILY_LENGTH,
            datagram,
            datagram_capacity,
            &encoded
        );
        pthread_mutex_unlock(&tunnel->peers_lock);
        if (status == CONTAINER_VXLAN_WIRE_UNKNOWN_PEER) {
            atomic_fetch_add(&tunnel->unknown_peer_packets, 1);
            continue;
        }
        if (status == CONTAINER_VXLAN_WIRE_OVERSIZED_PACKET) {
            atomic_fetch_add(&tunnel->oversized_packets, 1);
            continue;
        }
        if (status != CONTAINER_VXLAN_WIRE_SUCCESS) {
            atomic_fetch_add(&tunnel->invalid_packets, 1);
            continue;
        }

        struct sockaddr_in destination = {0};
        destination.sin_len = sizeof(destination);
        destination.sin_family = AF_INET;
        destination.sin_port = htons(encoded.destination_port);
        destination.sin_addr.s_addr = encoded.destination_ip;
        ssize_t sent = sendto(
            tunnel->udp_fd,
            datagram,
            encoded.datagram_length,
            0,
            (struct sockaddr *)&destination,
            sizeof(destination)
        );
        if (sent == (ssize_t)encoded.datagram_length) {
            atomic_fetch_add(&tunnel->transmitted_packets, 1);
            atomic_fetch_add(&tunnel->transmitted_bytes, encoded.inner_packet_length);
        } else if (sent < 0 && (errno == EBADF || errno == ENOTSOCK)) {
            break;
        } else {
            atomic_fetch_add(&tunnel->invalid_packets, 1);
        }
    }

    free(packet);
    free(datagram);
    atomic_store(&tunnel->running, false);
    return NULL;
}

static void *run_inbound(void *context) {
    container_vxlan_tunnel_t *tunnel = context;
    size_t datagram_capacity = VXLAN_HEADER_LENGTH + ETHERNET_HEADER_LENGTH + tunnel->config.mtu;
    uint8_t *datagram = malloc(datagram_capacity);
    uint8_t *packet = malloc(UTUN_FAMILY_LENGTH + tunnel->config.mtu);
    if (datagram == NULL || packet == NULL) {
        free(datagram);
        free(packet);
        atomic_store(&tunnel->running, false);
        return NULL;
    }

    while (atomic_load(&tunnel->running)) {
        struct sockaddr_in source = {0};
        socklen_t source_length = sizeof(source);
        ssize_t received = recvfrom(
            tunnel->udp_fd,
            datagram,
            datagram_capacity,
            0,
            (struct sockaddr *)&source,
            &source_length
        );
        if (received < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)) {
            continue;
        }
        if (received <= 0) {
            break;
        }
        container_vxlan_decoded_packet_t decoded;
        pthread_mutex_lock(&tunnel->peers_lock);
        container_vxlan_wire_status_t status = container_vxlan_decode_ipv4(
            &tunnel->config,
            tunnel->peers,
            tunnel->peer_count,
            source.sin_addr.s_addr,
            datagram,
            (size_t)received,
            packet + UTUN_FAMILY_LENGTH,
            tunnel->config.mtu,
            &decoded
        );
        pthread_mutex_unlock(&tunnel->peers_lock);
        if (status == CONTAINER_VXLAN_WIRE_UNKNOWN_PEER) {
            atomic_fetch_add(&tunnel->unknown_peer_packets, 1);
            continue;
        }
        if (status == CONTAINER_VXLAN_WIRE_OVERSIZED_PACKET) {
            atomic_fetch_add(&tunnel->oversized_packets, 1);
            continue;
        }
        if (status == CONTAINER_VXLAN_WIRE_SOURCE_CIDR_MISMATCH) {
            atomic_fetch_add(&tunnel->source_cidr_mismatches, 1);
            continue;
        }
        if (status != CONTAINER_VXLAN_WIRE_SUCCESS) {
            atomic_fetch_add(&tunnel->invalid_packets, 1);
            continue;
        }

        uint32_t family = htonl(AF_INET);
        memcpy(packet, &family, sizeof(family));
        ssize_t written = write(tunnel->utun_fd, packet, UTUN_FAMILY_LENGTH + decoded.inner_packet_length);
        if (written == (ssize_t)(UTUN_FAMILY_LENGTH + decoded.inner_packet_length)) {
            atomic_fetch_add(&tunnel->received_packets, 1);
            atomic_fetch_add(&tunnel->received_bytes, decoded.inner_packet_length);
        } else if (written < 0 && errno == EBADF) {
            break;
        } else {
            atomic_fetch_add(&tunnel->invalid_packets, 1);
        }
    }

    free(datagram);
    free(packet);
    atomic_store(&tunnel->running, false);
    return NULL;
}

int container_vxlan_tunnel_create(
    const container_vxlan_tunnel_config_t *config,
    container_vxlan_tunnel_t **tunnel,
    char *interface_name,
    size_t interface_name_capacity,
    char *error_message,
    size_t error_message_capacity
) {
    if (config == NULL || tunnel == NULL || interface_name == NULL || interface_name_capacity == 0) {
        set_error(error_message, error_message_capacity, "invalid tunnel create arguments");
        return EINVAL;
    }
    if (config->vni == 0 || config->vni > 0x00ffffffU || config->port == 0 ||
        config->mtu < 576 || config->mtu > MAXIMUM_TUNNEL_MTU ||
        config->bind_ip == INADDR_ANY || config->local_netmask == 0 ||
        !mac_is_unicast(config->local_vtep_mac))
    {
        set_error(error_message, error_message_capacity, "invalid tunnel configuration");
        return EINVAL;
    }

    container_vxlan_tunnel_t *value = calloc(1, sizeof(*value));
    if (value == NULL) {
        set_error(error_message, error_message_capacity, "failed to allocate tunnel");
        return ENOMEM;
    }
    value->config = *config;
    value->udp_fd = -1;
    value->utun_fd = -1;
    if (pthread_mutex_init(&value->peers_lock, NULL) != 0) {
        free(value);
        set_error(error_message, error_message_capacity, "failed to initialize peer lock");
        return EIO;
    }

    value->udp_fd = open_udp_socket(config);
    if (value->udp_fd < 0) {
        int saved_errno = errno;
        pthread_mutex_destroy(&value->peers_lock);
        free(value);
        set_error(error_message, error_message_capacity, "failed to bind VXLAN UDP socket: %s", strerror(saved_errno));
        return saved_errno;
    }
    value->utun_fd = open_utun(value->interface_name);
    if (value->utun_fd < 0) {
        int saved_errno = errno;
        close(value->udp_fd);
        pthread_mutex_destroy(&value->peers_lock);
        free(value);
        set_error(error_message, error_message_capacity, "failed to create utun interface: %s", strerror(saved_errno));
        return saved_errno;
    }
    strlcpy(interface_name, value->interface_name, interface_name_capacity);
    *tunnel = value;
    return 0;
}

int container_vxlan_tunnel_set_peers(
    container_vxlan_tunnel_t *tunnel,
    const container_vxlan_peer_t *peers,
    size_t peer_count,
    char *error_message,
    size_t error_message_capacity
) {
    if (tunnel == NULL || (peer_count > 0 && peers == NULL)) {
        set_error(error_message, error_message_capacity, "invalid peer update arguments");
        return EINVAL;
    }

    container_vxlan_peer_t *copy = NULL;
    if (peer_count > 0) {
        copy = calloc(peer_count, sizeof(*copy));
        if (copy == NULL) {
            set_error(error_message, error_message_capacity, "failed to allocate peer table");
            return ENOMEM;
        }
        for (size_t index = 0; index < peer_count; ++index) {
            if (peers[index].pod_netmask == 0 || peers[index].public_ip == INADDR_ANY ||
                !mac_is_unicast(peers[index].vtep_mac))
            {
                free(copy);
                set_error(error_message, error_message_capacity, "invalid peer at index %zu", index);
                return EINVAL;
            }
            copy[index] = peers[index];
        }
    }

    pthread_mutex_lock(&tunnel->peers_lock);
    container_vxlan_peer_t *previous = tunnel->peers;
    tunnel->peers = copy;
    tunnel->peer_count = peer_count;
    pthread_mutex_unlock(&tunnel->peers_lock);
    free(previous);
    return 0;
}

int container_vxlan_tunnel_start(
    container_vxlan_tunnel_t *tunnel,
    char *error_message,
    size_t error_message_capacity
) {
    if (tunnel == NULL) {
        set_error(error_message, error_message_capacity, "tunnel is required");
        return EINVAL;
    }
    if (tunnel->udp_fd < 0 || tunnel->utun_fd < 0) {
        set_error(error_message, error_message_capacity, "a stopped tunnel cannot be restarted");
        return EBADF;
    }
    bool expected = false;
    if (!atomic_compare_exchange_strong(&tunnel->running, &expected, true)) {
        set_error(error_message, error_message_capacity, "tunnel is already running");
        return EALREADY;
    }

    int status = pthread_create(&tunnel->outbound_thread, NULL, run_outbound, tunnel);
    if (status != 0) {
        atomic_store(&tunnel->running, false);
        set_error(error_message, error_message_capacity, "failed to start outbound tunnel thread: %s", strerror(status));
        return status;
    }
    tunnel->outbound_thread_created = true;
    status = pthread_create(&tunnel->inbound_thread, NULL, run_inbound, tunnel);
    if (status != 0) {
        atomic_store(&tunnel->running, false);
        pthread_join(tunnel->outbound_thread, NULL);
        tunnel->outbound_thread_created = false;
        set_error(error_message, error_message_capacity, "failed to start inbound tunnel thread: %s", strerror(status));
        return status;
    }
    tunnel->inbound_thread_created = true;
    return 0;
}

void container_vxlan_tunnel_get_stats(
    const container_vxlan_tunnel_t *tunnel,
    container_vxlan_tunnel_stats_t *stats
) {
    if (tunnel == NULL || stats == NULL) {
        return;
    }
    stats->transmitted_packets = atomic_load(&tunnel->transmitted_packets);
    stats->transmitted_bytes = atomic_load(&tunnel->transmitted_bytes);
    stats->received_packets = atomic_load(&tunnel->received_packets);
    stats->received_bytes = atomic_load(&tunnel->received_bytes);
    stats->unknown_peer_packets = atomic_load(&tunnel->unknown_peer_packets);
    stats->invalid_packets = atomic_load(&tunnel->invalid_packets);
    stats->oversized_packets = atomic_load(&tunnel->oversized_packets);
    stats->source_cidr_mismatches = atomic_load(&tunnel->source_cidr_mismatches);
}

bool container_vxlan_tunnel_is_running(const container_vxlan_tunnel_t *tunnel) {
    return tunnel != NULL && atomic_load(&tunnel->running);
}

void container_vxlan_tunnel_stop(container_vxlan_tunnel_t *tunnel) {
    if (tunnel == NULL) {
        return;
    }
    atomic_store(&tunnel->running, false);
    if (tunnel->udp_fd >= 0) {
        shutdown(tunnel->udp_fd, SHUT_RDWR);
    }
    if (tunnel->outbound_thread_created) {
        pthread_join(tunnel->outbound_thread, NULL);
        tunnel->outbound_thread_created = false;
    }
    if (tunnel->inbound_thread_created) {
        pthread_join(tunnel->inbound_thread, NULL);
        tunnel->inbound_thread_created = false;
    }
    if (tunnel->udp_fd >= 0) {
        close(tunnel->udp_fd);
        tunnel->udp_fd = -1;
    }
    if (tunnel->utun_fd >= 0) {
        close(tunnel->utun_fd);
        tunnel->utun_fd = -1;
    }
}

void container_vxlan_tunnel_destroy(container_vxlan_tunnel_t *tunnel) {
    if (tunnel == NULL) {
        return;
    }
    container_vxlan_tunnel_stop(tunnel);
    if (tunnel->udp_fd >= 0) {
        close(tunnel->udp_fd);
    }
    if (tunnel->utun_fd >= 0) {
        close(tunnel->utun_fd);
    }
    free(tunnel->peers);
    pthread_mutex_destroy(&tunnel->peers_lock);
    free(tunnel);
}

struct container_vxlan_tunnel_v6 {
    container_vxlan_tunnel_config_v6_t config;
    int udp_fd;
    int utun_fd;
    int wake_read_fd;
    int wake_write_fd;
    char interface_name[IFNAMSIZ];
    pthread_t outbound_thread;
    pthread_t inbound_thread;
    bool outbound_thread_created;
    bool inbound_thread_created;
    atomic_bool running;
    pthread_mutex_t peers_lock;
    container_vxlan_peer_v6_t *peers;
    size_t peer_count;
    atomic_uint_fast64_t transmitted_packets;
    atomic_uint_fast64_t transmitted_bytes;
    atomic_uint_fast64_t received_packets;
    atomic_uint_fast64_t received_bytes;
    atomic_uint_fast64_t unknown_peer_packets;
    atomic_uint_fast64_t invalid_packets;
    atomic_uint_fast64_t oversized_packets;
    atomic_uint_fast64_t source_cidr_mismatches;
};

typedef int (*container_vxlan_thread_create_fn)(
    pthread_t *,
    const pthread_attr_t *,
    void *(*)(void *),
    void *
);

static int set_nonblocking_close_on_exec(int fd) {
    int descriptor_flags = fcntl(fd, F_GETFD);
    if (descriptor_flags < 0 || fcntl(fd, F_SETFD, descriptor_flags | FD_CLOEXEC) != 0) {
        return -1;
    }
    int status_flags = fcntl(fd, F_GETFL);
    if (status_flags < 0 || fcntl(fd, F_SETFL, status_flags | O_NONBLOCK) != 0) {
        return -1;
    }
    return 0;
}

static int open_v6_wake_pipe(int descriptors[2]) {
    if (pipe(descriptors) != 0) {
        return -1;
    }
    if (set_nonblocking_close_on_exec(descriptors[0]) != 0 ||
        set_nonblocking_close_on_exec(descriptors[1]) != 0)
    {
        int saved_errno = errno;
        close(descriptors[0]);
        close(descriptors[1]);
        descriptors[0] = -1;
        descriptors[1] = -1;
        errno = saved_errno;
        return -1;
    }
    return 0;
}

static void signal_v6_wake(const container_vxlan_tunnel_v6_t *tunnel) {
    if (tunnel == NULL || tunnel->wake_write_fd < 0) {
        return;
    }
    const uint8_t value = 1;
    while (write(tunnel->wake_write_fd, &value, sizeof(value)) < 0) {
        if (errno == EINTR) {
            continue;
        }
        // EAGAIN means a wake byte is already pending, which is sufficient.
        return;
    }
}

static void drain_v6_wake(const container_vxlan_tunnel_v6_t *tunnel) {
    uint8_t buffer[64];
    for (;;) {
        ssize_t length = read(tunnel->wake_read_fd, buffer, sizeof(buffer));
        if (length > 0) {
            continue;
        }
        if (length < 0 && errno == EINTR) {
            continue;
        }
        return;
    }
}

// Returns 1 when utun has a packet, 0 when the wake pipe fired, and -1 on an
// unrecoverable descriptor error.
static int wait_for_v6_outbound_packet(const container_vxlan_tunnel_v6_t *tunnel) {
    struct pollfd descriptors[2] = {
        {.fd = tunnel->utun_fd, .events = POLLIN},
        {.fd = tunnel->wake_read_fd, .events = POLLIN},
    };
    for (;;) {
        int result = poll(descriptors, 2, -1);
        if (result < 0 && errno == EINTR) {
            continue;
        }
        if (result <= 0) {
            return -1;
        }
        if ((descriptors[1].revents & (POLLIN | POLLERR | POLLHUP | POLLNVAL)) != 0) {
            drain_v6_wake(tunnel);
            return 0;
        }
        if ((descriptors[0].revents & POLLIN) != 0) {
            return 1;
        }
        if ((descriptors[0].revents & (POLLERR | POLLHUP | POLLNVAL)) != 0) {
            return -1;
        }
    }
}

static bool ipv6_address_is_zero(const uint8_t address[16]) {
    static const uint8_t zero[16] = {0};
    return memcmp(address, zero, sizeof(zero)) == 0;
}

static bool ipv6_address_is_unicast(const uint8_t address[16]) {
    return !ipv6_address_is_zero(address) && address[0] != 0xffU;
}

static bool ipv6_address_is_loopback(const uint8_t address[16]) {
    static const uint8_t loopback[16] = {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1};
    return memcmp(address, loopback, sizeof(loopback)) == 0;
}

static bool ipv6_address_is_link_local(const uint8_t address[16]) {
    return address[0] == 0xfeU && (address[1] & 0xc0U) == 0x80U;
}

static bool ipv6_address_is_ipv4_mapped(const uint8_t address[16]) {
    static const uint8_t mapped_prefix[12] = {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff};
    return memcmp(address, mapped_prefix, sizeof(mapped_prefix)) == 0;
}

static bool ipv6_address_is_valid_underlay(const uint8_t address[16]) {
    return ipv6_address_is_unicast(address) && !ipv6_address_is_loopback(address) &&
        !ipv6_address_is_link_local(address) && !ipv6_address_is_ipv4_mapped(address);
}

static bool ipv6_address_in_network(
    const uint8_t address[16],
    const uint8_t network[16],
    uint8_t prefix_length
) {
    if (prefix_length > 128) {
        return false;
    }
    size_t whole_bytes = prefix_length / 8U;
    uint8_t remaining_bits = prefix_length % 8U;
    if (whole_bytes > 0 && memcmp(address, network, whole_bytes) != 0) {
        return false;
    }
    if (remaining_bits == 0) {
        return true;
    }
    uint8_t mask = (uint8_t)(0xffU << (8U - remaining_bits));
    return (address[whole_bytes] & mask) == (network[whole_bytes] & mask);
}

static bool ipv6_network_is_canonical(const uint8_t network[16], uint8_t prefix_length) {
    if (prefix_length == 0 || prefix_length > 128 || ipv6_address_is_zero(network) ||
        network[0] == 0xffU || ipv6_address_is_loopback(network) ||
        ipv6_address_is_link_local(network) || ipv6_address_is_ipv4_mapped(network))
    {
        return false;
    }
    size_t whole_bytes = prefix_length / 8U;
    uint8_t remaining_bits = prefix_length % 8U;
    size_t first_host_byte = whole_bytes;
    if (remaining_bits != 0) {
        uint8_t host_mask = (uint8_t)(0xffU >> remaining_bits);
        if ((network[whole_bytes] & host_mask) != 0) {
            return false;
        }
        first_host_byte += 1;
    }
    for (size_t index = first_host_byte; index < 16; ++index) {
        if (network[index] != 0) {
            return false;
        }
    }
    return true;
}

static bool valid_v6_config(const container_vxlan_tunnel_config_v6_t *config) {
    return config != NULL && config->abi_version == CONTAINER_VXLAN_V6_ABI_VERSION &&
        config->struct_size == sizeof(*config) && config->vni > 0 && config->vni <= 0x00ffffffU &&
        config->port > 0 && config->mtu >= 1280 && config->mtu <= MAXIMUM_TUNNEL_MTU &&
        ipv6_address_is_valid_underlay(config->bind_ip) &&
        ipv6_network_is_canonical(config->local_network, config->prefix_length) &&
        mac_is_unicast(config->local_vtep_mac);
}

static bool valid_v6_peer(const container_vxlan_peer_v6_t *peer) {
    return peer != NULL && peer->abi_version == CONTAINER_VXLAN_V6_ABI_VERSION &&
        peer->struct_size == sizeof(*peer) &&
        ipv6_network_is_canonical(peer->pod_network, peer->prefix_length) &&
        ipv6_address_is_valid_underlay(peer->public_ip) && mac_is_unicast(peer->vtep_mac);
}

static bool valid_v6_peers(const container_vxlan_peer_v6_t *peers, size_t peer_count) {
    if (peer_count > 0 && peers == NULL) {
        return false;
    }
    for (size_t index = 0; index < peer_count; ++index) {
        if (!valid_v6_peer(&peers[index])) {
            return false;
        }
    }
    return true;
}

static const container_vxlan_peer_v6_t *v6_peer_for_destination(
    const container_vxlan_peer_v6_t *peers,
    size_t peer_count,
    const uint8_t destination[16]
) {
    const container_vxlan_peer_v6_t *match = NULL;
    for (size_t index = 0; index < peer_count; ++index) {
        if (ipv6_address_in_network(destination, peers[index].pod_network, peers[index].prefix_length) &&
            (match == NULL || peers[index].prefix_length > match->prefix_length))
        {
            match = &peers[index];
        }
    }
    return match;
}

static const container_vxlan_peer_v6_t *v6_peer_for_source(
    const container_vxlan_peer_v6_t *peers,
    size_t peer_count,
    const uint8_t public_ip[16],
    const uint8_t vtep_mac[6]
) {
    for (size_t index = 0; index < peer_count; ++index) {
        if (memcmp(peers[index].public_ip, public_ip, 16) == 0 &&
            memcmp(peers[index].vtep_mac, vtep_mac, 6) == 0)
        {
            return &peers[index];
        }
    }
    return NULL;
}

static container_vxlan_wire_status_t ipv6_packet_length(
    const uint8_t *packet,
    size_t available,
    size_t mtu,
    size_t *packet_length
) {
    if (available < MINIMUM_IPV6_HEADER_LENGTH || (packet[0] >> 4) != 6) {
        return CONTAINER_VXLAN_WIRE_INVALID_PACKET;
    }
    uint16_t network_payload_length;
    memcpy(&network_payload_length, packet + 4, sizeof(network_payload_length));
    size_t value = MINIMUM_IPV6_HEADER_LENGTH + ntohs(network_payload_length);
    if (value > mtu) {
        return CONTAINER_VXLAN_WIRE_OVERSIZED_PACKET;
    }
    if (value > available) {
        return CONTAINER_VXLAN_WIRE_INVALID_PACKET;
    }
    *packet_length = value;
    return CONTAINER_VXLAN_WIRE_SUCCESS;
}

static const uint8_t *ipv6_source(const uint8_t *packet) {
    return packet + 8;
}

static const uint8_t *ipv6_destination(const uint8_t *packet) {
    return packet + 24;
}

static bool valid_vxlan_header_v6(
    const container_vxlan_tunnel_config_v6_t *config,
    const uint8_t *packet
) {
    if (packet[0] != 0x08U || packet[1] != 0 || packet[2] != 0 || packet[3] != 0 || packet[7] != 0) {
        return false;
    }
    uint32_t vni = ((uint32_t)packet[4] << 16) | ((uint32_t)packet[5] << 8) | packet[6];
    return vni == config->vni;
}

container_vxlan_wire_status_t container_vxlan_encode_ipv6(
    const container_vxlan_tunnel_config_v6_t *config,
    const container_vxlan_peer_v6_t *peers,
    size_t peer_count,
    const uint8_t *inner_packet,
    size_t inner_packet_available,
    uint8_t *datagram,
    size_t datagram_capacity,
    container_vxlan_encoded_packet_v6_t *encoded
) {
    if (encoded != NULL) {
        memset(encoded, 0, sizeof(*encoded));
    }
    if (!valid_v6_config(config) || !valid_v6_peers(peers, peer_count) || inner_packet == NULL ||
        datagram == NULL || encoded == NULL)
    {
        return CONTAINER_VXLAN_WIRE_INVALID_ARGUMENT;
    }

    size_t inner_packet_length = 0;
    container_vxlan_wire_status_t status =
        ipv6_packet_length(inner_packet, inner_packet_available, config->mtu, &inner_packet_length);
    if (status != CONTAINER_VXLAN_WIRE_SUCCESS) {
        return status;
    }
    const uint8_t *inner_source = ipv6_source(inner_packet);
    const uint8_t *inner_destination = ipv6_destination(inner_packet);
    if (!ipv6_address_is_unicast(inner_source) ||
        !ipv6_address_in_network(inner_source, config->local_network, config->prefix_length))
    {
        return CONTAINER_VXLAN_WIRE_SOURCE_CIDR_MISMATCH;
    }
    if (!ipv6_address_is_unicast(inner_destination)) {
        return CONTAINER_VXLAN_WIRE_INVALID_PACKET;
    }

    const container_vxlan_peer_v6_t *peer =
        v6_peer_for_destination(peers, peer_count, inner_destination);
    if (peer == NULL) {
        return CONTAINER_VXLAN_WIRE_UNKNOWN_PEER;
    }

    size_t datagram_length = VXLAN_HEADER_LENGTH + ETHERNET_HEADER_LENGTH + inner_packet_length;
    if (datagram_capacity < datagram_length) {
        return CONTAINER_VXLAN_WIRE_OUTPUT_TOO_SMALL;
    }

    memset(datagram, 0, VXLAN_HEADER_LENGTH + ETHERNET_HEADER_LENGTH);
    datagram[0] = 0x08;
    datagram[4] = (uint8_t)((config->vni >> 16) & 0xffU);
    datagram[5] = (uint8_t)((config->vni >> 8) & 0xffU);
    datagram[6] = (uint8_t)(config->vni & 0xffU);
    uint8_t *ethernet = datagram + VXLAN_HEADER_LENGTH;
    memcpy(ethernet, peer->vtep_mac, 6);
    memcpy(ethernet + 6, config->local_vtep_mac, 6);
    ethernet[12] = 0x86;
    ethernet[13] = 0xdd;
    memcpy(ethernet + ETHERNET_HEADER_LENGTH, inner_packet, inner_packet_length);

    encoded->datagram_length = datagram_length;
    encoded->inner_packet_length = inner_packet_length;
    memcpy(encoded->destination_ip, peer->public_ip, 16);
    encoded->destination_port = config->port;
    return CONTAINER_VXLAN_WIRE_SUCCESS;
}

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
) {
    if (decoded != NULL) {
        memset(decoded, 0, sizeof(*decoded));
    }
    if (!valid_v6_config(config) || !valid_v6_peers(peers, peer_count) ||
        outer_source_ip == NULL || datagram == NULL || inner_packet == NULL || decoded == NULL)
    {
        return CONTAINER_VXLAN_WIRE_INVALID_ARGUMENT;
    }
    if (datagram_length < VXLAN_HEADER_LENGTH + ETHERNET_HEADER_LENGTH + MINIMUM_IPV6_HEADER_LENGTH ||
        !valid_vxlan_header_v6(config, datagram))
    {
        return CONTAINER_VXLAN_WIRE_INVALID_PACKET;
    }

    const uint8_t *ethernet = datagram + VXLAN_HEADER_LENGTH;
    if (memcmp(ethernet, config->local_vtep_mac, 6) != 0 || ethernet[12] != 0x86 ||
        ethernet[13] != 0xdd)
    {
        return CONTAINER_VXLAN_WIRE_INVALID_PACKET;
    }

    const container_vxlan_peer_v6_t *peer =
        v6_peer_for_source(peers, peer_count, outer_source_ip, ethernet + 6);
    if (peer == NULL) {
        return CONTAINER_VXLAN_WIRE_UNKNOWN_PEER;
    }

    const uint8_t *inner = ethernet + ETHERNET_HEADER_LENGTH;
    size_t available = datagram_length - VXLAN_HEADER_LENGTH - ETHERNET_HEADER_LENGTH;
    size_t inner_packet_length = 0;
    container_vxlan_wire_status_t status =
        ipv6_packet_length(inner, available, config->mtu, &inner_packet_length);
    if (status != CONTAINER_VXLAN_WIRE_SUCCESS) {
        return status;
    }
    const uint8_t *inner_destination = ipv6_destination(inner);
    if (!ipv6_address_is_unicast(inner_destination) ||
        !ipv6_address_in_network(inner_destination, config->local_network, config->prefix_length))
    {
        return CONTAINER_VXLAN_WIRE_INVALID_PACKET;
    }
    const uint8_t *inner_source = ipv6_source(inner);
    decoded->source_cidr_mismatch =
        !ipv6_address_is_unicast(inner_source) ||
        (memcmp(inner_source, peer->public_ip, 16) != 0 &&
         !ipv6_address_in_network(inner_source, peer->pod_network, peer->prefix_length));
    if (decoded->source_cidr_mismatch) {
        return CONTAINER_VXLAN_WIRE_SOURCE_CIDR_MISMATCH;
    }
    if (inner_packet_capacity < inner_packet_length) {
        return CONTAINER_VXLAN_WIRE_OUTPUT_TOO_SMALL;
    }

    memcpy(inner_packet, inner, inner_packet_length);
    decoded->inner_packet_length = inner_packet_length;
    return CONTAINER_VXLAN_WIRE_SUCCESS;
}

static int open_udp_socket_v6(const container_vxlan_tunnel_config_v6_t *config) {
    int fd = socket(AF_INET6, SOCK_DGRAM, IPPROTO_UDP);
    if (fd < 0) {
        return -1;
    }

    int enabled = 1;
    if (setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &enabled, sizeof(enabled)) != 0 ||
        setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &enabled, sizeof(enabled)) != 0 ||
        set_socket_buffer(fd, SO_RCVBUF) != 0 || set_socket_buffer(fd, SO_SNDBUF) != 0 ||
        set_receive_timeout(fd) != 0)
    {
        close(fd);
        return -1;
    }

    struct sockaddr_in6 address = {0};
    address.sin6_len = sizeof(address);
    address.sin6_family = AF_INET6;
    address.sin6_port = htons(config->port);
    memcpy(&address.sin6_addr, config->bind_ip, 16);
    if (bind(fd, (struct sockaddr *)&address, sizeof(address)) != 0) {
        close(fd);
        return -1;
    }
    return fd;
}

static void *run_outbound_v6(void *context) {
    container_vxlan_tunnel_v6_t *tunnel = context;
    size_t packet_capacity = UTUN_FAMILY_LENGTH + tunnel->config.mtu;
    size_t datagram_capacity = VXLAN_HEADER_LENGTH + ETHERNET_HEADER_LENGTH + tunnel->config.mtu;
    uint8_t *packet = malloc(packet_capacity);
    uint8_t *datagram = malloc(datagram_capacity);
    if (packet == NULL || datagram == NULL) {
        free(packet);
        free(datagram);
        atomic_store(&tunnel->running, false);
        return NULL;
    }

    while (atomic_load(&tunnel->running)) {
        int wait_result = wait_for_v6_outbound_packet(tunnel);
        if (wait_result <= 0) {
            break;
        }
        ssize_t read_length = read(tunnel->utun_fd, packet, packet_capacity);
        if (read_length < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)) {
            continue;
        }
        if (read_length <= 0) {
            break;
        }
        if ((size_t)read_length <= UTUN_FAMILY_LENGTH) {
            atomic_fetch_add(&tunnel->invalid_packets, 1);
            continue;
        }

        uint32_t family;
        memcpy(&family, packet, sizeof(family));
        if (ntohl(family) != AF_INET6) {
            atomic_fetch_add(&tunnel->invalid_packets, 1);
            continue;
        }

        container_vxlan_encoded_packet_v6_t encoded;
        pthread_mutex_lock(&tunnel->peers_lock);
        container_vxlan_wire_status_t status = container_vxlan_encode_ipv6(
            &tunnel->config,
            tunnel->peers,
            tunnel->peer_count,
            packet + UTUN_FAMILY_LENGTH,
            (size_t)read_length - UTUN_FAMILY_LENGTH,
            datagram,
            datagram_capacity,
            &encoded
        );
        pthread_mutex_unlock(&tunnel->peers_lock);
        if (status == CONTAINER_VXLAN_WIRE_UNKNOWN_PEER) {
            atomic_fetch_add(&tunnel->unknown_peer_packets, 1);
            continue;
        }
        if (status == CONTAINER_VXLAN_WIRE_OVERSIZED_PACKET) {
            atomic_fetch_add(&tunnel->oversized_packets, 1);
            continue;
        }
        if (status == CONTAINER_VXLAN_WIRE_SOURCE_CIDR_MISMATCH) {
            atomic_fetch_add(&tunnel->source_cidr_mismatches, 1);
            continue;
        }
        if (status != CONTAINER_VXLAN_WIRE_SUCCESS) {
            atomic_fetch_add(&tunnel->invalid_packets, 1);
            continue;
        }

        struct sockaddr_in6 destination = {0};
        destination.sin6_len = sizeof(destination);
        destination.sin6_family = AF_INET6;
        destination.sin6_port = htons(encoded.destination_port);
        memcpy(&destination.sin6_addr, encoded.destination_ip, 16);
        ssize_t sent = sendto(
            tunnel->udp_fd,
            datagram,
            encoded.datagram_length,
            0,
            (struct sockaddr *)&destination,
            sizeof(destination)
        );
        if (sent == (ssize_t)encoded.datagram_length) {
            atomic_fetch_add(&tunnel->transmitted_packets, 1);
            atomic_fetch_add(&tunnel->transmitted_bytes, encoded.inner_packet_length);
        } else if (sent < 0 && (errno == EBADF || errno == ENOTSOCK)) {
            break;
        } else {
            atomic_fetch_add(&tunnel->invalid_packets, 1);
        }
    }

    free(packet);
    free(datagram);
    atomic_store(&tunnel->running, false);
    return NULL;
}

static void *run_inbound_v6(void *context) {
    container_vxlan_tunnel_v6_t *tunnel = context;
    size_t datagram_capacity = VXLAN_HEADER_LENGTH + ETHERNET_HEADER_LENGTH + tunnel->config.mtu;
    uint8_t *datagram = malloc(datagram_capacity);
    uint8_t *packet = malloc(UTUN_FAMILY_LENGTH + tunnel->config.mtu);
    if (datagram == NULL || packet == NULL) {
        free(datagram);
        free(packet);
        atomic_store(&tunnel->running, false);
        signal_v6_wake(tunnel);
        return NULL;
    }

    while (atomic_load(&tunnel->running)) {
        struct sockaddr_in6 source = {0};
        socklen_t source_length = sizeof(source);
        ssize_t received = recvfrom(
            tunnel->udp_fd,
            datagram,
            datagram_capacity,
            0,
            (struct sockaddr *)&source,
            &source_length
        );
        if (received < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)) {
            continue;
        }
        if (received <= 0) {
            break;
        }
        if (source_length < sizeof(source) || source.sin6_family != AF_INET6) {
            atomic_fetch_add(&tunnel->invalid_packets, 1);
            continue;
        }
        container_vxlan_decoded_packet_t decoded;
        pthread_mutex_lock(&tunnel->peers_lock);
        container_vxlan_wire_status_t status = container_vxlan_decode_ipv6(
            &tunnel->config,
            tunnel->peers,
            tunnel->peer_count,
            (const uint8_t *)&source.sin6_addr,
            datagram,
            (size_t)received,
            packet + UTUN_FAMILY_LENGTH,
            tunnel->config.mtu,
            &decoded
        );
        pthread_mutex_unlock(&tunnel->peers_lock);
        if (status == CONTAINER_VXLAN_WIRE_UNKNOWN_PEER) {
            atomic_fetch_add(&tunnel->unknown_peer_packets, 1);
            continue;
        }
        if (status == CONTAINER_VXLAN_WIRE_OVERSIZED_PACKET) {
            atomic_fetch_add(&tunnel->oversized_packets, 1);
            continue;
        }
        if (status == CONTAINER_VXLAN_WIRE_SOURCE_CIDR_MISMATCH) {
            atomic_fetch_add(&tunnel->source_cidr_mismatches, 1);
            continue;
        }
        if (status != CONTAINER_VXLAN_WIRE_SUCCESS) {
            atomic_fetch_add(&tunnel->invalid_packets, 1);
            continue;
        }

        uint32_t family = htonl(AF_INET6);
        memcpy(packet, &family, sizeof(family));
        ssize_t written = write(tunnel->utun_fd, packet, UTUN_FAMILY_LENGTH + decoded.inner_packet_length);
        if (written == (ssize_t)(UTUN_FAMILY_LENGTH + decoded.inner_packet_length)) {
            atomic_fetch_add(&tunnel->received_packets, 1);
            atomic_fetch_add(&tunnel->received_bytes, decoded.inner_packet_length);
        } else if (written < 0 && errno == EBADF) {
            break;
        } else {
            atomic_fetch_add(&tunnel->invalid_packets, 1);
        }
    }

    free(datagram);
    free(packet);
    atomic_store(&tunnel->running, false);
    signal_v6_wake(tunnel);
    return NULL;
}

int container_vxlan_tunnel_v6_create(
    const container_vxlan_tunnel_config_v6_t *config,
    container_vxlan_tunnel_v6_t **tunnel,
    char *interface_name,
    size_t interface_name_capacity,
    char *error_message,
    size_t error_message_capacity
) {
    if (!valid_v6_config(config) || tunnel == NULL || interface_name == NULL ||
        interface_name_capacity == 0)
    {
        set_error(error_message, error_message_capacity, "invalid IPv6 tunnel create arguments");
        return EINVAL;
    }

    container_vxlan_tunnel_v6_t *value = calloc(1, sizeof(*value));
    if (value == NULL) {
        set_error(error_message, error_message_capacity, "failed to allocate IPv6 tunnel");
        return ENOMEM;
    }
    value->config = *config;
    value->udp_fd = -1;
    value->utun_fd = -1;
    value->wake_read_fd = -1;
    value->wake_write_fd = -1;
    if (pthread_mutex_init(&value->peers_lock, NULL) != 0) {
        free(value);
        set_error(error_message, error_message_capacity, "failed to initialize IPv6 peer lock");
        return EIO;
    }

    value->udp_fd = open_udp_socket_v6(config);
    if (value->udp_fd < 0) {
        int saved_errno = errno;
        pthread_mutex_destroy(&value->peers_lock);
        free(value);
        set_error(
            error_message,
            error_message_capacity,
            "failed to bind IPv6 VXLAN UDP socket: %s",
            strerror(saved_errno)
        );
        return saved_errno;
    }
    value->utun_fd = open_utun(value->interface_name);
    if (value->utun_fd < 0) {
        int saved_errno = errno;
        close(value->udp_fd);
        pthread_mutex_destroy(&value->peers_lock);
        free(value);
        set_error(
            error_message,
            error_message_capacity,
            "failed to create IPv6 utun interface: %s",
            strerror(saved_errno)
        );
        return saved_errno;
    }
    int wake_descriptors[2] = {-1, -1};
    if (open_v6_wake_pipe(wake_descriptors) != 0) {
        int saved_errno = errno;
        close(value->utun_fd);
        close(value->udp_fd);
        pthread_mutex_destroy(&value->peers_lock);
        free(value);
        set_error(
            error_message,
            error_message_capacity,
            "failed to create IPv6 tunnel wake pipe: %s",
            strerror(saved_errno)
        );
        return saved_errno;
    }
    value->wake_read_fd = wake_descriptors[0];
    value->wake_write_fd = wake_descriptors[1];

    strlcpy(interface_name, value->interface_name, interface_name_capacity);
    *tunnel = value;
    return 0;
}

int container_vxlan_tunnel_v6_set_peers(
    container_vxlan_tunnel_v6_t *tunnel,
    const container_vxlan_peer_v6_t *peers,
    size_t peer_count,
    char *error_message,
    size_t error_message_capacity
) {
    if (peer_count > SIZE_MAX / sizeof(container_vxlan_peer_v6_t)) {
        set_error(error_message, error_message_capacity, "IPv6 peer table is too large");
        return EOVERFLOW;
    }
    if (tunnel == NULL || !valid_v6_peers(peers, peer_count)) {
        set_error(error_message, error_message_capacity, "invalid IPv6 peer update arguments");
        return EINVAL;
    }

    container_vxlan_peer_v6_t *copy = NULL;
    if (peer_count > 0) {
        copy = calloc(peer_count, sizeof(*copy));
        if (copy == NULL) {
            set_error(error_message, error_message_capacity, "failed to allocate IPv6 peer table");
            return ENOMEM;
        }
        memcpy(copy, peers, peer_count * sizeof(*copy));
    }

    pthread_mutex_lock(&tunnel->peers_lock);
    container_vxlan_peer_v6_t *previous = tunnel->peers;
    tunnel->peers = copy;
    tunnel->peer_count = peer_count;
    pthread_mutex_unlock(&tunnel->peers_lock);
    free(previous);
    return 0;
}

static int start_v6_with_thread_creator(
    container_vxlan_tunnel_v6_t *tunnel,
    char *error_message,
    size_t error_message_capacity,
    container_vxlan_thread_create_fn create_thread
) {
    if (tunnel == NULL || create_thread == NULL) {
        set_error(error_message, error_message_capacity, "IPv6 tunnel is required");
        return EINVAL;
    }
    if (tunnel->udp_fd < 0 || tunnel->utun_fd < 0 || tunnel->wake_read_fd < 0 ||
        tunnel->wake_write_fd < 0)
    {
        set_error(error_message, error_message_capacity, "a stopped IPv6 tunnel cannot be restarted");
        return EBADF;
    }
    bool expected = false;
    if (!atomic_compare_exchange_strong(&tunnel->running, &expected, true)) {
        set_error(error_message, error_message_capacity, "IPv6 tunnel is already running");
        return EALREADY;
    }

    int status = create_thread(&tunnel->outbound_thread, NULL, run_outbound_v6, tunnel);
    if (status != 0) {
        atomic_store(&tunnel->running, false);
        set_error(
            error_message,
            error_message_capacity,
            "failed to start outbound IPv6 tunnel thread: %s",
            strerror(status)
        );
        return status;
    }
    tunnel->outbound_thread_created = true;
    status = create_thread(&tunnel->inbound_thread, NULL, run_inbound_v6, tunnel);
    if (status != 0) {
        atomic_store(&tunnel->running, false);
        signal_v6_wake(tunnel);
        pthread_join(tunnel->outbound_thread, NULL);
        tunnel->outbound_thread_created = false;
        drain_v6_wake(tunnel);
        set_error(
            error_message,
            error_message_capacity,
            "failed to start inbound IPv6 tunnel thread: %s",
            strerror(status)
        );
        return status;
    }
    tunnel->inbound_thread_created = true;
    return 0;
}

int container_vxlan_tunnel_v6_start(
    container_vxlan_tunnel_v6_t *tunnel,
    char *error_message,
    size_t error_message_capacity
) {
    return start_v6_with_thread_creator(
        tunnel,
        error_message,
        error_message_capacity,
        pthread_create
    );
}

void container_vxlan_tunnel_v6_get_stats(
    const container_vxlan_tunnel_v6_t *tunnel,
    container_vxlan_tunnel_stats_t *stats
) {
    if (tunnel == NULL || stats == NULL) {
        return;
    }
    stats->transmitted_packets = atomic_load(&tunnel->transmitted_packets);
    stats->transmitted_bytes = atomic_load(&tunnel->transmitted_bytes);
    stats->received_packets = atomic_load(&tunnel->received_packets);
    stats->received_bytes = atomic_load(&tunnel->received_bytes);
    stats->unknown_peer_packets = atomic_load(&tunnel->unknown_peer_packets);
    stats->invalid_packets = atomic_load(&tunnel->invalid_packets);
    stats->oversized_packets = atomic_load(&tunnel->oversized_packets);
    stats->source_cidr_mismatches = atomic_load(&tunnel->source_cidr_mismatches);
}

bool container_vxlan_tunnel_v6_is_running(const container_vxlan_tunnel_v6_t *tunnel) {
    return tunnel != NULL && atomic_load(&tunnel->running);
}

void container_vxlan_tunnel_v6_stop(container_vxlan_tunnel_v6_t *tunnel) {
    if (tunnel == NULL) {
        return;
    }
    atomic_store(&tunnel->running, false);
    signal_v6_wake(tunnel);
    if (tunnel->udp_fd >= 0) {
        shutdown(tunnel->udp_fd, SHUT_RDWR);
    }
    if (tunnel->outbound_thread_created) {
        pthread_join(tunnel->outbound_thread, NULL);
        tunnel->outbound_thread_created = false;
    }
    if (tunnel->inbound_thread_created) {
        pthread_join(tunnel->inbound_thread, NULL);
        tunnel->inbound_thread_created = false;
    }
    if (tunnel->udp_fd >= 0) {
        close(tunnel->udp_fd);
        tunnel->udp_fd = -1;
    }
    if (tunnel->utun_fd >= 0) {
        close(tunnel->utun_fd);
        tunnel->utun_fd = -1;
    }
    if (tunnel->wake_read_fd >= 0) {
        close(tunnel->wake_read_fd);
        tunnel->wake_read_fd = -1;
    }
    if (tunnel->wake_write_fd >= 0) {
        close(tunnel->wake_write_fd);
        tunnel->wake_write_fd = -1;
    }
}

void container_vxlan_tunnel_v6_destroy(container_vxlan_tunnel_v6_t *tunnel) {
    if (tunnel == NULL) {
        return;
    }
    container_vxlan_tunnel_v6_stop(tunnel);
    if (tunnel->udp_fd >= 0) {
        close(tunnel->udp_fd);
    }
    if (tunnel->utun_fd >= 0) {
        close(tunnel->utun_fd);
    }
    if (tunnel->wake_read_fd >= 0) {
        close(tunnel->wake_read_fd);
    }
    if (tunnel->wake_write_fd >= 0) {
        close(tunnel->wake_write_fd);
    }
    free(tunnel->peers);
    pthread_mutex_destroy(&tunnel->peers_lock);
    free(tunnel);
}

#if defined(CONTAINER_VXLAN_TEST_HOOKS)
typedef struct {
    container_vxlan_tunnel_v6_t tunnel;
    int udp_peer_fd;
    int utun_write_fd;
} container_vxlan_v6_lifecycle_fixture_t;

static void close_if_open(int *fd) {
    if (*fd >= 0) {
        close(*fd);
        *fd = -1;
    }
}

static int initialize_v6_lifecycle_fixture(container_vxlan_v6_lifecycle_fixture_t *fixture) {
    memset(fixture, 0, sizeof(*fixture));
    fixture->tunnel.udp_fd = -1;
    fixture->tunnel.utun_fd = -1;
    fixture->tunnel.wake_read_fd = -1;
    fixture->tunnel.wake_write_fd = -1;
    fixture->udp_peer_fd = -1;
    fixture->utun_write_fd = -1;
    fixture->tunnel.config.mtu = 1280;
    atomic_init(&fixture->tunnel.running, false);

    int status = pthread_mutex_init(&fixture->tunnel.peers_lock, NULL);
    if (status != 0) {
        return status;
    }

    int udp_descriptors[2] = {-1, -1};
    if (socketpair(AF_UNIX, SOCK_DGRAM, 0, udp_descriptors) != 0) {
        status = errno;
        goto failure;
    }
    fixture->tunnel.udp_fd = udp_descriptors[0];
    fixture->udp_peer_fd = udp_descriptors[1];

    int utun_descriptors[2] = {-1, -1};
    if (pipe(utun_descriptors) != 0) {
        status = errno;
        goto failure;
    }
    fixture->tunnel.utun_fd = utun_descriptors[0];
    fixture->utun_write_fd = utun_descriptors[1];

    int wake_descriptors[2] = {-1, -1};
    if (open_v6_wake_pipe(wake_descriptors) != 0) {
        status = errno;
        goto failure;
    }
    fixture->tunnel.wake_read_fd = wake_descriptors[0];
    fixture->tunnel.wake_write_fd = wake_descriptors[1];
    return 0;

failure:
    close_if_open(&fixture->tunnel.udp_fd);
    close_if_open(&fixture->udp_peer_fd);
    close_if_open(&fixture->tunnel.utun_fd);
    close_if_open(&fixture->utun_write_fd);
    close_if_open(&fixture->tunnel.wake_read_fd);
    close_if_open(&fixture->tunnel.wake_write_fd);
    pthread_mutex_destroy(&fixture->tunnel.peers_lock);
    return status;
}

static void destroy_v6_lifecycle_fixture(container_vxlan_v6_lifecycle_fixture_t *fixture) {
    container_vxlan_tunnel_v6_stop(&fixture->tunnel);
    close_if_open(&fixture->udp_peer_fd);
    close_if_open(&fixture->utun_write_fd);
    pthread_mutex_destroy(&fixture->tunnel.peers_lock);
}

static bool v6_lifecycle_fixture_is_stopped(
    const container_vxlan_v6_lifecycle_fixture_t *fixture
) {
    return !atomic_load(&fixture->tunnel.running) &&
        !fixture->tunnel.outbound_thread_created &&
        !fixture->tunnel.inbound_thread_created && fixture->tunnel.udp_fd == -1 &&
        fixture->tunnel.utun_fd == -1 && fixture->tunnel.wake_read_fd == -1 &&
        fixture->tunnel.wake_write_fd == -1;
}

__attribute__((visibility("hidden"))) int container_vxlan_debug_v6_idle_stop(void) {
    container_vxlan_v6_lifecycle_fixture_t fixture;
    int status = initialize_v6_lifecycle_fixture(&fixture);
    if (status != 0) {
        return status;
    }

    char error_message[128] = {0};
    status = start_v6_with_thread_creator(
        &fixture.tunnel,
        error_message,
        sizeof(error_message),
        pthread_create
    );
    if (status == 0) {
        container_vxlan_tunnel_v6_stop(&fixture.tunnel);
        if (!v6_lifecycle_fixture_is_stopped(&fixture)) {
            status = EIO;
        }
    }
    destroy_v6_lifecycle_fixture(&fixture);
    return status;
}

static int create_outbound_then_fail_inbound(
    pthread_t *thread,
    const pthread_attr_t *attributes,
    void *(*start_routine)(void *),
    void *context
) {
    if (start_routine == run_inbound_v6) {
        return EAGAIN;
    }
    return pthread_create(thread, attributes, start_routine, context);
}

__attribute__((visibility("hidden"))) int container_vxlan_debug_v6_inbound_start_failure(void) {
    container_vxlan_v6_lifecycle_fixture_t fixture;
    int status = initialize_v6_lifecycle_fixture(&fixture);
    if (status != 0) {
        return status;
    }

    char error_message[128] = {0};
    status = start_v6_with_thread_creator(
        &fixture.tunnel,
        error_message,
        sizeof(error_message),
        create_outbound_then_fail_inbound
    );
    if (status == EAGAIN && !fixture.tunnel.outbound_thread_created &&
        !fixture.tunnel.inbound_thread_created && !atomic_load(&fixture.tunnel.running))
    {
        // A failed second pthread_create must leave the live descriptors reusable,
        // including a fully drained wake pipe.
        status = start_v6_with_thread_creator(
            &fixture.tunnel,
            error_message,
            sizeof(error_message),
            pthread_create
        );
        if (status == 0) {
            container_vxlan_tunnel_v6_stop(&fixture.tunnel);
            if (!v6_lifecycle_fixture_is_stopped(&fixture)) {
                status = EIO;
            }
        }
    } else if (status == EAGAIN) {
        status = EIO;
    }
    destroy_v6_lifecycle_fixture(&fixture);
    return status;
}
#endif
