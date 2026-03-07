import CryptoKit
import Darwin
import Foundation
import RuntimeMacOSSidecarShared

final class GuestAgentFileTransferTransaction {
    let request: MacOSSidecarFSBeginRequestPayload
    let finalURL: URL

    private var tempURL: URL?
    private var fileHandle: FileHandle?
    private var completed = false

    init(request: MacOSSidecarFSBeginRequestPayload) throws {
        let normalizedPath = URL(fileURLWithPath: request.path).standardizedFileURL
        guard !normalizedPath.path.isEmpty else {
            throw POSIXError(.EINVAL)
        }

        self.request = request
        self.finalURL = normalizedPath

        switch request.op {
        case .writeFile:
            let parent = normalizedPath.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

            if !request.overwrite, FileManager.default.fileExists(atPath: normalizedPath.path) {
                throw POSIXError(.EEXIST)
            }

            let candidate = parent.appendingPathComponent(".container-fs-\(request.txID)-\(UUID().uuidString).tmp")
            guard FileManager.default.createFile(atPath: candidate.path, contents: nil) else {
                throw POSIXError(.EIO)
            }

            tempURL = candidate
            let handle = try FileHandle(forWritingTo: candidate)
            fileHandle = handle

            if let inlineData = request.inlineData, !inlineData.isEmpty {
                try handle.write(contentsOf: inlineData)
            }
        case .mkdir, .symlink:
            guard request.inlineData == nil else {
                throw POSIXError(.EINVAL)
            }
        }
    }

    deinit {
        if !completed {
            abort()
        }
    }

    func append(data: Data, offset: UInt64) throws {
        guard request.op == .writeFile else {
            throw POSIXError(.EINVAL)
        }
        guard let fileHandle else {
            throw POSIXError(.EBADF)
        }
        try fileHandle.seek(toOffset: offset)
        try fileHandle.write(contentsOf: data)
    }

    func complete(action: MacOSSidecarFSEndAction, digest: String?) throws {
        switch action {
        case .abort:
            abort()
        case .commit:
            switch request.op {
            case .writeFile:
                try commitWriteFile(expectedDigest: digest)
            case .mkdir:
                try commitDirectory()
            case .symlink:
                try commitSymlink()
            }
            completed = true
        }
    }

    func abort() {
        try? fileHandle?.close()
        fileHandle = nil

        if let tempURL {
            try? FileManager.default.removeItem(at: tempURL)
        }
        tempURL = nil
        completed = true
    }

    private func commitWriteFile(expectedDigest: String?) throws {
        guard let tempURL else {
            throw POSIXError(.ENOENT)
        }

        try fileHandle?.close()
        fileHandle = nil

        if let expectedDigest {
            let actualDigest = try sha256(of: tempURL)
            guard normalizedDigest(expectedDigest) == actualDigest else {
                throw POSIXError(.EBADMSG)
            }
        }

        if !request.overwrite, FileManager.default.fileExists(atPath: finalURL.path) {
            throw POSIXError(.EEXIST)
        }

        var isDirectory = ObjCBool(false)
        if FileManager.default.fileExists(atPath: finalURL.path, isDirectory: &isDirectory), isDirectory.boolValue {
            throw POSIXError(.EISDIR)
        }

        guard Darwin.rename(tempURL.path, finalURL.path) == 0 else {
            throw POSIXError.fromErrno()
        }

        self.tempURL = nil
        try applyMetadata(at: finalURL.path, followSymlink: true)
    }

    private func commitDirectory() throws {
        var isDirectory = ObjCBool(false)
        if FileManager.default.fileExists(atPath: finalURL.path, isDirectory: &isDirectory) {
            if isDirectory.boolValue {
                try applyMetadata(at: finalURL.path, followSymlink: true)
                return
            }
            guard request.overwrite else {
                throw POSIXError(.EEXIST)
            }
            try FileManager.default.removeItem(at: finalURL)
        }

        try FileManager.default.createDirectory(at: finalURL, withIntermediateDirectories: true)
        try applyMetadata(at: finalURL.path, followSymlink: true)
    }

    private func commitSymlink() throws {
        guard let linkTarget = request.linkTarget, !linkTarget.isEmpty else {
            throw POSIXError(.EINVAL)
        }

        let parent = finalURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        if FileManager.default.fileExists(atPath: finalURL.path) {
            guard request.overwrite else {
                throw POSIXError(.EEXIST)
            }
            try FileManager.default.removeItem(at: finalURL)
        }

        try FileManager.default.createSymbolicLink(atPath: finalURL.path, withDestinationPath: linkTarget)
        try applyMetadata(at: finalURL.path, followSymlink: false)
    }

    private func applyMetadata(at path: String, followSymlink: Bool) throws {
        if let mode = request.mode, followSymlink {
            guard Darwin.chmod(path, mode_t(mode)) == 0 else {
                throw POSIXError.fromErrno()
            }
        }

        if request.uid != nil || request.gid != nil {
            let uid = request.uid.map { uid_t($0) } ?? uid_t(bitPattern: -1)
            let gid = request.gid.map { gid_t($0) } ?? gid_t(bitPattern: -1)
            let result = followSymlink ? Darwin.chown(path, uid, gid) : Darwin.lchown(path, uid, gid)
            guard result == 0 else {
                throw POSIXError.fromErrno()
            }
        }

        if let mtime = request.mtime {
            var times = [
                timeval(tv_sec: time_t(mtime), tv_usec: 0),
                timeval(tv_sec: time_t(mtime), tv_usec: 0),
            ]
            let result = times.withUnsafeMutableBufferPointer { buffer -> Int32 in
                guard let baseAddress = buffer.baseAddress else { return -1 }
                return followSymlink ? Darwin.utimes(path, baseAddress) : Darwin.lutimes(path, baseAddress)
            }
            guard result == 0 else {
                throw POSIXError.fromErrno()
            }
        }
    }

    private func normalizedDigest(_ digest: String) -> String {
        let lowercased = digest.lowercased()
        if let value = lowercased.split(separator: ":", maxSplits: 1).last, lowercased.hasPrefix("sha256:") {
            return String(value)
        }
        return lowercased
    }

    private func sha256(of fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer {
            try? handle.close()
        }

        var hasher = SHA256()
        while true {
            guard let data = try handle.read(upToCount: 1 << 20), !data.isEmpty else {
                break
            }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
