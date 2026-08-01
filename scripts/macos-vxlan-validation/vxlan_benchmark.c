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
#include <errno.h>
#include <netinet/in.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#define VXLAN_VNI 4096
#define VXLAN_HEADER_SIZE 8
#define ETHERNET_HEADER_SIZE 14
#define MAX_INNER_PACKET_SIZE 1400
#define SOCKET_BUFFER_SIZE (8 * 1024 * 1024)

struct benchmark_receiver {
    int socket_fd;
    size_t expected_length;
    uint64_t received_packets;
    uint64_t invalid_packets;
};

static double monotonic_seconds(void) {
    struct timespec value;
    clock_gettime(CLOCK_MONOTONIC, &value);
    return (double)value.tv_sec + (double)value.tv_nsec / 1000000000.0;
}

static double timeval_seconds(struct timeval value) {
    return (double)value.tv_sec + (double)value.tv_usec / 1000000.0;
}

static void throttle_sender(
    double started,
    uint64_t sent_packets,
    size_t inner_packet_size,
    double target_gbps
) {
    if (target_gbps <= 0) {
        return;
    }

    double expected_elapsed =
        (double)sent_packets * (double)inner_packet_size * 8.0 /
        (target_gbps * 1000000000.0);
    double delay = expected_elapsed - (monotonic_seconds() - started);
    if (delay < 0.0005) {
        return;
    }

    struct timespec remaining = {
        .tv_sec = (time_t)delay,
        .tv_nsec = (long)((delay - (double)(time_t)delay) * 1000000000.0),
    };
    while (nanosleep(&remaining, &remaining) != 0 && errno == EINTR) {
    }
}

static void prepare_vxlan_packet(uint8_t *packet, size_t inner_packet_size) {
    memset(packet, 0, VXLAN_HEADER_SIZE + ETHERNET_HEADER_SIZE + inner_packet_size);
    packet[0] = 0x08;
    packet[4] = (uint8_t)((VXLAN_VNI >> 16) & 0xff);
    packet[5] = (uint8_t)((VXLAN_VNI >> 8) & 0xff);
    packet[6] = (uint8_t)(VXLAN_VNI & 0xff);

    uint8_t *ethernet = packet + VXLAN_HEADER_SIZE;
    const uint8_t destination_mac[6] = {0x02, 0, 0, 0, 0, 2};
    const uint8_t source_mac[6] = {0x02, 0, 0, 0, 0, 1};
    memcpy(ethernet, destination_mac, sizeof(destination_mac));
    memcpy(ethernet + 6, source_mac, sizeof(source_mac));
    ethernet[12] = 0x08;
    ethernet[13] = 0x00;

    uint8_t *inner = ethernet + ETHERNET_HEADER_SIZE;
    for (size_t index = 0; index < inner_packet_size; ++index) {
        inner[index] = (uint8_t)(index & 0xff);
    }
}

static bool validate_vxlan_packet(
    const uint8_t *packet,
    size_t length,
    size_t expected_length
) {
    if (length != expected_length || packet[0] != 0x08) {
        return false;
    }
    uint32_t vni =
        ((uint32_t)packet[4] << 16) |
        ((uint32_t)packet[5] << 8) |
        (uint32_t)packet[6];
    if (vni != VXLAN_VNI) {
        return false;
    }
    const uint8_t *ethernet = packet + VXLAN_HEADER_SIZE;
    if (ethernet[12] != 0x08 || ethernet[13] != 0x00) {
        return false;
    }
    const uint8_t *inner = ethernet + ETHERNET_HEADER_SIZE;
    size_t inner_length = length - VXLAN_HEADER_SIZE - ETHERNET_HEADER_SIZE;
    return inner_length > 0 &&
        inner[0] == 0 &&
        inner[inner_length - 1] == (uint8_t)((inner_length - 1) & 0xff);
}

static void *receive_packets(void *context) {
    struct benchmark_receiver *receiver = context;
    uint8_t buffer[VXLAN_HEADER_SIZE + ETHERNET_HEADER_SIZE + MAX_INNER_PACKET_SIZE];

    for (;;) {
        ssize_t length = recv(receiver->socket_fd, buffer, sizeof(buffer), 0);
        if (length < 0) {
            if (errno == EINTR) {
                continue;
            }
            perror("recv");
            receiver->invalid_packets++;
            break;
        }
        if (length == 1 && buffer[0] == 0xff) {
            break;
        }
        if (!validate_vxlan_packet(buffer, (size_t)length, receiver->expected_length)) {
            receiver->invalid_packets++;
            continue;
        }
        receiver->received_packets++;
    }
    return NULL;
}

static int set_socket_buffer(int socket_fd, int option) {
    int size = SOCKET_BUFFER_SIZE;
    if (setsockopt(socket_fd, SOL_SOCKET, option, &size, sizeof(size)) != 0) {
        perror("setsockopt(socket buffer)");
        return -1;
    }
    return 0;
}

static int run_benchmark(
    size_t inner_packet_size,
    double duration_seconds,
    double target_gbps,
    double max_loss_percent
) {
    if (inner_packet_size == 0 || inner_packet_size > MAX_INNER_PACKET_SIZE) {
        fprintf(stderr, "invalid inner packet size: %zu\n", inner_packet_size);
        return -1;
    }

    int receiver_socket = socket(AF_INET, SOCK_DGRAM, 0);
    if (receiver_socket < 0) {
        perror("socket(receiver)");
        return -1;
    }
    if (set_socket_buffer(receiver_socket, SO_RCVBUF) != 0) {
        close(receiver_socket);
        return -1;
    }

    struct sockaddr_in receiver_address = {
        .sin_len = sizeof(receiver_address),
        .sin_family = AF_INET,
        .sin_port = 0,
        .sin_addr.s_addr = htonl(INADDR_LOOPBACK),
    };
    if (bind(
            receiver_socket,
            (struct sockaddr *)&receiver_address,
            sizeof(receiver_address)
        ) != 0)
    {
        perror("bind(receiver)");
        close(receiver_socket);
        return -1;
    }
    socklen_t receiver_address_length = sizeof(receiver_address);
    if (getsockname(
            receiver_socket,
            (struct sockaddr *)&receiver_address,
            &receiver_address_length
        ) != 0)
    {
        perror("getsockname(receiver)");
        close(receiver_socket);
        return -1;
    }

    int sender_socket = socket(AF_INET, SOCK_DGRAM, 0);
    if (sender_socket < 0) {
        perror("socket(sender)");
        close(receiver_socket);
        return -1;
    }
    if (set_socket_buffer(sender_socket, SO_SNDBUF) != 0 ||
        connect(
            sender_socket,
            (struct sockaddr *)&receiver_address,
            sizeof(receiver_address)
        ) != 0)
    {
        perror("connect(sender)");
        close(sender_socket);
        close(receiver_socket);
        return -1;
    }

    size_t datagram_length =
        VXLAN_HEADER_SIZE + ETHERNET_HEADER_SIZE + inner_packet_size;
    uint8_t packet[VXLAN_HEADER_SIZE + ETHERNET_HEADER_SIZE + MAX_INNER_PACKET_SIZE];
    uint8_t inner_packet[MAX_INNER_PACKET_SIZE];
    prepare_vxlan_packet(packet, inner_packet_size);
    memcpy(
        inner_packet,
        packet + VXLAN_HEADER_SIZE + ETHERNET_HEADER_SIZE,
        inner_packet_size
    );

    struct benchmark_receiver receiver = {
        .socket_fd = receiver_socket,
        .expected_length = datagram_length,
        .received_packets = 0,
        .invalid_packets = 0,
    };
    pthread_t receiver_thread;
    if (pthread_create(&receiver_thread, NULL, receive_packets, &receiver) != 0) {
        perror("pthread_create");
        close(sender_socket);
        close(receiver_socket);
        return -1;
    }

    struct rusage usage_before;
    struct rusage usage_after;
    getrusage(RUSAGE_SELF, &usage_before);
    double started = monotonic_seconds();
    double deadline = started + duration_seconds;
    uint64_t sent_packets = 0;
    while (monotonic_seconds() < deadline) {
        memcpy(
            packet + VXLAN_HEADER_SIZE + ETHERNET_HEADER_SIZE,
            inner_packet,
            inner_packet_size
        );
        ssize_t written = send(sender_socket, packet, datagram_length, 0);
        if (written == (ssize_t)datagram_length) {
            sent_packets++;
            throttle_sender(started, sent_packets, inner_packet_size, target_gbps);
            continue;
        }
        if (written < 0 && errno == EINTR) {
            continue;
        }
        perror("send");
        break;
    }
    double stopped = monotonic_seconds();
    getrusage(RUSAGE_SELF, &usage_after);

    usleep(100000);
    uint8_t stop = 0xff;
    if (send(sender_socket, &stop, sizeof(stop), 0) != (ssize_t)sizeof(stop)) {
        perror("send(stop)");
    }
    pthread_join(receiver_thread, NULL);

    double wall_seconds = stopped - started;
    double cpu_seconds =
        timeval_seconds(usage_after.ru_utime) +
        timeval_seconds(usage_after.ru_stime) -
        timeval_seconds(usage_before.ru_utime) -
        timeval_seconds(usage_before.ru_stime);
    uint64_t dropped_packets =
        sent_packets > receiver.received_packets
            ? sent_packets - receiver.received_packets
            : 0;
    double loss_percent =
        sent_packets == 0
            ? 100.0
            : (double)dropped_packets * 100.0 / (double)sent_packets;
    double packets_per_second =
        wall_seconds == 0
            ? 0
            : (double)receiver.received_packets / wall_seconds;
    double inner_gbps =
        wall_seconds == 0
            ? 0
            : (double)receiver.received_packets *
                (double)inner_packet_size * 8.0 /
                wall_seconds /
                1000000000.0;
    double datagram_gbps =
        wall_seconds == 0
            ? 0
            : (double)receiver.received_packets *
                (double)datagram_length * 8.0 /
                wall_seconds /
                1000000000.0;
    double cpu_cores = wall_seconds == 0 ? 0 : cpu_seconds / wall_seconds;
    bool target_rate_achieved =
        target_gbps <= 0 || inner_gbps >= target_gbps * 0.98;

    printf(
        "VXLAN_BENCHMARK packet_size=%zu duration=%.3f target_gbps=%.3f "
        "sent=%llu received=%llu "
        "invalid=%llu loss_percent=%.4f pps=%.0f inner_gbps=%.3f "
        "datagram_gbps=%.3f cpu_cores=%.3f target_achieved=%s\n",
        inner_packet_size,
        wall_seconds,
        target_gbps,
        sent_packets,
        receiver.received_packets,
        receiver.invalid_packets,
        loss_percent,
        packets_per_second,
        inner_gbps,
        datagram_gbps,
        cpu_cores,
        target_rate_achieved ? "true" : "false"
    );

    close(sender_socket);
    close(receiver_socket);
    return receiver.invalid_packets == 0 &&
            receiver.received_packets > 0 &&
            target_rate_achieved &&
            loss_percent <= max_loss_percent
        ? 0
        : -1;
}

int main(int argc, char **argv) {
    double duration_seconds = 3.0;
    double target_gbps = 0;
    double max_loss_percent = 100;
    size_t selected_packet_size = 0;

    for (int index = 1; index < argc; ++index) {
        if (strcmp(argv[index], "--duration") == 0 && index + 1 < argc) {
            duration_seconds = strtod(argv[++index], NULL);
        } else if (
            strcmp(argv[index], "--packet-size") == 0 &&
            index + 1 < argc
        ) {
            selected_packet_size = (size_t)strtoul(argv[++index], NULL, 10);
        } else if (
            strcmp(argv[index], "--target-gbps") == 0 &&
            index + 1 < argc
        ) {
            target_gbps = strtod(argv[++index], NULL);
        } else if (
            strcmp(argv[index], "--max-loss-percent") == 0 &&
            index + 1 < argc
        ) {
            max_loss_percent = strtod(argv[++index], NULL);
        } else {
            fprintf(
                stderr,
                "usage: %s [--duration seconds] [--packet-size bytes] "
                "[--target-gbps value] [--max-loss-percent value]\n",
                argv[0]
            );
            return EXIT_FAILURE;
        }
    }

    if (duration_seconds <= 0) {
        fprintf(stderr, "duration must be greater than zero\n");
        return EXIT_FAILURE;
    }
    if (target_gbps < 0 || max_loss_percent < 0 || max_loss_percent > 100) {
        fprintf(stderr, "target rate or loss threshold is invalid\n");
        return EXIT_FAILURE;
    }

    const size_t packet_sizes[] = {64, 512, 1400};
    int result = 0;
    if (selected_packet_size != 0) {
        result = run_benchmark(
            selected_packet_size,
            duration_seconds,
            target_gbps,
            max_loss_percent
        );
    } else {
        for (size_t index = 0; index < sizeof(packet_sizes) / sizeof(packet_sizes[0]); ++index) {
            if (run_benchmark(
                    packet_sizes[index],
                    duration_seconds,
                    target_gbps,
                    max_loss_percent
                ) != 0)
            {
                result = -1;
            }
        }
    }

    printf("VXLAN_BENCHMARK_VALIDATION=%s\n", result == 0 ? "PASS" : "FAIL");
    return result == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
}
