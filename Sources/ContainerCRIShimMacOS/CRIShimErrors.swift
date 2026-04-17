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

public enum CRIShimErrorKind: String, Sendable, Codable, Equatable {
    case unsupported
    case invalidArgument
    case notFound
    case internalError
}

public struct CRIShimErrorDisposition: Sendable, Equatable {
    public var kind: CRIShimErrorKind
    public var message: String

    public init(kind: CRIShimErrorKind, message: String) {
        self.kind = kind
        self.message = message
    }
}

public enum CRIShimError: Error, Sendable, Equatable, CustomStringConvertible {
    case unsupported(String)
    case invalidArgument(String)
    case notFound(String)
    case internalError(String)

    public var description: String {
        switch self {
        case .unsupported(let message):
            return message
        case .invalidArgument(let message):
            return message
        case .notFound(let message):
            return message
        case .internalError(let message):
            return message
        }
    }

    public var disposition: CRIShimErrorDisposition {
        switch self {
        case .unsupported(let message):
            return CRIShimErrorDisposition(kind: .unsupported, message: message)
        case .invalidArgument(let message):
            return CRIShimErrorDisposition(kind: .invalidArgument, message: message)
        case .notFound(let message):
            return CRIShimErrorDisposition(kind: .notFound, message: message)
        case .internalError(let message):
            return CRIShimErrorDisposition(kind: .internalError, message: message)
        }
    }
}

public enum CRIShimErrorMapper {
    public static func disposition(for error: any Error) -> CRIShimErrorDisposition {
        if let error = error as? CRIShimError {
            return error.disposition
        }

        if let error = error as? CRIShimMetadataStoreError {
            return error.disposition
        }

        if let error = error as? CRIShimValidationError {
            return CRIShimErrorDisposition(kind: .invalidArgument, message: error.description)
        }

        if let error = error as? RuntimeHandlerResolutionError {
            switch error {
            case .invalidConfig(let issues):
                return CRIShimErrorDisposition(kind: .invalidArgument, message: CRIShimValidationError(issues: issues).description)
            case .unknownRuntimeHandler(let handler):
                return CRIShimErrorDisposition(kind: .notFound, message: "unknown runtime handler: \(handler)")
            }
        }

        if let error = error as? CRIShimServerFactoryError {
            switch error {
            case .missingRuntimeEndpoint:
                return CRIShimErrorDisposition(kind: .invalidArgument, message: error.description)
            }
        }

        return CRIShimErrorDisposition(kind: .internalError, message: String(describing: error))
    }
}

public enum CRIShimMetadataKind: String, Codable, Sendable, Equatable {
    case sandbox
    case container
}

public enum CRIShimMetadataStoreError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidArgument(String)
    case notFound(kind: CRIShimMetadataKind, id: String)
    case alreadyExists(kind: CRIShimMetadataKind, id: String)
    case corruptedEntry(kind: CRIShimMetadataKind, id: String, reason: String)
    case internalError(String)

    public var description: String {
        switch self {
        case .invalidArgument(let message):
            return message
        case .notFound(let kind, let id):
            return "\(kind.rawValue) \(id) not found"
        case .alreadyExists(let kind, let id):
            return "\(kind.rawValue) \(id) already exists"
        case .corruptedEntry(let kind, let id, let reason):
            return "corrupted \(kind.rawValue) \(id) entry: \(reason)"
        case .internalError(let message):
            return message
        }
    }

    public var disposition: CRIShimErrorDisposition {
        switch self {
        case .invalidArgument(let message):
            return CRIShimErrorDisposition(kind: .invalidArgument, message: message)
        case .notFound:
            return CRIShimErrorDisposition(kind: .notFound, message: description)
        case .alreadyExists:
            return CRIShimErrorDisposition(kind: .invalidArgument, message: description)
        case .corruptedEntry:
            return CRIShimErrorDisposition(kind: .internalError, message: description)
        case .internalError(let message):
            return CRIShimErrorDisposition(kind: .internalError, message: message)
        }
    }
}
