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

import Darwin
import Foundation
import Virtualization
import XPC
import vmnet

// This standalone diagnostic uses no runtime configuration or existing network.
// Its owner and clients must run in the same explicitly selected bootstrap domain.
private let callbackQueue = DispatchQueue(label: "container.vmnet-probe.callback")
private let operationTimeout: Double = 10

private func emit(_ fields: [String: Any]) {
    var value = fields
    value["schemaVersion"] = 1
    value["pid"] = getpid()
    value["euid"] = geteuid()
    value["timestamp"] = ISO8601DateFormatter().string(from: Date())
    let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    FileHandle.standardOutput.write(data + Data([10]))
}

private struct ProbeError: Error {
    let code: String
}

private func errorFields(_ error: Error) -> [String: Any] {
    if let error = error as? ProbeError { return ["error": error.code] }
    let error = error as NSError
    // Never emit arbitrary userInfo, private network identifiers, or XPC objects.
    var result: [String: Any] = ["errorDomain": error.domain, "errorCode": error.code]
    if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
        result["underlyingErrorDomain"] = underlying.domain
        result["underlyingErrorCode"] = underlying.code
    }
    return result
}

private final class Completion<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value?
    private let semaphore = DispatchSemaphore(value: 0)

    func complete(_ value: Value) {
        lock.lock()
        guard self.value == nil else {
            lock.unlock()
            return
        }
        self.value = value
        lock.unlock()
        semaphore.signal()
    }

    func wait(seconds: Double = operationTimeout) -> Value? {
        guard semaphore.wait(timeout: .now() + seconds) == .success else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

@available(macOS 26, *)
private final class NetworkReference {
    let value: OpaquePointer
    init(_ value: OpaquePointer) { self.value = value }
    deinit { Unmanaged<AnyObject>.fromOpaque(UnsafeMutableRawPointer(value)).release() }
}

@available(macOS 26, *)
private func configuration(ipv4: String, ipv6: String) throws -> NetworkReference {
    var status = vmnet_return_t.VMNET_SUCCESS
    guard let raw = vmnet_network_configuration_create(.VMNET_HOST_MODE, &status) else {
        emit(["stage": "configuration.create", "status": status.rawValue, "passed": false])
        throw ProbeError(code: "configurationCreateFailed")
    }
    let configuration = NetworkReference(raw)
    emit(["stage": "configuration.create", "status": status.rawValue, "passed": status == .VMNET_SUCCESS])
    guard status == .VMNET_SUCCESS else { throw ProbeError(code: "configurationCreateFailed") }
    vmnet_network_configuration_disable_dhcp(raw)
    var gateway = in_addr()
    var mask = in_addr()
    var prefix = in6_addr()
    // The runner validates canonical private /24 and ULA /64 prefixes first.
    let parts = ipv4.split(separator: "/", omittingEmptySubsequences: false)[0].split(separator: ".")
    guard parts.count == 4, ipv4.hasSuffix(".0/24"), ipv6.hasSuffix("::/64"),
        inet_pton(AF_INET, parts.prefix(3).joined(separator: ".") + ".1", &gateway) == 1,
        inet_pton(AF_INET, "255.255.255.0", &mask) == 1,
        inet_pton(AF_INET6, String(ipv6.dropLast(3)), &prefix) == 1
    else { throw ProbeError(code: "invalidDualStackConfiguration") }
    let octets = parts.compactMap { UInt8($0) }
    guard octets.count == 4,
        octets[0] == 10 || (octets[0] == 172 && (16...31).contains(octets[1])) || (octets[0] == 192 && octets[1] == 168),
        withUnsafeBytes(of: prefix, { $0[0] == 0xfd && $0.suffix(8).allSatisfy { $0 == 0 } })
    else { throw ProbeError(code: "requiresPrivateDualStackPrefixes") }
    status = vmnet_network_configuration_set_ipv4_subnet(raw, &gateway, &mask)
    emit(["stage": "configuration.ipv4", "status": status.rawValue, "passed": status == .VMNET_SUCCESS])
    guard status == .VMNET_SUCCESS else { throw ProbeError(code: "ipv4ConfigurationRejected") }
    status = vmnet_network_configuration_set_ipv6_prefix(raw, &prefix, 64)
    emit(["stage": "configuration.ipv6", "status": status.rawValue, "passed": status == .VMNET_SUCCESS])
    guard status == .VMNET_SUCCESS else { throw ProbeError(code: "ipv6ConfigurationRejected") }
    return configuration
}

@available(macOS 26, *)
private func summary(_ reference: NetworkReference) -> [String: Any] {
    var subnet = in_addr()
    var mask = in_addr()
    var prefix = in6_addr()
    var length: UInt8 = 0
    vmnet_network_get_ipv4_subnet(reference.value, &subnet, &mask)
    vmnet_network_get_ipv6_prefix(reference.value, &prefix, &length)
    var v4 = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
    var v4Mask = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
    var v6 = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
    inet_ntop(AF_INET, &subnet, &v4, socklen_t(v4.count))
    inet_ntop(AF_INET, &mask, &v4Mask, socklen_t(v4Mask.count))
    inet_ntop(AF_INET6, &prefix, &v6, socklen_t(v6.count))
    return ["ipv4Address": String(cString: v4), "ipv4Mask": String(cString: v4Mask), "ipv6Prefix": String(cString: v6), "ipv6PrefixLength": length]
}

@available(macOS 26, *)
private func serialized(_ reference: NetworkReference) throws -> xpc_object_t {
    var status = vmnet_return_t.VMNET_SUCCESS
    let object = vmnet_network_copy_serialization(reference.value, &status)
    emit(["stage": "serialize", "status": status.rawValue, "passed": object != nil && status == .VMNET_SUCCESS])
    guard let object, status == .VMNET_SUCCESS else { throw ProbeError(code: "serializationFailed") }
    return object
}

@available(macOS 26, *)
private func imported(_ object: xpc_object_t) throws -> NetworkReference {
    var status = vmnet_return_t.VMNET_SUCCESS
    guard let raw = vmnet_network_create_with_serialization(object, &status) else {
        emit(["stage": "import", "status": status.rawValue, "passed": false])
        throw ProbeError(code: "importFailed")
    }
    let reference = NetworkReference(raw)
    emit(["stage": "import", "status": status.rawValue, "passed": status == .VMNET_SUCCESS, "network": summary(reference)])
    guard status == .VMNET_SUCCESS else { throw ProbeError(code: "importFailed") }
    return reference
}

@available(macOS 26, *)
private func nativeInterface(_ reference: NetworkReference) -> [String: Any] {
    let description = xpc_dictionary_create(nil, nil, 0)
    xpc_dictionary_set_bool(description, vmnet_allocate_mac_address_key, true)
    xpc_dictionary_set_bool(description, vmnet_enable_tso_key, false)
    xpc_dictionary_set_bool(description, vmnet_enable_checksum_offload_key, false)
    xpc_dictionary_set_bool(description, vmnet_enable_isolation_key, false)
    let start = Completion<vmnet_return_t>()
    let handle = vmnet_interface_start_with_network(reference.value, description, callbackQueue) { status, _ in
        start.complete(status)
    }
    let started = start.wait()
    emit(["stage": "interface.start", "status": started?.rawValue as Any? ?? NSNull(), "timedOut": started == nil])
    guard let handle else {
        return ["passed": false, "error": "interfaceHandleMissing", "cleanupConfirmed": true, "startStatus": started?.rawValue as Any? ?? NSNull()]
    }
    // Stop every returned handle, including start failure and timeout paths.
    let stop = Completion<vmnet_return_t>()
    let scheduled = vmnet_stop_interface(handle, callbackQueue) { stop.complete($0) }
    let stopped = scheduled == .VMNET_SUCCESS ? stop.wait() : nil
    let cleaned = stopped == .VMNET_SUCCESS
    emit(["stage": "interface.stop", "scheduledStatus": scheduled.rawValue, "status": stopped?.rawValue as Any? ?? NSNull(), "cleanupConfirmed": cleaned])
    return ["passed": started == .VMNET_SUCCESS && cleaned, "cleanupConfirmed": cleaned, "startStatus": started?.rawValue as Any? ?? NSNull()]
}

private func reply(_ request: xpc_object_t, on connection: xpc_connection_t, result: [String: Any], network: xpc_object_t? = nil, identity: Data? = nil) {
    guard let response = xpc_dictionary_create_reply(request) else { return }
    let data = try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    data.withUnsafeBytes { xpc_dictionary_set_data(response, "result", $0.baseAddress!, $0.count) }
    if let network { xpc_dictionary_set_value(response, "network", network) }
    if let identity { identity.withUnsafeBytes { xpc_dictionary_set_data(response, "identity", $0.baseAddress!, $0.count) } }
    xpc_connection_send_message(connection, response)
}

@available(macOS 26, *)
private final class Owner {
    private let identity = VZMacMachineIdentifier().dataRepresentation
    private var network: NetworkReference?
    private var cleanupUncertain = false
    private let queue = DispatchQueue(label: "container.vmnet-probe.owner")
    private let listener: xpc_connection_t
    private var signals: [DispatchSourceSignal] = []

    init(service: String, ipv4: String, ipv6: String) throws {
        let config = try configuration(ipv4: ipv4, ipv6: ipv6)
        var status = vmnet_return_t.VMNET_SUCCESS
        guard let raw = vmnet_network_create(config.value, &status) else {
            emit(["stage": "reservation.create", "status": status.rawValue, "passed": false])
            throw ProbeError(code: "reservationCreateFailed")
        }
        network = NetworkReference(raw)
        guard status == .VMNET_SUCCESS else { throw ProbeError(code: "reservationCreateFailed") }
        listener = xpc_connection_create_mach_service(service, queue, UInt64(XPC_CONNECTION_MACH_SERVICE_LISTENER))
        emit(["stage": "reservation.create", "status": status.rawValue, "passed": true, "network": summary(network!)])
    }

    func run() {
        xpc_connection_set_event_handler(listener) { [self] peer in
            guard xpc_get_type(peer) == XPC_TYPE_CONNECTION else { return }
            guard xpc_connection_get_euid(peer) == geteuid() else {
                xpc_connection_cancel(peer)
                return
            }
            xpc_connection_set_target_queue(peer, queue)
            xpc_connection_set_event_handler(peer) { [self] request in
                if xpc_get_type(request) == XPC_TYPE_ERROR {
                    xpc_connection_cancel(peer)
                    return
                }
                guard xpc_get_type(request) == XPC_TYPE_DICTIONARY else { return }
                handle(request, peer: peer)
            }
            xpc_connection_activate(peer)
        }
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
            source.setEventHandler { [self] in releaseAndExit(reason: "signal") }
            source.resume()
            signals.append(source)
        }
        queue.asyncAfter(deadline: .now() + 480) { [self] in releaseAndExit(reason: "watchdog") }
        xpc_connection_activate(listener)
    }

    private func releaseAndExit(reason: String) -> Never {
        network = nil
        emit(["stage": "reservation.release", "referenceReleased": true, "cleanupConfirmed": !cleanupUncertain, "reason": reason])
        exit(cleanupUncertain ? 1 : 0)
    }

    private func handle(_ request: xpc_object_t, peer: xpc_connection_t) {
        let method = xpc_dictionary_get_string(request, "method").map(String.init(cString:)) ?? ""
        if method == "shutdown" {
            network = nil
            reply(request, on: peer, result: ["passed": !cleanupUncertain, "cleanupConfirmed": !cleanupUncertain, "referenceReleased": true])
            xpc_connection_send_barrier(peer) { [self] in releaseAndExit(reason: "shutdown") }
            return
        }
        guard let network, !cleanupUncertain else {
            reply(request, on: peer, result: ["passed": false, "error": "ownerUnavailableOrCleanupUncertain", "cleanupConfirmed": !cleanupUncertain])
            return
        }
        do {
            switch method {
            case "status":
                reply(request, on: peer, result: ["passed": true, "network": summary(network), "ownerPID": getpid()])
            case "direct", "same-import", "direct-vz", "same-import-vz":
                let reference = method.hasPrefix("same-import") ? try imported(serialized(network)) : network
                var result: [String: Any]
                if method.hasSuffix("-vz") {
                    guard let seed = xpc_dictionary_get_string(request, "seed") else { throw ProbeError(code: "missingDisposableSeed") }
                    result = VMProbe().run(reference: reference, seed: String(cString: seed), identity: identity)
                } else {
                    result = nativeInterface(reference)
                }
                result["ownerPID"] = getpid()
                cleanupUncertain = result["cleanupConfirmed"] as? Bool != true
                reply(request, on: peer, result: result)
            case "export":
                reply(request, on: peer, result: ["passed": true, "network": summary(network), "ownerPID": getpid()], network: try serialized(network), identity: identity)
            default:
                reply(request, on: peer, result: ["passed": false, "error": "unknownMethod"])
            }
        } catch {
            reply(request, on: peer, result: errorFields(error).merging(["passed": false, "cleanupConfirmed": true]) { _, new in new })
        }
    }
}

private func request(service: String, method: String, seed: String? = nil) throws -> (xpc_connection_t, xpc_object_t, [String: Any]) {
    let connection = xpc_connection_create_mach_service(service, callbackQueue, geteuid() == 0 ? UInt64(XPC_CONNECTION_MACH_SERVICE_PRIVILEGED) : 0)
    xpc_connection_set_event_handler(connection) { _ in }
    xpc_connection_activate(connection)
    let message = xpc_dictionary_create(nil, nil, 0)
    xpc_dictionary_set_string(message, "method", method)
    if let seed { xpc_dictionary_set_string(message, "seed", seed) }
    let completion = Completion<xpc_object_t>()
    xpc_connection_send_message_with_reply(connection, message, callbackQueue) { completion.complete($0) }
    guard let response = completion.wait(seconds: 40), xpc_get_type(response) == XPC_TYPE_DICTIONARY else {
        xpc_connection_cancel(connection)
        throw ProbeError(code: "xpcUnavailableOrTimedOut")
    }
    var count = 0
    guard let bytes = xpc_dictionary_get_data(response, "result", &count), count <= 65536,
        let result = try JSONSerialization.jsonObject(with: Data(bytes: bytes, count: count)) as? [String: Any]
    else {
        xpc_connection_cancel(connection)
        throw ProbeError(code: "invalidReply")
    }
    return (connection, response, result)
}

// Main-queue state, separated from VZ so timeout/callback ordering can be tested
// without creating a native network or booting a VM.
private struct VMProbeLifecycle {
    private(set) var startPending = true
    private(set) var finishRequested = false
    private(set) var cleanupStarted = false
    private var failure: [String: Any]?
    var hasFailed: Bool { failure != nil }

    mutating func fail(_ fields: [String: Any]) { failure = failure ?? fields }

    mutating func startCompleted() { startPending = false }

    mutating func requestFinish() -> Bool {
        finishRequested = true
        guard !startPending, !cleanupStarted else { return false }
        cleanupStarted = true
        return true
    }

    func result(cleanupConfirmed: Bool, cleanupError: Error? = nil) -> [String: Any] {
        var result = failure ?? [:]
        result["passed"] = failure == nil && cleanupConfirmed && cleanupError == nil
        result["cleanupConfirmed"] = cleanupConfirmed
        if let cleanupError { result["cleanupError"] = errorFields(cleanupError) }
        return result
    }
}

@available(macOS 26, *)
private final class VMProbe: NSObject, VZVirtualMachineDelegate {
    private var lifecycle = VMProbeLifecycle()
    private var vm: VZVirtualMachine?
    private var reference: NetworkReference?
    // Keep uncertain or still-starting native resources alive until confirmed
    // cleanup or process exit; returning a timeout must not release them early.
    private var cleanupLifetime: VMProbe?
    private let completed = Completion<[String: Any]>()

    func run(reference: NetworkReference, seed: String, identity: Data) -> [String: Any] {
        self.reference = reference
        DispatchQueue.main.async { [self] in
            do {
                let directory = URL(fileURLWithPath: seed, isDirectory: true)
                try validateDisposableSeed(directory)
                guard let model = VZMacHardwareModel(dataRepresentation: try Data(contentsOf: directory.appendingPathComponent("HardwareModel.bin"))), model.isSupported else {
                    throw ProbeError(code: "hardwareModelUnsupported")
                }
                let platform = VZMacPlatformConfiguration()
                platform.hardwareModel = model
                guard let identifier = VZMacMachineIdentifier(dataRepresentation: identity) else { throw ProbeError(code: "invalidTestIdentity") }
                platform.machineIdentifier = identifier
                platform.auxiliaryStorage = VZMacAuxiliaryStorage(url: directory.appendingPathComponent("AuxiliaryStorage"))
                let config = VZVirtualMachineConfiguration()
                config.platform = platform
                config.bootLoader = VZMacOSBootLoader()
                config.cpuCount = 4
                config.memorySize = 8 * 1024 * 1024 * 1024
                config.storageDevices = [
                    VZVirtioBlockDeviceConfiguration(attachment: try VZDiskImageStorageDeviceAttachment(url: directory.appendingPathComponent("Disk.img"), readOnly: false))
                ]
                let device = VZVirtioNetworkDeviceConfiguration()
                device.macAddress = VZMACAddress(string: "02:63:74:72:00:01")!
                device.attachment = VZVmnetNetworkDeviceAttachment(network: reference.value)
                config.networkDevices = [device]
                config.socketDevices = [VZVirtioSocketDeviceConfiguration()]
                try config.validate()
                emit(["stage": "vz.validate", "passed": true])
                let machine = VZVirtualMachine(configuration: config)
                vm = machine
                cleanupLifetime = self
                machine.delegate = self
                machine.start { [self] result in
                    lifecycle.startCompleted()
                    switch result {
                    case .failure(let error):
                        lifecycle.fail(errorFields(error))
                        finish()
                    case .success:
                        emit(["stage": "vz.start", "passed": true])
                        if lifecycle.finishRequested {
                            // A timeout cannot cancel VZ start. Keep the VM and
                            // network alive until this callback permits stop.
                            finish()
                            return
                        }
                        // Start success alone is not interface success. Observe delayed callbacks.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [self] in finish() }
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [self] in
                    guard lifecycle.startPending else { return }
                    lifecycle.fail(["error": "vzStartTimedOut"])
                    emit(["stage": "vz.startTimeout", "passed": false, "cleanupConfirmed": false])
                    finish()
                }
            } catch {
                self.reference = nil
                completed.complete(errorFields(error).merging(["passed": false, "cleanupConfirmed": true]) { _, new in new })
            }
        }
        return completed.wait(seconds: 35) ?? ["passed": false, "error": "vzCleanupTimedOut", "cleanupConfirmed": false]
    }

    private func finish() {
        guard lifecycle.requestFinish(), let vm else { return }
        let connected = vm.networkDevices.count == 1 && vm.networkDevices[0].attachment != nil
        if !connected { lifecycle.fail(["error": "networkAttachmentMissing"]) }
        emit(["stage": "vz.attachment", "connected": connected, "passed": connected && !lifecycle.hasFailed])
        let finishStop: (Error?) -> Void = { [self] error in
            let cleaned = error == nil && self.vm?.state == .stopped
            // Delegate callbacks may report a disconnect while stop is pending.
            // Read the sticky failure only when producing the final receipt.
            let result = lifecycle.result(cleanupConfirmed: cleaned, cleanupError: error)
            emit(result.merging(["stage": "vz.stop"]) { _, new in new })
            if cleaned {
                self.vm = nil
                self.reference = nil
                self.cleanupLifetime = nil
            }
            completed.complete(result)
        }
        switch vm.state {
        case .stopped: finishStop(nil)
        case .running, .paused: vm.stop(completionHandler: finishStop)
        default: finishStop(ProbeError(code: "vzCleanupStateUnsupported"))
        }
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, networkDevice: VZNetworkDevice, attachmentWasDisconnectedWithError error: Error) {
        let fields = errorFields(error)
        lifecycle.fail(fields)
        emit(fields.merging(["stage": "vz.networkDisconnected", "passed": false]) { _, new in new })
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        lifecycle.fail(errorFields(error))
        finish()
    }

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        if !lifecycle.cleanupStarted { lifecycle.fail(["error": "guestStoppedBeforeObservation"]) }
        finish()
    }
}

private func validateDisposableSeed(_ directory: URL) throws {
    guard directory.path == directory.resolvingSymlinksInPath().path else { throw ProbeError(code: "unsafeDisposableSeed") }
    for name in ["", ".probe-seed", "HardwareModel.bin", "AuxiliaryStorage", "Disk.img"] {
        let path = name.isEmpty ? directory.path : directory.appendingPathComponent(name).path
        var info = stat()
        guard lstat(path, &info) == 0, info.st_uid == geteuid(), info.st_mode & 0o077 == 0,
            info.st_mode & S_IFMT == (name.isEmpty ? S_IFDIR : S_IFREG),
            name.isEmpty || info.st_nlink == 1
        else { throw ProbeError(code: "unsafeDisposableSeed") }
    }
    guard try String(contentsOf: directory.appendingPathComponent(".probe-seed"), encoding: .utf8) == "vmnet-native-probe-v1\n" else {
        throw ProbeError(code: "missingDisposableSeedMarker")
    }
}

private func offlineSelfTest() throws {
    let first = Completion<Int>()
    first.complete(1)
    first.complete(2)
    guard first.wait() == 1 else { throw ProbeError(code: "completionLostFirstResult") }
    let late = Completion<Int>()
    guard late.wait(seconds: 0.001) == nil else { throw ProbeError(code: "completionMissedTimeout") }
    late.complete(3)
    guard late.wait() == 3 else { throw ProbeError(code: "completionLostLateResult") }
    let nested = NSError(domain: "probe.nested", code: 17)
    let fields = errorFields(NSError(domain: "probe.error", code: 9, userInfo: [NSUnderlyingErrorKey: nested, "privateField": "not-emitted"]))
    guard Set(fields.keys) == Set(["errorDomain", "errorCode", "underlyingErrorDomain", "underlyingErrorCode"]),
        fields["errorCode"] as? Int == 9, fields["underlyingErrorCode"] as? Int == 17
    else { throw ProbeError(code: "unsafeErrorProjection") }
    do {
        try validateDisposableSeed(URL(fileURLWithPath: "/dev/null"))
        throw ProbeError(code: "acceptedNonDisposableSeed")
    } catch let error as ProbeError {
        guard error.code == "unsafeDisposableSeed" else { throw error }
    }
    var normal = VMProbeLifecycle()
    normal.startCompleted()
    guard normal.requestFinish(), !normal.requestFinish(), normal.result(cleanupConfirmed: true)["passed"] as? Bool == true else {
        throw ProbeError(code: "cleanupNotIdempotent")
    }
    var timedOut = VMProbeLifecycle()
    timedOut.fail(["error": "vzStartTimedOut"])
    guard !timedOut.requestFinish(), timedOut.startPending, timedOut.finishRequested else { throw ProbeError(code: "stoppedPendingStart") }
    timedOut.startCompleted()
    guard timedOut.requestFinish(), !timedOut.requestFinish(), timedOut.result(cleanupConfirmed: true)["passed"] as? Bool == false else {
        throw ProbeError(code: "lateStartMissedCleanup")
    }
    normal.fail(["error": "lateDisconnect"])
    normal.fail(["error": "laterFailure"])
    let failed = normal.result(cleanupConfirmed: true)
    guard failed["passed"] as? Bool == false, failed["error"] as? String == "lateDisconnect" else { throw ProbeError(code: "lostLateFailure") }
    let cleanupFailure = normal.result(cleanupConfirmed: false, cleanupError: nested)
    guard cleanupFailure["cleanupConfirmed"] as? Bool == false,
        (cleanupFailure["cleanupError"] as? [String: Any])?["errorCode"] as? Int == 17
    else { throw ProbeError(code: "lostCleanupError") }
    emit(["stage": "offline.selfTest", "passed": true, "checks": 10, "nativeNetworkingExecuted": false])
}

private func main() throws -> Int32? {
    let args = Array(CommandLine.arguments.dropFirst())
    if args == ["version"] {
        emit(["probeVersion": 1, "supportedOS": ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26])
        return 0
    }
    if args == ["self-test"] {
        try offlineSelfTest()
        return 0
    }
    guard #available(macOS 26, *) else { throw ProbeError(code: "requiresMacOS26") }
    guard args.count >= 2, args[1].hasPrefix("com.apple.container.vmnet-probe."),
        UUID(uuidString: String(args[1].dropFirst("com.apple.container.vmnet-probe.".count))) != nil
    else { throw ProbeError(code: "invalidTemporaryService") }
    switch args[0] {
    case "owner":
        guard args.count == 4 else { throw ProbeError(code: "invalidOwnerArguments") }
        let owner = try Owner(service: args[1], ipv4: args[2], ipv6: args[3])
        owner.run()
        return nil
    case "case":
        guard args.count == 3 || args.count == 4 else { throw ProbeError(code: "invalidCaseArguments") }
        let method = args[2]
        let crossing = method == "cross-native" || method == "cross-vz"
        let (connection, response, result) = try request(service: args[1], method: crossing ? "export" : method, seed: args.count == 4 ? args[3] : nil)
        defer { xpc_connection_cancel(connection) }
        var outcome = result
        if crossing, result["passed"] as? Bool == true {
            do {
                guard result["ownerPID"] as? Int != Int(getpid()), xpc_connection_get_euid(connection) == geteuid() else {
                    throw ProbeError(code: "invalidOwnerIdentity")
                }
                guard let object = xpc_dictionary_get_value(response, "network") else { throw ProbeError(code: "missingSerializedNetwork") }
                let reference = try imported(object)
                if method == "cross-vz" {
                    guard args.count == 4 else { throw ProbeError(code: "missingDisposableSeed") }
                    var count = 0
                    guard let bytes = xpc_dictionary_get_data(response, "identity", &count), count > 0, count <= 65536 else {
                        throw ProbeError(code: "missingTestIdentity")
                    }
                    outcome = VMProbe().run(reference: reference, seed: args[3], identity: Data(bytes: bytes, count: count))
                } else {
                    outcome = nativeInterface(reference)
                }
            } catch {
                outcome = errorFields(error).merging(["passed": false, "cleanupConfirmed": true]) { _, new in new }
            }
            outcome["ownerPID"] = result["ownerPID"]
        }
        emit(outcome.merging(["stage": "case.result", "case": method]) { _, new in new })
        return outcome["passed"] as? Bool == true ? 0 : 1
    default:
        throw ProbeError(code: "unknownCommand")
    }
}

// Native VZ operations run on the main dispatch queue; synchronous vmnet/XPC
// waits use separate queues and never block that queue.
DispatchQueue.global().async {
    do { if let status = try main() { exit(status) } } catch {
        emit(errorFields(error).merging(["stage": "fatal", "passed": false]) { _, new in new })
        exit(1)
    }
}
dispatchMain()
