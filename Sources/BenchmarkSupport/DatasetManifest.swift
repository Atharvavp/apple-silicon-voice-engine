import Foundation

public enum DatasetStatus: String, Sendable, CaseIterable {
    case pending, ready
}

public enum AnnotationType: String, Sendable, CaseIterable {
    case words, utterances
    case speakerSegments = "speaker_segments"
    case mixed
}

/// Which reference kinds an item genuinely carries (plan D4/D5 granularity rules).
public struct ReferenceCoverage: Sendable, Equatable, JSONRepresentable {
    public var transcript: Bool
    public var speakers: Bool
    public var jointWords: Bool

    static func read(_ value: JSONValue, _ path: String) throws -> ReferenceCoverage {
        var reader = try FieldReader(value, path: path)
        let coverage = ReferenceCoverage(
            transcript: try reader.bool("transcript"),
            speakers: try reader.bool("speakers"),
            jointWords: try reader.bool("joint_words"))
        try reader.finish()
        return coverage
    }

    public func toJSON() -> JSONValue {
        .object(JSONObject([("transcript", .bool(transcript)), ("speakers", .bool(speakers)),
                            ("joint_words", .bool(jointWords))]))
    }
}

public struct DatasetItem: Sendable, Equatable {
    public var itemID: String
    public var languages: [String]
    public var split: String
    public var status: DatasetStatus
    public var audioPath: String
    public var audioSHA256: String
    public var sampleRateHz: Int64
    public var channels: Int64
    public var durationSamples: Int64
    public var referenceTextPath: String?
    public var referenceTextSHA256: String?
    public var speakerSegmentsPath: String?
    public var speakerSegmentsSHA256: String?
    /// Descriptor hash over both independent reference file hashes (plan D4).
    public var referenceSHA256: String?
    public var fixtureScriptPath: String?
    public var fixtureScriptSHA256: String?
    public var annotationType: AnnotationType
    public var coverage: ReferenceCoverage
    public var rightsNotes: String

    static func read(_ value: JSONValue, _ path: String) throws -> DatasetItem {
        var r = try FieldReader(value, path: path)
        let item = DatasetItem(
            itemID: try r.required("item_id", Identifiers.stableID),
            languages: try r.array("languages", Identifiers.languageTag),
            split: try r.nonEmptyString("split"),
            status: try r.enumeration("status", DatasetStatus.self),
            audioPath: try r.nonEmptyString("audio_path"),
            audioSHA256: try r.required("audio_sha256", JSONRead.sha256),
            sampleRateHz: try r.int("sample_rate_hz", in: ConfigLimits.sampleRateHz),
            channels: try r.int("channels", in: 1...2),
            durationSamples: try r.required("duration_samples", JSONRead.nonNegative),
            referenceTextPath: try r.nullable("reference_text_path", JSONRead.nonEmptyString),
            referenceTextSHA256: try r.nullable("reference_text_sha256", JSONRead.sha256),
            speakerSegmentsPath: try r.nullable("speaker_segments_path", JSONRead.nonEmptyString),
            speakerSegmentsSHA256: try r.nullable("speaker_segments_sha256", JSONRead.sha256),
            referenceSHA256: try r.nullable("reference_sha256", JSONRead.sha256),
            fixtureScriptPath: try r.nullable("fixture_script_path", JSONRead.nonEmptyString),
            fixtureScriptSHA256: try r.nullable("fixture_script_sha256", JSONRead.sha256),
            annotationType: try r.enumeration("annotation_type", AnnotationType.self),
            coverage: try r.required("coverage", ReferenceCoverage.read),
            rightsNotes: try r.nonEmptyString("rights_notes"))
        try r.finish()
        try item.validate(path)
        return item
    }

    func validate(_ path: String) throws {
        guard !languages.isEmpty else { throw ValidationError("\(path).languages", "at least one language is required") }
        guard (referenceTextPath == nil) == (referenceTextSHA256 == nil) else {
            throw ValidationError("\(path).reference_text_sha256", "path and hash must both be present or both be null")
        }
        guard (speakerSegmentsPath == nil) == (speakerSegmentsSHA256 == nil) else {
            throw ValidationError("\(path).speaker_segments_sha256", "path and hash must both be present or both be null")
        }
        guard (fixtureScriptPath == nil) == (fixtureScriptSHA256 == nil) else {
            throw ValidationError("\(path).fixture_script_sha256", "path and hash must both be present or both be null")
        }
        guard coverage.transcript == (referenceTextPath != nil) else {
            throw ValidationError("\(path).coverage.transcript", "must be true exactly when reference_text_path is set")
        }
        guard coverage.speakers == (speakerSegmentsPath != nil) else {
            throw ValidationError("\(path).coverage.speakers", "must be true exactly when speaker_segments_path is set")
        }
        let hasReference = referenceTextPath != nil || speakerSegmentsPath != nil
        guard (referenceSHA256 != nil) == hasReference else {
            throw ValidationError("\(path).reference_sha256", "must be set exactly when at least one reference file exists")
        }
    }

    /// `reference_sha256` = SHA-256 of `"<transcript-hash or ->\n<speakers-hash or ->\n"`.
    public static func referenceDescriptorHash(transcriptSHA256: String?, speakersSHA256: String?) -> String {
        let text = "\(transcriptSHA256 ?? "-")\n\(speakersSHA256 ?? "-")\n"
        return SHA256Hex.digest(Data(text.utf8))
    }
}

/// Dataset-level manifest (plan D4). A pending manifest documents intent only
/// and is never runnable; a ready manifest must carry verified rights and
/// complete per-item hashes.
public struct DatasetManifest: Sendable, Equatable {
    public var schemaVersion: String
    public var datasetID: String
    public var version: String
    public var languages: [String]
    public var sourceName: String
    public var sourceURL: String?
    public var license: String?
    public var licenseVerified: Bool
    public var redistributionAllowed: Bool?
    public var externalRoot: String?
    public var annotationType: AnnotationType?
    public var status: DatasetStatus
    public var provenanceNotes: String
    public var items: [DatasetItem]

    public static func read(_ value: JSONValue) throws -> DatasetManifest {
        var r = try FieldReader(value, path: "$")
        let manifest = DatasetManifest(
            schemaVersion: try r.required("schema_version", SchemaVersion.check),
            datasetID: try r.required("dataset_id", Identifiers.stableID),
            version: try r.nonEmptyString("version"),
            languages: try r.array("languages", Identifiers.languageTag),
            sourceName: try r.nonEmptyString("source_name"),
            sourceURL: try r.nullable("source_url", JSONRead.nonEmptyString),
            license: try r.nullable("license", JSONRead.nonEmptyString),
            licenseVerified: try r.bool("license_verified"),
            redistributionAllowed: try r.nullableBool("redistribution_allowed"),
            externalRoot: try r.nullable("external_root", JSONRead.nonEmptyString),
            annotationType: try r.nullable("annotation_type", JSONRead.enumeration),
            status: try r.enumeration("status", DatasetStatus.self),
            provenanceNotes: try r.nonEmptyString("provenance_notes"),
            items: try r.array("items", DatasetItem.read))
        try r.finish()
        try manifest.validate()
        return manifest
    }

    public func validate() throws {
        guard !languages.isEmpty else { throw ValidationError("$.languages", "at least one language is required") }
        var seen = Set<String>()
        for (offset, item) in items.enumerated() {
            guard seen.insert(item.itemID).inserted else {
                throw ValidationError("$.items[\(offset)].item_id", "duplicate item_id \"\(item.itemID)\"")
            }
            if status == .pending && item.status == .ready {
                throw ValidationError("$.items[\(offset)].status", "a pending manifest cannot contain ready items")
            }
        }
        if status == .ready {
            guard !items.isEmpty else { throw ValidationError("$.items", "a ready manifest needs at least one item") }
            guard license != nil, licenseVerified else {
                throw ValidationError("$.license_verified", "a ready manifest needs a license statement that has been verified")
            }
            guard annotationType != nil else {
                throw ValidationError("$.annotation_type", "a ready manifest must declare its annotation type")
            }
        }
    }

    /// `validate --dataset --require-ready` semantics: structure is valid *and* runnable.
    public func requireReady() throws {
        guard status == .ready else {
            throw ValidationError("$.status", "dataset \"\(datasetID)\" is \(status.rawValue); Gate B staging is incomplete")
        }
    }

    public func item(_ id: String) throws -> DatasetItem {
        guard status == .ready else {
            throw ValidationError("$.status", "dataset \"\(datasetID)\" is \(status.rawValue) and cannot be selected for a run")
        }
        guard let item = items.first(where: { $0.itemID == id }) else {
            throw ValidationError("$.items", "item \"\(id)\" not found in dataset \"\(datasetID)\"")
        }
        guard item.status == .ready else {
            throw ValidationError("$.items", "item \"\(id)\" is \(item.status.rawValue) and cannot be selected for a run")
        }
        return item
    }
}
