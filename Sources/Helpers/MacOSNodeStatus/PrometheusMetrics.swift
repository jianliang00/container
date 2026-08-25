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

enum PrometheusMetricType: String, Sendable {
    case counter
    case gauge
}

struct PrometheusSample: Sendable, Equatable {
    var labels: [String: String]
    var value: String
}

struct PrometheusMetricFamily: Sendable, Equatable {
    var name: String
    var help: String
    var type: PrometheusMetricType
    var samples: [PrometheusSample]
}

struct PrometheusMetrics: Sendable {
    private var families: [String: PrometheusMetricFamily] = [:]

    mutating func gauge(
        _ name: String,
        help: String,
        labels: [String: String] = [:],
        value: Bool
    ) {
        gauge(name, help: help, labels: labels, value: value ? 1 : 0)
    }

    mutating func gauge<T: BinaryInteger>(
        _ name: String,
        help: String,
        labels: [String: String] = [:],
        value: T
    ) {
        add(name, help: help, type: .gauge, labels: labels, value: String(value))
    }

    mutating func counter<T: BinaryInteger>(
        _ name: String,
        help: String,
        labels: [String: String] = [:],
        value: T
    ) {
        precondition(name.hasSuffix("_total"), "Prometheus counters must use the _total suffix")
        add(name, help: help, type: .counter, labels: labels, value: String(value))
    }

    func rendered() -> String {
        var lines: [String] = []
        for family in families.values.sorted(by: { $0.name < $1.name }) {
            lines.append("# HELP \(family.name) \(Self.escapeHelp(family.help))")
            lines.append("# TYPE \(family.name) \(family.type.rawValue)")
            for sample in family.samples.sorted(by: Self.sampleLessThan) {
                let labels = Self.renderLabels(sample.labels)
                lines.append("\(family.name)\(labels) \(sample.value)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private mutating func add(
        _ name: String,
        help: String,
        type: PrometheusMetricType,
        labels: [String: String],
        value: String
    ) {
        precondition(Self.isMetricName(name), "invalid Prometheus metric name")
        precondition(labels.keys.allSatisfy(Self.isLabelName), "invalid Prometheus label name")
        if let existing = families[name] {
            precondition(existing.help == help && existing.type == type, "metric family metadata changed")
        } else {
            families[name] = PrometheusMetricFamily(name: name, help: help, type: type, samples: [])
        }
        families[name]!.samples.append(PrometheusSample(labels: labels, value: value))
    }

    private static func renderLabels(_ labels: [String: String]) -> String {
        guard !labels.isEmpty else {
            return ""
        }
        let body = labels.keys.sorted().map { key in
            "\(key)=\"\(escapeLabelValue(labels[key]!))\""
        }.joined(separator: ",")
        return "{\(body)}"
    }

    private static func escapeHelp(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    private static func escapeLabelValue(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func sampleLessThan(_ left: PrometheusSample, _ right: PrometheusSample) -> Bool {
        let leftLabels = left.labels.keys.sorted().map { "\($0)=\(left.labels[$0]!)" }.joined(separator: "\u{0}")
        let rightLabels = right.labels.keys.sorted().map { "\($0)=\(right.labels[$0]!)" }.joined(separator: "\u{0}")
        if leftLabels != rightLabels {
            return leftLabels < rightLabels
        }
        return left.value < right.value
    }

    private static func isMetricName(_ value: String) -> Bool {
        value.range(of: #"\A[a-zA-Z_:][a-zA-Z0-9_:]*\z"#, options: .regularExpression) != nil
    }

    private static func isLabelName(_ value: String) -> Bool {
        value.range(of: #"\A[a-zA-Z_][a-zA-Z0-9_]*\z"#, options: .regularExpression) != nil
    }
}
