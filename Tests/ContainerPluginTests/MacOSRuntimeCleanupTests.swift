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

import ContainerizationError
import Foundation
import Testing

@testable import ContainerPlugin

struct MacOSRuntimeCleanupTests {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    @Test
    func nativeInspectionDetectsAnUnlinkedVMFileHeldByATestProcess() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("AuxiliaryStorage")
        try Data().write(to: file)
        let output = try FileHandle(forWritingTo: file)
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        child.standardOutput = output
        try child.run()
        defer {
            if child.isRunning {
                child.terminate()
                child.waitUntilExit()
            }
        }
        try output.close()
        try FileManager.default.removeItem(at: file)
        let cleanup = MacOSRuntimeCleanup()
        #expect(throws: (any Error).self) {
            try cleanup.confirmStopped(
                id: root.lastPathComponent,
                root: root,
                parentLabel: "gui/501/parent",
                sidecarLabel: "gui/501/sidecar"
            )
        }
        child.terminate()
        child.waitUntilExit()
        try cleanup.confirmStopped(
            id: root.lastPathComponent,
            root: root,
            parentLabel: "gui/501/parent",
            sidecarLabel: "gui/501/sidecar"
        )
        #expect(!MacOSRuntimeCleanup.isPending(root: root))
    }

    @Test
    func missingHandleReclaimsTheExactSuppliedSidecarAndWaitsForVM() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let label = "gui/501/com.example.sidecar.persistence-id"
        var registered = true
        var scans = 0
        var bootouts: [String] = []
        var cleanup = MacOSRuntimeCleanup()
        cleanup.sleep = {}
        cleanup.processExists = { _ in false }
        cleanup.run = { executable, args in
            if executable.hasSuffix("lsof") {
                scans += 1
                return .init(
                    status: 0,
                    output:
                        scans == 1
                        ? "p42\nn\(root.path)/Disk.img\n"
                        : "p43\nn/other/normal/Disk.img\n"
                )
            }
            #expect(args.last == label)
            if args[0] == "bootout" {
                #expect(MacOSRuntimeCleanup.isPending(root: root))
                bootouts.append(args[1])
                registered = false
                return .init(status: 0, output: "")
            }
            return registered
                ? .init(status: 0, output: "pid = 42\n")
                : .init(
                    status: 113,
                    output: "",
                    error: "Could not find service"
                )
        }
        try cleanup.stop(
            id: root.lastPathComponent,
            root: root,
            sidecarLabel: label
        )
        try cleanup.stop(
            id: root.lastPathComponent,
            root: root,
            sidecarLabel: label
        )
        #expect(bootouts == [label])
        #expect(scans == 3)
    }

    @Test
    func bootoutFailureRetainsRetryRecord() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        var cleanup = MacOSRuntimeCleanup()
        cleanup.attempts = 2
        cleanup.sleep = {}
        cleanup.run = { _, args in
            args[0] == "print"
                ? .init(status: 0, output: "pid = 42")
                : .init(status: 5, output: "", error: "Input/output error")
        }
        #expect(throws: (any Error).self) {
            try cleanup.stop(
                id: root.lastPathComponent,
                root: root,
                sidecarLabel: "gui/501/sidecar"
            )
        }
        #expect(MacOSRuntimeCleanup.isPending(root: root))
    }

    @Test
    func absentLaunchdJobDoesNotProveVMExit() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        var cleanup = MacOSRuntimeCleanup()
        cleanup.attempts = 2
        cleanup.sleep = {}
        cleanup.run = { executable, _ in
            executable.hasSuffix("lsof")
                ? .init(
                    status: 0,
                    output: "p42\nn\(root.path)/AuxiliaryStorage (deleted)\n"
                )
                : .init(
                    status: 113,
                    output: "",
                    error: "Could not find service"
                )
        }
        #expect(throws: (any Error).self) {
            try cleanup.stop(
                id: root.lastPathComponent,
                root: root,
                sidecarLabel: "gui/501/sidecar"
            )
        }
        #expect(MacOSRuntimeCleanup.isPending(root: root))
    }

    @Test(arguments: [true, false])
    func parentLivenessRequiresActualProcessExit(running: Bool) throws {
        var cleanup = MacOSRuntimeCleanup()
        cleanup.run = { _, _ in .init(status: 0, output: "pid = 42") }
        cleanup.processExists = { _ in running }
        #expect(
            try cleanup.serviceHasExited(label: "gui/501/parent") == !running
        )
    }

    @Test
    func inspectionFailureNeverMeansAbsent() throws {
        var cleanup = MacOSRuntimeCleanup()
        cleanup.run = {
            _, _ in
            .init(status: 1, output: "", error: "Operation not permitted")
        }
        #expect(throws: (any Error).self) {
            try cleanup.serviceHasExited(label: "gui/501/example")
        }
    }

    @Test
    func concurrentBootoutIsIdempotentAfterConfirmedExit() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = "gui/501/parent"
        let sidecar = "gui/501/sidecar"
        var labels: [String] = []
        var removed: Set<String> = []
        var cleanup = MacOSRuntimeCleanup()
        cleanup.sleep = {}
        cleanup.processExists = { _ in false }
        cleanup.run = { executable, args in
            if executable.hasSuffix("lsof") {
                return .init(status: 0, output: "")
            }
            let label = args[1]
            if args[0] == "bootout" {
                labels.append(label)
                removed.insert(label)
                return .init(status: 3, output: "", error: "No such process")
            }
            return removed.contains(label)
                ? .init(
                    status: 113,
                    output: "",
                    error: "Could not find service"
                )
                : .init(status: 0, output: "pid = 42")
        }
        try cleanup.stop(
            id: root.lastPathComponent,
            root: root,
            parentLabel: parent,
            sidecarLabel: sidecar
        )
        #expect(labels == [parent, sidecar])
    }

    @Test
    func processMustExitEvenAfterJobDisappears() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        var removed = false
        var cleanup = MacOSRuntimeCleanup()
        cleanup.attempts = 2
        cleanup.sleep = {}
        cleanup.processExists = { _ in true }
        cleanup.run = { _, args in
            if args[0] == "bootout" {
                removed = true
                return .init(status: 0, output: "")
            }
            return removed
                ? .init(
                    status: 113,
                    output: "",
                    error: "Could not find service"
                )
                : .init(status: 0, output: "pid = 42")
        }
        #expect(throws: (any Error).self) {
            try cleanup.stop(
                id: root.lastPathComponent,
                root: root,
                sidecarLabel: "gui/501/sidecar"
            )
        }
    }
}
