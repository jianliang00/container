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

#if os(macOS)
import Darwin
import Foundation
import Testing

@testable import ContainerXPC

@Suite(.serialized)
struct XPCMessageFileHandleTests {
    @Test func setConsumesSingleFileHandleWithoutLeavingStaleOwner() throws {
        let message = XPCMessage(route: "test")
        let minimum = try highDescriptorMinimum()
        var handle: FileHandle? = try makeOwnedFileHandle(minimum: minimum)
        defer { try? handle?.close() }
        let descriptor = try #require(handle).fileDescriptor

        message.set(key: "fd", value: try #require(handle))
        let replacement = try installReplacement(
            at: descriptor,
            sourcePath: "/dev/zero"
        )
        defer { _ = Darwin.close(replacement) }

        try? handle?.close()
        handle = nil
        #expect(Darwin.fcntl(replacement, F_GETFD) >= 0)

        let transferred = try #require(message.fileHandle(key: "fd"))
        defer { try? transferred.close() }
        #expect(Darwin.fcntl(transferred.fileDescriptor, F_GETFD) >= 0)
    }

    @Test func setConsumesFileHandleArrayWithoutLeavingStaleOwners() throws {
        let message = XPCMessage(route: "test")
        let minimum = try highDescriptorMinimum()
        let first = try makeOwnedFileHandle(minimum: minimum)
        defer { try? first.close() }
        let second = try makeOwnedFileHandle(minimum: minimum)
        defer { try? second.close() }
        var handles: [FileHandle]? = [
            first,
            second,
        ]
        let descriptors = try #require(handles).map(\.fileDescriptor)

        try message.set(key: "fds", value: try #require(handles))
        let firstReplacement = try installReplacement(
            at: descriptors[0],
            sourcePath: "/dev/zero"
        )
        defer { _ = Darwin.close(firstReplacement) }
        let secondReplacement = try installReplacement(
            at: descriptors[1],
            sourcePath: "/dev/null"
        )
        defer { _ = Darwin.close(secondReplacement) }
        let replacements = [firstReplacement, secondReplacement]

        for handle in try #require(handles) {
            try? handle.close()
        }
        handles = nil
        for replacement in replacements {
            #expect(Darwin.fcntl(replacement, F_GETFD) >= 0)
        }

        let transferred = try #require(message.fileHandles(key: "fds"))
        defer {
            for handle in transferred {
                try? handle.close()
            }
        }
        #expect(transferred.count == 2)
        for handle in transferred {
            #expect(Darwin.fcntl(handle.fileDescriptor, F_GETFD) >= 0)
        }
    }
}

private func highDescriptorMinimum() throws -> Int32 {
    var limit = rlimit()
    guard Darwin.getrlimit(RLIMIT_NOFILE, &limit) == 0 else {
        throw currentPOSIXError()
    }
    let cappedLimit = min(limit.rlim_cur, rlim_t(32_768))
    guard cappedLimit > 64 else {
        throw POSIXError(.EMFILE)
    }
    return Int32(cappedLimit - 32)
}

private func makeOwnedFileHandle(minimum: Int32) throws -> FileHandle {
    let source = Darwin.open("/dev/null", O_RDONLY)
    guard source >= 0 else {
        throw currentPOSIXError()
    }
    defer { _ = Darwin.close(source) }

    let descriptor = Darwin.fcntl(source, F_DUPFD_CLOEXEC, minimum)
    guard descriptor >= 0 else {
        throw currentPOSIXError()
    }
    return FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
}

private func installReplacement(at descriptor: Int32, sourcePath: String) throws -> Int32 {
    let source = Darwin.open(sourcePath, O_RDONLY)
    guard source >= 0 else {
        throw currentPOSIXError()
    }
    defer { _ = Darwin.close(source) }

    // F_DUPFD_CLOEXEC never overwrites an occupied descriptor. Requiring the
    // exact number makes the reuse deterministic without touching unrelated FDs.
    let duplicated = Darwin.fcntl(source, F_DUPFD_CLOEXEC, descriptor)
    guard duplicated >= 0 else {
        throw currentPOSIXError()
    }
    guard duplicated == descriptor else {
        _ = Darwin.close(duplicated)
        throw POSIXError(.EBUSY)
    }
    return duplicated
}

private func currentPOSIXError() -> POSIXError {
    POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
}
#endif
