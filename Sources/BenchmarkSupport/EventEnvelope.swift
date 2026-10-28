import Foundation

/// Event families recognised by schema 1.0 (plan D5, plus `adapter.diagnostic`
/// added in M3 under DEC-008). Unknown types are rejected.
public enum EventType: String, Sendable, CaseIterable {
    case experimentStarted = "experiment.started"
    case experimentRuntimeCompleted = "experiment.runtime_completed"
    case experimentCompleted = "experiment.completed"
    case experimentFailed = "experiment.failed"
    case experimentCancelled = "experiment.cancelled"
    case audioChunkScheduled = "audio.chunk_scheduled"
    case audioChunkDelivered = "audio.chunk_delivered"
    case audioChunkConsumed = "audio.chunk_consumed"
    case audioQueueBackpressure = "audio.queue_backpressure"
    case audioQueueOverflow = "audio.queue_overflow"
    case adapterStarted = "adapter.started"
    case adapterFailed = "adapter.failed"
    case adapterStopped = "adapter.stopped"
    case adapterDiagnostic = "adapter.diagnostic"
    case transcriptPartial = "transcript.partial"
    case transcriptFinal = "transcript.final"
    case speakerSegment = "speaker.segment"
    case stageCompleted = "stage.completed"
    case telemetrySample = "telemetry.sample"

    public var isTerminal: Bool {
        self == .experimentCompleted || self == .experimentFailed || self == .experimentCancelled
    }
}

/// Versioned JSONL envelope (plan D5).
///
/// Clock domains: `monotonic_*` are real run-relative nanoseconds from the
/// run's single `RunClock`, present in every mode; `virtual_emitted_ns` exists
/// only in step mode and is never a latency. `sequence` is assigned by the
/// recorder at admission and is authoritative append order.
public struct EventEnvelope: Sendable, Equatable {
    public init(schemaVersion: String = SchemaVersion.current, eventID: String, runID: String, streamID: String,
                sourceID: String, sequence: Int64, producerID: String, producerSequence: Int64, type: EventType,
                mediaStartSample: Int64?, mediaEndSample: Int64?, sampleRateHz: Int64, monotonicEmittedNS: Int64,
                monotonicRecordedNS: Int64, virtualEmittedNS: Int64?, causeChunkIndex: Int64?, invocationID: String?,
                payload: JSONObject) {
        self.schemaVersion = schemaVersion
        self.eventID = eventID
        self.runID = runID
        self.streamID = streamID
        self.sourceID = sourceID
        self.sequence = sequence
        self.producerID = producerID
        self.producerSequence = producerSequence
        self.type = type
        self.mediaStartSample = mediaStartSample
        self.mediaEndSample = mediaEndSample
        self.sampleRateHz = sampleRateHz
        self.monotonicEmittedNS = monotonicEmittedNS
        self.monotonicRecordedNS = monotonicRecordedNS
        self.virtualEmittedNS = virtualEmittedNS
        self.causeChunkIndex = causeChunkIndex
        self.invocationID = invocationID
        self.payload = payload
    }

    public var schemaVersion: String
    public var eventID: String
    public var runID: String
    public var streamID: String
    public var sourceID: String
    public var sequence: Int64
    public var producerID: String
    public var producerSequence: Int64
    public var type: EventType
    public var mediaStartSample: Int64?
    public var mediaEndSample: Int64?
    public var sampleRateHz: Int64
    public var monotonicEmittedNS: Int64
    public var monotonicRecordedNS: Int64
    public var virtualEmittedNS: Int64?
    public var causeChunkIndex: Int64?
    public var invocationID: String?
    public var payload: JSONObject

    public static let fieldOrder = [
        "schema_version", "event_id", "run_id", "stream_id", "source_id", "sequence", "producer_id",
        "producer_sequence", "type", "media_start_sample", "media_end_sample", "sample_rate_hz",
        "monotonic_emitted_ns", "monotonic_recorded_ns", "virtual_emitted_ns", "cause_chunk_index",
        "invocation_id", "payload",
    ]

    public static func read(_ value: JSONValue, path: String = "$") throws -> EventEnvelope {
        var r = try FieldReader(value, path: path)
        let event = EventEnvelope(
            schemaVersion: try r.required("schema_version", SchemaVersion.check),
            eventID: try r.nonEmptyString("event_id"),
            runID: try r.required("run_id") { try Identifiers.validateRunID(JSONRead.string($0, $1), path: $1) },
            streamID: try r.required("stream_id", Identifiers.stableID),
            sourceID: try r.required("source_id", Identifiers.stableID),
            sequence: try r.required("sequence", JSONRead.nonNegative),
            producerID: try r.required("producer_id", Identifiers.stableID),
            producerSequence: try r.required("producer_sequence", JSONRead.nonNegative),
            type: try r.enumeration("type", EventType.self),
            mediaStartSample: try r.nullable("media_start_sample", JSONRead.nonNegative),
            mediaEndSample: try r.nullable("media_end_sample", JSONRead.nonNegative),
            sampleRateHz: try r.int("sample_rate_hz", in: ConfigLimits.sampleRateHz),
            monotonicEmittedNS: try r.required("monotonic_emitted_ns", JSONRead.nonNegative),
            monotonicRecordedNS: try r.required("monotonic_recorded_ns", JSONRead.nonNegative),
            virtualEmittedNS: try r.nullable("virtual_emitted_ns", JSONRead.nonNegative),
            causeChunkIndex: try r.nullable("cause_chunk_index", JSONRead.nonNegative),
            invocationID: try r.nullable("invocation_id", JSONRead.nonEmptyString),
            payload: try r.required("payload", JSONRead.object))
        try r.finish()
        try event.validate(path: path)
        return event
    }

    public func validate(path: String = "$") throws {
        switch (mediaStartSample, mediaEndSample) {
        case (nil, nil): break
        case let (start?, end?):
            guard start <= end else {
                throw ValidationError("\(path).media_end_sample", "media range must satisfy start <= end (got [\(start), \(end)))")
            }
        default:
            throw ValidationError("\(path).media_start_sample", "media_start_sample and media_end_sample must both be null or both be set")
        }
        guard monotonicRecordedNS >= monotonicEmittedNS else {
            throw ValidationError("\(path).monotonic_recorded_ns", "recorder admission cannot precede emission in the same clock domain")
        }
        try EventPayloads.validate(self, path: path)
    }

    public func toJSON() -> JSONValue {
        .object(JSONObject([
            ("schema_version", .string(schemaVersion)), ("event_id", .string(eventID)), ("run_id", .string(runID)),
            ("stream_id", .string(streamID)), ("source_id", .string(sourceID)), ("sequence", .int(sequence)),
            ("producer_id", .string(producerID)), ("producer_sequence", .int(producerSequence)),
            ("type", .string(type.rawValue)), ("media_start_sample", mediaStartSample.json),
            ("media_end_sample", mediaEndSample.json), ("sample_rate_hz", .int(sampleRateHz)),
            ("monotonic_emitted_ns", .int(monotonicEmittedNS)), ("monotonic_recorded_ns", .int(monotonicRecordedNS)),
            ("virtual_emitted_ns", virtualEmittedNS.json), ("cause_chunk_index", causeChunkIndex.json),
            ("invocation_id", invocationID.json), ("payload", .object(payload)),
        ]))
    }
}
