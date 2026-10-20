import Foundation

/// Typed audio failures (plan G3 exit 4 / dataset exit 3). `caseName` is the
/// stable identifier used by fixtures (`expected_error`) and tests.
public struct AudioError: Error, CustomStringConvertible, Equatable {
    public enum Kind: String, Sendable, CaseIterable {
        case notRIFF, notWAVE, truncated, unsupportedContainer, missingFormatChunk, missingDataChunk
        case unsupportedEncoding, unsupportedChannelCount, invalidFormat, nonFiniteSample
        case decodeFailed, conversionFailed, conversionContract, io
    }

    public let kind: Kind
    public let path: String
    public let detail: String

    public init(_ kind: Kind, _ path: String, _ detail: String) {
        self.kind = kind
        self.path = path
        self.detail = detail
    }

    public var caseName: String { kind.rawValue }
    public var description: String { "\(kind.rawValue): \(detail) [\(path)]" }
}
