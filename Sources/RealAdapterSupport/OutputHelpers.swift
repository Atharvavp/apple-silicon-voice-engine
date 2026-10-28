import AdapterContracts
import BenchmarkSupport
import Foundation
import os

// MARK: - Final speaker timeline projection

/// Where a native segment boundary is expressed: model output frames (exact) or seconds (rounded).
public enum NativeTime: Sendable, Equatable {
    case frame(Int64, samplesPerFrame: Int64)
    case seconds(Double)

    /// Nearest stream sample at `rate`; frames convert exactly.
    public func sample(rate: Int64) -> Int64 {
        switch self {
        case let .frame(index, samplesPerFrame): return index * samplesPerFrame
        case let .seconds(value): return Int64((value * Double(rate)).rounded())
        }
    }
}

/// One segment of a backend's complete final timeline. `slot` is the model's speaker slot.
public struct NativeSpeakerSegment: Sendable, Equatable {
    public let slot: Int
    public let start: NativeTime
    public let end: NativeTime

    public init(slot: Int, start: NativeTime, end: NativeTime) {
        self.slot = slot
        self.start = start
        self.end = end
    }
}

/// A speaker segment ready for the sink.
public struct ProjectedSpeakerSegment: Sendable, Equatable {
    public let segmentID: String
    public let speakerID: String
    public let interval: SampleInterval

    public init(segmentID: String, speakerID: String, interval: SampleInterval) {
        self.segmentID = segmentID
        self.speakerID = speakerID
        self.interval = interval
    }
}

/// Result of projecting a native final timeline onto the stream's sample grid.
public struct TimelineProjection: Sendable, Equatable {
    public let segments: [ProjectedSpeakerSegment]
    /// Samples removed past the stream end (declared EOS padding / float edge excess).
    public let clippedTailSamples: Int64
    /// Native segments lying entirely inside the tolerated tail, dropped.
    public let droppedTailSegments: Int
    /// Same-speaker native overlaps merged (union-preserving).
    public let mergedSameSpeakerOverlaps: Int
}

public enum TimelineProjectionError: Error, Equatable, CustomStringConvertible {
    case invalidRange(slot: Int, start: Int64, end: Int64)
    case beyondTolerance(slot: Int, end: Int64, duration: Int64, tolerance: Int64)
    case unionMismatch(String)

    public var description: String {
        switch self {
        case let .invalidRange(slot, start, end):
            return "native segment for slot \(slot) quantizes to an invalid range [\(start), \(end))"
        case let .beyondTolerance(slot, end, duration, tolerance):
            return "native segment for slot \(slot) ends at sample \(end), more than the declared tail tolerance \(tolerance) past the stream's \(duration) samples"
        case let .unionMismatch(detail):
            return "emitted interval union differs from the native final timeline: \(detail)"
        }
    }
}

public enum FinalTimelineProjector {
    /// Speaker IDs are the model's slot numbers (`spk0`...); not identities, never re-clustered.
    public static func speakerID(slot: Int) -> String { "spk\(slot)" }

    /// Quantizes the complete native timeline to half-open sample ranges, clips only the
    /// declared tail excess, merges same-speaker overlaps (union-preserving), keeps
    /// different-speaker overlap, assigns unique IDs, and proves the emitted union per
    /// speaker equals the native union clipped to the stream.
    public static func project(_ native: [NativeSpeakerSegment], rate: Int64, durationSamples: Int64,
                               tailToleranceSamples: Int64) throws -> TimelineProjection {
        var bySlot: [Int: [(Int64, Int64)]] = [:]
        var clipped: Int64 = 0
        var dropped = 0
        for segment in native {
            let start = segment.start.sample(rate: rate)
            let end = segment.end.sample(rate: rate)
            guard segment.slot >= 0, start >= 0, end > start else {
                throw TimelineProjectionError.invalidRange(slot: segment.slot, start: start, end: end)
            }
            guard end <= durationSamples + tailToleranceSamples else {
                throw TimelineProjectionError.beyondTolerance(slot: segment.slot, end: end, duration: durationSamples,
                                                              tolerance: tailToleranceSamples)
            }
            if start >= durationSamples {
                dropped += 1
                clipped += end - start
                continue
            }
            if end > durationSamples { clipped += end - durationSamples }
            bySlot[segment.slot, default: []].append((start, min(end, durationSamples)))
        }
        var merged = 0
        var output: [(slot: Int, start: Int64, end: Int64)] = []
        for (slot, ranges) in bySlot {
            let union = Self.union(ranges)
            merged += ranges.count - union.count - Self.abuttingJoins(ranges)
            output.append(contentsOf: union.map { (slot, $0.0, $0.1) })
        }
        output.sort { ($0.start, $0.end, $0.slot) < ($1.start, $1.end, $1.slot) }
        let segments = try output.enumerated().map { offset, item in
            ProjectedSpeakerSegment(segmentID: String(format: "seg-%06d", offset + 1),
                                    speakerID: speakerID(slot: item.slot),
                                    interval: try SampleInterval(start: item.start, end: item.end))
        }
        try verifyUnion(native: native, emitted: segments, rate: rate, durationSamples: durationSamples)
        return TimelineProjection(segments: segments, clippedTailSamples: clipped, droppedTailSegments: dropped,
                                  mergedSameSpeakerOverlaps: max(0, merged))
    }

    /// Independent check: per speaker, union(emitted) == union(native ∩ [0, duration)).
    public static func verifyUnion(native: [NativeSpeakerSegment], emitted: [ProjectedSpeakerSegment], rate: Int64,
                                   durationSamples: Int64) throws {
        var expected: [String: [(Int64, Int64)]] = [:]
        for segment in native {
            let start = segment.start.sample(rate: rate)
            let end = min(segment.end.sample(rate: rate), durationSamples)
            if start < end { expected[speakerID(slot: segment.slot), default: []].append((start, end)) }
        }
        var actual: [String: [(Int64, Int64)]] = [:]
        for segment in emitted { actual[segment.speakerID, default: []].append((segment.interval.start, segment.interval.end)) }
        guard Set(expected.keys) == Set(actual.keys) else {
            throw TimelineProjectionError.unionMismatch("speakers \(expected.keys.sorted()) vs \(actual.keys.sorted())")
        }
        for (speaker, ranges) in expected {
            let lhs = union(ranges), rhs = union(actual[speaker] ?? [])
            guard lhs.elementsEqual(rhs, by: { $0 == $1 }) else {
                throw TimelineProjectionError.unionMismatch("speaker \(speaker): \(lhs.count) native vs \(rhs.count) emitted intervals")
            }
        }
        guard Set(emitted.map(\.segmentID)).count == emitted.count else {
            throw TimelineProjectionError.unionMismatch("duplicate segment IDs")
        }
    }

    /// Sorted union of half-open ranges; touching ranges join.
    public static func union(_ ranges: [(Int64, Int64)]) -> [(Int64, Int64)] {
        var result: [(Int64, Int64)] = []
        for range in ranges.sorted(by: { $0 < $1 }) {
            if let last = result.last, range.0 <= last.1 {
                result[result.count - 1].1 = max(last.1, range.1)
            } else {
                result.append(range)
            }
        }
        return result
    }

    /// Joins caused by exactly touching (not overlapping) same-speaker ranges.
    private static func abuttingJoins(_ ranges: [(Int64, Int64)]) -> Int {
        let sorted = ranges.sorted(by: { $0 < $1 })
        var joins = 0
        var end: Int64 = .min
        for range in sorted {
            if range.0 == end { joins += 1 }
            end = max(end, range.1)
        }
        return joins
    }
}

// MARK: - Recording-granularity transcript assembly

/// A transcript observation reported by a streaming ASR backend.
public enum ASRNativeUpdate: Sendable, Equatable {
    /// The backend's whole-recording hypothesis so far (FluidAudio partial callbacks).
    case cumulative(String)
    /// Text of one native segment, keyed by its segment index (speech-swift sessions).
    /// A non-final update replaces that segment's current partial; a final one fixes it.
    case segment(index: Int, text: String, isFinal: Bool)
}

/// Builds one untimed recording hypothesis from genuine backend updates. It never
/// deduplicates substrings: repeated utterances in different segments are preserved.
public struct RecordingTranscriptAccumulator: Sendable {
    public enum Mode: Sendable { case cumulative, segmented }

    public let mode: Mode
    private var cumulativeText = ""
    private var finalizedSegments: [Int: String] = [:]
    private var openSegment: (index: Int, text: String)?
    public private(set) var lastHypothesis = ""

    public init(mode: Mode) { self.mode = mode }

    /// Applies an update; returns the new recording hypothesis when it changed.
    public mutating func apply(_ update: ASRNativeUpdate) throws -> String? {
        switch (mode, update) {
        case (.cumulative, .cumulative(let text)):
            cumulativeText = text
        case let (.segmented, .segment(index, text, isFinal)):
            guard index >= 0, finalizedSegments[index] == nil else {
                throw ValidationError("asr", "segment \(index) update after its final")
            }
            if let open = openSegment, index < open.index {
                throw ValidationError("asr", "segment index went backwards (\(index) after \(open.index))")
            }
            if isFinal {
                finalizedSegments[index] = text
                if openSegment?.index == index { openSegment = nil }
            } else {
                // A newer segment supersedes an open partial the backend never finalized.
                openSegment = (index, text)
            }
        default:
            throw ValidationError("asr", "update \(update) does not match accumulator mode \(mode)")
        }
        let hypothesis = currentText()
        guard hypothesis != lastHypothesis else { return nil }
        lastHypothesis = hypothesis
        return hypothesis
    }

    /// Finalized segments in index order, then the open partial (if any).
    public func currentText() -> String {
        switch mode {
        case .cumulative:
            return Self.normalizeSpaces(cumulativeText)
        case .segmented:
            var parts = finalizedSegments.keys.sorted().compactMap { finalizedSegments[$0] }
            if let open = openSegment { parts.append(open.text) }
            return Self.normalizeSpaces(parts.joined(separator: " "))
        }
    }

    /// Finalized text only (what the recording final reports after end of stream).
    public func finalizedText() -> String {
        switch mode {
        case .cumulative: return Self.normalizeSpaces(cumulativeText)
        case .segmented: return Self.normalizeSpaces(finalizedSegments.keys.sorted().compactMap { finalizedSegments[$0] }
                                                        .joined(separator: " "))
        }
    }

    public var openSegmentIndex: Int? { openSegment?.index }

    /// Trims and collapses runs of whitespace only; no other text change.
    static func normalizeSpaces(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

// MARK: - Bounded callback mailbox

/// Thread-safe bounded FIFO for synchronous SDK callbacks. The owner drains it after
/// each awaited backend call; overflow is recorded and fails the attempt, never drops silently.
public final class CallbackMailbox<Element: Sendable>: Sendable {
    private struct State: Sendable {
        var items: [Element] = []
        var overflowed = false
        var closed = false
    }

    public let capacity: Int
    private let state = OSAllocatedUnfairLock(initialState: State())

    public init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    /// Returns false (and marks overflow) when full; late posts after `close` are counted as overflow too.
    @discardableResult
    public func post(_ element: Element) -> Bool {
        state.withLock { s in
            guard !s.closed, s.items.count < capacity else {
                s.overflowed = true
                return false
            }
            s.items.append(element)
            return true
        }
    }

    public func drain() -> (items: [Element], overflowed: Bool) {
        state.withLock { s in
            defer { s.items.removeAll(keepingCapacity: true) }
            return (s.items, s.overflowed)
        }
    }

    public func close() { state.withLock { $0.closed = true } }

    public var pendingCount: Int { state.withLock { $0.items.count } }
}
