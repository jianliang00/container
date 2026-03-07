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
import libzstd

enum ZstdDecompressor {
    struct Error: Swift.Error, CustomStringConvertible {
        let message: String

        var description: String {
            message
        }
    }

    static func decompress(input: URL, output: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)

        let inputFD = open(input.path, O_RDONLY)
        guard inputFD >= 0 else {
            throw Error(message: "cannot open zstd input \(input.path): \(String(cString: strerror(errno)))")
        }
        defer { close(inputFD) }

        let outputFD = open(output.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard outputFD >= 0 else {
            throw Error(message: "cannot open zstd output \(output.path): \(String(cString: strerror(errno)))")
        }
        defer { close(outputFD) }

        guard let stream = ZSTD_createDStream() else {
            throw Error(message: "failed to create zstd decompression stream")
        }
        defer { ZSTD_freeDStream(stream) }

        try checkZstdResult(
            ZSTD_initDStream(stream),
            context: "failed to initialize zstd decompression stream"
        )

        let inputBufferSize = Int(ZSTD_DStreamInSize())
        let outputBufferSize = Int(ZSTD_DStreamOutSize())
        var inputBuffer = [UInt8](repeating: 0, count: inputBufferSize)
        var outputBuffer = [UInt8](repeating: 0, count: outputBufferSize)
        var sawInput = false
        var lastResult: Int = 1

        while true {
            let bytesRead = inputBuffer.withUnsafeMutableBytes { buffer -> Int in
                guard let baseAddress = buffer.baseAddress else {
                    return 0
                }
                return read(inputFD, baseAddress, buffer.count)
            }
            guard bytesRead >= 0 else {
                throw Error(message: "failed to read zstd input \(input.path): \(String(cString: strerror(errno)))")
            }
            guard bytesRead > 0 else {
                break
            }

            sawInput = true
            try inputBuffer.withUnsafeMutableBytes { inputBytes in
                var inputState = ZSTD_inBuffer(
                    src: inputBytes.baseAddress,
                    size: bytesRead,
                    pos: 0
                )

                while inputState.pos < inputState.size {
                    try outputBuffer.withUnsafeMutableBytes { outputBytes in
                        var outputState = ZSTD_outBuffer(
                            dst: outputBytes.baseAddress,
                            size: outputBytes.count,
                            pos: 0
                        )
                        let result = ZSTD_decompressStream(stream, &outputState, &inputState)
                        try checkZstdResult(result, context: "zstd decompression failed")
                        lastResult = result
                        if outputState.pos > 0 {
                            try writeAll(
                                outputFD,
                                buffer: UnsafeRawBufferPointer(
                                    start: outputBytes.baseAddress,
                                    count: outputState.pos
                                )
                            )
                        }
                    }
                }
            }
        }

        guard sawInput else {
            throw Error(message: "zstd input \(input.path) is empty")
        }
        guard lastResult == 0 else {
            throw Error(message: "zstd stream ended before the frame completed")
        }
    }

    private static func checkZstdResult(_ result: Int, context: String) throws {
        guard ZSTD_isError(result) == 0 else {
            throw Error(message: "\(context): \(String(cString: ZSTD_getErrorName(result)))")
        }
    }

    private static func writeAll(_ fd: Int32, buffer: UnsafeRawBufferPointer) throws {
        var written = 0
        while written < buffer.count {
            let bytesWritten = write(fd, buffer.baseAddress! + written, buffer.count - written)
            guard bytesWritten > 0 else {
                throw Error(message: "failed to write decompressed output: \(String(cString: strerror(errno)))")
            }
            written += bytesWritten
        }
    }
}
