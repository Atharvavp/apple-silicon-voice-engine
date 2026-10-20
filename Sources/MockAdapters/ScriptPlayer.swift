import AdapterContracts
import AudioCore
import BenchmarkSupport
import Foundation

/// Union of consumed sample ranges, kept sorted and merged.
struct CoverageSet: Sendable {
    private(set) var ranges: [SampleInterval] = []

    mutating func insert(_ range: SampleInterval) {
        var merged: [SampleInterval] = []
        var current = range
        for existing in ranges {
            if existing.end < current.start || current.end < existing.start {
                merged.append(existing)
            } else {
                current = try! SampleInterval(start: min(existing.start, current.start), end: max(existing.end, current.end))
            }
        }
        merged.append(current)
        ranges = merged.sorted()
    }

    /// Parts of `range` not covered.
    func missing(in range: SampleInterval) -> [SampleInterval] {
        var gaps: [SampleInterval] = []
        var cursor = range.start
        for covered in ranges where covered.end > cursor && covered.start < range.end {
            if covered.start > cursor { gaps.append(try! SampleInterval(start: cursor, end: covered.start)) }
            cursor = max(cursor, covered.end)
        }
        if cursor < range.end { gaps.append(try! SampleInterval(start: cursor, end: range.end)) }
        return gaps
    }
}

/// Shared scripted-emission engine used by both mocks (each mock remains a
/// distinct adapter with its own role). Pending entries are released in script
/// order once their trigger is reached; an entry whose media range was not fully
/// consumed (dropped audio) is suppressed and reported as a diagnostic instead
/// of producing a full-coverage prediction from missing input.
struct ScriptPlayer<Entry: Sendable>: Sendable {
    private var pending: [(trigger: Int64?, range: SampleInterval, entry: Entry)]
    private(set) var coverage = CoverageSet()

    init(_ entries: [(trigger: Int64?, range: SampleInterval, entry: Entry)]) {
        pending = entries
    }

    mutating func consumed(_ range: SampleInterval) { coverage.insert(range) }

    enum Release {
        case emit(Entry, SampleInterval)
        case suppressed(Entry, SampleInterval, missing: [SampleInterval])
    }

    /// Entries released after consuming audio up to `endSample` (or all remaining at flush).
    mutating func release(upTo endSample: Int64?) -> [Release] {
        var released: [Release] = []
        var keep: [(trigger: Int64?, range: SampleInterval, entry: Entry)] = []
        for item in pending {
            let due: Bool
            if let endSample { due = item.trigger.map { $0 <= endSample } ?? false } else { due = true }
            guard due else {
                keep.append(item)
                continue
            }
            let missing = coverage.missing(in: item.range)
            released.append(missing.isEmpty ? .emit(item.entry, item.range) : .suppressed(item.entry, item.range, missing: missing))
        }
        pending = keep
        return released
    }
}

func missingAudioDiagnostic(_ what: String, range: SampleInterval, missing: [SampleInterval], cause: EventCause) -> AdapterEvent {
    let lost = missing.reduce(0) { $0 + $1.end - $1.start }
    return AdapterEvent(.diagnostic(code: "missing_audio",
                                    message: "\(what) suppressed: \(lost) of \(range.end - range.start) required samples were not consumed",
                                    requiredRange: range, missingRanges: missing),
                        media: range, cause: cause)
}

func mockCapabilities(role: AdapterRole, revision: String, sampleRateHz: Int64) throws -> AdapterCapabilities {
    try AdapterCapabilities(
        role: role, revision: revision, sampleRatesHz: [sampleRateHz], channels: 1, frameMultipleSamples: nil,
        incremental: true, emitsPartials: role == .asr, emitsFinals: true,
        transcriptGranularity: role == .asr ? .utterances : nil, requestedPlacement: .cpu,
        observedPlacement: .missing(.unavailable, source: "mock_adapter", reason: "no_backend_execution_probe"))
}
