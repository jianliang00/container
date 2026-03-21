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

func isSessionOnConsole() -> Bool? {
    guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else {
        return nil
    }
    if let value = dict["kCGSessionOnConsoleKey"] as? NSNumber {
        return value.boolValue
    }
    if let value = dict["kCGSessionOnConsoleKey"] as? Bool {
        return value
    }
    return nil
}
