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
import RuntimeMacOSSidecarShared
import SystemConfiguration

struct GuestSystemNetworkConfigurator {
    struct InterfaceConfiguration: Sendable, Equatable {
        let networkID: String
        let interfaceName: String
        let macAddress: String
        let ipv4Address: String
        let ipv4PrefixLength: UInt8
        let ipv4Gateway: String
        let ipv6Address: String?
        let ipv6PrefixLength: UInt8?
        let ipv6Gateway: String?

        init(
            networkID: String,
            interfaceName: String,
            macAddress: String,
            ipv4Address: String,
            ipv4PrefixLength: UInt8,
            ipv4Gateway: String,
            ipv6Address: String? = nil,
            ipv6PrefixLength: UInt8? = nil,
            ipv6Gateway: String? = nil
        ) {
            self.networkID = networkID
            self.interfaceName = interfaceName
            self.macAddress = macAddress
            self.ipv4Address = ipv4Address
            self.ipv4PrefixLength = ipv4PrefixLength
            self.ipv4Gateway = ipv4Gateway
            self.ipv6Address = ipv6Address
            self.ipv6PrefixLength = ipv6PrefixLength
            self.ipv6Gateway = ipv6Gateway
        }
    }

    struct AppliedInterface: Sendable, Equatable {
        let networkID: String
        let interfaceName: String
        let macAddress: String
        let ipv4Address: String
        let ipv6Address: String?

        init(
            networkID: String,
            interfaceName: String,
            macAddress: String,
            ipv4Address: String,
            ipv6Address: String? = nil
        ) {
            self.networkID = networkID
            self.interfaceName = interfaceName
            self.macAddress = macAddress
            self.ipv4Address = ipv4Address
            self.ipv6Address = ipv6Address
        }
    }

    struct Result: Sendable, Equatable {
        let interfaces: [AppliedInterface]
        let effectiveDNS: MacOSGuestEffectiveDNSConfiguration?
    }

    private struct ProtocolSnapshot {
        let configuration: CFDictionary?
        let enabled: Bool
    }

    private struct ServiceSnapshot {
        let service: SCNetworkService
        let created: Bool
        let addedToSet: Bool
        let enabled: Bool
        let ipv4: ProtocolSnapshot?
        let ipv6: ProtocolSnapshot?
        let dns: ProtocolSnapshot?
    }

    private struct ConfiguredInterface {
        let request: InterfaceConfiguration
        let service: SCNetworkService
        let serviceID: String
        let isPrimary: Bool
    }

    static func apply(
        interfaces: [InterfaceConfiguration],
        primaryInterfaceIndex: Int,
        dns: MacOSGuestDNSConfiguration?
    ) throws -> Result {
        guard !interfaces.isEmpty else {
            return Result(interfaces: [], effectiveDNS: nil)
        }
        for interface in interfaces {
            _ = try requestedIPv6Configuration(interface)
        }

        guard
            let preferences = SCPreferencesCreate(
                nil,
                "container-macos-guest-agent" as CFString,
                nil
            )
        else {
            throw makeSystemConfigurationError("create preferences session")
        }
        guard lockPreferences(preferences) else {
            throw makeSystemConfigurationError("lock network preferences")
        }
        defer {
            SCPreferencesUnlock(preferences)
        }

        let setResult = try currentNetworkSet(in: preferences)
        let networkSet = setResult.set
        var snapshots: [ServiceSnapshot] = []

        do {
            let primaryIndex = min(max(primaryInterfaceIndex, 0), interfaces.count - 1)
            var configured: [ConfiguredInterface] = []

            for (index, interface) in interfaces.enumerated() {
                let serviceResult = try networkService(
                    for: interface.interfaceName,
                    preferences: preferences,
                    networkSet: networkSet
                )
                let service = serviceResult.service
                snapshots.append(
                    ServiceSnapshot(
                        service: service,
                        created: serviceResult.created,
                        addedToSet: serviceResult.addedToSet,
                        enabled: SCNetworkServiceGetEnabled(service),
                        ipv4: protocolSnapshot(service: service, type: kSCNetworkProtocolTypeIPv4),
                        ipv6: protocolSnapshot(service: service, type: kSCNetworkProtocolTypeIPv6),
                        dns: protocolSnapshot(service: service, type: kSCNetworkProtocolTypeDNS)
                    )
                )

                guard SCNetworkServiceSetEnabled(service, true) else {
                    throw makeSystemConfigurationError("enable network service for \(interface.interfaceName)")
                }
                try setProtocolConfiguration(
                    service: service,
                    type: kSCNetworkProtocolTypeIPv4,
                    configuration: ipv4ConfigurationDictionary(
                        for: interface,
                        includeDefaultRoute: index == primaryIndex
                    ),
                    enabled: true
                )
                if try requestedIPv6Configuration(interface) != nil {
                    try setProtocolConfiguration(
                        service: service,
                        type: kSCNetworkProtocolTypeIPv6,
                        configuration: try ipv6ConfigurationDictionary(
                            for: interface,
                            includeDefaultRoute: index == primaryIndex
                        ),
                        enabled: true
                    )
                } else if SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeIPv6) != nil {
                    try disableProtocolConfiguration(
                        service: service,
                        type: kSCNetworkProtocolTypeIPv6
                    )
                }

                if index == primaryIndex, let dns {
                    try setProtocolConfiguration(
                        service: service,
                        type: kSCNetworkProtocolTypeDNS,
                        configuration: dnsConfigurationDictionary(for: dns),
                        enabled: true
                    )
                } else if dns != nil {
                    try setProtocolConfiguration(
                        service: service,
                        type: kSCNetworkProtocolTypeDNS,
                        configuration: [:],
                        enabled: false
                    )
                }

                guard let serviceID = SCNetworkServiceGetServiceID(service) as String? else {
                    throw makeError("network service for \(interface.interfaceName) has no service identifier")
                }
                configured.append(
                    ConfiguredInterface(
                        request: interface,
                        service: service,
                        serviceID: serviceID,
                        isPrimary: index == primaryIndex
                    )
                )
            }

            guard SCPreferencesCommitChanges(preferences) else {
                throw makeSystemConfigurationError("commit network preferences")
            }
            guard SCPreferencesApplyChanges(preferences) else {
                throw makeSystemConfigurationError("apply network preferences")
            }

            return try waitForEffectiveConfiguration(
                configured,
                primaryInterfaceIndex: primaryIndex,
                dns: dns
            )
        } catch {
            rollback(
                snapshots: snapshots,
                networkSet: networkSet,
                removeNetworkSet: setResult.created,
                preferences: preferences
            )
            throw error
        }
    }

    static func ipv4ConfigurationDictionary(
        for interface: InterfaceConfiguration,
        includeDefaultRoute: Bool = true
    ) -> [String: Any] {
        var configuration: [String: Any] = [
            kSCPropNetIPv4ConfigMethod as String: kSCValNetIPv4ConfigMethodManual as String,
            kSCPropNetIPv4Addresses as String: [interface.ipv4Address],
            kSCPropNetIPv4SubnetMasks as String: [ipv4NetmaskString(prefixLength: interface.ipv4PrefixLength)],
        ]
        if includeDefaultRoute {
            configuration[kSCPropNetIPv4Router as String] = interface.ipv4Gateway
        }
        return configuration
    }

    static func ipv6ConfigurationDictionary(
        for interface: InterfaceConfiguration,
        includeDefaultRoute: Bool = true
    ) throws -> [String: Any] {
        guard let ipv6 = try requestedIPv6Configuration(interface) else {
            throw makeError("IPv6 configuration is not present for \(interface.interfaceName)")
        }
        var configuration: [String: Any] = [
            kSCPropNetIPv6ConfigMethod as String: kSCValNetIPv6ConfigMethodManual as String,
            kSCPropNetIPv6Addresses as String: [ipv6.address],
            kSCPropNetIPv6PrefixLength as String: [Int(ipv6.prefixLength)],
        ]
        if includeDefaultRoute {
            configuration[kSCPropNetIPv6Router as String] = ipv6.gateway
        }
        return configuration
    }

    static func dnsConfigurationDictionary(
        for dns: MacOSGuestDNSConfiguration
    ) -> [String: Any] {
        var configuration: [String: Any] = [
            kSCPropNetDNSServerAddresses as String: dns.nameservers,
            kSCPropNetDNSSearchDomains as String: dns.searchDomains,
        ]
        if let domain = dns.domain, !domain.isEmpty {
            configuration[kSCPropNetDNSDomainName as String] = domain
        }
        if !dns.options.isEmpty {
            configuration[kSCPropNetDNSOptions as String] = dns.options.joined(separator: " ")
        }
        return configuration
    }

    static func effectiveDNSConfiguration(
        serviceID: String,
        interfaceName: String,
        requested: MacOSGuestDNSConfiguration,
        configuredProperties: NSDictionary,
        effectiveProperties: NSDictionary
    ) throws -> MacOSGuestEffectiveDNSConfiguration {
        _ = try validatedDNSProperties(
            requested: requested,
            properties: configuredProperties,
            stateDescription: "configured"
        )
        let effective = try validatedDNSProperties(
            requested: requested,
            properties: effectiveProperties,
            stateDescription: "effective"
        )

        return MacOSGuestEffectiveDNSConfiguration(
            serviceID: serviceID,
            interfaceName: interfaceName,
            nameservers: effective.nameservers,
            domain: effective.domain,
            searchDomains: effective.searchDomains,
            options: effective.options
        )
    }

    private static func validatedDNSProperties(
        requested: MacOSGuestDNSConfiguration,
        properties: NSDictionary,
        stateDescription: String
    ) throws -> (
        nameservers: [String],
        domain: String?,
        searchDomains: [String],
        options: [String]
    ) {
        let nameservers = stringArray(properties[kSCPropNetDNSServerAddresses as String])
        let searchDomains = stringArray(properties[kSCPropNetDNSSearchDomains as String])
        let domain = nonEmptyString(properties[kSCPropNetDNSDomainName as String])
        let options =
            (properties[kSCPropNetDNSOptions as String] as? String)?
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init) ?? []

        guard nameservers == requested.nameservers else {
            throw makeError("\(stateDescription) DNS nameserver mismatch: requested \(requested.nameservers), found \(nameservers)")
        }
        guard searchDomains == requested.searchDomains else {
            throw makeError("\(stateDescription) DNS search domain mismatch: requested \(requested.searchDomains), found \(searchDomains)")
        }
        guard domain == nonEmptyString(requested.domain) else {
            throw makeError("\(stateDescription) DNS domain mismatch: requested \(requested.domain ?? "none"), found \(domain ?? "none")")
        }
        guard options == requested.options else {
            throw makeError("\(stateDescription) DNS option mismatch: requested \(requested.options), found \(options)")
        }

        return (nameservers, domain, searchDomains, options)
    }

    private static func lockPreferences(_ preferences: SCPreferences) -> Bool {
        for attempt in 0..<50 {
            if SCPreferencesLock(preferences, false) {
                return true
            }
            if attempt < 49 {
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        return false
    }

    private static func currentNetworkSet(
        in preferences: SCPreferences
    ) throws -> (set: SCNetworkSet, created: Bool) {
        if let current = SCNetworkSetCopyCurrent(preferences) {
            return (current, false)
        }
        guard let created = SCNetworkSetCreate(preferences) else {
            throw makeSystemConfigurationError("create network set")
        }
        guard SCNetworkSetSetName(created, "Container" as CFString) else {
            throw makeSystemConfigurationError("name network set")
        }
        guard SCNetworkSetSetCurrent(created) else {
            throw makeSystemConfigurationError("select network set")
        }
        return (created, true)
    }

    private static func networkService(
        for interfaceName: String,
        preferences: SCPreferences,
        networkSet: SCNetworkSet
    ) throws -> (service: SCNetworkService, created: Bool, addedToSet: Bool) {
        let services = (SCNetworkServiceCopyAll(preferences) as NSArray?) ?? []
        let setServices = (SCNetworkSetCopyServices(networkSet) as NSArray?) ?? []
        let setServiceIDs = Set(
            setServices.compactMap { value -> String? in
                guard let service = networkService(from: value) else {
                    return nil
                }
                return SCNetworkServiceGetServiceID(service) as String?
            }
        )
        let setServiceNames = Set(
            setServices.compactMap { value -> String? in
                guard let service = networkService(from: value) else {
                    return nil
                }
                return SCNetworkServiceGetName(service) as String?
            }
        )
        let matchingServices = services.compactMap { value -> SCNetworkService? in
            guard let service = networkService(from: value) else {
                return nil
            }
            guard
                let interface = SCNetworkServiceGetInterface(service),
                SCNetworkInterfaceGetBSDName(interface) as String? == interfaceName
            else {
                return nil
            }
            return service
        }

        let existing =
            matchingServices.first {
                guard let serviceID = SCNetworkServiceGetServiceID($0) as String? else {
                    return false
                }
                return setServiceIDs.contains(serviceID)
            } ?? matchingServices.first

        let service: SCNetworkService
        let created: Bool
        if let existing {
            service = existing
            created = false
        } else {
            let availableInterfaces = SCNetworkInterfaceCopyAll() as NSArray
            guard
                let interface = availableInterfaces.compactMap(networkInterface(from:)).first(where: {
                    SCNetworkInterfaceGetBSDName($0) as String? == interfaceName
                })
            else {
                throw makeError("SystemConfiguration interface not found for \(interfaceName)")
            }
            guard let newService = SCNetworkServiceCreate(preferences, interface) else {
                throw makeSystemConfigurationError("create network service for \(interfaceName)")
            }
            guard SCNetworkServiceEstablishDefaultConfiguration(newService) else {
                throw makeSystemConfigurationError("establish network service for \(interfaceName)")
            }
            service = newService
            created = true

            guard let serviceID = SCNetworkServiceGetServiceID(service) as String? else {
                throw makeError("new network service for \(interfaceName) has no service identifier")
            }
            let baseName = "Container \(interfaceName)"
            let serviceName = setServiceNames.contains(baseName) ? "\(baseName) \(serviceID.prefix(8))" : baseName
            guard SCNetworkServiceSetName(service, serviceName as CFString) else {
                throw makeSystemConfigurationError("name network service for \(interfaceName)")
            }
        }

        let serviceID = SCNetworkServiceGetServiceID(service) as String?
        let isInSet = serviceID.map(setServiceIDs.contains) ?? false
        if !isInSet, !SCNetworkSetAddService(networkSet, service) {
            throw makeSystemConfigurationError("add network service for \(interfaceName) to current set")
        }
        return (service, created, !isInSet)
    }

    private static func networkService(from value: Any) -> SCNetworkService? {
        let object = value as AnyObject
        guard CFGetTypeID(object) == SCNetworkServiceGetTypeID() else {
            return nil
        }
        return unsafeDowncast(object, to: SCNetworkService.self)
    }

    private static func networkInterface(from value: Any) -> SCNetworkInterface? {
        let object = value as AnyObject
        guard CFGetTypeID(object) == SCNetworkInterfaceGetTypeID() else {
            return nil
        }
        return unsafeDowncast(object, to: SCNetworkInterface.self)
    }

    private static func setProtocolConfiguration(
        service: SCNetworkService,
        type: CFString,
        configuration: [String: Any],
        enabled: Bool
    ) throws {
        if SCNetworkServiceCopyProtocol(service, type) == nil,
            !SCNetworkServiceAddProtocolType(service, type)
        {
            throw makeSystemConfigurationError("add \(type) network protocol")
        }
        guard let networkProtocol = SCNetworkServiceCopyProtocol(service, type) else {
            throw makeSystemConfigurationError("load \(type) network protocol")
        }
        guard SCNetworkProtocolSetConfiguration(networkProtocol, configuration as CFDictionary) else {
            throw makeSystemConfigurationError("configure \(type) network protocol")
        }
        guard SCNetworkProtocolSetEnabled(networkProtocol, enabled) else {
            throw makeSystemConfigurationError("set \(type) network protocol state")
        }
    }

    private static func disableProtocolConfiguration(
        service: SCNetworkService,
        type: CFString
    ) throws {
        guard let networkProtocol = SCNetworkServiceCopyProtocol(service, type) else {
            return
        }
        guard SCNetworkProtocolSetConfiguration(networkProtocol, nil) else {
            throw makeSystemConfigurationError("clear \(type) network protocol configuration")
        }
        guard SCNetworkProtocolSetEnabled(networkProtocol, false) else {
            throw makeSystemConfigurationError("disable \(type) network protocol")
        }
    }

    private static func protocolSnapshot(
        service: SCNetworkService,
        type: CFString
    ) -> ProtocolSnapshot? {
        guard let networkProtocol = SCNetworkServiceCopyProtocol(service, type) else {
            return nil
        }
        return ProtocolSnapshot(
            configuration: SCNetworkProtocolGetConfiguration(networkProtocol),
            enabled: SCNetworkProtocolGetEnabled(networkProtocol)
        )
    }

    private static func rollback(
        snapshots: [ServiceSnapshot],
        networkSet: SCNetworkSet,
        removeNetworkSet: Bool,
        preferences: SCPreferences
    ) {
        for snapshot in snapshots.reversed() {
            if snapshot.created {
                _ = SCNetworkServiceRemove(snapshot.service)
                continue
            }
            restoreProtocol(snapshot.ipv4, service: snapshot.service, type: kSCNetworkProtocolTypeIPv4)
            restoreProtocol(snapshot.ipv6, service: snapshot.service, type: kSCNetworkProtocolTypeIPv6)
            restoreProtocol(snapshot.dns, service: snapshot.service, type: kSCNetworkProtocolTypeDNS)
            _ = SCNetworkServiceSetEnabled(snapshot.service, snapshot.enabled)
            if snapshot.addedToSet {
                _ = SCNetworkSetRemoveService(networkSet, snapshot.service)
            }
        }
        if removeNetworkSet {
            _ = SCNetworkSetRemove(networkSet)
        }
        _ = SCPreferencesCommitChanges(preferences)
        _ = SCPreferencesApplyChanges(preferences)
    }

    private static func restoreProtocol(
        _ snapshot: ProtocolSnapshot?,
        service: SCNetworkService,
        type: CFString
    ) {
        guard let snapshot else {
            _ = SCNetworkServiceRemoveProtocolType(service, type)
            return
        }
        guard let networkProtocol = SCNetworkServiceCopyProtocol(service, type) else {
            return
        }
        _ = SCNetworkProtocolSetConfiguration(networkProtocol, snapshot.configuration)
        _ = SCNetworkProtocolSetEnabled(networkProtocol, snapshot.enabled)
    }

    private static func waitForEffectiveConfiguration(
        _ configured: [ConfiguredInterface],
        primaryInterfaceIndex: Int,
        dns: MacOSGuestDNSConfiguration?
    ) throws -> Result {
        guard
            let store = SCDynamicStoreCreate(
                nil,
                "container-macos-guest-agent-validation" as CFString,
                nil,
                nil
            )
        else {
            throw makeSystemConfigurationError("create dynamic store session")
        }

        var lastMismatch = "active network state was not published"
        for attempt in 0..<50 {
            do {
                let appliedInterfaces = try configured.map {
                    let ipv4 = try readEffectiveIPv4($0, store: store)
                    let ipv6 = try readEffectiveIPv6($0, store: store)
                    return AppliedInterface(
                        networkID: ipv4.networkID,
                        interfaceName: ipv4.interfaceName,
                        macAddress: ipv4.macAddress,
                        ipv4Address: ipv4.ipv4Address,
                        ipv6Address: ipv6
                    )
                }
                let effectiveDNS: MacOSGuestEffectiveDNSConfiguration?
                if let dns {
                    effectiveDNS = try readEffectiveDNS(
                        configured[primaryInterfaceIndex],
                        requested: dns,
                        store: store
                    )
                } else {
                    effectiveDNS = nil
                }
                return Result(interfaces: appliedInterfaces, effectiveDNS: effectiveDNS)
            } catch {
                lastMismatch = error.localizedDescription
            }

            if attempt < 49 {
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        throw makeError("active SystemConfiguration state did not match the request: \(lastMismatch)")
    }

    private static func readEffectiveIPv4(
        _ configured: ConfiguredInterface,
        store: SCDynamicStore
    ) throws -> AppliedInterface {
        let key = "State:/Network/Service/\(configured.serviceID)/IPv4"
        guard let dictionary = dynamicStoreDictionary(store: store, key: key) else {
            throw makeError("active IPv4 state is missing for service \(configured.serviceID)")
        }

        let request = configured.request
        let addresses = stringArray(dictionary[kSCPropNetIPv4Addresses as String])
        let subnetMasks = stringArray(dictionary[kSCPropNetIPv4SubnetMasks as String])
        let router = dictionary[kSCPropNetIPv4Router as String] as? String
        let interfaceName = dictionary[kSCPropInterfaceName as String] as? String ?? request.interfaceName
        let expectedMask = ipv4NetmaskString(prefixLength: request.ipv4PrefixLength)

        guard addresses.contains(request.ipv4Address) else {
            throw makeError("active IPv4 address mismatch for \(request.interfaceName): \(addresses)")
        }
        guard subnetMasks.contains(expectedMask) else {
            throw makeError("active IPv4 subnet mask mismatch for \(request.interfaceName): \(subnetMasks)")
        }
        if configured.isPrimary {
            guard router == request.ipv4Gateway else {
                throw makeError("active IPv4 router mismatch for \(request.interfaceName): \(router ?? "missing")")
            }
        } else if let router {
            throw makeError("secondary interface \(request.interfaceName) unexpectedly installed router \(router)")
        }
        guard interfaceName == request.interfaceName else {
            throw makeError("active interface mismatch for service \(configured.serviceID): \(interfaceName)")
        }

        return AppliedInterface(
            networkID: request.networkID,
            interfaceName: interfaceName,
            macAddress: request.macAddress,
            ipv4Address: "\(request.ipv4Address)/\(request.ipv4PrefixLength)",
            ipv6Address: nil
        )
    }

    private static func readEffectiveIPv6(
        _ configured: ConfiguredInterface,
        store: SCDynamicStore
    ) throws -> String? {
        guard let expected = try requestedIPv6Configuration(configured.request) else {
            let networkProtocol = SCNetworkServiceCopyProtocol(
                configured.service,
                kSCNetworkProtocolTypeIPv6
            )
            try validateDisabledIPv6State(
                protocolEnabled: networkProtocol.map { SCNetworkProtocolGetEnabled($0) },
                configuredProperties: networkProtocol.flatMap {
                    SCNetworkProtocolGetConfiguration($0).map { $0 as NSDictionary }
                },
                effectiveProperties: dynamicStoreDictionary(
                    store: store,
                    key: "State:/Network/Service/\(configured.serviceID)/IPv6"
                ),
                interfaceName: configured.request.interfaceName
            )
            return nil
        }
        let key = "State:/Network/Service/\(configured.serviceID)/IPv6"
        guard let dictionary = dynamicStoreDictionary(store: store, key: key) else {
            throw makeError("active IPv6 state is missing for service \(configured.serviceID)")
        }

        let request = configured.request
        let addresses = stringArray(dictionary[kSCPropNetIPv6Addresses as String])
        let prefixLengths = integerArray(dictionary[kSCPropNetIPv6PrefixLength as String])
        let router = dictionary[kSCPropNetIPv6Router as String] as? String
        let interfaceName = dictionary[kSCPropInterfaceName as String] as? String ?? request.interfaceName

        guard addresses.contains(where: { ipv6AddressesEqual($0, expected.address) }) else {
            throw makeError("active IPv6 address mismatch for \(request.interfaceName): \(addresses)")
        }
        guard prefixLengths.contains(Int(expected.prefixLength)) else {
            throw makeError("active IPv6 prefix mismatch for \(request.interfaceName): \(prefixLengths)")
        }
        if configured.isPrimary {
            guard let router, ipv6AddressesEqual(router, expected.gateway) else {
                throw makeError("active IPv6 router mismatch for \(request.interfaceName): \(router ?? "missing")")
            }
        } else if let router {
            throw makeError("secondary interface \(request.interfaceName) unexpectedly installed IPv6 router \(router)")
        }
        guard interfaceName == request.interfaceName else {
            throw makeError("active IPv6 interface mismatch for service \(configured.serviceID): \(interfaceName)")
        }

        return "\(expected.address)/\(expected.prefixLength)"
    }

    static func validateDisabledIPv6State(
        protocolEnabled: Bool?,
        configuredProperties: NSDictionary?,
        effectiveProperties: NSDictionary?,
        interfaceName: String
    ) throws {
        if protocolEnabled == true {
            throw makeError("IPv6 protocol remained enabled for \(interfaceName)")
        }
        if configuredProperties != nil {
            throw makeError("static IPv6 configuration remained for \(interfaceName)")
        }
        guard let effectiveProperties else {
            return
        }

        let addresses = stringArray(effectiveProperties[kSCPropNetIPv6Addresses as String])
        let unexpectedAddresses = addresses.filter { !isLinkLocalIPv6Address($0) }
        guard unexpectedAddresses.isEmpty else {
            throw makeError("active IPv6 address remained for \(interfaceName): \(unexpectedAddresses)")
        }

        if let router = nonEmptyString(effectiveProperties[kSCPropNetIPv6Router as String]) {
            throw makeError("active IPv6 router remained for \(interfaceName): \(router)")
        }
    }

    private static func readEffectiveDNS(
        _ configured: ConfiguredInterface,
        requested: MacOSGuestDNSConfiguration,
        store: SCDynamicStore
    ) throws -> MacOSGuestEffectiveDNSConfiguration {
        // Static service DNS is published in Setup:. IPMonitor folds that configuration into
        // State:/Network/Global/DNS; per-service State: DNS is reserved for dynamic sources.
        let configuredKey =
            SCDynamicStoreKeyCreateNetworkServiceEntity(
                nil,
                kSCDynamicStoreDomainSetup,
                configured.serviceID as CFString,
                kSCEntNetDNS
            ) as String
        guard let configuredDictionary = dynamicStoreDictionary(store: store, key: configuredKey) else {
            throw makeError("configured DNS state is missing for service \(configured.serviceID)")
        }

        let effectiveKey =
            SCDynamicStoreKeyCreateNetworkGlobalEntity(
                nil,
                kSCDynamicStoreDomainState,
                kSCEntNetDNS
            ) as String
        guard let effectiveDictionary = dynamicStoreDictionary(store: store, key: effectiveKey) else {
            throw makeError("effective global DNS state is missing")
        }

        return try effectiveDNSConfiguration(
            serviceID: configured.serviceID,
            interfaceName: configured.request.interfaceName,
            requested: requested,
            configuredProperties: configuredDictionary,
            effectiveProperties: effectiveDictionary
        )
    }

    private static func dynamicStoreDictionary(
        store: SCDynamicStore,
        key: String
    ) -> NSDictionary? {
        guard let value = SCDynamicStoreCopyValue(store, key as CFString) else {
            return nil
        }
        return value as? NSDictionary
    }

    private static func stringArray(_ value: Any?) -> [String] {
        (value as? [String]) ?? []
    }

    private static func integerArray(_ value: Any?) -> [Int] {
        guard let values = value as? [NSNumber] else {
            return []
        }
        return values.map(\.intValue)
    }

    private static func requestedIPv6Configuration(
        _ interface: InterfaceConfiguration
    ) throws -> (address: String, prefixLength: UInt8, gateway: String)? {
        switch (interface.ipv6Address, interface.ipv6PrefixLength, interface.ipv6Gateway) {
        case (nil, nil, nil):
            return nil
        case (.some(let address), .some(let prefixLength), .some(let gateway)):
            guard prefixLength == 64,
                let addressBytes = normalizedIPv6Address(address),
                let gatewayBytes = normalizedIPv6Address(gateway),
                usableIPv6Unicast(addressBytes),
                usableIPv6Unicast(gatewayBytes),
                addressBytes != gatewayBytes,
                addressBytes.suffix(8).contains(where: { $0 != 0 }),
                gatewayBytes.suffix(8).contains(where: { $0 != 0 }),
                addressBytes.prefix(8).elementsEqual(gatewayBytes.prefix(8))
            else {
                throw makeError("invalid IPv6 configuration for \(interface.interfaceName)")
            }
            return (address, prefixLength, gateway)
        default:
            throw makeError("incomplete IPv6 configuration for \(interface.interfaceName)")
        }
    }

    private static func ipv6AddressesEqual(_ lhs: String, _ rhs: String) -> Bool {
        normalizedIPv6Address(lhs) == normalizedIPv6Address(rhs)
    }

    private static func normalizedIPv6Address(_ value: String) -> [UInt8]? {
        var address = in6_addr()
        guard value.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else {
            return nil
        }
        return withUnsafeBytes(of: &address) { Array($0) }
    }

    private static func isLinkLocalIPv6Address(_ value: String) -> Bool {
        guard let addressPart = value.split(separator: "%", maxSplits: 1).first else {
            return false
        }
        let unscoped = String(addressPart)
        guard let address = normalizedIPv6Address(unscoped) else {
            return false
        }
        return address[0] == 0xfe && (address[1] & 0xc0) == 0x80
    }

    private static func usableIPv6Unicast(_ address: [UInt8]) -> Bool {
        guard address.count == 16,
            address.contains(where: { $0 != 0 }),
            address[0] != 0xff,
            !(address[0] == 0xfe && (address[1] & 0xc0) == 0x80),
            address != [UInt8](repeating: 0, count: 15) + [1]
        else {
            return false
        }
        let ipv4MappedPrefix = [UInt8](repeating: 0, count: 10) + [0xff, 0xff]
        return !address.prefix(12).elementsEqual(ipv4MappedPrefix)
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func nonEmptyString(_ value: String?) -> String? {
        guard let value, !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func ipv4NetmaskString(prefixLength: UInt8) -> String {
        let bits = Int(prefixLength)
        let value: UInt32 = bits == 0 ? 0 : ~UInt32(0) << (32 - bits)
        return [
            String((value >> 24) & 0xff),
            String((value >> 16) & 0xff),
            String((value >> 8) & 0xff),
            String(value & 0xff),
        ].joined(separator: ".")
    }

    private static func makeSystemConfigurationError(_ action: String) -> NSError {
        let code = SCError()
        return NSError(
            domain: "container.macos.guest-agent.system-configuration",
            code: Int(code),
            userInfo: [
                NSLocalizedDescriptionKey: "failed to \(action): \(String(cString: SCErrorString(code)))"
            ]
        )
    }

    private static func makeError(_ message: String) -> NSError {
        NSError(
            domain: "container.macos.guest-agent.system-configuration",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
