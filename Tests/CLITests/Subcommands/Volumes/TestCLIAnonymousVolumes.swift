//===----------------------------------------------------------------------===//
// Copyright © 2025-2026 Apple Inc. and the container project authors.
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

import ContainerResource
import Foundation
import Testing

@Suite(.serialized, .enabled(if: CLITest.isCLIServiceAvailable(), "requires running container API service"))
class TestCLIAnonymousVolumes: CLITest {

    private func getTestName() -> String {
        Test.current!.name.trimmingCharacters(in: ["(", ")"]).lowercased()
    }

    func getAnonymousVolumeNames() throws -> [String] {
        let (_, output, error, status) = try run(arguments: ["volume", "list", "--quiet"])
        guard status == 0 else {
            throw CLIError.executionFailed("volume list failed: \(error)")
        }
        return output.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { isValidUUID($0) }
    }

    func snapshotAnonymousVolumes() throws -> Set<String> {
        Set(try getAnonymousVolumeNames())
    }

    func anonymousVolumesCreated(since baseline: Set<String>) throws -> [String] {
        Array(try snapshotAnonymousVolumes().subtracting(baseline)).sorted()
    }

    func cleanUpAnonymousVolumes(createdSince baseline: Set<String>) {
        guard let volumes = try? anonymousVolumesCreated(since: baseline) else {
            return
        }
        volumes.forEach { doVolumeDeleteIfExists(name: $0) }
    }

    func anonymousVolumesAttached(to containerName: String) throws -> [String] {
        try inspectContainer(containerName).configuration.mounts
            .compactMap(\.volumeName)
            .filter(isValidUUID)
            .sorted()
    }

    func containerExists(_ name: String) throws -> Bool {
        let (_, output, error, status) = try run(arguments: ["ls", "-a"])
        guard status == 0 else {
            throw CLIError.executionFailed("container list failed: \(error)")
        }
        return output.components(separatedBy: .newlines).contains(name)
    }

    func waitForContainerRemoval(_ name: String, attempts: Int = 30) async throws {
        for _ in 0..<attempts {
            if try !containerExists(name) {
                return
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw CLIError.executionFailed("timed out waiting for container \(name) to be removed")
    }

    func volumeExists(name: String) throws -> Bool {
        let (_, output, _, status) = try run(arguments: ["volume", "list", "--quiet"])
        guard status == 0 else { return false }
        let volumes = output.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        return volumes.contains(name)
    }

    func isValidUUID(_ name: String) -> Bool {
        let pattern = #"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"#
        guard let regex = try? Regex(pattern) else { return false }
        return (try? regex.firstMatch(in: name)) != nil
    }

    func doVolumeCreate(name: String) throws {
        let (_, _, error, status) = try run(arguments: ["volume", "create", name])
        if status != 0 {
            throw CLIError.executionFailed("volume create failed: \(error)")
        }
    }

    func doVolumeDeleteIfExists(name: String) {
        let (_, _, _, _) = (try? run(arguments: ["volume", "rm", name])) ?? (nil, "", "", 1)
    }

    func doRemoveIfExists(name: String, force: Bool = false) {
        var args = ["delete"]
        if force {
            args.append("--force")
        }
        args.append(name)
        let (_, _, _, _) = (try? run(arguments: args)) ?? (nil, "", "", 1)
    }

    @Test func testAnonymousVolumeCreationAndPersistence() async throws {
        let testName = getTestName()
        let containerName = "\(testName)_c1"
        let baselineAnonymousVolumes = try snapshotAnonymousVolumes()
        var attachedVolumes: [String] = []

        doRemoveIfExists(name: containerName, force: true)

        defer {
            doRemoveIfExists(name: containerName, force: true)
            attachedVolumes.forEach { doVolumeDeleteIfExists(name: $0) }
            cleanUpAnonymousVolumes(createdSince: baselineAnonymousVolumes)
        }

        // Run a short-lived detached container so we can inspect the mounted
        // anonymous volume before auto-remove kicks in.
        let (_, _, _, status) = try run(arguments: [
            "run",
            "-d",
            "--rm",
            "--name",
            containerName,
            "-v",
            "/data",
            alpine,
            "sleep",
            "2",
        ])

        #expect(status == 0, "container run should succeed")
        attachedVolumes = try anonymousVolumesAttached(to: containerName)
        #expect(attachedVolumes.count == 1, "anonymous volume should be attached")

        try await waitForContainerRemoval(containerName)
        #expect(try !containerExists(containerName), "container should be removed with --rm")

        // Verify anonymous volume persists (no auto-cleanup)
        for volumeName in attachedVolumes {
            #expect(try volumeExists(name: volumeName), "anonymous volume \(volumeName) should persist even with --rm")
        }
    }

    @Test func testAnonymousVolumePersistenceWithoutRm() throws {
        let testName = getTestName()
        let containerName = "\(testName)_c1"
        let containerName2 = "\(testName)_c2"
        let testData = "persistent-data"
        let baselineAnonymousVolumes = try snapshotAnonymousVolumes()

        doRemoveIfExists(name: containerName, force: true)
        doRemoveIfExists(name: containerName2, force: true)

        defer {
            doRemoveIfExists(name: containerName, force: true)
            doRemoveIfExists(name: containerName2, force: true)
            cleanUpAnonymousVolumes(createdSince: baselineAnonymousVolumes)
        }

        // Run container WITHOUT --rm
        try doLongRun(name: containerName, args: ["-v", "/data"], autoRemove: false)
        try waitForContainerRunning(containerName)

        // Write data to anonymous volume
        _ = try doExec(name: containerName, cmd: ["sh", "-c", "echo '\(testData)' > /data/test.txt"])

        // Get the anonymous volume ID
        let volumeNames = try anonymousVolumesAttached(to: containerName)
        #expect(volumeNames.count == 1, "should have exactly one anonymous volume")
        let volumeID = volumeNames[0]

        // Stop and remove container
        try doStop(name: containerName)
        doRemoveIfExists(name: containerName, force: true)

        // Verify volume still exists
        let exists = try volumeExists(name: volumeID)
        #expect(exists, "anonymous volume should persist without --rm")

        // Mount same volume in new container and verify data
        try doLongRun(name: containerName2, args: ["-v", "\(volumeID):/data"], autoRemove: false)
        try waitForContainerRunning(containerName2)

        var output = try doExec(name: containerName2, cmd: ["cat", "/data/test.txt"])
        output = output.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(output == testData, "data should persist in anonymous volume")

        // Clean up
        try doStop(name: containerName2)
        doRemoveIfExists(name: containerName2, force: true)
        doVolumeDeleteIfExists(name: volumeID)
    }

    @Test func testMultipleAnonymousVolumes() async throws {
        let testName = getTestName()
        let containerName = "\(testName)_c1"
        let baselineAnonymousVolumes = try snapshotAnonymousVolumes()
        var attachedVolumes: [String] = []

        doRemoveIfExists(name: containerName, force: true)

        defer {
            doRemoveIfExists(name: containerName, force: true)
            attachedVolumes.forEach { doVolumeDeleteIfExists(name: $0) }
            cleanUpAnonymousVolumes(createdSince: baselineAnonymousVolumes)
        }

        // Run with multiple anonymous volumes long enough to inspect them.
        let (_, _, _, status) = try run(arguments: [
            "run",
            "-d",
            "--rm",
            "--name",
            containerName,
            "-v", "/data1",
            "-v", "/data2",
            "-v", "/data3",
            alpine,
            "sleep", "2",
        ])

        #expect(status == 0, "container run should succeed")
        attachedVolumes = try anonymousVolumesAttached(to: containerName)
        #expect(attachedVolumes.count == 3, "all 3 anonymous volumes should be attached")

        try await waitForContainerRemoval(containerName)
        for volumeName in attachedVolumes {
            #expect(try volumeExists(name: volumeName), "anonymous volume \(volumeName) should persist")
        }
    }

    @Test func testAnonymousMountSyntax() async throws {
        let testName = getTestName()
        let containerName = "\(testName)_c1"
        let baselineAnonymousVolumes = try snapshotAnonymousVolumes()
        var attachedVolumes: [String] = []

        doRemoveIfExists(name: containerName, force: true)

        defer {
            doRemoveIfExists(name: containerName, force: true)
            attachedVolumes.forEach { doVolumeDeleteIfExists(name: $0) }
            cleanUpAnonymousVolumes(createdSince: baselineAnonymousVolumes)
        }

        // Use --mount syntax with a detached container so we can inspect the mount.
        let (_, _, _, status) = try run(arguments: [
            "run",
            "-d",
            "--rm",
            "--name",
            containerName,
            "--mount", "type=volume,dst=/mydata",
            alpine,
            "sleep", "2",
        ])

        #expect(status == 0, "container run with --mount should succeed")
        attachedVolumes = try anonymousVolumesAttached(to: containerName)
        #expect(attachedVolumes.count == 1, "anonymous volume should be attached")

        try await waitForContainerRemoval(containerName)
        for volumeName in attachedVolumes {
            #expect(try volumeExists(name: volumeName), "anonymous volume \(volumeName) should persist")
        }
    }

    @Test func testAnonymousVolumeUUIDFormat() throws {
        let testName = getTestName()
        let containerName = "\(testName)_c1"
        let baselineAnonymousVolumes = try snapshotAnonymousVolumes()

        defer {
            try? doStop(name: containerName)
            doRemoveIfExists(name: containerName, force: true)
            cleanUpAnonymousVolumes(createdSince: baselineAnonymousVolumes)
        }

        // Create container with anonymous volume
        try doLongRun(name: containerName, args: ["-v", "/data"])
        try waitForContainerRunning(containerName)

        // Get the anonymous volume name
        let volumeNames = try anonymousVolumesAttached(to: containerName)
        #expect(volumeNames.count == 1, "should have exactly one anonymous volume")

        let volumeName = volumeNames[0]

        // Verify UUID format: {lowercase uuid}
        #expect(isValidUUID(volumeName), "volume name should match UUID format: \(volumeName)")

        // Verify total length is 36 characters (UUID without prefix)
        #expect(volumeName.count == 36, "volume name should be 36 characters long")
    }

    @Test func testAnonymousVolumeMetadata() throws {
        let testName = getTestName()
        let containerName = "\(testName)_c1"
        let baselineAnonymousVolumes = try snapshotAnonymousVolumes()

        defer {
            try? doStop(name: containerName)
            doRemoveIfExists(name: containerName, force: true)
            cleanUpAnonymousVolumes(createdSince: baselineAnonymousVolumes)
        }

        // Create container with anonymous volume
        try doLongRun(name: containerName, args: ["-v", "/data"])
        try waitForContainerRunning(containerName)

        // Get the anonymous volume
        let volumeNames = try anonymousVolumesAttached(to: containerName)
        #expect(volumeNames.count == 1, "should have exactly one anonymous volume")
        let volumeName = volumeNames[0]

        // Inspect volume in JSON format
        let (_, output, error, status) = try run(arguments: ["volume", "list", "--format", "json"])
        #expect(status == 0, "volume list should succeed: \(error)")

        // Parse JSON to verify metadata
        let data = output.data(using: .utf8)!
        let volumes = try JSONDecoder().decode([Volume].self, from: data)

        let anonVolume = volumes.first { $0.name == volumeName }
        #expect(anonVolume != nil, "should find anonymous volume in list")

        if let vol = anonVolume {
            #expect(vol.isAnonymous == true, "isAnonymous should be true")
        }
    }

    @Test func testAnonymousVolumeListDisplay() throws {
        let testName = getTestName()
        let namedVolumeName = "\(testName)_namedvol"
        let containerName = "\(testName)_c1"
        let baselineAnonymousVolumes = try snapshotAnonymousVolumes()

        defer {
            try? doStop(name: containerName)
            doRemoveIfExists(name: containerName, force: true)
            doVolumeDeleteIfExists(name: namedVolumeName)
            cleanUpAnonymousVolumes(createdSince: baselineAnonymousVolumes)
        }

        // Create named volume
        try doVolumeCreate(name: namedVolumeName)

        // Create container with anonymous volume
        try doLongRun(name: containerName, args: ["-v", "/data"])
        try waitForContainerRunning(containerName)

        // List volumes
        let (_, output, error, status) = try run(arguments: ["volume", "list"])
        #expect(status == 0, "volume list should succeed: \(error)")

        // Verify TYPE column exists and shows both types
        #expect(output.contains("TYPE"), "output should contain TYPE column")
        #expect(output.contains("named"), "output should show named volume type")
        #expect(output.contains("anonymous"), "output should show anonymous volume type")
        #expect(output.contains(namedVolumeName), "output should contain named volume")
    }

    @Test func testAnonymousVolumeMixedWithNamedVolume() async throws {
        let testName = getTestName()
        let namedVolumeName = "\(testName)_namedvol"
        let containerName = "\(testName)_c1"
        let baselineAnonymousVolumes = try snapshotAnonymousVolumes()
        var attachedVolumes: [String] = []

        doRemoveIfExists(name: containerName, force: true)
        doVolumeDeleteIfExists(name: namedVolumeName)

        defer {
            doRemoveIfExists(name: containerName, force: true)
            doVolumeDeleteIfExists(name: namedVolumeName)
            attachedVolumes.forEach { doVolumeDeleteIfExists(name: $0) }
            cleanUpAnonymousVolumes(createdSince: baselineAnonymousVolumes)
        }

        // Create named volume
        try doVolumeCreate(name: namedVolumeName)

        // Run with both named and anonymous volumes, with --rm
        let (_, _, _, status) = try run(arguments: [
            "run",
            "-d",
            "--rm",
            "--name",
            containerName,
            "-v", "\(namedVolumeName):/named",
            "-v", "/anon",
            alpine,
            "sleep", "2",
        ])

        #expect(status == 0, "container run should succeed")
        attachedVolumes = try anonymousVolumesAttached(to: containerName)
        #expect(attachedVolumes.count == 1, "anonymous volume should be attached")

        try await waitForContainerRemoval(containerName)

        // Named volume should still exist
        let namedExists = try volumeExists(name: namedVolumeName)
        #expect(namedExists, "named volume should persist")

        for volumeName in attachedVolumes {
            #expect(try volumeExists(name: volumeName), "anonymous volume \(volumeName) should persist")
        }
    }

    @Test func testAnonymousVolumeManualDeletion() throws {
        let testName = getTestName()
        let containerName = "\(testName)_c1"
        let baselineAnonymousVolumes = try snapshotAnonymousVolumes()

        defer {
            doRemoveIfExists(name: containerName, force: true)
            cleanUpAnonymousVolumes(createdSince: baselineAnonymousVolumes)
        }

        // Create container WITHOUT --rm
        try doLongRun(name: containerName, args: ["-v", "/data"], autoRemove: false)
        try waitForContainerRunning(containerName)

        // Read the mounted anonymous volume from the container configuration so
        // concurrent suites do not interfere with global volume snapshots.
        let volumeNames = try anonymousVolumesAttached(to: containerName)
        #expect(volumeNames.count == 1, "should have one anonymous volume")
        let volumeID = volumeNames[0]

        // Stop container (unmounts volume)
        try doStop(name: containerName)
        doRemoveIfExists(name: containerName, force: true)

        // Manual deletion should succeed (volume is unmounted)
        let (_, _, error, status) = try run(arguments: ["volume", "rm", volumeID])
        #expect(status == 0, "manual deletion of unmounted anonymous volume should succeed: \(error)")

        // Verify volume is gone
        let exists = try volumeExists(name: volumeID)
        #expect(!exists, "volume should be deleted")
    }

    @Test func testAnonymousVolumeDetachedMode() async throws {
        let testName = getTestName()
        let containerName = "\(testName)_c1"
        let baselineAnonymousVolumes = try snapshotAnonymousVolumes()
        var attachedVolumes: [String] = []

        doRemoveIfExists(name: containerName, force: true)

        defer {
            doRemoveIfExists(name: containerName, force: true)
            attachedVolumes.forEach { doVolumeDeleteIfExists(name: $0) }
            cleanUpAnonymousVolumes(createdSince: baselineAnonymousVolumes)
        }

        // Run in detached mode with --rm
        let (_, _, _, status) = try run(arguments: [
            "run",
            "-d",
            "--rm",
            "--name",
            containerName,
            "-v", "/data",
            alpine,
            "sleep", "2",
        ])

        #expect(status == 0, "detached container run should succeed")
        attachedVolumes = try anonymousVolumesAttached(to: containerName)
        #expect(attachedVolumes.count == 1, "anonymous volume should be attached")

        try await waitForContainerRemoval(containerName)
        #expect(try !containerExists(containerName), "container should be auto-removed")
        for volumeName in attachedVolumes {
            #expect(try volumeExists(name: volumeName), "anonymous volume \(volumeName) should persist")
        }
    }
}
