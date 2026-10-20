import Foundation

/// Half-open interval of integer sample indices at the document's own rate.
public struct SampleInterval: Sendable, Equatable, Comparable, JSONRepresentable {
    public let start: Int64
    public let end: Int64

    public init(start: Int64, end: Int64, path: String = "$") throws {
        guard start >= 0, end > start else {
            throw ValidationError(path, "interval must satisfy 0 <= start_sample < end_sample (got [\(start), \(end)))")
        }
        self.start = start
        self.end = end
    }

    public static func < (lhs: SampleInterval, rhs: SampleInterval) -> Bool {
        (lhs.start, lhs.end) < (rhs.start, rhs.end)
    }

    public func contains(_ other: SampleInterval) -> Bool { start <= other.start && other.end <= end }
    public func overlaps(_ other: SampleInterval) -> Bool { start < other.end && other.start < end }

    public static func read(_ value: JSONValue, _ path: String) throws -> SampleInterval {
        var r = try FieldReader(value, path: path)
        let start = try r.int("start_sample")
        let end = try r.int("end_sample")
        try r.finish()
        return try SampleInterval(start: start, end: end, path: path)
    }

    public func toJSON() -> JSONValue {
        .object(JSONObject([("start_sample", .int(start)), ("end_sample", .int(end))]))
    }
}

public enum AnnotationKind: String, Sendable, CaseIterable {
    case transcript, speakers
    case jointWords = "joint_words"
}

public enum TranscriptGranularity: String, Sendable, CaseIterable {
    case recording, utterances, words
}

public enum PrecisionUnit: String, Sendable, CaseIterable {
    case samples, ms, cs, s
}

/// Original annotation precision, preserved verbatim so a coarse source is
/// never upgraded to a finer claimed precision (plan D2 item 11, D5).
public struct AnnotationPrecision: Sendable, Equatable, JSONRepresentable {
    public let unit: PrecisionUnit
    public let step: Int64

    static func read(_ value: JSONValue, _ path: String) throws -> AnnotationPrecision {
        var r = try FieldReader(value, path: path)
        let precision = AnnotationPrecision(unit: try r.enumeration("unit", PrecisionUnit.self),
                                            step: try r.int("step", in: 1...Int64.max))
        try r.finish()
        return precision
    }

    public func toJSON() -> JSONValue { .object(JSONObject([("unit", .string(unit.rawValue)), ("step", .int(step))])) }
}

/// Fields common to every annotation document.
public struct AnnotationHeader: Sendable, Equatable {
    public let schemaVersion: String
    public let kind: AnnotationKind
    public let sourceID: String
    public let languages: [String]
    public let sampleRateHz: Int64
    public let durationSamples: Int64
    public let precision: AnnotationPrecision
    /// Declared coverage / UEM: sorted, non-overlapping scored regions.
    public let coverage: [SampleInterval]

    fileprivate static func read(_ r: inout FieldReader) throws -> AnnotationHeader {
        let schemaVersion = try r.required("schema_version", SchemaVersion.check)
        let kind = try r.enumeration("kind", AnnotationKind.self)
        let sourceID = try r.required("source_id", Identifiers.stableID)
        let languages = try r.array("languages", Identifiers.languageTag)
        var timebase = try FieldReader(try r.raw("timebase"), path: "$.timebase")
        guard try timebase.string("unit") == "samples" else {
            throw ValidationError("$.timebase.unit", "v1 annotations use unit \"samples\"")
        }
        let rate = try timebase.int("sample_rate_hz", in: ConfigLimits.sampleRateHz)
        try timebase.finish()
        let duration = try r.required("duration_samples", JSONRead.nonNegative)
        let precision = try r.required("original_precision", AnnotationPrecision.read)
        let coverage = try r.array("coverage", SampleInterval.read)
        guard !languages.isEmpty else { throw ValidationError("$.languages", "at least one language is required") }
        for (offset, region) in coverage.enumerated() {
            guard region.end <= duration else {
                throw ValidationError("$.coverage[\(offset)]", "region ends after duration_samples \(duration)")
            }
            if offset > 0, coverage[offset - 1].end > region.start {
                throw ValidationError("$.coverage[\(offset)]", "coverage regions must be sorted and non-overlapping")
            }
        }
        return AnnotationHeader(schemaVersion: schemaVersion, kind: kind, sourceID: sourceID, languages: languages,
                                sampleRateHz: rate, durationSamples: duration, precision: precision, coverage: coverage)
    }

    func covered(_ interval: SampleInterval) -> Bool { coverage.contains { $0.contains(interval) } }

    fileprivate var jsonMembers: [(String, JSONValue)] {
        [("schema_version", .string(schemaVersion)), ("kind", .string(kind.rawValue)), ("source_id", .string(sourceID)),
         ("languages", .array(languages.map(JSONValue.string))),
         ("timebase", .object(JSONObject([("unit", .string("samples")), ("sample_rate_hz", .int(sampleRateHz))]))),
         ("duration_samples", .int(durationSamples)), ("original_precision", precision.toJSON()),
         ("coverage", .array(coverage.map { $0.toJSON() }))]
    }
}

public struct TranscriptSegment: Sendable, Equatable {
    public let segmentID: String
    public let interval: SampleInterval
    public let text: String
}

/// Transcript reference. `recording` granularity carries untimed text in
/// `recording_text` with an empty `segments` array; it must cover the whole
/// recording and never gains invented timestamps.
public struct TranscriptAnnotation: Sendable, Equatable {
    public let header: AnnotationHeader
    public let granularity: TranscriptGranularity
    public let segments: [TranscriptSegment]
    public let recordingText: String?

    public func toJSON() -> JSONValue {
        let segmentValues = segments.map { segment -> JSONValue in
            .object(JSONObject([("segment_id", .string(segment.segmentID)),
                                ("start_sample", .int(segment.interval.start)),
                                ("end_sample", .int(segment.interval.end)), ("text", .string(segment.text))]))
        }
        return .object(JSONObject(header.jsonMembers + [
            ("granularity", .string(granularity.rawValue)), ("segments", .array(segmentValues)),
            ("recording_text", recordingText.json),
        ]))
    }
}

public struct SpeakerSegment: Sendable, Equatable {
    public let segmentID: String
    public let speakerID: String
    public let interval: SampleInterval
}

/// Speaker reference. Different speakers may overlap; same-speaker overlaps are
/// kept as authored and unioned only at scoring time. Segments may extend
/// outside scored regions (the scorer crops them to the UEM).
public struct SpeakerAnnotation: Sendable, Equatable {
    public let header: AnnotationHeader
    public let segments: [SpeakerSegment]

    public func toJSON() -> JSONValue {
        let segmentValues = segments.map { segment -> JSONValue in
            .object(JSONObject([("segment_id", .string(segment.segmentID)), ("speaker_id", .string(segment.speakerID)),
                                ("start_sample", .int(segment.interval.start)),
                                ("end_sample", .int(segment.interval.end))]))
        }
        return .object(JSONObject(header.jsonMembers + [("segments", .array(segmentValues))]))
    }
}

public struct JointWord: Sendable, Equatable {
    public let wordID: String
    public let interval: SampleInterval
    public let text: String
    public let speakerID: String?
}

/// Jointly annotated words: preserved for future use only; no Phase 2 attribution scoring.
public struct JointWordAnnotation: Sendable, Equatable {
    public let header: AnnotationHeader
    public let words: [JointWord]

    public func toJSON() -> JSONValue {
        let wordValues = words.map { word -> JSONValue in
            .object(JSONObject([("word_id", .string(word.wordID)), ("start_sample", .int(word.interval.start)),
                                ("end_sample", .int(word.interval.end)), ("text", .string(word.text)),
                                ("speaker_id", word.speakerID.json)]))
        }
        return .object(JSONObject(header.jsonMembers + [("granularity", .string("words")), ("words", .array(wordValues))]))
    }
}

public enum AnnotationDocument: Sendable, Equatable {
    case transcript(TranscriptAnnotation)
    case speakers(SpeakerAnnotation)
    case jointWords(JointWordAnnotation)

    public func toJSON() -> JSONValue {
        switch self {
        case .transcript(let doc): return doc.toJSON()
        case .speakers(let doc): return doc.toJSON()
        case .jointWords(let doc): return doc.toJSON()
        }
    }

    public static func read(_ value: JSONValue) throws -> AnnotationDocument {
        var r = try FieldReader(value, path: "$")
        let header = try AnnotationHeader.read(&r)
        let document: AnnotationDocument
        switch header.kind {
        case .transcript: document = .transcript(try readTranscript(&r, header))
        case .speakers: document = .speakers(try readSpeakers(&r, header))
        case .jointWords: document = .jointWords(try readJointWords(&r, header))
        }
        try r.finish()
        return document
    }

    private static func segmentInterval(_ s: inout FieldReader) throws -> SampleInterval {
        try SampleInterval(start: try s.int("start_sample"), end: try s.int("end_sample"), path: s.path)
    }

    private static func readTranscript(_ r: inout FieldReader, _ header: AnnotationHeader) throws -> TranscriptAnnotation {
        let granularity = try r.enumeration("granularity", TranscriptGranularity.self)
        let segments = try r.array("segments") { value, path -> TranscriptSegment in
            var s = try FieldReader(value, path: path)
            let segment = TranscriptSegment(segmentID: try s.required("segment_id", Identifiers.stableID),
                                            interval: try segmentInterval(&s), text: try s.string("text"))
            try s.finish()
            return segment
        }
        let recordingText = try r.nullableString("recording_text")
        switch granularity {
        case .recording:
            guard segments.isEmpty, recordingText != nil else {
                throw ValidationError("$.recording_text", "recording granularity needs recording_text and an empty segments array")
            }
            guard header.durationSamples > 0,
                  header.coverage == [try SampleInterval(start: 0, end: header.durationSamples)] else {
                throw ValidationError("$.coverage", "recording granularity must cover the full recording [0, duration_samples)")
            }
        case .utterances, .words:
            guard recordingText == nil else {
                throw ValidationError("$.recording_text", "must be null unless granularity is recording")
            }
            try checkUniqueIDs(segments.map(\.segmentID), path: "$.segments")
            for (offset, segment) in segments.enumerated() {
                guard header.covered(segment.interval) else {
                    throw ValidationError("$.segments[\(offset)]", "transcript segment lies outside the declared coverage")
                }
                if offset > 0, segments[offset - 1].interval.end > segment.interval.start {
                    throw ValidationError("$.segments[\(offset)]",
                                          "transcript segments must be in media order without overlap (v1 has no declared reference ordering)")
                }
            }
        }
        return TranscriptAnnotation(header: header, granularity: granularity, segments: segments, recordingText: recordingText)
    }

    private static func readSpeakers(_ r: inout FieldReader, _ header: AnnotationHeader) throws -> SpeakerAnnotation {
        let segments = try r.array("segments") { value, path -> SpeakerSegment in
            var s = try FieldReader(value, path: path)
            let segment = SpeakerSegment(segmentID: try s.required("segment_id", Identifiers.stableID),
                                         speakerID: try s.required("speaker_id", Identifiers.stableID),
                                         interval: try segmentInterval(&s))
            try s.finish()
            return segment
        }
        try checkUniqueIDs(segments.map(\.segmentID), path: "$.segments")
        for (offset, segment) in segments.enumerated() where segment.interval.end > header.durationSamples {
            throw ValidationError("$.segments[\(offset)]", "segment ends after duration_samples \(header.durationSamples)")
        }
        return SpeakerAnnotation(header: header, segments: segments)
    }

    private static func readJointWords(_ r: inout FieldReader, _ header: AnnotationHeader) throws -> JointWordAnnotation {
        guard try r.string("granularity") == "words" else {
            throw ValidationError("$.granularity", "joint_words documents have granularity \"words\"")
        }
        let words = try r.array("words") { value, path -> JointWord in
            var s = try FieldReader(value, path: path)
            let word = JointWord(wordID: try s.required("word_id", Identifiers.stableID), interval: try segmentInterval(&s),
                                 text: try s.nonEmptyString("text"),
                                 speakerID: try s.nullable("speaker_id", Identifiers.stableID))
            try s.finish()
            return word
        }
        try checkUniqueIDs(words.map(\.wordID), path: "$.words")
        for (offset, word) in words.enumerated() where !header.covered(word.interval) {
            throw ValidationError("$.words[\(offset)]", "word lies outside the declared coverage")
        }
        return JointWordAnnotation(header: header, words: words)
    }

    private static func checkUniqueIDs(_ ids: [String], path: String) throws {
        var seen = Set<String>()
        for (offset, id) in ids.enumerated() where !seen.insert(id).inserted {
            throw ValidationError("\(path)[\(offset)]", "duplicate ID \"\(id)\"")
        }
    }
}
