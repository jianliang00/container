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

import ContainerAPIClient
import ContainerizationOCI
import Foundation
import Testing

/// Tests that need total control over environment to avoid conflicts.
@Suite(.serialized, .enabled(if: CLITest.isCLIServiceAvailable(), "requires running container API service"))
class TestCLINoParallelCases: CLITest {
    func getTestName() -> String {
        Test.current!.name.trimmingCharacters(in: ["(", ")"]).lowercased()
    }

    func getLowercasedTestName() -> String {
        getTestName().lowercased()
    }

    func makeLocalTestImage(_ suffix: String) -> String {
        "registry.local/\(getLowercasedTestName())-\(suffix):\(UUID().uuidString)"
    }

    @Test func testImageSingleConcurrentDownload() throws {
        do {
            try doPull(imageName: alpine, args: ["--max-concurrent-downloads", "1"])
            let imagePresent = try isImagePresent(targetImage: alpine)
            #expect(imagePresent, "Expected image to be pulled with maxConcurrentDownloads=1")
        } catch {
            Issue.record("failed to pull image with maxConcurrentDownloads flag: \(error)")
            return
        }
    }

    @Test func testImageManyConcurrentDownloads() throws {
        do {
            try doPull(imageName: alpine, args: ["--max-concurrent-downloads", "64"])
            let imagePresent = try isImagePresent(targetImage: alpine)
            #expect(imagePresent, "Expected image to be pulled with maxConcurrentDownloads=64")
        } catch {
            Issue.record("failed to pull image with maxConcurrentDownloads flag: \(error)")
            return
        }
    }

    @Test func testImagePruneNoImages() throws {
        let (_, output, error, status) = try run(arguments: ["image", "prune"])
        if status != 0 {
            throw CLIError.executionFailed("image prune failed: \(error)")
        }

        #expect(!output.contains("Error"), "image prune should succeed without reporting an error")
    }

    @Test func testImagePruneUnusedImages() throws {
        let alpineTagged = makeLocalTestImage("alpine")
        let busyboxTagged = makeLocalTestImage("busybox")
        defer { try? doRemoveImages(images: [alpineTagged, busyboxTagged]) }

        // 1. Pull and isolate the images under test
        try doPull(imageName: alpine)
        try doPull(imageName: busybox)
        try doImageTag(image: alpine, newName: alpineTagged)
        try doImageTag(image: busybox, newName: busyboxTagged)

        // 2. Verify the images are present
        let alpinePresent = try isImagePresent(targetImage: alpineTagged)
        #expect(alpinePresent, "expected to see image \(alpineTagged) tagged")
        let busyBoxPresent = try isImagePresent(targetImage: busyboxTagged)
        #expect(busyBoxPresent, "expected to see image \(busyboxTagged) tagged")

        // 3. Remove only the isolated test tags so the shared image store is not
        // disturbed for other concurrently-running integration suites.
        try doRemoveImages(images: [alpineTagged, busyboxTagged])

        // 4. Verify the images are gone
        let alpineRemoved = try !isImagePresent(targetImage: alpineTagged)
        #expect(alpineRemoved, "expected image \(alpineTagged) to be removed")
        let busyboxRemoved = try !isImagePresent(targetImage: busyboxTagged)
        #expect(busyboxRemoved, "expected image \(busyboxTagged) to be removed")
    }

    @Test func testImagePruneDanglingImages() throws {
        let name = getTestName()
        let containerName = "\(name)_container"
        let alpineTagged = makeLocalTestImage("alpine")
        let busyboxTagged = makeLocalTestImage("busybox")
        defer {
            try? doStop(name: containerName)
            try? doRemove(name: containerName, force: true)
            try? doRemoveImages(images: [alpineTagged, busyboxTagged])
        }

        // 1. Pull and isolate the images
        try doPull(imageName: alpine)
        try doPull(imageName: busybox)
        try doImageTag(image: alpine, newName: alpineTagged)
        try doImageTag(image: busybox, newName: busyboxTagged)

        // 2. Verify the images are present
        let alpinePresent = try isImagePresent(targetImage: alpineTagged)
        #expect(alpinePresent, "expected to see image \(alpineTagged) tagged")
        let busyBoxPresent = try isImagePresent(targetImage: busyboxTagged)
        #expect(busyBoxPresent, "expected to see image \(busyboxTagged) tagged")

        // 3. Create a running container based on the protected test image
        try doLongRun(
            name: containerName,
            image: alpineTagged
        )
        try waitForContainerRunning(containerName)

        // 4. Remove only the unused image tag under test.
        try doRemoveImages(images: [busyboxTagged])

        // 5. Verify the busybox image is gone
        let busyboxRemoved = try !isImagePresent(targetImage: busyboxTagged)
        #expect(busyboxRemoved, "expected image \(busyboxTagged) to be removed")

        // 6. Verify the alpine image still exists
        let alpineStillPresent = try isImagePresent(targetImage: alpineTagged)
        #expect(alpineStillPresent, "expected image \(alpineTagged) to remain")
    }

    @available(macOS 26, *)
    @Test func testNetworkPruneNoNetworks() throws {
        // Ensure the testnetworkcreateanduse network is deleted
        // Clean up is necessary for testing prune with no networks
        doNetworkDeleteIfExists(name: "testnetworkcreateanduse")

        // Prune with no networks should succeed
        let (_, _, _, statusBefore) = try run(arguments: ["network", "list", "--quiet"])
        #expect(statusBefore == 0)
        let (_, output, error, status) = try run(arguments: ["network", "prune"])
        if status != 0 {
            throw CLIError.executionFailed("network prune failed: \(error)")
        }

        #expect(output.isEmpty, "should show no networks pruned")
    }

    @available(macOS 26, *)
    @Test func testNetworkPruneUnusedNetworks() throws {
        let name = getTestName()
        let network1 = "\(name)_1"
        let network2 = "\(name)_2"

        // Clean up any existing resources from previous runs
        doNetworkDeleteIfExists(name: network1)
        doNetworkDeleteIfExists(name: network2)

        defer {
            doNetworkDeleteIfExists(name: network1)
            doNetworkDeleteIfExists(name: network2)
        }

        try doNetworkCreate(name: network1)
        try doNetworkCreate(name: network2)

        // Verify networks are created
        let (_, listBefore, _, statusBefore) = try run(arguments: ["network", "list", "--quiet"])
        #expect(statusBefore == 0)
        #expect(listBefore.contains(network1))
        #expect(listBefore.contains(network2))

        // Prune should remove both
        let (_, output, error, status) = try run(arguments: ["network", "prune"])
        if status != 0 {
            throw CLIError.executionFailed("network prune failed: \(error)")
        }

        #expect(output.contains(network1), "should prune network1")
        #expect(output.contains(network2), "should prune network2")

        // Verify networks are gone
        let (_, listAfter, _, statusAfter) = try run(arguments: ["network", "list", "--quiet"])
        #expect(statusAfter == 0)
        #expect(!listAfter.contains(network1), "network1 should be pruned")
        #expect(!listAfter.contains(network2), "network2 should be pruned")
    }

    @available(macOS 26, *)
    @Test func testNetworkPruneSkipsNetworksInUse() throws {
        let name = getTestName()
        let containerName = "\(name)_c1"
        let networkInUse = "\(name)_inuse"
        let networkUnused = "\(name)_unused"

        // Clean up any existing resources from previous runs
        try? doStop(name: containerName)
        try? doRemove(name: containerName)
        doNetworkDeleteIfExists(name: networkInUse)
        doNetworkDeleteIfExists(name: networkUnused)

        defer {
            try? doStop(name: containerName)
            try? doRemove(name: containerName)
            doNetworkDeleteIfExists(name: networkInUse)
            doNetworkDeleteIfExists(name: networkUnused)
        }

        try doNetworkCreate(name: networkInUse)
        try doNetworkCreate(name: networkUnused)

        // Verify networks are created
        let (_, listBefore, _, statusBefore) = try run(arguments: ["network", "list", "--quiet"])
        #expect(statusBefore == 0)
        #expect(listBefore.contains(networkInUse))
        #expect(listBefore.contains(networkUnused))

        // Creation of container with network connection
        let port = UInt16.random(in: 50000..<60000)
        try doLongRun(
            name: containerName,
            image: "docker.io/library/python:alpine",
            args: ["--network", networkInUse],
            containerArgs: ["python3", "-m", "http.server", "--bind", "0.0.0.0", "\(port)"]
        )
        try waitForContainerRunning(containerName)
        let container = try inspectContainer(containerName)
        #expect(container.networks.count > 0)

        // Prune should only remove the unused network
        let (_, _, error, status) = try run(arguments: ["network", "prune"])
        if status != 0 {
            throw CLIError.executionFailed("network prune failed: \(error)")
        }

        // Verify in-use network still exists
        let (_, listAfter, _, statusAfter) = try run(arguments: ["network", "list", "--quiet"])
        #expect(statusAfter == 0)
        #expect(listAfter.contains(networkInUse), "network in use should NOT be pruned")
        #expect(!listAfter.contains(networkUnused), "unused network should be pruned")
    }

    @available(macOS 26, *)
    @Test func testNetworkPruneSkipsNetworkAttachedToStoppedContainer() async throws {
        let name = getTestName()
        let containerName = "\(name)_c1"
        let networkName = "\(name)"

        // Clean up any existing resources from previous runs
        try? doStop(name: containerName)
        try? doRemove(name: containerName)
        doNetworkDeleteIfExists(name: networkName)

        defer {
            try? doStop(name: containerName)
            try? doRemove(name: containerName)
            doNetworkDeleteIfExists(name: networkName)
        }

        try doNetworkCreate(name: networkName)

        // Creation of container with network connection
        let port = UInt16.random(in: 50000..<60000)
        try doLongRun(
            name: containerName,
            image: "docker.io/library/python:alpine",
            args: ["--network", networkName],
            containerArgs: ["python3", "-m", "http.server", "--bind", "0.0.0.0", "\(port)"]
        )
        try await Task.sleep(for: .seconds(1))

        // Prune should NOT remove the network (container exists, even if stopped)
        let (_, _, error, status) = try run(arguments: ["network", "prune"])
        if status != 0 {
            throw CLIError.executionFailed("network prune failed: \(error)")
        }

        let (_, listAfter, _, statusAfter) = try run(arguments: ["network", "list", "--quiet"])
        #expect(statusAfter == 0)
        #expect(listAfter.contains(networkName), "network attached to stopped container should NOT be pruned")

        try? doStop(name: containerName)
        try? doRemove(name: containerName)

        let (_, _, error2, status2) = try run(arguments: ["network", "prune"])
        if status2 != 0 {
            throw CLIError.executionFailed("network prune failed: \(error2)")
        }

        // Verify network is gone
        let (_, listFinal, _, statusFinal) = try run(arguments: ["network", "list", "--quiet"])
        #expect(statusFinal == 0)
        #expect(!listFinal.contains(networkName), "network should be pruned after container is deleted")
    }
}
