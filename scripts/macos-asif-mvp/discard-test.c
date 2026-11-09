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

/* Native discard fixture helper. The validator supplies a private raw image device. */
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/disk.h>
#include <sys/ioctl.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc != 4) {
        return 2;
    }
    int fd = open(argv[1], O_RDWR);
    if (fd < 0) {
        perror("open fixture");
        return 1;
    }
    dk_extent_t extent = {
        .offset = strtoull(argv[2], NULL, 10),
        .length = strtoull(argv[3], NULL, 10),
    };
    dk_unmap_t request = {.extents = &extent, .extentsCount = 1};
    int result = 0;
    if (ioctl(fd, DKIOCUNMAP, &request) < 0 || fsync(fd) < 0) {
        perror("discard fixture extent");
        result = 1;
    }
    if (close(fd) < 0) {
        perror("close fixture");
        result = 1;
    }
    return result;
}
