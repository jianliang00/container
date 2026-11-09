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

import CryptoKit
import Darwin
import Foundation

/// Compacts immutable inputs via descriptors opened on native logical devices.
/// The caller owns attachment, durable checkpoint publication and fencing.
public struct MacOSASIFCompaction: Sendable {
    private static let block = MacOSASIFLayerIndex.blockBytes
    private static let batch = 256

    public enum Failure: Swift.Error, Equatable {
        case invalidInput
        case invalidCheckpoint
        case shortIO
        case segmentMismatch
        case unexpectedOutputRanges
    }

    public let logicalBytes: UInt64
    private let offsets: [UInt64]?

    public var usesIndex: Bool { offsets != nil }
    public var blockCount: Int {
        offsets?.count ?? Int((logicalBytes + UInt64(Self.block) - 1) / UInt64(Self.block))
    }
    private var segmentCount: Int { (blockCount + Self.batch - 1) / Self.batch }

    public init(layers: [URL], logicalBytes: UInt64, sparseBase: URL? = nil) throws {
        guard (1...4).contains(layers.count), logicalBytes > 0, logicalBytes <= 1 << 40, logicalBytes % 512 == 0 else {
            throw Failure.invalidInput
        }
        self.logicalBytes = logicalBytes
        var candidates: Set<UInt64> = []
        var fullDiscards: Set<UInt64> = []
        var known = true
        for layer in layers {
            if let changes = try MacOSASIFLayerIndex.changes(in: layer, logicalBytes: logicalBytes) {
                candidates.formUnion(changes.data)
                fullDiscards.formUnion(changes.fullDiscards)
            } else {
                known = false
            }
        }
        guard known else {
            offsets = nil
            return
        }
        fullDiscards.subtract(candidates)
        if let sparseBase, !fullDiscards.isEmpty {
            fullDiscards = try Self.discardsWithBaseData(fullDiscards, base: sparseBase, logicalBytes: logicalBytes)
        }
        offsets = candidates.union(fullDiscards).sorted()
    }

    /// If every overlay either inherits or discards a block, a hole in the
    /// RAW base proves the native source and target both read as zero.
    private static func discardsWithBaseData(_ offsets: Set<UInt64>, base: URL, logicalBytes: UInt64) throws -> Set<UInt64> {
        let fd = open(base.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        var value = stat()
        guard fstat(fd, &value) == 0, value.st_mode & S_IFMT == S_IFREG, value.st_mode & 0o222 == 0,
            value.st_size == off_t(logicalBytes)
        else { throw Failure.invalidInput }
        var withData: Set<UInt64> = []
        var nextData: UInt64 = 0
        for offset in offsets.sorted() {
            if offset >= nextData {
                let start = lseek(fd, off_t(offset), SEEK_DATA)
                if start == -1 {
                    switch errno {
                    case ENXIO: return withData
                    case EINVAL, ENOTSUP, ENOSYS: return offsets
                    default: throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                }
                guard start >= off_t(offset) else { throw Failure.invalidInput }
                nextData = UInt64(start)
            }
            if nextData < min(offset + UInt64(Self.block), logicalBytes) {
                withData.insert(offset)
            }
        }
        return withData
    }

    /// The caller also binds the journal to the immutable input generation.
    public var planDigest: String {
        var digest = SHA256()
        digest.update(data: Data([usesIndex ? 1 : 0]))
        var size = logicalBytes.bigEndian
        withUnsafeBytes(of: &size) { digest.update(bufferPointer: $0) }
        for offset in offsets ?? [] {
            var value = offset.bigEndian
            withUnsafeBytes(of: &value) { digest.update(bufferPointer: $0) }
        }
        return digest.finalize().hex
    }

    public func copy(
        base: Int32, source: Int32, target: Int32, completed: [String],
        checkpoint: ([String]) throws -> Void
    ) throws -> [String] {
        guard completed.count <= segmentCount else { throw Failure.invalidCheckpoint }
        var hashes = completed
        for segment in 0..<segmentCount {
            try Task.checkCancellation()
            let write = segment >= completed.count
            var expected = SHA256()
            for index in indices(segment) {
                let offset = position(index)
                let data = try read(source, at: offset)
                expected.update(data: data)
                if write, try data != read(base, at: offset) {
                    let count = data.withUnsafeBytes { pwrite(target, $0.baseAddress, data.count, off_t(offset)) }
                    guard count == data.count else { throw Failure.shortIO }
                }
            }
            if write, fsync(target) != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let hash = expected.finalize().hex
            guard try segmentDigest(target, segment: segment) == hash else { throw Failure.segmentMismatch }
            if write {
                hashes.append(hash)
                try checkpoint(hashes)
            } else if completed[segment] != hash {
                throw Failure.invalidCheckpoint
            }
        }
        return hashes
    }

    /// Call after detaching the writable output, then reopen it read-only for verify.
    public func validateOutputRanges(_ output: URL) throws {
        guard let offsets else { return }
        guard let candidates = try MacOSASIFLayerIndex.candidates(in: output, logicalBytes: logicalBytes),
            candidates.isSubset(of: offsets)
        else { throw Failure.unexpectedOutputRanges }
    }

    public func verify(target: Int32, expected: [String]) throws {
        guard expected.count == segmentCount else { throw Failure.invalidCheckpoint }
        for (segment, hash) in expected.enumerated() {
            try Task.checkCancellation()
            guard try segmentDigest(target, segment: segment) == hash else { throw Failure.segmentMismatch }
        }
    }

    private func segmentDigest(_ fd: Int32, segment: Int) throws -> String {
        var digest = SHA256()
        for index in indices(segment) { digest.update(data: try read(fd, at: position(index))) }
        return digest.finalize().hex
    }

    private func indices(_ segment: Int) -> Range<Int> {
        segment * Self.batch..<min((segment + 1) * Self.batch, blockCount)
    }

    private func position(_ index: Int) -> UInt64 {
        offsets?[index] ?? UInt64(index * Self.block)
    }

    private func read(_ fd: Int32, at offset: UInt64) throws -> Data {
        let count = Int(min(UInt64(Self.block), logicalBytes - offset))
        var data = Data(count: count)
        let actual = data.withUnsafeMutableBytes { pread(fd, $0.baseAddress, count, off_t(offset)) }
        guard actual == count else { throw Failure.shortIO }
        return data
    }
}

extension SHA256.Digest {
    fileprivate var hex: String { map { String(format: "%02x", $0) }.joined() }
}
