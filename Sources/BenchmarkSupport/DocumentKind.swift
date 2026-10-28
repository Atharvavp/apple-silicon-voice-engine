import Foundation

/// Document kinds that Swift reads and writes in M1, used by the cross-language
/// schema round-trip (`voicebench dev roundtrip`).
public enum DocumentKind: String, Sendable, CaseIterable {
    case config, dataset, annotations, event, metric, status

    /// Strictly parses, semantically validates and re-encodes one document.
    public func roundTrip(_ value: JSONValue) throws -> JSONValue {
        switch self {
        case .config: return try RunConfig.read(value).toJSON()
        case .dataset: return try DatasetManifest.read(value).toJSON()
        case .annotations: return try AnnotationDocument.read(value).toJSON()
        case .event: return try EventEnvelope.read(value).toJSON()
        case .metric: return try MetricRecord.read(value).toJSON()
        case .status: return try RunStatus.read(value).toJSON()
        }
    }
}

extension DatasetItem: JSONRepresentable {
    public func toJSON() -> JSONValue {
        .object(JSONObject([
            ("item_id", .string(itemID)), ("languages", .array(languages.map(JSONValue.string))),
            ("split", .string(split)), ("status", .string(status.rawValue)), ("audio_path", .string(audioPath)),
            ("audio_sha256", .string(audioSHA256)), ("sample_rate_hz", .int(sampleRateHz)),
            ("channels", .int(channels)), ("duration_samples", .int(durationSamples)),
            ("reference_text_path", referenceTextPath.json), ("reference_text_sha256", referenceTextSHA256.json),
            ("speaker_segments_path", speakerSegmentsPath.json),
            ("speaker_segments_sha256", speakerSegmentsSHA256.json), ("reference_sha256", referenceSHA256.json),
            ("fixture_script_path", fixtureScriptPath.json), ("fixture_script_sha256", fixtureScriptSHA256.json),
            ("annotation_type", .string(annotationType.rawValue)), ("coverage", coverage.toJSON()),
            ("rights_notes", .string(rightsNotes)),
        ]))
    }
}

extension DatasetManifest: JSONRepresentable {
    public func toJSON() -> JSONValue {
        .object(JSONObject([
            ("schema_version", .string(schemaVersion)), ("dataset_id", .string(datasetID)),
            ("version", .string(version)), ("languages", .array(languages.map(JSONValue.string))),
            ("source_name", .string(sourceName)), ("source_url", sourceURL.json), ("license", license.json),
            ("license_verified", .bool(licenseVerified)), ("redistribution_allowed", redistributionAllowed.json),
            ("external_root", externalRoot.json), ("annotation_type", annotationType.map { .string($0.rawValue) } ?? .null),
            ("status", .string(status.rawValue)), ("provenance_notes", .string(provenanceNotes)),
            ("items", .array(items.map { $0.toJSON() })),
        ]))
    }
}
