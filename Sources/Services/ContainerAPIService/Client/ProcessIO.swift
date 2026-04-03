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

import ContainerizationExtras
import ContainerizationOS
import Foundation
import Logging

public struct ProcessIO: Sendable {
    package typealias StartupNoticeWriter = @Sendable (String) -> Void

    private final class StartupNoticeState: @unchecked Sendable {
        private let lock = NSLock()
        private var didEmit = false

        func emitIfNeeded(_ body: () -> Void) {
            let shouldEmit = lock.withLock { () -> Bool in
                guard !didEmit else {
                    return false
                }
                didEmit = true
                return true
            }

            guard shouldEmit else {
                return
            }

            body()
        }
    }

    let stdin: Pipe?
    let stdout: Pipe?
    let stderr: Pipe?
    var ioTracker: IoTracker?

    static let signalSet: [Int32] = [
        SIGTERM,
        SIGINT,
        SIGUSR1,
        SIGUSR2,
        SIGWINCH,
    ]

    public struct IoTracker: Sendable {
        let stream: AsyncStream<Void>
        let cont: AsyncStream<Void>.Continuation
        let configuredStreams: Int
    }

    public let stdio: [FileHandle?]

    public let console: Terminal?

    public static func create(tty: Bool, interactive: Bool, detach: Bool) throws -> ProcessIO {
        let current: Terminal? = try {
            if !tty || !interactive {
                return nil
            }
            let current = try Terminal(descriptor: STDIN_FILENO)
            try current.setraw()
            return current
        }()

        var stdio = [FileHandle?](repeating: nil, count: 3)

        let stdin: Pipe? = {
            if !interactive {
                return nil
            }
            return Pipe()
        }()

        if let stdin {
            let pin = FileHandle.standardInput
            let stdinOSFile = OSFile(fd: pin.fileDescriptor)
            let pipeOSFile = OSFile(fd: stdin.fileHandleForWriting.fileDescriptor)
            try stdinOSFile.makeNonBlocking()
            nonisolated(unsafe) let buf = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: Int(getpagesize()))

            pin.readabilityHandler = { _ in
                Self.streamStdin(
                    from: stdinOSFile,
                    to: pipeOSFile,
                    buffer: buf,
                ) {
                    pin.readabilityHandler = nil
                    buf.deallocate()
                    try? stdin.fileHandleForWriting.close()
                }
            }
            stdio[0] = stdin.fileHandleForReading
        }

        let stdout: Pipe? = {
            if detach {
                return nil
            }
            return Pipe()
        }()

        var configuredStreams = 0
        let (stream, cc) = AsyncStream<Void>.makeStream()
        if let stdout {
            configuredStreams += 1

            stdio[1] = stdout.fileHandleForWriting
            let pout = FileHandle.standardOutput
            let rout = stdout.fileHandleForReading
            rout.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    rout.readabilityHandler = nil
                    cc.yield()
                    return
                }
                try! pout.write(contentsOf: data)
            }
        }

        let stderr: Pipe? = {
            if detach || tty {
                return nil
            }
            return Pipe()
        }()
        if let stderr {
            configuredStreams += 1
            let perr: FileHandle = .standardError
            let rerr = stderr.fileHandleForReading
            rerr.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    rerr.readabilityHandler = nil
                    cc.yield()
                    return
                }
                try! perr.write(contentsOf: data)
            }
            stdio[2] = stderr.fileHandleForWriting
        }

        var ioTracker: IoTracker? = nil
        if configuredStreams > 0 {
            ioTracker = .init(stream: stream, cont: cc, configuredStreams: configuredStreams)
        }

        return .init(
            stdin: stdin,
            stdout: stdout,
            stderr: stderr,
            ioTracker: ioTracker,
            stdio: stdio,
            console: current
        )
    }

    public func handleProcess(process: ClientProcess, log: Logger) async throws -> Int32 {
        try await handleProcess(
            process: process,
            log: log,
            startupMessage: nil
        )
    }

    public func handleAttachment(
        attachment: any ClientWorkloadAttachment,
        log: Logger
    ) async throws -> Int32 {
        try closeAfterStart()
        return try await handleInteractiveSession(
            log: log,
            waitForExit: {
                try await attachment.wait()
            },
            resize: { size in
                try await attachment.resize(size)
            },
            signal: { signal in
                try await attachment.signal(signal)
            }
        )
    }

    package func handleProcess(
        process: ClientProcess,
        log: Logger,
        startupMessage: String?,
        startupDelayNanoseconds: UInt64 = 2_000_000_000,
        startupWriter: @escaping StartupNoticeWriter = Self.writeStandardErrorLine
    ) async throws -> Int32 {
        try await Self.startProcess(
            process: process,
            startupMessage: startupMessage,
            startupDelayNanoseconds: startupDelayNanoseconds,
            startupWriter: startupWriter
        )
        try closeAfterStart()
        return try await handleInteractiveSession(
            log: log,
            waitForExit: {
                try await process.wait()
            },
            resize: { size in
                try await process.resize(size)
            },
            signal: { signal in
                try await process.kill(signal)
            }
        )
    }

    private func handleInteractiveSession(
        log: Logger,
        waitForExit: @escaping @Sendable () async throws -> Int32,
        resize: @escaping @Sendable (Terminal.Size) async throws -> Void,
        signal: @escaping @Sendable (Int32) async throws -> Void
    ) async throws -> Int32 {
        let signals = AsyncSignalHandler.create(notify: Self.signalSet)

        return try await withThrowingTaskGroup(of: Int32?.self, returning: Int32.self) { group in
            let waitAdded = group.addTaskUnlessCancelled {
                let code = try await waitForExit()
                try await wait()
                return code
            }

            guard waitAdded else {
                group.cancelAll()
                return -1
            }

            if let current = console {
                let size = try current.size
                // It's supremely possible the process could've exited already. We shouldn't treat
                // this as fatal.
                try? await resize(size)
                _ = group.addTaskUnlessCancelled {
                    let winchHandler = AsyncSignalHandler.create(notify: [SIGWINCH])
                    for await _ in winchHandler.signals {
                        do {
                            try await resize(try current.size)
                        } catch {
                            log.error(
                                "failed to send terminal resize event",
                                metadata: [
                                    "error": "\(error)"
                                ]
                            )
                        }
                    }
                    return nil
                }
            } else {
                _ = group.addTaskUnlessCancelled {
                    for await sig in signals.signals {
                        do {
                            try await signal(sig)
                        } catch {
                            log.error(
                                "failed to send signal",
                                metadata: [
                                    "signal": "\(sig)",
                                    "error": "\(error)",
                                ]
                            )
                        }
                    }
                    return nil
                }
            }

            while true {
                let result = try await group.next()
                if result == nil {
                    return -1
                }
                let status = result!
                if let status {
                    group.cancelAll()
                    return status
                }
            }
            return -1
        }
    }

    public func closeAfterStart() throws {
        try stdin?.fileHandleForReading.close()
        try stdout?.fileHandleForWriting.close()
        try stderr?.fileHandleForWriting.close()
    }

    public func close() throws {
        try console?.reset()
    }

    public func wait() async throws {
        guard let ioTracker = self.ioTracker else {
            return
        }
        do {
            try await Timeout.run(seconds: 3) {
                var counter = ioTracker.configuredStreams
                for await _ in ioTracker.stream {
                    counter -= 1
                    if counter == 0 {
                        ioTracker.cont.finish()
                        break
                    }
                }
            }
        } catch {
            throw error
        }
    }

    static func streamStdin(
        from: OSFile,
        to: OSFile,
        buffer: UnsafeMutableBufferPointer<UInt8>,
        onErrorOrEOF: () -> Void,
    ) {
        while true {
            let (bytesRead, action) = from.read(buffer)
            if bytesRead > 0 {
                let view = UnsafeMutableBufferPointer(
                    start: buffer.baseAddress,
                    count: bytesRead
                )

                let (bytesWritten, _) = to.write(view)
                if bytesWritten != bytesRead {
                    onErrorOrEOF()
                    return
                }
            }

            switch action {
            case .error(_), .eof, .brokenPipe:
                onErrorOrEOF()
                return
            case .again:
                return
            case .success:
                break
            }
        }
    }

    package static func startProcess(
        process: ClientProcess,
        startupMessage: String? = nil,
        startupDelayNanoseconds: UInt64 = 2_000_000_000,
        startupWriter: @escaping StartupNoticeWriter = Self.writeStandardErrorLine
    ) async throws {
        let startupNoticeState = StartupNoticeState()
        let startUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
        let noticeTask = Self.makeStartupNoticeTask(
            startupMessage: startupMessage,
            startupDelayNanoseconds: startupDelayNanoseconds,
            startupWriter: startupWriter,
            startupNoticeState: startupNoticeState
        )

        do {
            try await process.start()
            Self.emitStartupNoticeIfOverdue(
                startupMessage: startupMessage,
                startupDelayNanoseconds: startupDelayNanoseconds,
                startupWriter: startupWriter,
                startupNoticeState: startupNoticeState,
                elapsedNanoseconds: DispatchTime.now().uptimeNanoseconds &- startUptimeNanoseconds
            )
            noticeTask?.cancel()
            _ = await noticeTask?.result
        } catch {
            Self.emitStartupNoticeIfOverdue(
                startupMessage: startupMessage,
                startupDelayNanoseconds: startupDelayNanoseconds,
                startupWriter: startupWriter,
                startupNoticeState: startupNoticeState,
                elapsedNanoseconds: DispatchTime.now().uptimeNanoseconds &- startUptimeNanoseconds
            )
            noticeTask?.cancel()
            _ = await noticeTask?.result
            throw error
        }
    }

    private static func emitStartupNoticeIfOverdue(
        startupMessage: String?,
        startupDelayNanoseconds: UInt64,
        startupWriter: @escaping StartupNoticeWriter,
        startupNoticeState: StartupNoticeState,
        elapsedNanoseconds: UInt64
    ) {
        guard let startupMessage, !startupMessage.isEmpty else {
            return
        }
        guard elapsedNanoseconds >= startupDelayNanoseconds else {
            return
        }

        startupNoticeState.emitIfNeeded {
            startupWriter(startupMessage)
        }
    }

    private static func makeStartupNoticeTask(
        startupMessage: String?,
        startupDelayNanoseconds: UInt64,
        startupWriter: @escaping StartupNoticeWriter,
        startupNoticeState: StartupNoticeState
    ) -> Task<Void, Never>? {
        guard let startupMessage, !startupMessage.isEmpty else {
            return nil
        }

        return Task {
            do {
                try await Task.sleep(nanoseconds: startupDelayNanoseconds)
                guard !Task.isCancelled else {
                    return
                }
                startupNoticeState.emitIfNeeded {
                    startupWriter(startupMessage)
                }
            } catch is CancellationError {
            } catch {
                return
            }
        }
    }

    private static func writeStandardErrorLine(_ line: String) {
        let formatted = line.hasSuffix("\n") ? line : "\(line)\n"
        try? FileHandle.standardError.write(contentsOf: Data(formatted.utf8))
    }
}

public struct OSFile: Sendable {
    private let fd: Int32

    public enum IOAction: Equatable {
        case eof
        case again
        case success
        case brokenPipe
        case error(_ errno: Int32)
    }

    public init(fd: Int32) {
        self.fd = fd
    }

    public init(handle: FileHandle) {
        self.fd = handle.fileDescriptor
    }

    func makeNonBlocking() throws {
        let flags = fcntl(fd, F_GETFL)
        guard flags != -1 else {
            throw POSIXError.fromErrno()
        }

        if fcntl(fd, F_SETFL, flags | O_NONBLOCK) == -1 {
            throw POSIXError.fromErrno()
        }
    }

    func write(_ buffer: UnsafeMutableBufferPointer<UInt8>) -> (wrote: Int, action: IOAction) {
        if buffer.count == 0 {
            return (0, .success)
        }

        var bytesWrote: Int = 0
        while true {
            let n = Darwin.write(
                self.fd,
                buffer.baseAddress!.advanced(by: bytesWrote),
                buffer.count - bytesWrote
            )
            if n == -1 {
                if errno == EAGAIN || errno == EIO {
                    return (bytesWrote, .again)
                }
                return (bytesWrote, .error(errno))
            }

            if n == 0 {
                return (bytesWrote, .brokenPipe)
            }

            bytesWrote += n
            if bytesWrote < buffer.count {
                continue
            }
            return (bytesWrote, .success)
        }
    }

    func read(_ buffer: UnsafeMutableBufferPointer<UInt8>) -> (read: Int, action: IOAction) {
        if buffer.count == 0 {
            return (0, .success)
        }

        var bytesRead: Int = 0
        while true {
            let n = Darwin.read(
                self.fd,
                buffer.baseAddress!.advanced(by: bytesRead),
                buffer.count - bytesRead
            )
            if n == -1 {
                if errno == EAGAIN || errno == EIO {
                    return (bytesRead, .again)
                }
                return (bytesRead, .error(errno))
            }

            if n == 0 {
                return (bytesRead, .eof)
            }

            bytesRead += n
            if bytesRead < buffer.count {
                continue
            }
            return (bytesRead, .success)
        }
    }
}
