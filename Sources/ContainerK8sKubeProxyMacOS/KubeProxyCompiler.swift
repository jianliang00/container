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

            guard isClusterIPService(spec) else {
                continue
            }

            guard let clusterIP = ipv4ClusterIP(spec) else {
                issues.append(KubeProxyCompileIssue(id: "service/\(serviceID)/cluster-ip", message: "skipped Service \(serviceID) without an IPv4 ClusterIP"))
                continue
            }

            let serviceSlices = (endpointSlicesByService[serviceName] ?? [])
                .filter { $0.metadata.namespace == namespace && $0.addressType == "IPv4" }

            for servicePort in spec.ports {
                guard validPort(servicePort.port) else {
                    issues.append(KubeProxyCompileIssue(id: "service/\(serviceID)/port", message: "skipped invalid Service port \(servicePort.port)"))
                    continue
                }
                let protocolName = servicePort.protocolName ?? .tcp
                let backendResult = resolveBackends(
                    servicePort: servicePort,
                    protocolName: protocolName,
                    endpointSlices: serviceSlices,
                    nodeName: nodeName,
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
                        clusterIP: clusterIP,
                        servicePort: servicePort.port,
                        backends: backends
                    )
                )
            }
        }

        return KubeProxyRuleSet(generation: generation, rules: rules.sorted(), issues: issues.sorted())
    }

    private static func isClusterIPService(_ spec: KubeProxyServiceSpec) -> Bool {
        let type = spec.type ?? "ClusterIP"
        return type == "ClusterIP"
    }

    private static func ipv4ClusterIP(_ spec: KubeProxyServiceSpec) -> String? {
        let candidates = (spec.clusterIPs ?? []) + [spec.clusterIP].compactMap { $0 }
        return candidates.first { candidate in
            candidate != "None" && isIPv4Literal(candidate)
        }
    }

    private static func resolveBackends(
        servicePort: KubeProxyServicePort,
        protocolName: KubeProxyProtocol,
        endpointSlices: [KubeProxyEndpointSlice],
        nodeName: String,
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
                if let endpointNode = endpoint.nodeName, endpointNode != nodeName {
                    continue
                }
                for address in endpoint.addresses where isIPv4Literal(address) {
                    backends.append(KubeProxyBackend(ip: address, port: endpointPort))
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

    private static func isIPv4Literal(_ value: String) -> Bool {
        var address = in_addr()
        return value.withCString { pointer in
            inet_pton(AF_INET, pointer, &address) == 1
        }
    }
}

extension Array {
    fileprivate var single: Element? {
        count == 1 ? self[0] : nil
    }
}
