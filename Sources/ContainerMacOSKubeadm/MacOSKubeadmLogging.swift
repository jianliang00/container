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

import ContainerLog
import Foundation
import Logging

public struct MacOSKubeadmLog: Sendable {
    private let logger: Logger
    private let debugEnabled: Bool

    public init(debugEnabled: Bool = false) {
        var logger = Logger(label: "container-macos-kubeadm", factory: { _ in StderrLogHandler() })
        logger.logLevel = debugEnabled ? .debug : .info
        self.logger = logger
        self.debugEnabled = debugEnabled
    }

    public func step(_ index: Int, total: Int, _ message: String) {
        logger.info(Logger.Message(stringLiteral: "[\(index)/\(total)] \(message)"))
    }

    public func info(_ message: String) {
        logger.info(Logger.Message(stringLiteral: message))
    }

    public func warning(_ message: String) {
        logger.warning("warning: \(message)")
    }

    public func debug(_ message: String) {
        guard debugEnabled else {
            return
        }
        logger.debug(Logger.Message(stringLiteral: message))
    }
}
