import Foundation

/// Typed validation of every v1 event payload plus the cross-field rules that
/// tie a payload to its envelope (closes the DEC-010 gap).
///
/// JSON Schema checks the same structure on the Python side; the rules below
/// marked "semantic" are ones JSON Schema cannot express. Every event the
/// runner writes passes through `EventEnvelope.validate`, so a malformed
/// payload is a contract failure at emission, not a surprise at scoring time.
public enum EventPayloads {
    public static let deadlineConvention = "end_of_frame_v1"

    public static func validate(_ envelope: EventEnvelope, path: String) throws {
        let p = "\(path).payload"
        var r = try FieldReader(.object(envelope.payload), path: p)
        switch envelope.type {
        case .experimentStarted:
            _ = try r.enumeration("mode", ReplayMode.self)
            for key in ["settings_sha256", "manifest_sha256", "audio_sha256", "schema_bundle_sha256"] {
                _ = try r.required(key, JSONRead.sha256)
            }
        case .experimentRuntimeCompleted:
            let produced = try r.required("produced_samples", JSONRead.nonNegative)
            let admitted = try r.required("admitted_samples", JSONRead.nonNegative)
            let consumed = try r.required("consumed_samples", JSONRead.nonNegative)
            let dropped = try r.required("dropped_samples", JSONRead.nonNegative)
            let ranges = try r.array("dropped_ranges", sampleInterval)
            _ = try r.required("last_media_sample", JSONRead.nonNegative)
            _ = try r.required("replay_elapsed_ns", JSONRead.nonNegative)
            guard admitted + dropped == produced, consumed == admitted else {
                throw ValidationError(p, "semantic: admitted + dropped must equal produced and consumed must equal admitted")
            }
            guard ranges.reduce(0, { $0 + $1.end - $1.start }) == dropped else {
                throw ValidationError("\(p).dropped_ranges", "semantic: ranges must total dropped_samples")
            }
            try requireSortedDisjoint(ranges, "\(p).dropped_ranges")
        case .experimentCompleted:
            _ = try r.array("artifacts") { try ArtifactDigest.read($0, $1) }
        case .experimentFailed, .experimentCancelled:
            let failure = try r.required("failure", RunFailure.read)
            _ = try r.nullable("last_valid_sequence", JSONRead.nonNegative)
            if (envelope.type == .experimentCancelled) != (failure.category == .cancelled) {
                throw ValidationError("\(p).failure.category", "semantic: category cancelled exactly for experiment.cancelled")
            }
        case .audioChunkScheduled:
            let index = try r.required("chunk_index", JSONRead.nonNegative)
            let range = try chunkRange(&r, p)
            guard try r.string("deadline_convention") == deadlineConvention else {
                throw ValidationError("\(p).deadline_convention", "must be \(deadlineConvention)")
            }
            let planned = try r.nullable("planned_deadline_ns", JSONRead.nonNegative)
            let virtual = try r.nullable("media_deadline_virtual_ns", JSONRead.nonNegative)
            guard (planned == nil) != (virtual == nil) else {
                throw ValidationError(p, "semantic: exactly one of planned_deadline_ns (real/accelerated) and media_deadline_virtual_ns (step) is set")
            }
            try requireChunkEnvelope(envelope, index: index, range: range, path: path)
        case .audioChunkDelivered:
            let index = try r.required("chunk_index", JSONRead.nonNegative)
            let offer = try r.required("offer_ns", JSONRead.nonNegative)
            let entry = try r.required("entry_ns", JSONRead.nonNegative)
            let wake = try r.nullable("wake_error_ns", JSONRead.int)
            let deadline = try r.nullable("deadline_error_ns", JSONRead.int)
            _ = try r.required("queue_depth", JSONRead.nonNegative)
            let virtual = try r.nullable("delivered_virtual_ns", JSONRead.nonNegative)
            guard entry >= offer else { throw ValidationError("\(p).entry_ns", "semantic: admission cannot precede the offer") }
            guard (wake == nil) == (deadline == nil), (wake == nil) == (virtual != nil) else {
                throw ValidationError(p, "semantic: real/accelerated deliveries carry wake and deadline errors; step deliveries carry delivered_virtual_ns only")
            }
            try requireChunkCause(envelope, index: index, path: path)
        case .audioChunkConsumed:
            let index = try r.required("chunk_index", JSONRead.nonNegative)
            let range = try chunkRange(&r, p)
            let dequeue = try r.required("dequeue_ns", JSONRead.nonNegative)
            let finish = try r.required("finish_ns", JSONRead.nonNegative)
            _ = try r.array("invocation_ids", JSONRead.nonEmptyString)
            _ = try r.required("queue_depth", JSONRead.nonNegative)
            guard finish >= dequeue else { throw ValidationError("\(p).finish_ns", "semantic: finish cannot precede dequeue") }
            try requireChunkEnvelope(envelope, index: index, range: range, path: path)
        case .audioQueueBackpressure:
            let index = try r.required("chunk_index", JSONRead.nonNegative)
            _ = try r.required("blocked_ns", JSONRead.nonNegative)
            _ = try r.required("capacity", JSONRead.positive)
            guard try r.string("policy") == OverflowPolicy.block.rawValue else {
                throw ValidationError("\(p).policy", "backpressure is reported only under the block policy")
            }
            try requireChunkCause(envelope, index: index, path: path)
        case .audioQueueOverflow:
            let index = try r.required("chunk_index", JSONRead.nonNegative)
            guard try r.string("policy") == OverflowPolicy.dropNewest.rawValue else {
                throw ValidationError("\(p).policy", "overflow is reported only under the drop_newest policy")
            }
            let range = try chunkRange(&r, p)
            let lost = try r.required("lost_samples", JSONRead.nonNegative)
            let cumulative = try r.required("cumulative_lost_samples", JSONRead.nonNegative)
            guard lost == range.end - range.start, cumulative >= lost else {
                throw ValidationError("\(p).lost_samples", "semantic: lost_samples must equal the range length and not exceed the cumulative count")
            }
            try requireChunkEnvelope(envelope, index: index, range: range, path: path)
        case .adapterStarted:
            try adapterIdentity(&r, envelope, p)
            _ = try r.nonEmptyString("revision")
            _ = try r.required("capabilities", AdapterCapabilities.read)
        case .adapterFailed:
            try adapterIdentity(&r, envelope, p)
            _ = try r.nonEmptyString("stage")
            _ = try r.nonEmptyString("message")
        case .adapterStopped:
            try adapterIdentity(&r, envelope, p)
            _ = try r.required("shutdown", AdapterShutdownReport.read)
        case .adapterDiagnostic:
            try adapterIdentity(&r, envelope, p)
            _ = try r.required("code", Identifiers.stableID)
            _ = try r.nonEmptyString("message")
            _ = try r.nullable("required_range", sampleInterval)
            try requireSortedDisjoint(try r.array("missing_ranges", sampleInterval), "\(p).missing_ranges")
        case .transcriptPartial, .transcriptFinal:
            _ = try r.required("utterance_id", Identifiers.stableID)
            _ = try r.required("revision", JSONRead.nonNegative)
            _ = try r.string("text")
            guard try r.bool("is_final") == (envelope.type == .transcriptFinal) else {
                throw ValidationError("\(p).is_final", "must be \(envelope.type == .transcriptFinal) for \(envelope.type.rawValue)")
            }
            try requireAdapterCause(envelope, path: path)
            try requireNonEmptyMediaIfPresent(envelope, path: path)
        case .speakerSegment:
            _ = try r.required("segment_id", Identifiers.stableID)
            _ = try r.required("speaker_id", Identifiers.stableID)
            guard try r.bool("is_final") else { throw ValidationError("\(p).is_final", "speaker segments are final in v1") }
            try requireAdapterCause(envelope, path: path)
            guard envelope.mediaStartSample != nil else {
                throw ValidationError("\(path).media_start_sample", "semantic: a speaker segment needs a media range")
            }
            try requireNonEmptyMediaIfPresent(envelope, path: path)
        case .stageCompleted:
            _ = try r.required("stage", Identifiers.stableID)
            let start = try r.required("start_ns", JSONRead.nonNegative)
            let end = try r.required("end_ns", JSONRead.nonNegative)
            let duration = try r.required("duration_ns", JSONRead.nonNegative)
            _ = try r.nullable("virtual_duration_ns", JSONRead.nonNegative)
            guard end >= start, duration == end - start else {
                throw ValidationError("\(p).duration_ns", "semantic: duration_ns must equal end_ns - start_ns >= 0")
            }
        case .telemetrySample:
            _ = try r.nonEmptyString("sample_id")
            _ = try r.nonEmptyString("phase")
        }
        try r.finish()
    }

    // MARK: Helpers

    public static func sampleInterval(_ value: JSONValue, _ path: String) throws -> SampleInterval {
        try SampleInterval.read(value, path)
    }

    private static func chunkRange(_ r: inout FieldReader, _ path: String) throws -> SampleInterval {
        try SampleInterval(start: try r.required("start_sample", JSONRead.nonNegative),
                           end: try r.required("end_sample", JSONRead.nonNegative), path: path)
    }

    private static func requireSortedDisjoint(_ ranges: [SampleInterval], _ path: String) throws {
        for (offset, range) in ranges.enumerated().dropFirst() where ranges[offset - 1].end > range.start {
            throw ValidationError("\(path)[\(offset)]", "semantic: ranges must be sorted and disjoint")
        }
    }

    private static func requireChunkCause(_ envelope: EventEnvelope, index: Int64, path: String) throws {
        guard envelope.causeChunkIndex == index else {
            throw ValidationError("\(path).cause_chunk_index", "semantic: must equal payload chunk_index \(index)")
        }
    }

    private static func requireChunkEnvelope(_ envelope: EventEnvelope, index: Int64, range: SampleInterval,
                                             path: String) throws {
        try requireChunkCause(envelope, index: index, path: path)
        guard envelope.mediaStartSample == range.start, envelope.mediaEndSample == range.end else {
            throw ValidationError("\(path).media_start_sample", "semantic: envelope media range must equal the chunk range")
        }
    }

    private static func requireAdapterCause(_ envelope: EventEnvelope, path: String) throws {
        guard envelope.invocationID != nil else {
            throw ValidationError("\(path).invocation_id", "semantic: adapter output must name the invocation that produced it")
        }
    }

    private static func requireNonEmptyMediaIfPresent(_ envelope: EventEnvelope, path: String) throws {
        if let start = envelope.mediaStartSample, let end = envelope.mediaEndSample, start >= end {
            throw ValidationError("\(path).media_end_sample", "semantic: an output media range must be non-empty")
        }
    }

    private static func adapterIdentity(_ r: inout FieldReader, _ envelope: EventEnvelope, _ path: String) throws {
        _ = try r.enumeration("role", AdapterRole.self)
        let id = try r.required("adapter_id", Identifiers.stableID)
        guard id == envelope.producerID else {
            throw ValidationError("\(path).adapter_id", "semantic: must equal the envelope producer_id \"\(envelope.producerID)\"")
        }
    }
}
