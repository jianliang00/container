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
#define MAXIMUM_TUNNEL_MTU 9000U
#define SOCKET_BUFFER_SIZE (8 * 1024 * 1024)
#define SOCKET_RECEIVE_TIMEOUT_SECONDS 1

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
    const uint8_t vtep_mac[6]
) {
    for (size_t index = 0; index < peer_count; ++index) {
        if (peers[index].public_ip == public_ip && memcmp(peers[index].vtep_mac, vtep_mac, 6) == 0)
        {
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
