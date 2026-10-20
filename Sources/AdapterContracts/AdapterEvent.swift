import BenchmarkSupport
import Foundation

/// The invocation that produced an output. Lets media and output timing be
/// joined without assuming one event per chunk.
public enum EventCause: Sendable, Equatable {
    case chunk(index: Int64, invocationID: String)
    case flush(invocationID: String)

    public var invocationID: String {
        switch self {
        case .chunk(_, let id), .flush(let id): return id
        }
    }

    public var chunkIndex: Int64? {
        if case .chunk(let index, _) = self { return index }
        return nil
    }
}

/// Typed adapter output (plan D1). The sink adds run/source identity, the
/// emission timestamp, producer sequence and the logical event ID; the
/// recorder adds the global sequence and recorded time.
public enum AdapterOutput: Sendable, Equatable {
    case transcript(utteranceID: String, revision: Int64, text: String, isFinal: Bool)
    case speakerSegment(segmentID: String, speakerID: String)
    /// Non-scoring note, e.g. an output suppressed because its audio was dropped.
    case diagnostic(code: String, message: String, requiredRange: SampleInterval?, missingRanges: [SampleInterval])
}

public struct AdapterEvent: Sendable, Equatable {
    public let output: AdapterOutput
    /// Media range at the stream rate; nil only for untimed (recording-granularity) transcripts and diagnostics.
    public let media: SampleInterval?
    public let cause: EventCause

    public init(_ output: AdapterOutput, media: SampleInterval?, cause: EventCause) {
        self.output = output
        self.media = media
        self.cause = cause
    }

    public var eventType: EventType {
        switch output {
        case .transcript(_, _, _, let isFinal): return isFinal ? .transcriptFinal : .transcriptPartial
        case .speakerSegment: return .speakerSegment
        case .diagnostic: return .adapterDiagnostic
        }
    }

    /// Payload object in the v1 event schema form.
    public func payload(role: AdapterRole, adapterID: String) -> JSONObject {
        switch output {
        case let .transcript(utteranceID, revision, text, isFinal):
            return JSONObject([("utterance_id", .string(utteranceID)), ("revision", .int(revision)),
                               ("text", .string(text)), ("is_final", .bool(isFinal))])
        case let .speakerSegment(segmentID, speakerID):
            return JSONObject([("segment_id", .string(segmentID)), ("speaker_id", .string(speakerID)),
                               ("is_final", .bool(true))])
        case let .diagnostic(code, message, required, missing):
            return JSONObject([("role", .string(role.rawValue)), ("adapter_id", .string(adapterID)),
                               ("code", .string(code)), ("message", .string(message)),
                               ("required_range", required.toJSON()), ("missing_ranges", .array(missing.map { $0.toJSON() }))])
        }
    }
}

/// Output-contract checks applied by every sink before admission (plan D5):
/// media ranges inside the stream, roles emitting only their own outputs,
/// transcript revision rules, unique speaker segment IDs.
///
/// Out-of-order *emission* (a later event describing earlier media) is
/// allowed; invalid revision transitions are not. For one utterance: partial
/// revisions strictly increase, at most one final follows, and nothing follows
/// the final.
public struct AdapterOutputValidator: Sendable {
    private enum UtteranceState { case open(lastRevision: Int64), finalized }

    public let role: AdapterRole
    public let adapterID: String
    public let durationSamples: Int64
    public let transcriptGranularity: TranscriptOutputGranularity?
    private var utterances: [String: UtteranceState] = [:]
    private var segmentIDs: Set<String> = []

    public init(role: AdapterRole, adapterID: String, durationSamples: Int64,
                transcriptGranularity: TranscriptOutputGranularity?) {
        self.role = role
        self.adapterID = adapterID
        self.durationSamples = durationSamples
        self.transcriptGranularity = transcriptGranularity
    }

    public mutating func check(_ event: AdapterEvent) throws {
        if let media = event.media, media.end > durationSamples {
            throw fail(event, "media range [\(media.start), \(media.end)) ends after the stream's \(durationSamples) samples")
        }
        switch event.output {
        case let .transcript(utteranceID, revision, _, isFinal):
            guard role == .asr else { throw fail(event, "a diarization adapter cannot emit transcripts") }
            _ = try Identifiers.validateStableID(utteranceID, path: "utterance_id")
            let untimed = transcriptGranularity == .recording
            guard (event.media == nil) == untimed else {
                throw fail(event, untimed ? "recording-granularity transcripts are untimed and carry no media range"
                                          : "timed transcripts must carry a media range")
            }
            switch utterances[utteranceID] {
            case .finalized?:
                throw fail(event, "utterance \(utteranceID) already has a final; \(isFinal ? "duplicate final" : "partial after final")")
            case .open(let last)? where revision <= last:
                throw fail(event, "utterance \(utteranceID) revision \(revision) does not increase past \(last)")
            default:
                utterances[utteranceID] = isFinal ? .finalized : .open(lastRevision: revision)
            }
        case let .speakerSegment(segmentID, speakerID):
            guard role == .diarization else { throw fail(event, "an ASR adapter cannot emit speaker segments") }
            _ = try Identifiers.validateStableID(segmentID, path: "segment_id")
            _ = try Identifiers.validateStableID(speakerID, path: "speaker_id")
            guard event.media != nil else { throw fail(event, "speaker segments need a media range") }
            guard segmentIDs.insert(segmentID).inserted else { throw fail(event, "duplicate segment_id \(segmentID)") }
        case .diagnostic(let code, _, _, _):
            _ = try Identifiers.validateStableID(code, path: "code")
        }
    }

    /// Utterances that received partials but never a final.
    public var unfinalizedUtterances: [String] {
        utterances.compactMap { id, state in
            if case .open = state { return id }
            return nil
        }.sorted()
    }

    private func fail(_ event: AdapterEvent, _ message: String) -> AdapterError {
        AdapterError(.contract, adapterID: adapterID, stage: .emit, chunkIndex: event.cause.chunkIndex, message)
    }
}
