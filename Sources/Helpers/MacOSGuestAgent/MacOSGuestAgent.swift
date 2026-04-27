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

import ArgumentParser
import Darwin
import Foundation
import RuntimeMacOSSidecarShared

@main
struct MacOSGuestAgent: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "container-macos-guest-agent",
        abstract: "Guest-side vsock agent for container-runtime-macos"
    )

    @Option(name: .long, help: "vsock listen port")
    var port: UInt32 = 27000

    mutating func run() throws {
        configureGuestAgentSignals()
        logAgentInfo("starting guest agent on vsock port \(port)")
        logAgentStartupContext()
        let listener = try VsockListener(port: port)
        try listener.serveForever()
    }
}

private final class VsockListener {
    private let listenFD: Int32

    init(port: UInt32) throws {
        let fd = socket(AF_VSOCK, Int32(SOCK_STREAM), 0)
        guard fd >= 0 else {
            throw POSIXError.fromErrno()
        }

        var on: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw POSIXError.fromErrno()
        }

        var address = sockaddr_vm()
        address.svm_len = UInt8(MemoryLayout<sockaddr_vm>.size)
        address.svm_family = sa_family_t(AF_VSOCK)
        address.svm_reserved1 = 0
        address.svm_port = port
        address.svm_cid = VMADDR_CID_ANY

        let addressLength = socklen_t(address.svm_len)
        let bindResult = withUnsafePointer(to: &address) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, addressLength)
            }
        }
        guard bindResult == 0 else {
            throw POSIXError.fromErrno()
        }
        logAgentInfo("vsock listener bind succeeded on cid=\(VMADDR_CID_ANY) port=\(port)")

        guard listen(fd, 16) == 0 else {
            throw POSIXError.fromErrno()
        }
        logAgentInfo("vsock listener listening on port \(port) backlog=16")

        self.listenFD = fd
    }

    deinit {
        _ = Darwin.close(listenFD)
    }

    func serveForever() throws {
        while true {
            var clientAddr = sockaddr_vm()
            var clientLen = socklen_t(MemoryLayout<sockaddr_vm>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.accept(listenFD, $0, &clientLen)
                }
            }
            guard clientFD >= 0 else {
                throw POSIXError.fromErrno()
            }
            let peerPort = clientAddr.svm_port
            let peerCID = clientAddr.svm_cid
            logAgentInfo("accepted vsock client fd=\(clientFD) cid=\(peerCID) port=\(peerPort)")

            let connection = AgentConnection(fd: clientFD)
            Thread.detachNewThread {
                do {
                    try connection.run()
                } catch {
                    logAgentError("connection loop failed: \(describeError(error))")
                    _ = Darwin.close(clientFD)
                }
            }
        }
    }
}

final class AgentConnection: @unchecked Sendable {
    private let fd: Int32
    private let lock = NSLock()
    private let socketHandle: FileHandle

    private var buffer = Data()
    private var session: (any GuestAgentProcessSession)?
    private var fileTransactions: [String: GuestAgentFileTransferTransaction] = [:]
    private var fileReadTransactions: [String: FileHandle] = [:]

    init(fd: Int32) {
        self.fd = fd
        self.socketHandle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    func run() throws {
        logAgentInfo("connection fd=\(fd): sending ready frame")
        try send(frame: .ready)
        logAgentInfo("connection fd=\(fd): ready frame sent")
        var chunkBuffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            guard let chunk = try readSocketChunk(into: &chunkBuffer), !chunk.isEmpty else {
                logAgentInfo("connection fd=\(fd): peer closed stream")
                break
            }
            buffer.append(chunk)
            do {
                try consumeFrames()
            } catch {
                let message = "failed to consume frame: \(describeError(error))"
                logAgentError(message)
                try? send(frame: .error(message))
                try? send(frame: .exit(1))
                break
            }
        }
        session?.cleanup()
        for transaction in fileTransactions.values {
            logFileTransaction("aborting outstanding transaction", request: transaction.request, extra: ["reason": "connection_closed"])
            transaction.abort()
        }
        fileTransactions.removeAll()
        for (txID, handle) in fileReadTransactions {
            logAgentInfo("connection fd=\(fd): closing outstanding read transaction tx_id=\(txID) reason=connection_closed")
            try? handle.close()
        }
        fileReadTransactions.removeAll()
        try? socketHandle.close()
    }

    private func consumeFrames() throws {
        while buffer.count >= MemoryLayout<UInt32>.size {
            let lengthBytes = buffer.prefix(MemoryLayout<UInt32>.size)
            let payloadLength = try MacOSSidecarSocketIO.frameLength(
                fromHeader: lengthBytes,
                maxSize: MacOSSidecarSocketIO.defaultMaxFrameSize
            )
            let total = MemoryLayout<UInt32>.size + payloadLength
            guard buffer.count >= total else {
                return
            }

            let payload = buffer.subdata(in: MemoryLayout<UInt32>.size..<total)
            buffer.removeSubrange(0..<total)

            let frame = try JSONDecoder().decode(GuestAgentFrame.self, from: payload)
            logAgentInfo("connection fd=\(fd): received frame \(frame.type.rawValue)")
            try handle(frame: frame)
        }
    }

    private func handle(frame: GuestAgentFrame) throws {
        switch frame.type {
        case .exec:
            do {
                try startProcess(frame: frame)
            } catch {
                session?.cleanup()
                session = nil
                let message = "failed to start process: \(describeError(error))"
                logAgentError(message)
                try? send(frame: .error(message))
                try? send(frame: .exit(1))
            }
        case .stdin:
            if let data = frame.data {
                do {
                    try session?.writeStdin(data)
                } catch {
                    let message = "failed to write stdin: \(describeError(error))"
                    logAgentError(message)
                    try? send(frame: .error(message))
                }
            }
        case .signal:
            if let signal = frame.signal {
                do {
                    try session?.sendSignal(signal)
                } catch {
                    let message = "failed to send signal \(signal): \(describeError(error))"
                    logAgentError(message)
                    try? send(frame: .error(message))
                }
            }
        case .resize:
            if let width = frame.width, let height = frame.height {
                do {
                    try session?.resize(width: width, height: height)
                } catch {
                    let message = "failed to resize tty to \(width)x\(height): \(describeError(error))"
                    logAgentError(message)
                    try? send(frame: .error(message))
                }
            }
        case .close:
            session?.closeStdin()
        case .networkConfigure:
            try configureNetwork(frame: frame)
        case .fsBegin:
            try beginFileTransaction(frame: frame)
        case .fsChunk:
            try appendFileTransaction(frame: frame)
        case .fsEnd:
            try finishFileTransaction(frame: frame)
        case .fsReadBegin:
            try handleFsReadBegin(frame: frame)
        case .fsReadChunk:
            try handleFsReadChunk(frame: frame)
        case .fsReadEnd:
            try handleFsReadEnd(frame: frame)
        case .fsListDir:
            try handleFsListDir(frame: frame)
        case .stdout, .stderr, .exit, .error, .ready, .ack, .networkResult:
            break
        }
    }

    private func configureNetwork(frame: GuestAgentFrame) throws {
        guard let data = frame.data else {
            throw NSError(
                domain: "container.macos.guest-agent.network",
                code: Int(EINVAL),
                userInfo: [NSLocalizedDescriptionKey: "missing guest network configuration payload"]
            )
        }

        let request = try JSONDecoder().decode(MacOSGuestNetworkConfigurationRequest.self, from: data)
        do {
            let result = try GuestNetworkConfigurator().apply(request)
            try send(frame: .networkResult(result))
        } catch {
            let message = "failed to configure guest network: \(describeError(error))"
            logAgentError(message)
            try send(frame: .error(message))
        }
    }

    private func startProcess(frame: GuestAgentFrame) throws {
        session?.cleanup()

        guard let processID = frame.id, !processID.isEmpty else {
            throw NSError(
                domain: "container.macos.guest-agent.exec",
                code: Int(EINVAL),
                userInfo: [NSLocalizedDescriptionKey: "missing process identifier"]
            )
        }

        guard let executable = frame.executable else {
            throw NSError(
                domain: "container.macos.guest-agent.exec",
                code: Int(EINVAL),
                userInfo: [NSLocalizedDescriptionKey: "missing executable"]
            )
        }

        let terminal = frame.terminal == true
        let explicitIdentity = try GuestAgentExecIdentity.resolve(from: frame)
        let spawnedIdentity = explicitIdentity.flatMap { identity in
            identity.requiresSpawnedSession() ? identity : nil
        }
        let session = try SpawnedProcessSession.spawn(
            executable: executable,
            arguments: frame.arguments ?? [],
            environment: frame.environment ?? [],
            workingDirectory: frame.workingDirectory,
            terminal: terminal,
            identity: spawnedIdentity ?? .currentProcess(),
            connection: self
        )
        self.session = session
        try session.start(stdoutHandle: nil, stderrHandle: nil)
        try send(frame: .ack(id: processID))
    }

    private func beginFileTransaction(frame: GuestAgentFrame) throws {
        guard let txID = frame.id, !txID.isEmpty else {
            throw POSIXError(.EINVAL)
        }
        guard fileTransactions[txID] == nil else {
            throw POSIXError(.EEXIST)
        }
        guard let op = frame.op, let path = frame.path else {
            throw POSIXError(.EINVAL)
        }

        let request = MacOSSidecarFSBeginRequestPayload(
            txID: txID,
            op: op,
            path: path,
            digest: frame.digest,
            mode: frame.mode,
            uid: frame.uid,
            gid: frame.gid,
            mtime: frame.mtime,
            linkTarget: frame.linkTarget,
            overwrite: frame.overwrite ?? true,
            inlineData: frame.data,
            autoCommit: frame.autoCommit ?? false
        )
        logFileTransaction(
            "begin",
            request: request,
            extra: [
                "auto_commit": "\(request.autoCommit)",
                "inline_bytes": "\(request.inlineData?.count ?? 0)",
                "digest": request.digest ?? "-",
            ]
        )

        do {
            let transaction = try GuestAgentFileTransferTransaction(request: request)

            if request.autoCommit {
                try transaction.complete(action: .commit, digest: request.digest)
                logFileTransaction("auto-commit completed", request: request)
            } else {
                fileTransactions[txID] = transaction
                logFileTransaction("transaction opened", request: request)
            }
        } catch {
            throw filesystemError(txID: txID, op: op, path: path, stage: "begin", error: error)
        }

        try send(frame: .ack(id: txID))
    }

    private func appendFileTransaction(frame: GuestAgentFrame) throws {
        guard let txID = frame.id, let offset = frame.offset, let data = frame.data else {
            throw POSIXError(.EINVAL)
        }
        guard let transaction = fileTransactions[txID] else {
            throw POSIXError(.ENOENT)
        }

        logFileTransaction(
            "chunk",
            request: transaction.request,
            extra: [
                "offset": "\(offset)",
                "bytes": "\(data.count)",
            ]
        )
        do {
            try transaction.append(data: data, offset: offset)
        } catch {
            throw filesystemError(transaction.request, stage: "chunk", error: error)
        }
        try send(frame: .ack(id: txID))
    }

    private func finishFileTransaction(frame: GuestAgentFrame) throws {
        guard let txID = frame.id else {
            throw POSIXError(.EINVAL)
        }
        guard let transaction = fileTransactions.removeValue(forKey: txID) else {
            throw POSIXError(.ENOENT)
        }

        let action = frame.action ?? .commit
        logFileTransaction(
            "end",
            request: transaction.request,
            extra: [
                "action": action.rawValue,
                "digest": frame.digest ?? "-",
            ]
        )

        do {
            try transaction.complete(action: action, digest: frame.digest)
            logFileTransaction(
                "transaction completed",
                request: transaction.request,
                extra: ["action": action.rawValue]
            )
            try send(frame: .ack(id: txID))
        } catch {
            transaction.abort()
            throw filesystemError(transaction.request, stage: "end(\(action.rawValue))", error: error)
        }
    }

    private func handleFsReadBegin(frame: GuestAgentFrame) throws {
        guard let txID = frame.id, !txID.isEmpty else {
            throw POSIXError(.EINVAL)
        }
        guard let path = frame.path else {
            throw POSIXError(.EINVAL)
        }
        logAgentInfo("connection fd=\(fd): filesystem read begin tx_id=\(txID) path=\(path)")

        // stat the path to determine file type and metadata
        var st = stat()
        guard lstat(path, &st) == 0 else {
            let code = errno
            let message = "failed to stat path \(path): \(String(cString: strerror(code)))"
            logAgentError(message)
            try send(frame: .error(message))
            return
        }

        let fileType: MacOSSidecarFSFileType
        let fileMode = st.st_mode
        if fileMode & UInt16(S_IFMT) == UInt16(S_IFLNK) {
            fileType = .symlink
        } else if fileMode & UInt16(S_IFMT) == UInt16(S_IFDIR) {
            fileType = .directory
        } else {
            fileType = .file
        }

        var linkTarget: String? = nil
        if fileType == .symlink {
            linkTarget = readSymbolicLinkTarget(atPath: path)
        }

        let size: UInt64? = fileType == .file ? UInt64(st.st_size) : nil
        let mode = UInt32(fileMode & ~UInt16(S_IFMT))
        let mtime = Int64(st.st_mtimespec.tv_sec)

        let meta = MacOSSidecarFSReadBeginResponsePayload(
            fileType: fileType,
            size: size,
            mode: mode,
            uid: UInt32(st.st_uid),
            gid: UInt32(st.st_gid),
            mtime: mtime,
            linkTarget: linkTarget
        )

        if fileType == .file {
            // Open the file and store handle for subsequent chunk reads
            guard let handle = FileHandle(forReadingAtPath: path) else {
                let message = "failed to open file for reading: \(path)"
                logAgentError(message)
                try send(frame: .error(message))
                return
            }
            fileReadTransactions[txID] = handle
        }

        let responseData = try JSONEncoder().encode(meta)
        try send(frame: .ack(id: txID, data: responseData))
        logAgentInfo("connection fd=\(fd): filesystem read begin ack sent tx_id=\(txID) file_type=\(fileType.rawValue)")
    }

    private func handleFsReadChunk(frame: GuestAgentFrame) throws {
        guard let txID = frame.id, !txID.isEmpty else {
            throw POSIXError(.EINVAL)
        }
        guard let offset = frame.offset else {
            throw POSIXError(.EINVAL)
        }
        let maxLength = frame.maxLength ?? (256 * 1024)

        guard let handle = fileReadTransactions[txID] else {
            let message = "filesystem read chunk: no open transaction for tx_id=\(txID)"
            logAgentError(message)
            try send(frame: .error(message))
            return
        }

        logAgentInfo("connection fd=\(fd): filesystem read chunk tx_id=\(txID) offset=\(offset) max_length=\(maxLength)")

        do {
            try handle.seek(toOffset: offset)
            guard let data = try handle.read(upToCount: maxLength), !data.isEmpty else {
                try send(frame: .ack(id: txID))
                return
            }
            try send(frame: .ack(id: txID, data: data))
        } catch {
            let message = "filesystem read chunk failed tx_id=\(txID): \(describeError(error))"
            logAgentError(message)
            try? handle.close()
            fileReadTransactions.removeValue(forKey: txID)
            try send(frame: .error(message))
        }
    }

    private func handleFsReadEnd(frame: GuestAgentFrame) throws {
        guard let txID = frame.id, !txID.isEmpty else {
            throw POSIXError(.EINVAL)
        }
        logAgentInfo("connection fd=\(fd): filesystem read end tx_id=\(txID)")

        if let handle = fileReadTransactions.removeValue(forKey: txID) {
            try? handle.close()
        }
        try send(frame: .ack(id: txID))
    }

    private func handleFsListDir(frame: GuestAgentFrame) throws {
        guard let txID = frame.id, !txID.isEmpty else {
            throw POSIXError(.EINVAL)
        }
        guard let path = frame.path else {
            throw POSIXError(.EINVAL)
        }
        logAgentInfo("connection fd=\(fd): filesystem listdir tx_id=\(txID) path=\(path)")

        do {
            let names = try FileManager.default.contentsOfDirectory(atPath: path)
            var entries: [MacOSSidecarFSListDirEntry] = []
            for name in names {
                let childPath = (path as NSString).appendingPathComponent(name)
                var st = stat()
                guard lstat(childPath, &st) == 0 else {
                    continue
                }
                let fileMode = st.st_mode
                let entryType: MacOSSidecarFSFileType
                if fileMode & UInt16(S_IFMT) == UInt16(S_IFLNK) {
                    entryType = .symlink
                } else if fileMode & UInt16(S_IFMT) == UInt16(S_IFDIR) {
                    entryType = .directory
                } else {
                    entryType = .file
                }

                var linkTarget: String? = nil
                if entryType == .symlink {
                    linkTarget = readSymbolicLinkTarget(atPath: childPath)
                }

                let size: UInt64? = entryType == .file ? UInt64(st.st_size) : nil
                let mode = UInt32(fileMode & ~UInt16(S_IFMT))
                let mtime = Int64(st.st_mtimespec.tv_sec)

                entries.append(
                    MacOSSidecarFSListDirEntry(
                        name: name,
                        fileType: entryType,
                        size: size,
                        mode: mode,
                        uid: UInt32(st.st_uid),
                        gid: UInt32(st.st_gid),
                        mtime: mtime,
                        linkTarget: linkTarget
                    ))
            }
            let responseData = try JSONEncoder().encode(entries)
            try send(frame: .ack(id: txID, data: responseData))
            logAgentInfo("connection fd=\(fd): filesystem listdir ack sent tx_id=\(txID) count=\(entries.count)")
        } catch {
            let message = "filesystem listdir failed tx_id=\(txID) path=\(path): \(describeError(error))"
            logAgentError(message)
            try send(frame: .error(message))
        }
    }

    fileprivate func send(frame: GuestAgentFrame) throws {
        let payload = try JSONEncoder().encode(frame)
        var length = UInt32(payload.count).bigEndian
        let header = Data(bytes: &length, count: MemoryLayout<UInt32>.size)

        lock.lock()
        defer { lock.unlock() }
        try writeAllToSocket(header)
        try writeAllToSocket(payload)
    }

    private func readSocketChunk(into storage: inout [UInt8]) throws -> Data? {
        while true {
            let bytesRead = storage.withUnsafeMutableBytes { rawBuffer -> Int in
                guard let baseAddress = rawBuffer.baseAddress else { return 0 }
                return Darwin.read(fd, baseAddress, rawBuffer.count)
            }

            if bytesRead > 0 {
                return Data(storage.prefix(bytesRead))
            }
            if bytesRead == 0 {
                return nil
            }

            let code = errno
            if code == EINTR {
                continue
            }
            if code == EAGAIN || code == EWOULDBLOCK {
                usleep(10_000)
                continue
            }
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(code),
                userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(code))]
            )
        }
    }

    private func writeAllToSocket(_ data: Data) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var totalWritten = 0
            while totalWritten < rawBuffer.count {
                let pointer = baseAddress.advanced(by: totalWritten)
                let remaining = rawBuffer.count - totalWritten
                let written = Darwin.write(fd, pointer, remaining)
                if written > 0 {
                    totalWritten += written
                    continue
                }
                if written == 0 {
                    throw NSError(
                        domain: NSPOSIXErrorDomain,
                        code: Int(EPIPE),
                        userInfo: [NSLocalizedDescriptionKey: "write returned 0 bytes"]
                    )
                }

                let code = errno
                if code == EINTR {
                    continue
                }
                if code == EAGAIN || code == EWOULDBLOCK {
                    usleep(10_000)
                    continue
                }
                throw NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(code),
                    userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(code))]
                )
            }
        }
    }

    private func logFileTransaction(
        _ message: String,
        request: MacOSSidecarFSBeginRequestPayload,
        extra: [String: String] = [:]
    ) {
        var segments = [
            "connection fd=\(fd): filesystem \(message)",
            "tx_id=\(request.txID)",
            "op=\(request.op.rawValue)",
            "path=\(request.path)",
        ]
        for key in extra.keys.sorted() {
            segments.append("\(key)=\(extra[key] ?? "")")
        }
        logAgentInfo(segments.joined(separator: " "))
    }

    private func filesystemError(
        _ request: MacOSSidecarFSBeginRequestPayload,
        stage: String,
        error: Error
    ) -> NSError {
        filesystemError(txID: request.txID, op: request.op, path: request.path, stage: stage, error: error)
    }

    private func filesystemError(
        txID: String,
        op: MacOSSidecarFSOperation,
        path: String,
        stage: String,
        error: Error
    ) -> NSError {
        let nsError = error as NSError
        let message =
            "filesystem transaction tx_id=\(txID) op=\(op.rawValue) path=\(path) stage=\(stage) failed: \(describeError(error))"
        return NSError(
            domain: "container.macos.guest-agent.fs",
            code: nsError.code,
            userInfo: [
                NSLocalizedDescriptionKey: message,
                NSUnderlyingErrorKey: nsError,
            ]
        )
    }
}

private protocol GuestAgentProcessSession: AnyObject {
    func start(stdoutHandle: FileHandle?, stderrHandle: FileHandle?) throws
    func writeStdin(_ data: Data) throws
    func closeStdin()
    func sendSignal(_ signal: Int32) throws
    func resize(width: UInt16, height: UInt16) throws
    func cleanup()
}

struct GuestAgentExecIdentity {
    let uid: uid_t
    let gid: gid_t
    let supplementalGroups: [gid_t]

    static func currentProcess() -> Self {
        .init(uid: geteuid(), gid: getegid(), supplementalGroups: [])
    }

    func requiresSpawnedSession(relativeTo currentIdentity: Self = .currentProcess()) -> Bool {
        uid != currentIdentity.uid || gid != currentIdentity.gid || !supplementalGroups.isEmpty
    }

    static func resolve(from frame: GuestAgentFrame) throws -> Self? {
        let supplementalGroups = frame.supplementalGroups ?? []
        if let user = frame.user, !user.isEmpty {
            return try resolve(rawUser: user, additionalGroups: supplementalGroups)
        }
        if let uid = frame.uid, let gid = frame.gid {
            return .init(uid: uid_t(uid), gid: gid_t(gid), supplementalGroups: supplementalGroups.map { gid_t($0) })
        }
        if frame.uid == nil, frame.gid == nil, supplementalGroups.isEmpty {
            return nil
        }
        throw NSError(
            domain: "container.macos.guest-agent.exec",
            code: Int(EINVAL),
            userInfo: [NSLocalizedDescriptionKey: "incomplete exec user identity"]
        )
    }

    private static func resolve(rawUser: String, additionalGroups: [UInt32]) throws -> Self {
        let parts = rawUser.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard let rawUserToken = parts.first, !rawUserToken.isEmpty else {
            throw NSError(
                domain: "container.macos.guest-agent.exec",
                code: Int(EINVAL),
                userInfo: [NSLocalizedDescriptionKey: "USER may not be empty"]
            )
        }

        let resolvedUser = try resolveUser(token: rawUserToken)
        let gid = try parts.count == 2 ? resolveGroup(token: parts[1]) : resolvedUser.defaultGID
        let groups = try resolveSupplementalGroups(
            userName: resolvedUser.userName,
            primaryGID: gid,
            additionalGroups: additionalGroups
        )
        return .init(uid: resolvedUser.uid, gid: gid, supplementalGroups: groups)
    }

    private static func resolveUser(token: String) throws -> (uid: uid_t, defaultGID: gid_t, userName: String?) {
        if let uid = UInt32(token) {
            if let pw = getpwuid(uid_t(uid)) {
                let userName = String(cString: pw.pointee.pw_name)
                return (pw.pointee.pw_uid, pw.pointee.pw_gid, userName)
            }
            return (uid_t(uid), gid_t(uid), nil)
        }
        guard let pw = getpwnam(token) else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(ENOENT),
                userInfo: [NSLocalizedDescriptionKey: "user \(token) not found"]
            )
        }
        let userName = String(cString: pw.pointee.pw_name)
        return (pw.pointee.pw_uid, pw.pointee.pw_gid, userName)
    }

    private static func resolveGroup(token: String) throws -> gid_t {
        guard !token.isEmpty else {
            throw NSError(
                domain: "container.macos.guest-agent.exec",
                code: Int(EINVAL),
                userInfo: [NSLocalizedDescriptionKey: "group may not be empty"]
            )
        }
        if let gid = UInt32(token) {
            return gid_t(gid)
        }
        guard let group = getgrnam(token) else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(ENOENT),
                userInfo: [NSLocalizedDescriptionKey: "group \(token) not found"]
            )
        }
        return group.pointee.gr_gid
    }

    private static func resolveSupplementalGroups(
        userName: String?,
        primaryGID: gid_t,
        additionalGroups: [UInt32]
    ) throws -> [gid_t] {
        _ = userName

        // The primary group is applied via `setgid`. Carrying auto-resolved
        // group memberships through `setgroups` currently breaks special guest
        // accounts such as `nobody`, so only explicit supplemental groups are
        // forwarded for now.
        let groups = Set<gid_t>(additionalGroups.map { gid_t($0) })
        return Array(groups.filter { $0 != primaryGID }).sorted()
    }
}

private final class SpawnedProcessSession: GuestAgentProcessSession, @unchecked Sendable {
    private let pid: pid_t
    private let terminal: Bool
    private unowned let connection: AgentConnection
    private let masterHandle: FileHandle?
    private let stdinHandle: FileHandle?
    private let stdoutHandle: FileHandle?
    private let stderrHandle: FileHandle?
    private let outputLock = NSLock()
    private var exitSent = false

    private init(
        pid: pid_t,
        terminal: Bool,
        connection: AgentConnection,
        masterHandle: FileHandle?,
        stdinHandle: FileHandle?,
        stdoutHandle: FileHandle?,
        stderrHandle: FileHandle?
    ) {
        self.pid = pid
        self.terminal = terminal
        self.connection = connection
        self.masterHandle = masterHandle
        self.stdinHandle = stdinHandle
        self.stdoutHandle = stdoutHandle
        self.stderrHandle = stderrHandle
    }

    static func spawn(
        executable: String,
        arguments: [String],
        environment: [String],
        workingDirectory: String?,
        terminal: Bool,
        identity: GuestAgentExecIdentity,
        connection: AgentConnection
    ) throws -> SpawnedProcessSession {
        let preparedExec = PreparedCStringArray([executable] + arguments)
        let preparedEnv = PreparedCStringArray(environment)
        let preparedWorkingDirectory = workingDirectory.map(PreparedCString.init)

        let execStatus = try makePipe()
        try setCloseOnExec(execStatus.writeEnd)

        var stdinPipe: RawPipe?
        var stdoutPipe: RawPipe?
        var stderrPipe: RawPipe?
        var masterFD: Int32 = -1
        var slaveFD: Int32 = -1

        if terminal {
            guard openpty(&masterFD, &slaveFD, nil, nil, nil) == 0 else {
                throw POSIXError.fromErrno()
            }
        } else {
            stdinPipe = try makePipe()
            stdoutPipe = try makePipe()
            stderrPipe = try makePipe()
        }

        let pid = sysFork()
        guard pid >= 0 else {
            closeIfValid(execStatus.readEnd)
            closeIfValid(execStatus.writeEnd)
            closeIfValid(masterFD)
            closeIfValid(slaveFD)
            closePipe(stdinPipe)
            closePipe(stdoutPipe)
            closePipe(stderrPipe)
            throw POSIXError.fromErrno()
        }

        if pid == 0 {
            closeIfValid(execStatus.readEnd)
            if terminal {
                closeIfValid(masterFD)
                runChild(
                    execStatusFD: execStatus.writeEnd,
                    executable: preparedExec.pointer.pointee,
                    arguments: preparedExec.pointer,
                    environment: preparedEnv.pointer,
                    workingDirectory: preparedWorkingDirectory?.pointer,
                    identity: identity,
                    stdinFD: slaveFD,
                    stdoutFD: slaveFD,
                    stderrFD: slaveFD,
                    terminal: true
                )
            } else {
                closeIfValid(stdinPipe?.writeEnd)
                closeIfValid(stdoutPipe?.readEnd)
                closeIfValid(stderrPipe?.readEnd)
                runChild(
                    execStatusFD: execStatus.writeEnd,
                    executable: preparedExec.pointer.pointee,
                    arguments: preparedExec.pointer,
                    environment: preparedEnv.pointer,
                    workingDirectory: preparedWorkingDirectory?.pointer,
                    identity: identity,
                    stdinFD: stdinPipe?.readEnd ?? -1,
                    stdoutFD: stdoutPipe?.writeEnd ?? -1,
                    stderrFD: stderrPipe?.writeEnd ?? -1,
                    terminal: false
                )
            }
        }

        closeIfValid(execStatus.writeEnd)
        closeIfValid(slaveFD)
        closeIfValid(stdinPipe?.readEnd)
        closeIfValid(stdoutPipe?.writeEnd)
        closeIfValid(stderrPipe?.writeEnd)

        if let errorCode = try readExecStatus(execStatus.readEnd) {
            closeIfValid(masterFD)
            closeIfValid(stdinPipe?.writeEnd)
            closeIfValid(stdoutPipe?.readEnd)
            closeIfValid(stderrPipe?.readEnd)
            var status: Int32 = 0
            _ = waitpid(pid, &status, 0)
            throw POSIXError(POSIXErrorCode(rawValue: errorCode) ?? .EIO)
        }

        return .init(
            pid: pid,
            terminal: terminal,
            connection: connection,
            masterHandle: terminal ? FileHandle(fileDescriptor: masterFD, closeOnDealloc: true) : nil,
            stdinHandle: terminal ? nil : FileHandle(fileDescriptor: stdinPipe?.writeEnd ?? -1, closeOnDealloc: true),
            stdoutHandle: terminal ? nil : FileHandle(fileDescriptor: stdoutPipe?.readEnd ?? -1, closeOnDealloc: true),
            stderrHandle: terminal ? nil : FileHandle(fileDescriptor: stderrPipe?.readEnd ?? -1, closeOnDealloc: true)
        )
    }

    func start(stdoutHandle: FileHandle?, stderrHandle: FileHandle?) throws {
        _ = stdoutHandle
        _ = stderrHandle

        if let masterHandle {
            masterHandle.readabilityHandler = { [weak self] handle in
                self?.forwardAvailableData(from: handle, channel: .stdout)
            }
        } else {
            self.stdoutHandle?.readabilityHandler = { [weak self] handle in
                self?.forwardAvailableData(from: handle, channel: .stdout)
            }
            self.stderrHandle?.readabilityHandler = { [weak self] handle in
                self?.forwardAvailableData(from: handle, channel: .stderr)
            }
        }

        Thread.detachNewThread { [weak self] in
            self?.waitForExit()
        }
    }

    func writeStdin(_ data: Data) throws {
        if terminal {
            guard let masterHandle else { return }
            try masterHandle.write(contentsOf: data)
        } else {
            try stdinHandle?.write(contentsOf: data)
        }
    }

    func closeStdin() {
        if terminal {
            sendTerminalEOF(masterHandle)
            return
        }
        try? stdinHandle?.close()
    }

    func sendSignal(_ signal: Int32) throws {
        try sendSignalToProcessTree(pid: pid, signal: signal)
    }

    func resize(width: UInt16, height: UInt16) throws {
        guard terminal, let masterHandle else { return }
        var ws = winsize(ws_row: height, ws_col: width, ws_xpixel: 0, ws_ypixel: 0)
        guard ioctl(masterHandle.fileDescriptor, TIOCSWINSZ, &ws) == 0 else {
            throw POSIXError.fromErrno()
        }
    }

    func cleanup() {
        stdoutHandle?.readabilityHandler = nil
        stderrHandle?.readabilityHandler = nil
        masterHandle?.readabilityHandler = nil
        try? sendSignalToProcessTree(pid: pid, signal: SIGKILL)
        try? masterHandle?.close()
        try? stdinHandle?.close()
        try? stdoutHandle?.close()
        try? stderrHandle?.close()
    }

    private enum OutputChannel {
        case stdout
        case stderr
    }

    private func waitForExit() {
        var status: Int32 = 0
        let result = waitpid(pid, &status, 0)
        let exitCode: Int32
        if result == pid {
            if wifexited(status) {
                exitCode = wexitstatus(status)
            } else if wifsignaled(status) {
                exitCode = 128 + wtermsig(status)
            } else {
                exitCode = 1
            }
        } else {
            exitCode = 1
        }
        flushOutputAndSendExit(exitCode)
    }

    private func forwardAvailableData(from handle: FileHandle, channel: OutputChannel) {
        outputLock.lock()
        defer { outputLock.unlock() }

        guard !exitSent else {
            handle.readabilityHandler = nil
            return
        }

        let data = handle.availableData
        if data.isEmpty {
            handle.readabilityHandler = nil
            return
        }

        send(data, channel: channel)
    }

    private func flushOutputAndSendExit(_ status: Int32) {
        outputLock.lock()
        defer { outputLock.unlock() }

        guard !exitSent else {
            return
        }

        drainRemainingOutput(from: masterHandle, channel: .stdout)
        drainRemainingOutput(from: stdoutHandle, channel: .stdout)
        drainRemainingOutput(from: stderrHandle, channel: .stderr)

        exitSent = true
        try? connection.send(frame: .exit(status))
    }

    private func drainRemainingOutput(from handle: FileHandle?, channel: OutputChannel) {
        guard let handle else { return }

        while true {
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            send(data, channel: channel)
        }
    }

    private func send(_ data: Data, channel: OutputChannel) {
        switch channel {
        case .stdout:
            try? connection.send(frame: .stdout(data))
        case .stderr:
            try? connection.send(frame: .stderr(data))
        }
    }
}

private struct RawPipe {
    let readEnd: Int32
    let writeEnd: Int32
}

@_silgen_name("fork")
private func sysFork() -> pid_t

private final class PreparedCString {
    let pointer: UnsafeMutablePointer<CChar>

    init(_ value: String) {
        guard let pointer = strdup(value) else {
            fatalError("failed to allocate C string")
        }
        self.pointer = pointer
    }

    deinit {
        free(pointer)
    }
}

private final class PreparedCStringArray {
    let pointer: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
    private let count: Int

    init(_ values: [String]) {
        let storage = values.map { value -> UnsafeMutablePointer<CChar>? in
            guard let pointer = strdup(value) else {
                fatalError("failed to allocate C string")
            }
            return pointer
        }
        self.count = storage.count + 1
        self.pointer = .allocate(capacity: count)
        for (index, value) in storage.enumerated() {
            pointer.advanced(by: index).initialize(to: value)
        }
        pointer.advanced(by: storage.count).initialize(to: nil)
    }

    deinit {
        for index in 0..<(count - 1) {
            free(pointer.advanced(by: index).pointee)
            pointer.advanced(by: index).deinitialize(count: 1)
        }
        pointer.advanced(by: count - 1).deinitialize(count: 1)
        pointer.deallocate()
    }
}

private func makePipe() throws -> RawPipe {
    var fds = [Int32](repeating: -1, count: 2)
    guard pipe(&fds) == 0 else {
        throw POSIXError.fromErrno()
    }
    return .init(readEnd: fds[0], writeEnd: fds[1])
}

private func closePipe(_ pipe: RawPipe?) {
    closeIfValid(pipe?.readEnd)
    closeIfValid(pipe?.writeEnd)
}

private func closeIfValid(_ fd: Int32?) {
    guard let fd, fd >= 0 else { return }
    _ = Darwin.close(fd)
}

private func setCloseOnExec(_ fd: Int32) throws {
    let flags = fcntl(fd, F_GETFD)
    guard flags != -1 else {
        throw POSIXError.fromErrno()
    }
    guard fcntl(fd, F_SETFD, flags | FD_CLOEXEC) == 0 else {
        throw POSIXError.fromErrno()
    }
}

private func readExecStatus(_ fd: Int32) throws -> Int32? {
    defer { closeIfValid(fd) }
    var code: Int32 = 0
    let bytes = withUnsafeMutablePointer(to: &code) {
        Darwin.read(fd, $0, MemoryLayout<Int32>.size)
    }
    if bytes == 0 {
        return nil
    }
    guard bytes == MemoryLayout<Int32>.size else {
        throw POSIXError(.EIO)
    }
    return code
}

private func wifexited(_ status: Int32) -> Bool {
    (status & 0x7f) == 0
}

private func wexitstatus(_ status: Int32) -> Int32 {
    (status >> 8) & 0xff
}

private func wifsignaled(_ status: Int32) -> Bool {
    let signal = status & 0x7f
    return signal != 0 && signal != 0x7f
}

private func wtermsig(_ status: Int32) -> Int32 {
    status & 0x7f
}

private func runChild(
    execStatusFD: Int32,
    executable: UnsafeMutablePointer<CChar>?,
    arguments: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>,
    environment: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>,
    workingDirectory: UnsafeMutablePointer<CChar>?,
    identity: GuestAgentExecIdentity,
    stdinFD: Int32,
    stdoutFD: Int32,
    stderrFD: Int32,
    terminal: Bool
) -> Never {
    func fail(_ code: Int32) -> Never {
        var errorCode = code
        _ = withUnsafePointer(to: &errorCode) {
            Darwin.write(execStatusFD, $0, MemoryLayout<Int32>.size)
        }
        _exit(127)
    }

    if setsid() == -1 {
        fail(Int32(errno))
    }

    if terminal {
        _ = ioctl(stdinFD, TIOCSCTTY, 0)
    }

    if dup2(stdinFD, STDIN_FILENO) == -1 {
        fail(Int32(errno))
    }
    if dup2(stdoutFD, STDOUT_FILENO) == -1 {
        fail(Int32(errno))
    }
    if dup2(stderrFD, STDERR_FILENO) == -1 {
        fail(Int32(errno))
    }

    if stdinFD > STDERR_FILENO {
        _ = Darwin.close(stdinFD)
    }
    if stdoutFD > STDERR_FILENO, stdoutFD != stdinFD {
        _ = Darwin.close(stdoutFD)
    }
    if stderrFD > STDERR_FILENO, stderrFD != stdinFD, stderrFD != stdoutFD {
        _ = Darwin.close(stderrFD)
    }

    let currentUID = geteuid()
    let currentGID = getegid()

    if !identity.supplementalGroups.isEmpty {
        var groups = identity.supplementalGroups
        let result = groups.withUnsafeMutableBufferPointer { buffer in
            setgroups(Int32(buffer.count), buffer.baseAddress)
        }
        if result != 0 {
            fail(Int32(errno))
        }
    }
    if identity.gid != currentGID, setgid(identity.gid) != 0 {
        fail(Int32(errno))
    }
    if identity.uid != currentUID, setuid(identity.uid) != 0 {
        fail(Int32(errno))
    }

    if let workingDirectory, chdir(workingDirectory) != 0 {
        fail(Int32(errno))
    }
    guard let executable else {
        fail(Int32(EINVAL))
    }
    execve(executable, arguments, environment)
    fail(Int32(errno))
}

private func sendSignalToProcessTree(pid: pid_t, signal: Int32) throws {
    if Darwin.kill(-pid, signal) == 0 {
        return
    }
    let processGroupErrno = errno
    if processGroupErrno == ESRCH {
        guard Darwin.kill(pid, 0) == 0 else {
            return
        }
        guard Darwin.kill(pid, signal) == 0 else {
            throw POSIXError.fromErrno()
        }
        return
    }
    throw POSIXError(POSIXErrorCode(rawValue: processGroupErrno) ?? .EIO)
}

struct GuestAgentFrame: Codable {
    enum FrameType: String, Codable {
        case exec
        case stdin
        case signal
        case resize
        case close
        case networkConfigure
        case networkResult
        case fsBegin
        case fsChunk
        case fsEnd
        case fsReadBegin
        case fsReadChunk
        case fsReadEnd
        case fsListDir
        case ack
        case stdout
        case stderr
        case exit
        case error
        case ready
    }

    let type: FrameType
    let id: String?
    let executable: String?
    let arguments: [String]?
    let environment: [String]?
    let rootDirectory: String?
    let workingDirectory: String?
    let terminal: Bool?
    let user: String?
    let signal: Int32?
    let width: UInt16?
    let height: UInt16?
    let data: Data?
    let exitCode: Int32?
    let message: String?
    let op: MacOSSidecarFSOperation?
    let path: String?
    let mode: UInt32?
    let uid: UInt32?
    let gid: UInt32?
    let supplementalGroups: [UInt32]?
    let mtime: Int64?
    let linkTarget: String?
    let overwrite: Bool?
    let autoCommit: Bool?
    let offset: UInt64?
    let action: MacOSSidecarFSEndAction?
    let digest: String?
    let maxLength: Int?

    init(
        type: FrameType,
        id: String? = nil,
        executable: String? = nil,
        arguments: [String]? = nil,
        environment: [String]? = nil,
        rootDirectory: String? = nil,
        workingDirectory: String? = nil,
        terminal: Bool? = nil,
        user: String? = nil,
        signal: Int32? = nil,
        width: UInt16? = nil,
        height: UInt16? = nil,
        data: Data? = nil,
        exitCode: Int32? = nil,
        message: String? = nil,
        op: MacOSSidecarFSOperation? = nil,
        path: String? = nil,
        mode: UInt32? = nil,
        uid: UInt32? = nil,
        gid: UInt32? = nil,
        supplementalGroups: [UInt32]? = nil,
        mtime: Int64? = nil,
        linkTarget: String? = nil,
        overwrite: Bool? = nil,
        autoCommit: Bool? = nil,
        offset: UInt64? = nil,
        action: MacOSSidecarFSEndAction? = nil,
        digest: String? = nil,
        maxLength: Int? = nil
    ) {
        self.type = type
        self.id = id
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.rootDirectory = rootDirectory
        self.workingDirectory = workingDirectory
        self.terminal = terminal
        self.user = user
        self.signal = signal
        self.width = width
        self.height = height
        self.data = data
        self.exitCode = exitCode
        self.message = message
        self.op = op
        self.path = path
        self.mode = mode
        self.uid = uid
        self.gid = gid
        self.supplementalGroups = supplementalGroups
        self.mtime = mtime
        self.linkTarget = linkTarget
        self.overwrite = overwrite
        self.autoCommit = autoCommit
        self.offset = offset
        self.action = action
        self.digest = digest
        self.maxLength = maxLength
    }

    static let ready = GuestAgentFrame(
        type: .ready
    )

    static func stdout(_ data: Data) -> Self {
        .init(type: .stdout, data: data)
    }

    static func stderr(_ data: Data) -> Self {
        .init(type: .stderr, data: data)
    }

    static func exit(_ code: Int32) -> Self {
        .init(type: .exit, exitCode: code)
    }

    static func error(_ message: String) -> Self {
        .init(type: .error, message: message)
    }

    static func ack(id: String, data: Data? = nil) -> Self {
        .init(type: .ack, id: id, data: data)
    }

    static func networkResult(_ payload: MacOSGuestNetworkConfigurationResult) throws -> Self {
        .init(type: .networkResult, data: try JSONEncoder().encode(payload))
    }
}

private func sendTerminalEOF(_ masterHandle: FileHandle?) {
    guard let masterHandle else {
        return
    }

    // PTY stdin/stdout/stderr share the same master FD. Inject the terminal EOF
    // control character so host-side stdin close does not tear down output.
    try? masterHandle.write(contentsOf: Data([0x04]))
}

private func configureGuestAgentSignals() {
    signal(SIGPIPE, SIG_IGN)
}

private func describeError(_ error: Error) -> String {
    let nsError = error as NSError
    return "\(nsError.domain) Code=\(nsError.code) \"\(nsError.localizedDescription)\""
}

private func readSymbolicLinkTarget(atPath path: String) -> String? {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    let length = readlink(path, &buffer, buffer.count)
    guard length >= 0 else {
        return nil
    }
    return buffer.withUnsafeBytes { rawBuffer in
        String(decoding: rawBuffer.prefix(Int(length)), as: UTF8.self)
    }
}

private func logAgentStartupContext() {
    let uid = getuid()
    let euid = geteuid()
    let gid = getgid()
    let egid = getegid()
    let pid = getpid()
    let ppid = getppid()
    let stdinTTY = isatty(STDIN_FILENO) == 1
    let stdoutTTY = isatty(STDOUT_FILENO) == 1
    let stderrTTY = isatty(STDERR_FILENO) == 1
    let cwd = FileManager.default.currentDirectoryPath
    let launchLabel = ProcessInfo.processInfo.environment["LAUNCH_JOB_LABEL"] ?? "<nil>"
    let xpcService = ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] ?? "<nil>"
    let home = ProcessInfo.processInfo.environment["HOME"] ?? "<nil>"
    let path = ProcessInfo.processInfo.environment["PATH"] ?? "<nil>"
    let tmpdir = ProcessInfo.processInfo.environment["TMPDIR"] ?? "<nil>"
    let consoleOwner = currentConsoleOwner()

    logAgentInfo(
        """
        startup context pid=\(pid) ppid=\(ppid) uid=\(uid)/\(euid) gid=\(gid)/\(egid) \
        tty(stdin/stdout/stderr)=\(stdinTTY)/\(stdoutTTY)/\(stderrTTY) cwd=\(cwd)
        """
    )
    logAgentInfo("startup env LAUNCH_JOB_LABEL=\(launchLabel) XPC_SERVICE_NAME=\(xpcService) HOME=\(home) TMPDIR=\(tmpdir)")
    logAgentInfo("startup env PATH=\(path)")
    logAgentInfo("startup console owner=\(consoleOwner)")
}

private func currentConsoleOwner() -> String {
    var st = stat()
    if stat("/dev/console", &st) != 0 {
        let code = errno
        return "unavailable (\(code): \(String(cString: strerror(code))))"
    }
    let uid = st.st_uid
    let gid = st.st_gid
    if let pw = getpwuid(uid), let name = pw.pointee.pw_name {
        let user = String(cString: name)
        return "\(user) uid=\(uid) gid=\(gid)"
    }
    return "uid=\(uid) gid=\(gid)"
}

private func logAgentError(_ message: String) {
    fputs("container-macos-guest-agent: \(message)\n", stderr)
    fflush(stderr)
}

private func logAgentInfo(_ message: String) {
    fputs("container-macos-guest-agent: \(message)\n", stderr)
    fflush(stderr)
}

extension POSIXError {
    static func fromErrno() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
