import CoreGraphics
import Darwin
import Foundation
import Virtualization

func ensureFileExists(_ path: URL, message: String) throws {
    guard FileManager.default.fileExists(atPath: path.path) else {
        throw ArgumentError.required("\(message): \(path.path)")
    }
}

func ensureDirectoryExists(_ path: URL, message: String) throws {
    var isDirectory: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: path.path, isDirectory: &isDirectory)
    guard exists, isDirectory.boolValue else {
        throw ArgumentError.required("\(message): \(path.path)")
    }
}

func clampedCPUCount(_ requested: Int) -> Int {
    let minAllowed = Int(VZVirtualMachineConfiguration.minimumAllowedCPUCount)
    let maxAllowed = Int(VZVirtualMachineConfiguration.maximumAllowedCPUCount)
    return max(minAllowed, min(maxAllowed, requested))
}

func clampedMemoryBytes(_ requestedMiB: UInt64) -> UInt64 {
    let requested = requestedMiB * 1024 * 1024
    let minAllowed = VZVirtualMachineConfiguration.minimumAllowedMemorySize
    let maxAllowed = VZVirtualMachineConfiguration.maximumAllowedMemorySize
    return max(minAllowed, min(maxAllowed, requested))
}

func loadOrCreateMachineIdentifier(at path: URL) throws -> VZMacMachineIdentifier {
    if FileManager.default.fileExists(atPath: path.path) {
        let data = try Data(contentsOf: path)
        if let machineIdentifier = VZMacMachineIdentifier(dataRepresentation: data) {
            return machineIdentifier
        }
        fputs("warning: existing MachineIdentifier.bin is invalid, generating a new one\n", stderr)
    }

    let machineIdentifier = VZMacMachineIdentifier()
    try machineIdentifier.dataRepresentation.write(to: path)
    return machineIdentifier
}

func splitWhitespace(_ value: String) -> [String] {
    value.split(whereSeparator: \.isWhitespace).map(String.init)
}

func describeError(_ error: Error) -> String {
    if let debuggerError = error as? DebuggerError {
        return debuggerError.description
    }
    let nsError = error as NSError
    return "\(nsError.domain) Code=\(nsError.code) \"\(nsError.localizedDescription)\""
}

func makePOSIXError(_ code: Int32) -> NSError {
    NSError(
        domain: NSPOSIXErrorDomain,
        code: Int(code),
        userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(code))]
    )
}

func currentSessionSummary() -> String {
    guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else {
        return "unavailable"
    }
    let onConsole = dict["kCGSessionOnConsoleKey"].map { "\($0)" } ?? "nil"
    let loginDone = dict["kCGSessionLoginDoneKey"].map { "\($0)" } ?? "nil"
    let userName = dict["kCGSessionUserNameKey"].map { "\($0)" } ?? "nil"
    let userID = dict["kCGSessionUserIDKey"].map { "\($0)" } ?? "nil"
    return "onConsole=\(onConsole) loginDone=\(loginDone) user=\(userName) uid=\(userID)"
}
