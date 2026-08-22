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

public enum KubeProxyCompiler {
    private struct ServiceClusterIP: Hashable {
        var family: KubeProxyAddressFamily
        var address: String
    }

    public static func compile(
        snapshot: KubeProxySnapshot,
        nodeName: String,
        generation: Int = 0
    ) -> KubeProxyRuleSet {
        var rules: [KubeProxyServiceRule] = []
        var issues: [KubeProxyCompileIssue] = []
        let endpointSlicesByService = Dictionary(grouping: snapshot.endpointSlices) { slice in
            slice.metadata.labels?["kubernetes.io/service-name"] ?? ""
        }

        for service in snapshot.services {
            guard let namespace = service.metadata.namespace, let serviceName = service.metadata.name else {
                issues.append(KubeProxyCompileIssue(id: "service/missing-metadata", message: "skipped Service with missing namespace or name"))
                continue
            }
            let serviceID = "\(namespace)/\(serviceName)"

            guard let spec = service.spec else {
                issues.append(KubeProxyCompileIssue(id: "service/\(serviceID)/missing-spec", message: "skipped Service \(serviceID) with missing spec"))
                continue
            }

            guard supportsClusterIP(spec) else {
                continue
            }

            let clusterIPs = serviceClusterIPs(spec)
            guard !clusterIPs.isEmpty else {
                issues.append(
                    KubeProxyCompileIssue(
                        id: "service/\(serviceID)/cluster-ip",
                        message: "skipped Service \(serviceID) without a valid IPv4 or IPv6 ClusterIP"
                    )
                )
                continue
            }

            for servicePort in spec.ports {
                guard validPort(servicePort.port) else {
                    issues.append(KubeProxyCompileIssue(id: "service/\(serviceID)/port", message: "skipped invalid Service port \(servicePort.port)"))
                    continue
                }
                for clusterIP in clusterIPs {
                    let serviceSlices = (endpointSlicesByService[serviceName] ?? [])
                        .filter {
                            $0.metadata.namespace == namespace
                                && KubeProxyAddressFamily(rawValue: $0.addressType) == clusterIP.family
                        }
                    let protocolName = servicePort.protocolName ?? .tcp
                    let backendResult = resolveBackends(
                        servicePort: servicePort,
                        protocolName: protocolName,
                        family: clusterIP.family,
                        endpointSlices: serviceSlices,
                        nodeName: nodeName,
                        internalTrafficPolicy: spec.internalTrafficPolicy ?? .cluster,
                        serviceID: serviceID
                    )
                    issues.append(contentsOf: backendResult.issues)

                    let backends = Array(Set(backendResult.backends)).sorted()
                    guard !backends.isEmpty else {
                        continue
                    }

                    let distinctPorts = Set(backends.map(\.port))
                    guard distinctPorts.count == 1 else {
                        issues.append(
                            KubeProxyCompileIssue(
                                id: "service/\(serviceID)/\(servicePort.name ?? "\(servicePort.port)")/heterogeneous-backend-ports",
                                message: "skipped Service \(serviceID) port \(servicePort.port) because PF backend groups require one backend port"
                            )
                        )
                        continue
                    }

                    rules.append(
                        KubeProxyServiceRule(
                            namespace: namespace,
                            serviceName: serviceName,
                            portName: servicePort.name,
                            protocolName: protocolName,
                            family: clusterIP.family,
                            clusterIP: clusterIP.address,
                            servicePort: servicePort.port,
                            backends: backends
                        )
                    )
                }
            }
        }

        return KubeProxyRuleSet(generation: generation, rules: rules.sorted(), issues: issues.sorted())
    }

    private static func supportsClusterIP(_ spec: KubeProxyServiceSpec) -> Bool {
        switch spec.type ?? "ClusterIP" {
        case "ClusterIP", "NodePort", "LoadBalancer":
            true
        default:
            false
        }
    }

    private static func serviceClusterIPs(_ spec: KubeProxyServiceSpec) -> [ServiceClusterIP] {
        let candidates = (spec.clusterIPs ?? []) + [spec.clusterIP].compactMap { $0 }
        var seen: Set<ServiceClusterIP> = []
        return candidates.compactMap { candidate in
            guard candidate != "None", let family = addressFamily(of: candidate) else {
                return nil
            }
            let clusterIP = ServiceClusterIP(family: family, address: candidate)
            guard seen.insert(clusterIP).inserted else {
                return nil
            }
            return clusterIP
        }
    }

    private static func resolveBackends(
        servicePort: KubeProxyServicePort,
        protocolName: KubeProxyProtocol,
        family: KubeProxyAddressFamily,
        endpointSlices: [KubeProxyEndpointSlice],
        nodeName: String,
        internalTrafficPolicy: KubeProxyInternalTrafficPolicy,
        serviceID: String
    ) -> (backends: [KubeProxyBackend], issues: [KubeProxyCompileIssue]) {
        var backends: [KubeProxyBackend] = []
        var issues: [KubeProxyCompileIssue] = []

        for endpointSlice in endpointSlices {
            guard
                let endpointPort = resolveEndpointPort(
                    servicePort: servicePort,
                    protocolName: protocolName,
                    endpointSlice: endpointSlice
                )
            else {
                issues.append(
                    KubeProxyCompileIssue(
                        id: "service/\(serviceID)/\(servicePort.name ?? "\(servicePort.port)")/missing-endpoint-port",
                        message: "skipped EndpointSlice \(endpointSlice.metadata.name ?? "<unknown>") because no matching endpoint port exists"
                    )
                )
                continue
            }
            guard validPort(endpointPort) else {
                issues.append(
                    KubeProxyCompileIssue(
                        id: "service/\(serviceID)/\(servicePort.name ?? "\(servicePort.port)")/invalid-endpoint-port",
                        message: "skipped EndpointSlice \(endpointSlice.metadata.name ?? "<unknown>") with invalid endpoint port \(endpointPort)"
                    )
                )
                continue
            }

            for endpoint in endpointSlice.endpoints {
                guard endpoint.conditions?.isUsable ?? true else {
                    continue
                }
                if internalTrafficPolicy == .local, endpoint.nodeName != nodeName {
                    continue
                }
                for address in endpoint.addresses where addressFamily(of: address) == family {
                    backends.append(KubeProxyBackend(family: family, ip: address, port: endpointPort))
                }
            }
        }

        return (backends, issues)
    }

    private static func resolveEndpointPort(
        servicePort: KubeProxyServicePort,
        protocolName: KubeProxyProtocol,
        endpointSlice: KubeProxyEndpointSlice
    ) -> Int? {
        if case .int(let targetPort) = servicePort.targetPort {
            return targetPort
        }

        let matchingPorts = endpointSlice.ports.filter { port in
            (port.protocolName ?? .tcp) == protocolName
        }

        if case .string(let targetPortName) = servicePort.targetPort {
            return matchingPorts.first { $0.name == targetPortName }?.port
        }

        if let servicePortName = servicePort.name, !servicePortName.isEmpty {
            return matchingPorts.first { $0.name == servicePortName }?.port
        }

        if let singlePort = matchingPorts.single?.port {
            return singlePort
        }

        return servicePort.port
    }

    private static func validPort(_ port: Int) -> Bool {
        port > 0 && port <= 65535
    }

    private static func addressFamily(of value: String) -> KubeProxyAddressFamily? {
        var ipv4Address = in_addr()
        if value.withCString({ inet_pton(AF_INET, $0, &ipv4Address) }) == 1 {
            return .ipv4
        }

        var ipv6Address = in6_addr()
        if value.withCString({ inet_pton(AF_INET6, $0, &ipv6Address) }) == 1 {
            return .ipv6
        }
        return nil
    }
}

extension Array {
    fileprivate var single: Element? {
        count == 1 ? self[0] : nil
    }
}
