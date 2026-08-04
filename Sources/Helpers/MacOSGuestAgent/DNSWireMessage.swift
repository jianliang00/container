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

import Foundation

enum DNSWireError: Error {
    case invalidMessage(String)
}

struct DNSWireName: Sendable, Equatable, CustomStringConvertible {
    let labels: [[UInt8]]

    init(_ value: String) throws {
        let normalized = value.hasSuffix(".") ? String(value.dropLast()) : value
        if normalized.isEmpty {
            self.labels = []
            return
        }

        let labels = normalized.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.allSatisfy({ !$0.isEmpty }) else {
            throw DNSWireError.invalidMessage("DNS name contains an empty label")
        }
        self.labels = try labels.map {
            let bytes = Array($0.utf8)
            guard bytes.count <= 63 else {
                throw DNSWireError.invalidMessage("DNS label exceeds 63 bytes")
            }
            return bytes
        }
        guard encoded.count <= 255 else {
            throw DNSWireError.invalidMessage("DNS name exceeds 255 bytes")
        }
    }

    init(labels: [[UInt8]]) throws {
        guard labels.allSatisfy({ !$0.isEmpty && $0.count <= 63 }) else {
            throw DNSWireError.invalidMessage("DNS name contains an invalid label")
        }
        self.labels = labels
        guard encoded.count <= 255 else {
            throw DNSWireError.invalidMessage("DNS name exceeds 255 bytes")
        }
    }

    var description: String {
        if labels.isEmpty {
            return "."
        }
        return labels.map { String(decoding: $0, as: UTF8.self) }.joined(separator: ".") + "."
    }

    var encoded: [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity(labels.reduce(1) { $0 + $1.count + 1 })
        for label in labels {
            result.append(UInt8(label.count))
            result.append(contentsOf: label)
        }
        result.append(0)
        return result
    }

    var dotCount: Int {
        max(labels.count - 1, 0)
    }

    func appending(_ suffix: DNSWireName) throws -> DNSWireName {
        try DNSWireName(labels: labels + suffix.labels)
    }

    func isEqualCaseInsensitive(to other: DNSWireName) -> Bool {
        guard labels.count == other.labels.count else {
            return false
        }
        return zip(labels, other.labels).allSatisfy { lhs, rhs in
            guard lhs.count == rhs.count else {
                return false
            }
            return zip(lhs, rhs).allSatisfy { asciiLowercased($0) == asciiLowercased($1) }
        }
    }

    func hasSuffix(_ suffix: DNSWireName) -> Bool {
        guard labels.count >= suffix.labels.count else {
            return false
        }
        let start = labels.count - suffix.labels.count
        return zip(labels[start...], suffix.labels).allSatisfy { lhs, rhs in
            guard lhs.count == rhs.count else {
                return false
            }
            return zip(lhs, rhs).allSatisfy { asciiLowercased($0) == asciiLowercased($1) }
        }
    }

    private func asciiLowercased(_ byte: UInt8) -> UInt8 {
        guard byte >= 65, byte <= 90 else {
            return byte
        }
        return byte + 32
    }
}

struct DNSWireMessage: Sendable {
    struct Question: Sendable {
        var name: DNSWireName
        let type: UInt16
        let recordClass: UInt16
    }

    enum RDataSegment: Sendable {
        case bytes([UInt8])
        case name(DNSWireName)
    }

    struct Record: Sendable {
        var name: DNSWireName
        let type: UInt16
        let recordClass: UInt16
        let ttl: UInt32
        var rdata: [RDataSegment]
    }

    var id: UInt16
    var flags: UInt16
    var questions: [Question]
    var answers: [Record]
    var authorities: [Record]
    var additional: [Record]

    init(response bytes: [UInt8]) throws {
        guard bytes.count >= 12 else {
            throw DNSWireError.invalidMessage("DNS response is shorter than its header")
        }
        id = try Self.readUInt16(bytes, at: 0)
        flags = try Self.readUInt16(bytes, at: 2)
        let questionCount = Int(try Self.readUInt16(bytes, at: 4))
        let answerCount = Int(try Self.readUInt16(bytes, at: 6))
        let authorityCount = Int(try Self.readUInt16(bytes, at: 8))
        let additionalCount = Int(try Self.readUInt16(bytes, at: 10))

        var offset = 12
        questions = try (0..<questionCount).map { _ in
            let name = try Self.readName(bytes, offset: &offset)
            let type = try Self.readUInt16(bytes, at: offset)
            let recordClass = try Self.readUInt16(bytes, at: offset + 2)
            offset += 4
            return Question(name: name, type: type, recordClass: recordClass)
        }
        answers = try Self.readRecords(bytes, count: answerCount, offset: &offset)
        authorities = try Self.readRecords(bytes, count: authorityCount, offset: &offset)
        additional = try Self.readRecords(bytes, count: additionalCount, offset: &offset)
    }

    mutating func replaceName(_ source: DNSWireName, with replacement: DNSWireName) {
        for index in questions.indices where questions[index].name.isEqualCaseInsensitive(to: source) {
            questions[index].name = replacement
        }
        Self.replaceName(source, with: replacement, in: &answers)
        Self.replaceName(source, with: replacement, in: &authorities)
        Self.replaceName(source, with: replacement, in: &additional)
    }

    func serialized() throws -> [UInt8] {
        guard questions.count <= Int(UInt16.max), answers.count <= Int(UInt16.max),
            authorities.count <= Int(UInt16.max), additional.count <= Int(UInt16.max)
        else {
            throw DNSWireError.invalidMessage("DNS section count exceeds UInt16")
        }

        var result: [UInt8] = []
        Self.appendUInt16(id, to: &result)
        Self.appendUInt16(flags, to: &result)
        Self.appendUInt16(UInt16(questions.count), to: &result)
        Self.appendUInt16(UInt16(answers.count), to: &result)
        Self.appendUInt16(UInt16(authorities.count), to: &result)
        Self.appendUInt16(UInt16(additional.count), to: &result)

        for question in questions {
            result.append(contentsOf: question.name.encoded)
            Self.appendUInt16(question.type, to: &result)
            Self.appendUInt16(question.recordClass, to: &result)
        }
        try Self.appendRecords(answers, to: &result)
        try Self.appendRecords(authorities, to: &result)
        try Self.appendRecords(additional, to: &result)
        return result
    }

    static func questionName(in bytes: [UInt8]) throws -> DNSWireName {
        guard bytes.count >= 12, try readUInt16(bytes, at: 4) == 1 else {
            throw DNSWireError.invalidMessage("DNS proxy requires exactly one question")
        }
        var offset = 12
        return try readName(bytes, offset: &offset)
    }

    static func replacingQuestionName(in bytes: [UInt8], with name: DNSWireName) throws -> [UInt8] {
        guard bytes.count >= 12, try readUInt16(bytes, at: 4) == 1 else {
            throw DNSWireError.invalidMessage("DNS proxy requires exactly one question")
        }
        var questionEnd = 12
        _ = try readName(bytes, offset: &questionEnd)
        guard questionEnd + 4 <= bytes.count else {
            throw DNSWireError.invalidMessage("DNS question is truncated")
        }

        var result = Array(bytes[..<12])
        result.append(contentsOf: name.encoded)
        result.append(contentsOf: bytes[questionEnd...])
        return result
    }

    static func rewritingResponse(
        _ bytes: [UInt8],
        expandedName: DNSWireName,
        originalName: DNSWireName
    ) throws -> [UInt8] {
        var message = try DNSWireMessage(response: bytes)
        message.replaceName(expandedName, with: originalName)
        return try message.serialized()
    }

    static func isSearchMiss(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 12 else {
            return false
        }
        let responseCode = bytes[3] & 0x0f
        let answerCount = (UInt16(bytes[6]) << 8) | UInt16(bytes[7])
        return responseCode == 3 || (responseCode == 0 && answerCount == 0)
    }

    static func isServerFailure(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 4 else {
            return true
        }
        let responseCode = bytes[3] & 0x0f
        return responseCode == 2 || responseCode == 5
    }

    static func isTruncated(_ bytes: [UInt8]) -> Bool {
        bytes.count >= 3 && bytes[2] & 0x02 != 0
    }

    static func transactionID(_ bytes: [UInt8]) -> UInt16? {
        guard bytes.count >= 2 else {
            return nil
        }
        return (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
    }

    static func udpPayloadSize(in query: [UInt8]) -> Int {
        guard let message = try? DNSWireMessage(response: query),
            let advertisedSize = message.additional.first(where: { $0.type == 41 })?.recordClass
        else {
            return 512
        }
        return max(Int(advertisedSize), 512)
    }

    static func truncatedResponse(for query: [UInt8]) -> [UInt8] {
        response(for: query, responseCode: 0, truncated: true)
    }

    static func serverFailureResponse(for query: [UInt8]) -> [UInt8] {
        response(for: query, responseCode: 2, truncated: false)
    }

    private static func response(for query: [UInt8], responseCode: UInt8, truncated: Bool) -> [UInt8] {
        guard query.count >= 12, (try? readUInt16(query, at: 4)) == 1 else {
            return []
        }
        var questionEnd = 12
        guard (try? readName(query, offset: &questionEnd)) != nil, questionEnd + 4 <= query.count else {
            return []
        }
        var result = Array(query[..<(questionEnd + 4)])
        result[2] = (result[2] & 0x79) | 0x80 | (truncated ? 0x02 : 0)
        result[3] = (result[3] & 0x10) | 0x80 | (responseCode & 0x0f)
        result[6] = 0
        result[7] = 0
        result[8] = 0
        result[9] = 0
        result[10] = 0
        result[11] = 0
        return result
    }

    private static func replaceName(
        _ source: DNSWireName,
        with replacement: DNSWireName,
        in records: inout [Record]
    ) {
        for recordIndex in records.indices {
            if records[recordIndex].name.isEqualCaseInsensitive(to: source) {
                records[recordIndex].name = replacement
            }
            for segmentIndex in records[recordIndex].rdata.indices {
                guard case .name(let name) = records[recordIndex].rdata[segmentIndex],
                    name.isEqualCaseInsensitive(to: source)
                else {
                    continue
                }
                records[recordIndex].rdata[segmentIndex] = .name(replacement)
            }
        }
    }

    private static func readRecords(
        _ bytes: [UInt8],
        count: Int,
        offset: inout Int
    ) throws -> [Record] {
        try (0..<count).map { _ in
            let name = try readName(bytes, offset: &offset)
            let type = try readUInt16(bytes, at: offset)
            let recordClass = try readUInt16(bytes, at: offset + 2)
            let ttl = try readUInt32(bytes, at: offset + 4)
            let dataLength = Int(try readUInt16(bytes, at: offset + 8))
            offset += 10
            let dataStart = offset
            let dataEnd = dataStart + dataLength
            guard dataEnd <= bytes.count else {
                throw DNSWireError.invalidMessage("DNS record data is truncated")
            }
            let rdata = try readRData(bytes, type: type, start: dataStart, end: dataEnd)
            offset = dataEnd
            return Record(name: name, type: type, recordClass: recordClass, ttl: ttl, rdata: rdata)
        }
    }

    private static func readRData(
        _ bytes: [UInt8],
        type: UInt16,
        start: Int,
        end: Int
    ) throws -> [RDataSegment] {
        func singleName(prefixLength: Int = 0) throws -> [RDataSegment] {
            guard start + prefixLength <= end else {
                throw DNSWireError.invalidMessage("DNS record prefix is truncated")
            }
            var cursor = start + prefixLength
            let name = try readName(bytes, offset: &cursor)
            guard cursor <= end else {
                throw DNSWireError.invalidMessage("DNS record name exceeds record data")
            }
            var result: [RDataSegment] = []
            if prefixLength > 0 {
                result.append(.bytes(Array(bytes[start..<(start + prefixLength)])))
            }
            result.append(.name(name))
            if cursor < end {
                result.append(.bytes(Array(bytes[cursor..<end])))
            }
            return result
        }

        func twoNames(prefixLength: Int = 0) throws -> [RDataSegment] {
            guard start + prefixLength <= end else {
                throw DNSWireError.invalidMessage("DNS record prefix is truncated")
            }
            var cursor = start + prefixLength
            let first = try readName(bytes, offset: &cursor)
            let second = try readName(bytes, offset: &cursor)
            guard cursor <= end else {
                throw DNSWireError.invalidMessage("DNS record names exceed record data")
            }
            var result: [RDataSegment] = []
            if prefixLength > 0 {
                result.append(.bytes(Array(bytes[start..<(start + prefixLength)])))
            }
            result.append(.name(first))
            result.append(.name(second))
            if cursor < end {
                result.append(.bytes(Array(bytes[cursor..<end])))
            }
            return result
        }

        switch type {
        case 2, 5, 12, 39:
            return try singleName()
        case 6, 14, 17:
            return try twoNames()
        case 15, 18, 21, 36:
            return try singleName(prefixLength: 2)
        case 26:
            return try twoNames(prefixLength: 2)
        case 33:
            return try singleName(prefixLength: 6)
        case 35:
            var cursor = start + 4
            guard cursor <= end else {
                throw DNSWireError.invalidMessage("NAPTR record is truncated")
            }
            for _ in 0..<3 {
                guard cursor < end else {
                    throw DNSWireError.invalidMessage("NAPTR character string is truncated")
                }
                cursor += 1 + Int(bytes[cursor])
                guard cursor <= end else {
                    throw DNSWireError.invalidMessage("NAPTR character string exceeds record data")
                }
            }
            let prefixLength = cursor - start
            return try singleName(prefixLength: prefixLength)
        case 46:
            return try singleName(prefixLength: 18)
        case 47:
            return try singleName()
        case 64, 65:
            return try singleName(prefixLength: 2)
        case 249, 250:
            return try singleName()
        default:
            return [.bytes(Array(bytes[start..<end]))]
        }
    }

    private static func appendRecords(_ records: [Record], to result: inout [UInt8]) throws {
        for record in records {
            result.append(contentsOf: record.name.encoded)
            appendUInt16(record.type, to: &result)
            appendUInt16(record.recordClass, to: &result)
            appendUInt32(record.ttl, to: &result)

            var rdata: [UInt8] = []
            for segment in record.rdata {
                switch segment {
                case .bytes(let bytes):
                    rdata.append(contentsOf: bytes)
                case .name(let name):
                    rdata.append(contentsOf: name.encoded)
                }
            }
            guard rdata.count <= Int(UInt16.max) else {
                throw DNSWireError.invalidMessage("DNS record data exceeds UInt16")
            }
            appendUInt16(UInt16(rdata.count), to: &result)
            result.append(contentsOf: rdata)
        }
    }

    private static func readName(_ bytes: [UInt8], offset: inout Int) throws -> DNSWireName {
        var cursor = offset
        var nextOffset: Int?
        var labels: [[UInt8]] = []
        var visited: Set<Int> = []

        while true {
            guard cursor < bytes.count else {
                throw DNSWireError.invalidMessage("DNS name is truncated")
            }
            guard visited.insert(cursor).inserted else {
                throw DNSWireError.invalidMessage("DNS compression pointer loop")
            }

            let length = bytes[cursor]
            if length & 0xc0 == 0xc0 {
                guard cursor + 1 < bytes.count else {
                    throw DNSWireError.invalidMessage("DNS compression pointer is truncated")
                }
                let pointer = Int(length & 0x3f) << 8 | Int(bytes[cursor + 1])
                guard pointer < bytes.count else {
                    throw DNSWireError.invalidMessage("DNS compression pointer is out of range")
                }
                if nextOffset == nil {
                    nextOffset = cursor + 2
                }
                cursor = pointer
                continue
            }
            guard length & 0xc0 == 0 else {
                throw DNSWireError.invalidMessage("DNS label uses an unsupported encoding")
            }
            cursor += 1
            if length == 0 {
                offset = nextOffset ?? cursor
                return try DNSWireName(labels: labels)
            }

            let end = cursor + Int(length)
            guard end <= bytes.count else {
                throw DNSWireError.invalidMessage("DNS label is truncated")
            }
            labels.append(Array(bytes[cursor..<end]))
            cursor = end
        }
    }

    private static func readUInt16(_ bytes: [UInt8], at offset: Int) throws -> UInt16 {
        guard offset >= 0, offset + 2 <= bytes.count else {
            throw DNSWireError.invalidMessage("UInt16 is truncated")
        }
        return (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
    }

    private static func readUInt32(_ bytes: [UInt8], at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= bytes.count else {
            throw DNSWireError.invalidMessage("UInt32 is truncated")
        }
        return (UInt32(bytes[offset]) << 24) | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8) | UInt32(bytes[offset + 3])
    }

    private static func appendUInt16(_ value: UInt16, to result: inout [UInt8]) {
        result.append(UInt8((value >> 8) & 0xff))
        result.append(UInt8(value & 0xff))
    }

    private static func appendUInt32(_ value: UInt32, to result: inout [UInt8]) {
        result.append(UInt8((value >> 24) & 0xff))
        result.append(UInt8((value >> 16) & 0xff))
        result.append(UInt8((value >> 8) & 0xff))
        result.append(UInt8(value & 0xff))
    }
}
