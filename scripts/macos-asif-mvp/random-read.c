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

#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

// Isolated guest benchmark: fixed offsets, guest data-cache bypass, no writes
// during measurement. A block's header records its original index.
#define BLOCK 4096
#define MAX_THREADS 16

static uint64_t next_random(uint64_t *state) {
    uint64_t value = *state;
    value ^= value << 13;
    value ^= value >> 7;
    value ^= value << 17;
    return *state = value;
}

static uint64_t now_ns(void) {
    struct timespec value;
    if (clock_gettime(CLOCK_MONOTONIC_RAW, &value)) abort();
    return (uint64_t)value.tv_sec * 1000000000 + value.tv_nsec;
}

static uint64_t number(const char *text) {
    char *end;
    errno = 0;
    uint64_t value = strtoull(text, &end, 10);
    if (errno || !*text || *end || *text == '-') {
        fprintf(stderr, "invalid number\n");
        exit(1);
    }
    return value;
}

static int prepare(const char *path, uint64_t bytes) {
    if (bytes < BLOCK || bytes > (UINT64_C(16) << 30) || bytes % (1 << 20)) return 1;
    int fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0600);
    if (fd < 0) { perror("create dataset"); return 1; }
    uint64_t *buffer = malloc(1 << 20);
    if (!buffer) { close(fd); return 1; }
    uint64_t state = UINT64_C(0x6a09e667f3bcc909);
    int result = 0;
    for (uint64_t offset = 0; offset < bytes; offset += 1 << 20) {
        for (unsigned i = 0; i < (1 << 20) / sizeof(uint64_t); ++i)
            buffer[i] = next_random(&state);
        for (unsigned i = 0; i < (1 << 20) / BLOCK; ++i)
            buffer[i * BLOCK / sizeof(uint64_t)] = offset / BLOCK + i;
        if (write(fd, buffer, 1 << 20) != 1 << 20) { perror("write dataset"); result = 1; break; }
    }
    if (fsync(fd)) result = 1;
    free(buffer);
    if (close(fd)) result = 1;
    if (!result) printf("{\"datasetBytes\":%" PRIu64 "}\n", bytes);
    return result;
}

struct start_gate {
    pthread_mutex_t mutex;
    pthread_cond_t ready;
    unsigned arrived;
    int go;
};

struct worker {
    const char *path;
    struct start_gate *gate;
    uint64_t blocks, operations, seed;
    uint64_t *latencies;
    int failed;
};

static void *read_worker(void *raw) {
    struct worker *worker = raw;
    int fd = open(worker->path, O_RDONLY);
    if (fd < 0 || fcntl(fd, F_NOCACHE, 1) < 0) worker->failed = 1;
    uint64_t buffer[BLOCK / sizeof(uint64_t)];
    pthread_mutex_lock(&worker->gate->mutex);
    worker->gate->arrived++;
    pthread_cond_broadcast(&worker->gate->ready);
    while (!worker->gate->go) pthread_cond_wait(&worker->gate->ready, &worker->gate->mutex);
    pthread_mutex_unlock(&worker->gate->mutex);
    for (uint64_t i = 0; i < worker->operations && !worker->failed; ++i) {
        uint64_t block = next_random(&worker->seed) % worker->blocks;
        uint64_t start = now_ns();
        ssize_t bytes = pread(fd, buffer, BLOCK, (off_t)(block * BLOCK));
        worker->latencies[i] = now_ns() - start;
        if (bytes != BLOCK || buffer[0] != block) worker->failed = 1;
    }
    if (fd >= 0) close(fd);
    return NULL;
}

static int compare(const void *left, const void *right) {
    uint64_t a = *(const uint64_t *)left, b = *(const uint64_t *)right;
    return (a > b) - (a < b);
}

static int measure(const char *path, unsigned threads, uint64_t operations, uint64_t seed) {
    struct stat status;
    if (!threads || threads > MAX_THREADS || operations < threads || operations > 1048576 || operations % threads || !seed) return 1;
    if (stat(path, &status) || !S_ISREG(status.st_mode) || status.st_size < BLOCK || status.st_size % BLOCK) return 1;
    uint64_t *latencies = calloc(operations, sizeof(uint64_t));
    if (!latencies) return 1;
    struct start_gate gate = {PTHREAD_MUTEX_INITIALIZER, PTHREAD_COND_INITIALIZER, 0, 0};
    struct worker workers[MAX_THREADS];
    pthread_t ids[MAX_THREADS];
    for (unsigned i = 0; i < threads; ++i) {
        workers[i] = (struct worker){path, &gate, status.st_size / BLOCK, operations / threads,
            seed + i * UINT64_C(0x9e3779b97f4a7c15), latencies + i * (operations / threads), 0};
        if (pthread_create(&ids[i], NULL, read_worker, &workers[i])) {
            fprintf(stderr, "cannot start benchmark thread\n");
            exit(1);
        }
    }
    pthread_mutex_lock(&gate.mutex);
    while (gate.arrived != threads) pthread_cond_wait(&gate.ready, &gate.mutex);
    uint64_t start = now_ns();
    gate.go = 1;
    pthread_cond_broadcast(&gate.ready);
    pthread_mutex_unlock(&gate.mutex);
    int failed = 0;
    for (unsigned i = 0; i < threads; ++i) {
        pthread_join(ids[i], NULL);
        failed |= workers[i].failed;
    }
    double seconds = (now_ns() - start) / 1e9;
    if (!failed) {
        qsort(latencies, operations, sizeof(uint64_t), compare);
        printf("{\"blockBytes\":4096,\"queueDepth\":%u,\"operations\":%" PRIu64 ",\"seed\":%" PRIu64
            ",\"guestNoCache\":true,\"seconds\":%.6f,\"iops\":%.3f,\"latencyUs\":{\"p50\":%.3f,\"p95\":%.3f,\"p99\":%.3f},\"verified\":true}\n",
            threads, operations, seed, seconds, operations / seconds,
            latencies[operations / 2] / 1e3, latencies[operations * 95 / 100] / 1e3, latencies[operations * 99 / 100] / 1e3);
    } else fprintf(stderr, "read failed or dataset content differs\n");
    pthread_cond_destroy(&gate.ready);
    pthread_mutex_destroy(&gate.mutex);
    free(latencies);
    return failed;
}

int main(int argc, char **argv) {
    if (argc == 4 && !strcmp(argv[1], "prepare")) return prepare(argv[2], number(argv[3]));
    if (argc == 6 && !strcmp(argv[1], "read")) {
        uint64_t threads = number(argv[3]);
        if (threads > MAX_THREADS) return 1;
        return measure(argv[2], (unsigned)threads, number(argv[4]), number(argv[5]));
    }
    fprintf(stderr, "usage: random-read prepare FILE BYTES | read FILE THREADS OPERATIONS SEED\n");
    return 1;
}
