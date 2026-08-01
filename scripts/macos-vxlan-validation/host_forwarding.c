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

#include <arpa/inet.h>
#include <dispatch/dispatch.h>
#include <errno.h>
#include <fcntl.h>
#include <net/if.h>
#include <net/if_utun.h>
#include <netinet/in.h>
#include <poll.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/kern_control.h>
#include <sys/socket.h>
#include <sys/sys_domain.h>
#include <sys/sysctl.h>
#include <unistd.h>
#include <uuid/uuid.h>
#include <vmnet/vmnet.h>
#include <xpc/xpc.h>

#define TEST_MTU 1450
#define GUEST_IP_TEXT "172.30.250.2"
#define HOST_IP_TEXT "172.30.250.1"
#define REMOTE_IP_TEXT "198.18.0.2"
#define TUN_LOCAL_IP_TEXT "198.18.0.1"
#define REMOTE_CIDR_TEXT "198.18.0.0/24"
#define WAIT_TIMEOUT_MS 10000

struct ethernet_header {
    uint8_t destination[6];
    uint8_t source[6];
    uint16_t ether_type;
} __attribute__((packed));

struct arp_packet {
    uint16_t hardware_type;
    uint16_t protocol_type;
    uint8_t hardware_length;
    uint8_t protocol_length;
    uint16_t operation;
    uint8_t sender_hardware[6];
    uint32_t sender_protocol;
    uint8_t target_hardware[6];
    uint32_t target_protocol;
} __attribute__((packed));

struct ipv4_header {
    uint8_t version_ihl;
    uint8_t dscp_ecn;
    uint16_t total_length;
    uint16_t identification;
    uint16_t flags_fragment;
    uint8_t ttl;
    uint8_t protocol;
    uint16_t checksum;
    uint32_t source;
    uint32_t destination;
} __attribute__((packed));

struct udp_header {
    uint16_t source_port;
    uint16_t destination_port;
    uint16_t length;
    uint16_t checksum;
} __attribute__((packed));

static const uint8_t broadcast_mac[6] = {0xff, 0xff, 0xff, 0xff, 0xff, 0xff};
static const uint8_t zero_mac[6] = {0, 0, 0, 0, 0, 0};
static const uint8_t test_payload[] = "macos-vmnet-host-forwarding";

struct validation_state {
    interface_ref vmnet_interface;
    dispatch_queue_t vmnet_queue;
    int utun_fd;
    char utun_name[IFNAMSIZ];
    int original_forwarding;
    bool forwarding_changed;
    bool route_installed;
};

struct allocated_mac_storage {
    char value[18];
};

static uint16_t internet_checksum(const void *data, size_t length) {
    const uint8_t *bytes = data;
    uint32_t sum = 0;
    while (length > 1) {
        sum += (uint16_t)((bytes[0] << 8) | bytes[1]);
        bytes += 2;
        length -= 2;
    }
    if (length == 1) {
        sum += (uint16_t)(bytes[0] << 8);
    }
    while (sum >> 16) {
        sum = (sum & 0xffff) + (sum >> 16);
    }
    return htons((uint16_t)~sum);
}

static bool parse_mac(const char *text, uint8_t output[6]) {
    unsigned int values[6];
    if (sscanf(
            text,
            "%x:%x:%x:%x:%x:%x",
            &values[0],
            &values[1],
            &values[2],
            &values[3],
            &values[4],
            &values[5]
        ) != 6)
    {
        return false;
    }
    for (size_t index = 0; index < 6; ++index) {
        if (values[index] > 0xff) {
            return false;
        }
        output[index] = (uint8_t)values[index];
    }
    return true;
}

static void format_mac(const uint8_t mac[6], char output[18]) {
    snprintf(
        output,
        18,
        "%02x:%02x:%02x:%02x:%02x:%02x",
        mac[0],
        mac[1],
        mac[2],
        mac[3],
        mac[4],
        mac[5]
    );
}

static int run_command(const char *format, const char *argument) {
    char command[512];
    int written = snprintf(command, sizeof(command), format, argument);
    if (written <= 0 || (size_t)written >= sizeof(command)) {
        fprintf(stderr, "command is too long\n");
        return -1;
    }
    int status = system(command);
    if (status != 0) {
        fprintf(stderr, "command failed (%d): %s\n", status, command);
        return -1;
    }
    return 0;
}

static int write_vmnet_packet(interface_ref interface, const uint8_t *data, size_t length) {
    struct iovec iov = {
        .iov_base = (void *)data,
        .iov_len = length,
    };
    struct vmpktdesc packet = {
        .vm_pkt_size = length,
        .vm_pkt_iov = &iov,
        .vm_pkt_iovcnt = 1,
        .vm_flags = 0,
    };
    int packet_count = 1;
    vmnet_return_t status = vmnet_write(interface, &packet, &packet_count);
    if (status != VMNET_SUCCESS || packet_count != 1) {
        fprintf(stderr, "vmnet_write failed: status=%u count=%d\n", status, packet_count);
        return -1;
    }
    return 0;
}

static ssize_t read_vmnet_packet_once(interface_ref interface, uint8_t *buffer, size_t capacity) {
    struct iovec iov = {
        .iov_base = buffer,
        .iov_len = capacity,
    };
    struct vmpktdesc packet = {
        .vm_pkt_size = capacity,
        .vm_pkt_iov = &iov,
        .vm_pkt_iovcnt = 1,
        .vm_flags = 0,
    };
    int packet_count = 1;
    vmnet_return_t status = vmnet_read(interface, &packet, &packet_count);
    if (status != VMNET_SUCCESS) {
        fprintf(stderr, "vmnet_read failed: status=%u\n", status);
        return -1;
    }
    if (packet_count == 0) {
        return 0;
    }
    return (ssize_t)packet.vm_pkt_size;
}

static size_t build_arp_request(
    uint8_t *buffer,
    const uint8_t guest_mac[6],
    uint32_t guest_ip,
    uint32_t host_ip
) {
    struct ethernet_header *ethernet = (struct ethernet_header *)buffer;
    memcpy(ethernet->destination, broadcast_mac, 6);
    memcpy(ethernet->source, guest_mac, 6);
    ethernet->ether_type = htons(0x0806);

    struct arp_packet *arp = (struct arp_packet *)(buffer + sizeof(*ethernet));
    arp->hardware_type = htons(1);
    arp->protocol_type = htons(0x0800);
    arp->hardware_length = 6;
    arp->protocol_length = 4;
    arp->operation = htons(1);
    memcpy(arp->sender_hardware, guest_mac, 6);
    arp->sender_protocol = guest_ip;
    memcpy(arp->target_hardware, zero_mac, 6);
    arp->target_protocol = host_ip;
    return sizeof(*ethernet) + sizeof(*arp);
}

static size_t build_arp_reply(
    uint8_t *buffer,
    const uint8_t guest_mac[6],
    uint32_t guest_ip,
    const uint8_t target_mac[6],
    uint32_t target_ip
) {
    struct ethernet_header *ethernet = (struct ethernet_header *)buffer;
    memcpy(ethernet->destination, target_mac, 6);
    memcpy(ethernet->source, guest_mac, 6);
    ethernet->ether_type = htons(0x0806);

    struct arp_packet *arp = (struct arp_packet *)(buffer + sizeof(*ethernet));
    arp->hardware_type = htons(1);
    arp->protocol_type = htons(0x0800);
    arp->hardware_length = 6;
    arp->protocol_length = 4;
    arp->operation = htons(2);
    memcpy(arp->sender_hardware, guest_mac, 6);
    arp->sender_protocol = guest_ip;
    memcpy(arp->target_hardware, target_mac, 6);
    arp->target_protocol = target_ip;
    return sizeof(*ethernet) + sizeof(*arp);
}

static size_t build_ipv4_udp_packet(
    uint8_t *buffer,
    size_t capacity,
    uint32_t source_ip,
    uint32_t destination_ip,
    const uint8_t *payload,
    size_t payload_length
) {
    size_t total_length = sizeof(struct ipv4_header) + sizeof(struct udp_header) + payload_length;
    if (total_length > capacity || total_length > UINT16_MAX) {
        return 0;
    }

    struct ipv4_header *ipv4 = (struct ipv4_header *)buffer;
    memset(ipv4, 0, sizeof(*ipv4));
    ipv4->version_ihl = 0x45;
    ipv4->total_length = htons((uint16_t)total_length);
    ipv4->identification = htons(0x2608);
    ipv4->flags_fragment = htons(0x4000);
    ipv4->ttl = 64;
    ipv4->protocol = IPPROTO_UDP;
    ipv4->source = source_ip;
    ipv4->destination = destination_ip;
    ipv4->checksum = internet_checksum(ipv4, sizeof(*ipv4));

    struct udp_header *udp = (struct udp_header *)(buffer + sizeof(*ipv4));
    udp->source_port = htons(32001);
    udp->destination_port = htons(32002);
    udp->length = htons((uint16_t)(sizeof(*udp) + payload_length));
    udp->checksum = 0;
    memcpy(buffer + sizeof(*ipv4) + sizeof(*udp), payload, payload_length);
    return total_length;
}

static size_t build_ethernet_ipv4(
    uint8_t *buffer,
    size_t capacity,
    const uint8_t source_mac[6],
    const uint8_t destination_mac[6],
    uint32_t source_ip,
    uint32_t destination_ip
) {
    if (capacity < sizeof(struct ethernet_header)) {
        return 0;
    }
    struct ethernet_header *ethernet = (struct ethernet_header *)buffer;
    memcpy(ethernet->destination, destination_mac, 6);
    memcpy(ethernet->source, source_mac, 6);
    ethernet->ether_type = htons(0x0800);

    size_t ip_length = build_ipv4_udp_packet(
        buffer + sizeof(*ethernet),
        capacity - sizeof(*ethernet),
        source_ip,
        destination_ip,
        test_payload,
        sizeof(test_payload)
    );
    return ip_length == 0 ? 0 : sizeof(*ethernet) + ip_length;
}

static int start_vmnet(
    struct validation_state *state,
    uint8_t guest_mac[6]
) {
    xpc_object_t description = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_uint64(description, vmnet_operation_mode_key, VMNET_HOST_MODE);
    xpc_dictionary_set_string(description, vmnet_host_ip_address_key, HOST_IP_TEXT);
    xpc_dictionary_set_string(description, vmnet_host_subnet_mask_key, "255.255.255.0");
    xpc_dictionary_set_uint64(description, vmnet_mtu_key, TEST_MTU);
    xpc_dictionary_set_bool(description, vmnet_allocate_mac_address_key, true);

    uuid_t network_identifier;
    uuid_generate_random(network_identifier);
    xpc_dictionary_set_uuid(description, vmnet_network_identifier_key, network_identifier);

    state->vmnet_queue = dispatch_queue_create("container.macos-vxlan-validation.vmnet", DISPATCH_QUEUE_SERIAL);
    dispatch_semaphore_t started = dispatch_semaphore_create(0);
    __block vmnet_return_t start_status = VMNET_FAILURE;
    __block struct allocated_mac_storage allocated_mac = {{0}};

    state->vmnet_interface = vmnet_start_interface(
        description,
        state->vmnet_queue,
        ^(vmnet_return_t status, xpc_object_t parameters) {
          start_status = status;
          if (status == VMNET_SUCCESS && parameters != NULL) {
              const char *mac = xpc_dictionary_get_string(parameters, vmnet_mac_address_key);
              if (mac != NULL) {
                  strlcpy(allocated_mac.value, mac, sizeof(allocated_mac.value));
              }
          }
          dispatch_semaphore_signal(started);
        }
    );
    xpc_release(description);

    if (state->vmnet_interface == NULL) {
        fprintf(stderr, "vmnet_start_interface returned NULL\n");
        return -1;
    }
    if (dispatch_semaphore_wait(started, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)) != 0) {
        fprintf(stderr, "timed out starting vmnet interface\n");
        return -1;
    }
    if (start_status != VMNET_SUCCESS) {
        fprintf(stderr, "vmnet interface start failed: status=%u\n", start_status);
        return -1;
    }
    if (!parse_mac(allocated_mac.value, guest_mac)) {
        fprintf(stderr, "invalid allocated vmnet MAC: %s\n", allocated_mac.value);
        return -1;
    }
    printf("vmnet_guest_mac=%s\n", allocated_mac.value);
    return 0;
}

static int open_utun(struct validation_state *state) {
    int fd = socket(PF_SYSTEM, SOCK_DGRAM, SYSPROTO_CONTROL);
    if (fd < 0) {
        perror("socket(PF_SYSTEM)");
        return -1;
    }

    struct ctl_info control_info = {0};
    strlcpy(control_info.ctl_name, UTUN_CONTROL_NAME, sizeof(control_info.ctl_name));
    if (ioctl(fd, CTLIOCGINFO, &control_info) != 0) {
        perror("ioctl(CTLIOCGINFO)");
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
        perror("connect(utun)");
        close(fd);
        return -1;
    }

    socklen_t name_length = sizeof(state->utun_name);
    if (getsockopt(fd, SYSPROTO_CONTROL, UTUN_OPT_IFNAME, state->utun_name, &name_length) != 0) {
        perror("getsockopt(UTUN_OPT_IFNAME)");
        close(fd);
        return -1;
    }
    state->utun_fd = fd;
    printf("utun_interface=%s\n", state->utun_name);

    if (run_command(
            "/sbin/ifconfig %s " TUN_LOCAL_IP_TEXT " " REMOTE_IP_TEXT " mtu 1450 up",
            state->utun_name
        ) != 0)
    {
        return -1;
    }
    if (run_command(
            "/sbin/route -n add -net " REMOTE_CIDR_TEXT " -interface %s",
            state->utun_name
        ) != 0)
    {
        return -1;
    }
    state->route_installed = true;
    return 0;
}

static int enable_forwarding(struct validation_state *state) {
    size_t length = sizeof(state->original_forwarding);
    if (sysctlbyname(
            "net.inet.ip.forwarding",
            &state->original_forwarding,
            &length,
            NULL,
            0
        ) != 0)
    {
        perror("sysctlbyname(read forwarding)");
        return -1;
    }
    int enabled = 1;
    if (sysctlbyname("net.inet.ip.forwarding", NULL, NULL, &enabled, sizeof(enabled)) != 0) {
        perror("sysctlbyname(enable forwarding)");
        return -1;
    }
    state->forwarding_changed = true;
    printf("ip_forwarding_before=%d\n", state->original_forwarding);
    return 0;
}

static int wait_for_gateway_arp(
    interface_ref interface,
    uint32_t host_ip,
    uint8_t gateway_mac[6]
) {
    uint8_t buffer[2048];
    int elapsed = 0;
    while (elapsed < WAIT_TIMEOUT_MS) {
        ssize_t length = read_vmnet_packet_once(interface, buffer, sizeof(buffer));
        if (length < 0) {
            return -1;
        }
        if ((size_t)length >= sizeof(struct ethernet_header) + sizeof(struct arp_packet)) {
            struct ethernet_header *ethernet = (struct ethernet_header *)buffer;
            struct arp_packet *arp = (struct arp_packet *)(buffer + sizeof(*ethernet));
            if (ntohs(ethernet->ether_type) == 0x0806 &&
                ntohs(arp->operation) == 2 &&
                arp->sender_protocol == host_ip)
            {
                memcpy(gateway_mac, arp->sender_hardware, 6);
                return 0;
            }
        }
        usleep(10000);
        elapsed += 10;
    }
    fprintf(stderr, "timed out waiting for gateway ARP reply\n");
    return -1;
}

static int wait_for_utun_packet(
    int fd,
    uint32_t expected_source,
    uint32_t expected_destination
) {
    struct pollfd descriptor = {
        .fd = fd,
        .events = POLLIN,
    };
    int poll_status = poll(&descriptor, 1, WAIT_TIMEOUT_MS);
    if (poll_status <= 0) {
        fprintf(stderr, "timed out waiting for outbound utun packet\n");
        return -1;
    }

    uint8_t buffer[4096];
    ssize_t length = read(fd, buffer, sizeof(buffer));
    if (length < (ssize_t)(sizeof(uint32_t) + sizeof(struct ipv4_header))) {
        fprintf(stderr, "short utun packet: %zd\n", length);
        return -1;
    }
    uint32_t family = 0;
    memcpy(&family, buffer, sizeof(family));
    if (ntohl(family) != AF_INET) {
        fprintf(stderr, "unexpected utun family: %u\n", ntohl(family));
        return -1;
    }
    struct ipv4_header *ipv4 = (struct ipv4_header *)(buffer + sizeof(family));
    if (ipv4->source != expected_source || ipv4->destination != expected_destination) {
        char source[INET_ADDRSTRLEN];
        char destination[INET_ADDRSTRLEN];
        inet_ntop(AF_INET, &ipv4->source, source, sizeof(source));
        inet_ntop(AF_INET, &ipv4->destination, destination, sizeof(destination));
        fprintf(stderr, "unexpected outbound packet: %s -> %s\n", source, destination);
        return -1;
    }
    printf("outbound_source_preserved=true\n");
    return 0;
}

static int inject_reverse_packet(int fd, uint32_t source_ip, uint32_t destination_ip) {
    uint8_t buffer[4096];
    uint32_t family = htonl(AF_INET);
    memcpy(buffer, &family, sizeof(family));
    size_t packet_length = build_ipv4_udp_packet(
        buffer + sizeof(family),
        sizeof(buffer) - sizeof(family),
        source_ip,
        destination_ip,
        test_payload,
        sizeof(test_payload)
    );
    if (packet_length == 0) {
        return -1;
    }
    ssize_t written = write(fd, buffer, sizeof(family) + packet_length);
    if (written != (ssize_t)(sizeof(family) + packet_length)) {
        perror("write(utun reverse)");
        return -1;
    }
    return 0;
}

static int wait_for_reverse_vmnet_packet(
    interface_ref interface,
    const uint8_t guest_mac[6],
    uint32_t guest_ip,
    uint32_t expected_source
) {
    uint8_t buffer[4096];
    int elapsed = 0;
    while (elapsed < WAIT_TIMEOUT_MS) {
        ssize_t length = read_vmnet_packet_once(interface, buffer, sizeof(buffer));
        if (length < 0) {
            return -1;
        }
        if ((size_t)length >= sizeof(struct ethernet_header)) {
            struct ethernet_header *ethernet = (struct ethernet_header *)buffer;
            uint16_t ether_type = ntohs(ethernet->ether_type);
            if (ether_type == 0x0806 &&
                (size_t)length >= sizeof(*ethernet) + sizeof(struct arp_packet))
            {
                struct arp_packet *arp = (struct arp_packet *)(buffer + sizeof(*ethernet));
                if (ntohs(arp->operation) == 1 && arp->target_protocol == guest_ip) {
                    uint8_t reply[128];
                    size_t reply_length = build_arp_reply(
                        reply,
                        guest_mac,
                        guest_ip,
                        arp->sender_hardware,
                        arp->sender_protocol
                    );
                    if (write_vmnet_packet(interface, reply, reply_length) != 0) {
                        return -1;
                    }
                }
            } else if (
                ether_type == 0x0800 &&
                (size_t)length >= sizeof(*ethernet) + sizeof(struct ipv4_header))
            {
                struct ipv4_header *ipv4 =
                    (struct ipv4_header *)(buffer + sizeof(*ethernet));
                if (ipv4->source == expected_source && ipv4->destination == guest_ip) {
                    printf("reverse_path_delivered=true\n");
                    return 0;
                }
            }
        }
        usleep(10000);
        elapsed += 10;
    }
    fprintf(stderr, "timed out waiting for reverse vmnet packet\n");
    return -1;
}

static void cleanup(struct validation_state *state) {
    if (state->route_installed) {
        (void)run_command(
            "/sbin/route -n delete -net " REMOTE_CIDR_TEXT " -interface %s >/dev/null 2>&1",
            state->utun_name
        );
    }
    if (state->utun_fd >= 0) {
        close(state->utun_fd);
        state->utun_fd = -1;
    }
    if (state->forwarding_changed) {
        int original = state->original_forwarding;
        if (sysctlbyname("net.inet.ip.forwarding", NULL, NULL, &original, sizeof(original)) != 0) {
            perror("sysctlbyname(restore forwarding)");
        }
    }
    if (state->vmnet_interface != NULL) {
        dispatch_semaphore_t stopped = dispatch_semaphore_create(0);
        vmnet_stop_interface(
            state->vmnet_interface,
            state->vmnet_queue,
            ^(vmnet_return_t status) {
              if (status != VMNET_SUCCESS) {
                  fprintf(stderr, "vmnet stop failed: status=%u\n", status);
              }
              dispatch_semaphore_signal(stopped);
            }
        );
        (void)dispatch_semaphore_wait(
            stopped,
            dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)
        );
        state->vmnet_interface = NULL;
    }
}

int main(void) {
    if (geteuid() != 0) {
        fprintf(stderr, "host forwarding validation must run as root\n");
        return EXIT_FAILURE;
    }

    struct validation_state state = {
        .vmnet_interface = NULL,
        .vmnet_queue = NULL,
        .utun_fd = -1,
        .utun_name = {0},
        .original_forwarding = 0,
        .forwarding_changed = false,
        .route_installed = false,
    };

    int result = EXIT_FAILURE;
    uint8_t guest_mac[6];
    uint8_t gateway_mac[6];
    uint32_t guest_ip = inet_addr(GUEST_IP_TEXT);
    uint32_t host_ip = inet_addr(HOST_IP_TEXT);
    uint32_t remote_ip = inet_addr(REMOTE_IP_TEXT);

    if (start_vmnet(&state, guest_mac) != 0 ||
        open_utun(&state) != 0 ||
        enable_forwarding(&state) != 0)
    {
        goto done;
    }

    uint8_t arp_request[128];
    size_t arp_length = build_arp_request(arp_request, guest_mac, guest_ip, host_ip);
    if (write_vmnet_packet(state.vmnet_interface, arp_request, arp_length) != 0 ||
        wait_for_gateway_arp(state.vmnet_interface, host_ip, gateway_mac) != 0)
    {
        goto done;
    }
    char gateway_mac_text[18];
    format_mac(gateway_mac, gateway_mac_text);
    printf("vmnet_gateway_mac=%s\n", gateway_mac_text);

    uint8_t outbound_frame[2048];
    size_t outbound_length = build_ethernet_ipv4(
        outbound_frame,
        sizeof(outbound_frame),
        guest_mac,
        gateway_mac,
        guest_ip,
        remote_ip
    );
    if (outbound_length == 0 ||
        write_vmnet_packet(state.vmnet_interface, outbound_frame, outbound_length) != 0 ||
        wait_for_utun_packet(state.utun_fd, guest_ip, remote_ip) != 0)
    {
        goto done;
    }

    if (inject_reverse_packet(state.utun_fd, remote_ip, guest_ip) != 0 ||
        wait_for_reverse_vmnet_packet(
            state.vmnet_interface,
            guest_mac,
            guest_ip,
            remote_ip
        ) != 0)
    {
        goto done;
    }

    printf("HOST_FORWARDING_VALIDATION=PASS\n");
    result = EXIT_SUCCESS;

done:
    cleanup(&state);
    if (result != EXIT_SUCCESS) {
        printf("HOST_FORWARDING_VALIDATION=FAIL\n");
    }
    return result;
}
