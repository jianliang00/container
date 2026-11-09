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

import Darwin
import Foundation

/// Enumerates possible changes from the observed ASIF v1 allocation table.
/// Native stacked devices still resolve reads and apply all writes, including
/// partial writes and discards. Unknown geometries require a native scan.
/// Layout notes: https://github.com/huven/asif-format
public enum MacOSASIFLayerIndex {
    public static let blockBytes = 1 << 20
    private static let sectorBytes = 512
    private static let entriesPerGroup = 4 * sectorBytes
    private static let groupBytes = 8 * (entriesPerGroup + 1)
    private static let groupsPerTable = blockBytes / groupBytes
    private static let blocksPerTable = groupsPerTable * entriesPerGroup
    private static let physicalMask = (UInt64(1) << 55) - 1
    private static let reservedMask = ((UInt64(1) << 62) - 1) ^ physicalMask

    public enum IndexError: Swift.Error, Equatable {
        case malformed
    }

    /// `nil` means the layout is unknown. An invalid known layout throws.
    /// This must be called only on an immutable, detached layer.
    public static func candidates(in url: URL, logicalBytes: UInt64) throws -> Set<UInt64>? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        var value = stat()
        guard fstat(fd, &value) == 0, value.st_mode & S_IFMT == S_IFREG,
            value.st_mode & 0o222 == 0, value.st_uid == geteuid(), value.st_size >= 0
        else { throw IndexError.malformed }
        let length = UInt64(value.st_size)

        func read(_ offset: UInt64, _ count: Int) throws -> Data {
            guard offset <= length, UInt64(count) <= length - offset else { throw IndexError.malformed }
            var data = Data(count: count)
            let countRead = data.withUnsafeMutableBytes { pread(fd, $0.baseAddress, count, off_t(offset)) }
            guard countRead == count else { throw IndexError.malformed }
            return data
        }

        guard length >= 8, try read(0, 8) == Data([0x73, 0x68, 0x64, 0x77, 0, 0, 0, 1]) else { return nil }
        let header = try read(0, sectorBytes)
        guard header.be32(8) == sectorBytes, header.be32(12) == 0,
            header.be32(64) == blockBytes, header.be16(68) == sectorBytes, header.be16(70) == 0
        else { return nil }
        let sectors = header.be64(48)
        let maximum = header.be64(56)
        guard sectors > 0, sectors <= maximum, maximum <= UInt64.max / UInt64(sectorBytes) else { throw IndexError.malformed }
        guard sectors * UInt64(sectorBytes) == logicalBytes else { return nil }
        let tableCount = ceiling(maximum * UInt64(sectorBytes), UInt64(blocksPerTable * blockBytes))
        guard tableCount < UInt64(blockBytes / 8) else { throw IndexError.malformed }
        let directoryBytes = 8 * (1 + tableCount)
        let first = header.be64(16)
        let second = header.be64(24)
        guard first >= sectorBytes, first <= second, second <= blockBytes,
            first % UInt64(sectorBytes) == 0, second % UInt64(sectorBytes) == 0,
            directoryBytes <= second - first, directoryBytes <= UInt64(blockBytes) - second
        else { throw IndexError.malformed }
        let a = try read(first, Int(directoryBytes))
        let b = try read(second, Int(directoryBytes))
        guard a.be64(0) != b.be64(0) || a == b else { throw IndexError.malformed }
        let directory = a.be64(0) >= b.be64(0) ? a : b
        let tables = (0..<Int(tableCount)).map { directory.be64(($0 + 1) * 8) }
        var used: Set<UInt64> = [0]
        for table in tables where table != 0 {
            guard validChunk(table, length: length), used.insert(table).inserted else { throw IndexError.malformed }
        }

        let limit = ceiling(logicalBytes, UInt64(blockBytes))
        var offsets: Set<UInt64> = []
        for (tableIndex, table) in tables.prefix(Int(ceiling(limit, UInt64(blocksPerTable)))).enumerated() where table != 0 {
            let data = try read(table * UInt64(blockBytes), blockBytes)
            for group in 0..<groupsPerTable {
                let start = UInt64(tableIndex * blocksPerTable + group * entriesPerGroup)
                guard start < limit else { break }
                let groupStart = group * groupBytes
                let bitmap = data.be64(groupStart + entriesPerGroup * 8)
                if bitmap != 0 {
                    guard validChunk(bitmap, length: length), used.insert(bitmap).inserted else { throw IndexError.malformed }
                }
                for index in 0..<Int(min(UInt64(entriesPerGroup), limit - start)) {
                    let entry = data.be64(groupStart + index * 8)
                    guard entry != 0 else { continue }
                    let physical = entry & physicalMask
                    guard entry & reservedMask == 0 else { throw IndexError.malformed }
                    switch entry >> 62 {
                    case 1:
                        guard physical != 0, validChunk(physical, length: length) else { throw IndexError.malformed }
                    case 2:
                        guard physical == 0 else { throw IndexError.malformed }
                    case 3:
                        // Partial discard can be represented without any payload.
                        guard bitmap != 0, physical == 0 || (length > 0 && physical <= (length - 1) / UInt64(blockBytes)) else {
                            throw IndexError.malformed
                        }
                    default:
                        throw IndexError.malformed
                    }
                    if physical != 0, !used.insert(physical).inserted { throw IndexError.malformed }
                    offsets.insert((start + UInt64(index)) * UInt64(blockBytes))
                }
            }
        }
        return offsets
    }

    private static func validChunk(_ index: UInt64, length: UInt64) -> Bool {
        length >= blockBytes && index <= (length - UInt64(blockBytes)) / UInt64(blockBytes)
    }

    private static func ceiling(_ value: UInt64, _ divisor: UInt64) -> UInt64 {
        value / divisor + (value % divisor == 0 ? 0 : 1)
    }
}

extension Data {
    fileprivate func be16(_ offset: Int) -> UInt16 {
        withUnsafeBytes { UInt16(bigEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self)) }
    }

    fileprivate func be32(_ offset: Int) -> UInt32 {
        withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
    }

    fileprivate func be64(_ offset: Int) -> UInt64 {
        withUnsafeBytes { UInt64(bigEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self)) }
    }
}
