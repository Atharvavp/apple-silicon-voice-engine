import AdapterContracts
import AudioCore
import BenchmarkSupport
import Foundation
import Replay

/// Typed run failure carrying the plan G3 category, the lifecycle stage it
/// happened in, and a secondary cleanup diagnostic that never replaces the
/// primary cause.
public struct ExperimentError: Error, CustomStringConvertible {
    public let category: ErrorCategory
    public let stage: RunState
    public let message: String
    public var cleanupNote: String?

    public init(_ category: ErrorCategory, stage: RunState, _ message: String) {
        self.category = category
        self.stage = stage
        self.message = message
    }

    public var description: String { "\(category.rawValue) at \(stage.rawValue): \(message)" }

    public var failure: RunFailure {
        let note = cleanupNote.map { " [cleanup: \($0)]" } ?? ""
        return RunFailure(category: category, stage: stage, message: message + note)
    }

    /// Plan G3 exit codes.
    public var exitCode: Int32 { ExitCodes.code(for: category) }

    /// Classifies any error thrown during a run stage.
    public static func classify(_ error: Error, stage: RunState) -> ExperimentError {
        switch error {
        case let error as ExperimentError:
            return error
        case is CancellationError:
            return ExperimentError(.cancelled, stage: stage, "run cancelled")
        case let error as AudioError:
            return ExperimentError(error.kind == .io ? .recorder : .audio, stage: stage, error.description)
        case let error as AdapterError:
            return ExperimentError(.runtime, stage: stage, error.description)
        case let error as QueueError:
            return ExperimentError(.runtime, stage: stage, error.description)
        case let error as CoverageError:
            return ExperimentError(.runtime, stage: stage, error.description)
        case let error as RecorderError:
            return ExperimentError(.recorder, stage: stage, error.description)
        case let error as ValidationError:
            return ExperimentError(.runtime, stage: stage, "invariant violated: \(error)")
        default:
            return ExperimentError(.runtime, stage: stage, String(describing: error))
        }
    }
}

public enum ExitCodes {
    public static let success: Int32 = 0
    public static let invalidInput: Int32 = 2
    public static let dataset: Int32 = 3
    public static let audio: Int32 = 4
    public static let runtime: Int32 = 5
    public static let recorder: Int32 = 6
    public static let analysis: Int32 = 7
    public static let incompatible: Int32 = 8
    public static let validation: Int32 = 9
    public static let interrupted: Int32 = 130

    public static func code(for category: ErrorCategory) -> Int32 {
        switch category {
        case .invalidInput: return invalidInput
        case .dataset: return dataset
        case .audio: return audio
        case .runtime: return runtime
        case .recorder: return recorder
        case .analysis: return analysis
        case .incompatible: return incompatible
        case .validation: return validation
        case .cancelled: return interrupted
        }
    }
}

/// Recorder failures (disk, permission, oversized record, output ceiling, use after freeze).
public struct RecorderError: Error, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { "recorder: \(message)" }
}
