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
import Testing

@testable import ContainerK8sFlannelVXLANMacOS

struct FlannelRouteManagementTests {
    @Test
    func addsExactPodCIDRRouteWhenLookupFallsBackToDefault() throws {
        let script = RouteCommandScript([
            .get(Self.defaultRoute(interface: "en0")),
            .add(),
            .get(Self.exactRoute(interface: "utun4")),
        ])
        let manager = FlannelSystemManager(commandRunner: script.run)

        try manager.ensureRoute(podCIDR: "10.250.8.17/24", interface: "utun4")

        #expect(script.isExhausted)
        #expect(!script.commands.contains { $0.contains("change") })
    }

    @Test
    func addsExactPodCIDRRouteWhenLookupFindsOnlyABroaderRoute() throws {
        let script = RouteCommandScript([
            .get(Self.broaderRoute(interface: "en0")),
            .add(),
            .get(Self.exactRoute(interface: "utun4")),
        ])
        let manager = FlannelSystemManager(commandRunner: script.run)

        try manager.ensureRoute(podCIDR: "10.250.8.0/24", interface: "utun4")

        #expect(script.isExhausted)
        #expect(!script.commands.contains { $0.contains("change") })
    }

    @Test
    func doesNotDeleteDefaultRouteWhenExactPodCIDRRouteIsAbsent() throws {
        let script = RouteCommandScript([
            .get(Self.defaultRoute(interface: "utun4"))
        ])
        let manager = FlannelSystemManager(commandRunner: script.run)

        try manager.removeRoute(podCIDR: "10.250.8.0/24", interface: "utun4")

        #expect(script.isExhausted)
        #expect(!script.commands.contains { $0.contains("delete") })
    }

    @Test
    func refusesToReplaceExactRouteOwnedByAnotherInterface() {
        let script = RouteCommandScript([
            .get(Self.exactRoute(interface: "en0"))
        ])
        let manager = FlannelSystemManager(commandRunner: script.run)

        #expect(throws: FlannelVXLANError.self) {
            try manager.ensureRoute(podCIDR: "10.250.8.0/24", interface: "utun4")
        }

        #expect(script.isExhausted)
        #expect(script.commands.count == 1)
    }

    @Test
    func acceptsAnExistingExactRouteOnTheOwnedInterface() throws {
        let script = RouteCommandScript([
            .get(Self.exactRoute(interface: "utun4"))
        ])
        let manager = FlannelSystemManager(commandRunner: script.run)

        try manager.ensureRoute(podCIDR: "10.250.8.0/24", interface: "utun4")

        #expect(script.isExhausted)
        #expect(script.commands.count == 1)
    }

    @Test
    func deletesOnlyAnExactRouteOnTheOwnedInterface() throws {
        let script = RouteCommandScript([
            .get(Self.exactRoute(interface: "utun4")),
            .delete(),
            .get(Self.defaultRoute(interface: "en0")),
        ])
        let manager = FlannelSystemManager(commandRunner: script.run)

        try manager.removeRoute(podCIDR: "10.250.8.0/24", interface: "utun4")

        #expect(script.isExhausted)
    }

    @Test
    func refusesToDeleteAnExactRouteOnAnotherInterface() {
        let script = RouteCommandScript([
            .get(Self.exactRoute(interface: "en0"))
        ])
        let manager = FlannelSystemManager(commandRunner: script.run)

        #expect(throws: FlannelVXLANError.self) {
            try manager.removeRoute(podCIDR: "10.250.8.0/24", interface: "utun4")
        }

        #expect(script.isExhausted)
        #expect(!script.commands.contains { $0.contains("delete") })
    }

    @Test
    func failsClosedWhenRouteQueryFailsOrReturnsMalformedOutput() {
        let failedQuery = RouteCommandScript([
            .getFailure()
        ])
        let failedQueryManager = FlannelSystemManager(commandRunner: failedQuery.run)

        #expect(throws: FlannelVXLANError.self) {
            try failedQueryManager.removeRoute(podCIDR: "10.250.8.0/24", interface: "utun4")
        }
        #expect(failedQuery.isExhausted)

        let malformedQuery = RouteCommandScript([
            .get("interface: en0\n")
        ])
        let malformedQueryManager = FlannelSystemManager(commandRunner: malformedQuery.run)

        #expect(throws: FlannelVXLANError.self) {
            try malformedQueryManager.ensureRoute(podCIDR: "10.250.8.0/24", interface: "utun4")
        }
        #expect(malformedQuery.isExhausted)
    }

    @Test
    func acceptsConcurrentAddOrDeleteWhenTheExactPostconditionIsSatisfied() throws {
        let addRace = RouteCommandScript([
            .get(Self.defaultRoute(interface: "en0")),
            .addFailure(),
            .get(Self.exactRoute(interface: "utun4")),
        ])
        let addManager = FlannelSystemManager(commandRunner: addRace.run)
        try addManager.ensureRoute(podCIDR: "10.250.8.0/24", interface: "utun4")
        #expect(addRace.isExhausted)

        let deleteRace = RouteCommandScript([
            .get(Self.exactRoute(interface: "utun4")),
            .deleteFailure(),
            .get(Self.defaultRoute(interface: "en0")),
        ])
        let deleteManager = FlannelSystemManager(commandRunner: deleteRace.run)
        try deleteManager.removeRoute(podCIDR: "10.250.8.0/24", interface: "utun4")
        #expect(deleteRace.isExhausted)
    }

    @Test
    func rejectsSuccessfulCommandsWhoseExactPostconditionsAreNotSatisfied() {
        let addWithoutRoute = RouteCommandScript([
            .get(Self.defaultRoute(interface: "en0")),
            .add(),
            .get(Self.defaultRoute(interface: "en0")),
        ])
        let addManager = FlannelSystemManager(commandRunner: addWithoutRoute.run)
        #expect(throws: FlannelVXLANError.self) {
            try addManager.ensureRoute(podCIDR: "10.250.8.0/24", interface: "utun4")
        }
        #expect(addWithoutRoute.isExhausted)

        let deleteWithRouteRemaining = RouteCommandScript([
            .get(Self.exactRoute(interface: "utun4")),
            .delete(),
            .get(Self.exactRoute(interface: "utun4")),
        ])
        let deleteManager = FlannelSystemManager(commandRunner: deleteWithRouteRemaining.run)
        #expect(throws: FlannelVXLANError.self) {
            try deleteManager.removeRoute(podCIDR: "10.250.8.0/24", interface: "utun4")
        }
        #expect(deleteWithRouteRemaining.isExhausted)
    }

    @Test
    func rejectsUnsafeManagedRouteArgumentsBeforeRunningRouteCommands() {
        let script = RouteCommandScript([])
        let manager = FlannelSystemManager(commandRunner: script.run)

        #expect(throws: FlannelVXLANError.self) {
            try manager.ensureRoute(podCIDR: "0.0.0.0/0", interface: "utun4")
        }
        #expect(throws: FlannelVXLANError.self) {
            try manager.removeRoute(podCIDR: "10.250.8.0/24", interface: "-utun4")
        }

        #expect(script.commands.isEmpty)
    }

    private static func defaultRoute(interface: String) -> String {
        """
           route to: 10.250.8.0
        destination: default
               mask: default
          interface: \(interface)
        """
    }

    private static func exactRoute(interface: String) -> String {
        """
           route to: 10.250.8.0
        destination: 10.250.8.0
               mask: 255.255.255.0
          interface: \(interface)
        """
    }

    private static func broaderRoute(interface: String) -> String {
        """
           route to: 10.250.8.0
        destination: 10.250.0.0
               mask: 255.255.0.0
          interface: \(interface)
        """
    }
}

private final class RouteCommandScript: @unchecked Sendable {
    struct Step: Sendable {
        var arguments: [String]
        var output: String
        var errorMessage: String?

        static func get(_ output: String) -> Self {
            Self(arguments: ["-n", "get", "-net", "10.250.8.0/24"], output: output, errorMessage: nil)
        }

        static func getFailure() -> Self {
            Self(
                arguments: ["-n", "get", "-net", "10.250.8.0/24"],
                output: "",
                errorMessage: "injected route query failure"
            )
        }

        static func add() -> Self {
            Self(
                arguments: ["-n", "add", "-net", "10.250.8.0/24", "-interface", "utun4"],
                output: "",
                errorMessage: nil
            )
        }

        static func addFailure() -> Self {
            Self(
                arguments: ["-n", "add", "-net", "10.250.8.0/24", "-interface", "utun4"],
                output: "",
                errorMessage: "injected route add failure"
            )
        }

        static func delete() -> Self {
            Self(
                arguments: ["-n", "delete", "-net", "10.250.8.0/24", "-interface", "utun4"],
                output: "",
                errorMessage: nil
            )
        }

        static func deleteFailure() -> Self {
            Self(
                arguments: ["-n", "delete", "-net", "10.250.8.0/24", "-interface", "utun4"],
                output: "",
                errorMessage: "injected route delete failure"
            )
        }
    }

    private let lock = NSLock()
    private var steps: [Step]
    private var commandValues: [[String]] = []

    init(_ steps: [Step]) {
        self.steps = steps
    }

    var isExhausted: Bool {
        lock.withLock { steps.isEmpty }
    }

    var commands: [[String]] {
        lock.withLock { commandValues }
    }

    func run(_ executable: String, _ arguments: [String]) throws -> String {
        try lock.withLock {
            guard executable == "/sbin/route", let step = steps.first else {
                throw FlannelVXLANError.runtime("unexpected route command")
            }
            steps.removeFirst()
            commandValues.append(arguments)
            guard arguments == step.arguments else {
                throw FlannelVXLANError.runtime("unexpected route arguments: \(arguments)")
            }
            if let errorMessage = step.errorMessage {
                throw FlannelVXLANError.runtime(errorMessage)
            }
            return step.output
        }
    }
}
