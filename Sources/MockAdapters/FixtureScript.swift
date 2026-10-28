import AdapterContracts
import BenchmarkSupport
import Foundation

/// Independently authored prediction script for one fixture item
/// (`fixture-script.schema.json`). It states what the mocks emit and when;
/// it is never derived from the references it will be scored against.
///
/// Causality rule: an entry with a `trigger_sample` is emitted while consuming
/// the first chunk whose end reaches the trigger, and the trigger may not
/// precede the entry's own media end (a mock cannot hear the future). A null
/// trigger means "emit during flush".
public struct FixtureScript: Sendable, Equatable {
    public struct TranscriptEntry: Sendable, Equatable {
        public let ordinal: Int64
        public let triggerSample: Int64?
        public let utteranceID: String
        public let revision: Int64
        public let text: String
        public let isFinal: Bool
        public let range: SampleInterval
    }

    public struct SpeakerEntry: Sendable, Equatable {
        public let ordinal: Int64
        public let triggerSample: Int64?
        public let segmentID: String
        public let speakerID: String
        public let range: SampleInterval
    }

    /// Test-only failure declared in the (hashed) fixture file; there is no
    /// hidden production switch.
    public struct Fault: Sendable, Equatable {
        public let role: AdapterRole
        public let stage: AdapterStage
        public let chunkIndex: Int64?
    }

    public struct Perturbation: Sendable, Equatable {
        public static let algorithm = SplitMix64.algorithmID
        /// Each speaker segment shrinks by up to this many samples at each end.
        public let speakerBoundaryJitterSamples: Int64
    }

    public static let kind = "mock_fixture_script"

    public let sourceID: String
    public let sampleRateHz: Int64
    public let durationSamples: Int64
    public let perturbation: Perturbation?
    public let faults: [Fault]
    public let asr: [TranscriptEntry]
    public let diarization: [SpeakerEntry]

    /// Loads the script, verifying its SHA-256 against the bytes actually read.
    public static func load(_ reference: FixtureScriptReference, adapterID: String) throws -> FixtureScript {
        let data: Data
        do { data = try Data(contentsOf: reference.url) } catch {
            throw AdapterError(.fixture, adapterID: adapterID, stage: .prepare,
                               "cannot read fixture script \(reference.url.path): \(error.localizedDescription)")
        }
        let digest = SHA256Hex.digest(data)
        guard digest == reference.sha256 else {
            throw AdapterError(.fixture, adapterID: adapterID, stage: .prepare,
                               "fixture script hash \(digest) differs from the manifest's \(reference.sha256)")
        }
        do { return try read(try StrictJSON.parse(data)) } catch {
            throw AdapterError(.fixture, adapterID: adapterID, stage: .prepare, "invalid fixture script: \(error)")
        }
    }

    public static func read(_ value: JSONValue) throws -> FixtureScript {
        var r = try FieldReader(value, path: "$")
        _ = try r.required("schema_version", SchemaVersion.check)
        guard try r.string("kind") == kind else { throw ValidationError("$.kind", "must be \"\(kind)\"") }
        let sourceID = try r.required("source_id", Identifiers.stableID)
        let rate = try r.int("sample_rate_hz", in: ConfigLimits.sampleRateHz)
        let duration = try r.required("duration_samples", JSONRead.nonNegative)
        let perturbation = try r.nullable("perturbation") { value, path -> Perturbation in
            var p = try FieldReader(value, path: path)
            guard try p.string("algorithm") == Perturbation.algorithm else {
                throw ValidationError("\(path).algorithm", "must be \"\(Perturbation.algorithm)\"")
            }
            let jitter = try p.int("speaker_boundary_jitter_samples", in: 0...Int64(Int32.max))
            try p.finish()
            return Perturbation(speakerBoundaryJitterSamples: jitter)
        }
        let faults = try r.array("faults") { value, path -> Fault in
            var f = try FieldReader(value, path: path)
            let fault = Fault(role: try f.enumeration("role", AdapterRole.self),
                              stage: try f.enumeration("stage", AdapterStage.self),
                              chunkIndex: try f.nullableInt("chunk_index"))
            try f.finish()
            guard fault.stage != .emit else { throw ValidationError("\(path).stage", "emit is not an injectable stage") }
            guard (fault.chunkIndex != nil) == (fault.stage == .consume) else {
                throw ValidationError("\(path).chunk_index", "chunk_index is required for consume faults and null otherwise")
            }
            return fault
        }
        let asr = try r.array("asr") { value, path -> TranscriptEntry in
            var e = try FieldReader(value, path: path)
            let entry = TranscriptEntry(
                ordinal: try e.required("ordinal", JSONRead.nonNegative),
                triggerSample: try e.nullable("trigger_sample", JSONRead.nonNegative),
                utteranceID: try e.required("utterance_id", Identifiers.stableID),
                revision: try e.required("revision", JSONRead.nonNegative),
                text: try e.string("text"), isFinal: try e.bool("is_final"),
                range: try SampleInterval(start: try e.int("start_sample"), end: try e.int("end_sample"), path: path))
            try e.finish()
            return entry
        }
        let diarization = try r.array("diarization") { value, path -> SpeakerEntry in
            var e = try FieldReader(value, path: path)
            let entry = SpeakerEntry(
                ordinal: try e.required("ordinal", JSONRead.nonNegative),
                triggerSample: try e.nullable("trigger_sample", JSONRead.nonNegative),
                segmentID: try e.required("segment_id", Identifiers.stableID),
                speakerID: try e.required("speaker_id", Identifiers.stableID),
                range: try SampleInterval(start: try e.int("start_sample"), end: try e.int("end_sample"), path: path))
            try e.finish()
            return entry
        }
        try r.finish()
        let script = FixtureScript(sourceID: sourceID, sampleRateHz: rate, durationSamples: duration,
                                   perturbation: perturbation, faults: faults, asr: asr, diarization: diarization)
        try script.validate()
        return script
    }

    func validate() throws {
        func check(_ entries: [(ordinal: Int64, trigger: Int64?, range: SampleInterval)], _ path: String) throws {
            for (offset, entry) in entries.enumerated() {
                guard entry.ordinal == Int64(offset) else {
                    throw ValidationError("\(path)[\(offset)].ordinal", "ordinals must be 0, 1, 2, ... in script order")
                }
                guard entry.range.end <= durationSamples else {
                    throw ValidationError("\(path)[\(offset)]", "range ends after duration_samples \(durationSamples)")
                }
                if let trigger = entry.trigger, trigger < entry.range.end {
                    throw ValidationError("\(path)[\(offset)].trigger_sample",
                                          "trigger \(trigger) precedes the entry's media end \(entry.range.end); a mock cannot emit before its audio exists")
                }
            }
        }
        try check(asr.map { ($0.ordinal, $0.triggerSample, $0.range) }, "$.asr")
        try check(diarization.map { ($0.ordinal, $0.triggerSample, $0.range) }, "$.diarization")
    }

    /// Checks the script describes the stream it is being prepared for.
    public func checkMatches(_ context: AdapterContext, adapterID: String) throws {
        var problems: [String] = []
        if sourceID != context.sourceID { problems.append("script is for source \(sourceID), stream is \(context.sourceID)") }
        if sampleRateHz != context.format.sampleRateHz {
            problems.append("script rate \(sampleRateHz) Hz, stream rate \(context.format.sampleRateHz) Hz")
        }
        if durationSamples != context.durationSamples {
            problems.append("script duration \(durationSamples), stream duration \(context.durationSamples) samples")
        }
        if !problems.isEmpty {
            throw AdapterError(.fixture, adapterID: adapterID, stage: .prepare, problems.joined(separator: "; "))
        }
    }

    public func toJSON() -> JSONValue {
        func entry(_ e: TranscriptEntry) -> JSONValue {
            .object(JSONObject([("ordinal", .int(e.ordinal)), ("trigger_sample", e.triggerSample.json),
                                ("utterance_id", .string(e.utteranceID)), ("revision", .int(e.revision)),
                                ("text", .string(e.text)), ("is_final", .bool(e.isFinal)),
                                ("start_sample", .int(e.range.start)), ("end_sample", .int(e.range.end))]))
        }
        func segment(_ e: SpeakerEntry) -> JSONValue {
            .object(JSONObject([("ordinal", .int(e.ordinal)), ("trigger_sample", e.triggerSample.json),
                                ("segment_id", .string(e.segmentID)), ("speaker_id", .string(e.speakerID)),
                                ("start_sample", .int(e.range.start)), ("end_sample", .int(e.range.end))]))
        }
        let perturbationJSON: JSONValue = perturbation.map {
            .object(JSONObject([("algorithm", .string(Perturbation.algorithm)),
                                ("speaker_boundary_jitter_samples", .int($0.speakerBoundaryJitterSamples))]))
        } ?? .null
        return .object(JSONObject([
            ("schema_version", .string(SchemaVersion.current)), ("kind", .string(Self.kind)),
            ("source_id", .string(sourceID)), ("sample_rate_hz", .int(sampleRateHz)),
            ("duration_samples", .int(durationSamples)), ("perturbation", perturbationJSON),
            ("faults", .array(faults.map { fault in
                .object(JSONObject([("role", .string(fault.role.rawValue)), ("stage", .string(fault.stage.rawValue)),
                                    ("chunk_index", fault.chunkIndex.json)]))
            })),
            ("asr", .array(asr.map(entry))), ("diarization", .array(diarization.map(segment))),
        ]))
    }

    public func fault(role: AdapterRole, stage: AdapterStage, chunkIndex: Int64? = nil) -> Fault? {
        faults.first { $0.role == role && $0.stage == stage && $0.chunkIndex == chunkIndex }
    }
}

/// `splitmix64_v1`: the only PRNG used for mock output, and only when a script
/// requests a perturbation. Swift's randomized `Hasher` and
/// `SystemRandomNumberGenerator` are never used for output behavior.
public struct SplitMix64: RandomNumberGenerator, Sendable {
    public static let algorithmID = "splitmix64_v1"
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform integer in `0...bound` by rejection sampling (no modulo bias).
    public mutating func uniform(upTo bound: UInt64) -> UInt64 {
        if bound == UInt64.max { return next() }
        let span = bound + 1
        let limit = UInt64.max - (UInt64.max % span)
        while true {
            let value = next()
            if value < limit { return value % span }
        }
    }
}
