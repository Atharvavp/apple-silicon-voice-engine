import BenchmarkSupport
import Darwin
import Foundation
import Telemetry

public enum VoiceBenchVersion {
    public static let current = "0.7.0-phase0"
}

/// Output of `python -m phase0_analysis env-info` (interpreter facts gathered
/// by the analysis package itself).
public struct PythonFacts: Sendable {
    public let executable: String
    public let version: String
    public let analysisVersion: String
    public let unicodeVersion: String?
    public let distributions: [(String, String)]

    static func read(_ data: Data) throws -> PythonFacts {
        var r = try FieldReader(try StrictJSON.parse(data), path: "$")
        let facts = PythonFacts(
            executable: try r.nonEmptyString("executable"), version: try r.nonEmptyString("version"),
            analysisVersion: try r.nonEmptyString("analysis_version"),
            unicodeVersion: try r.nullable("unicode_version", JSONRead.nonEmptyString),
            distributions: try r.required("distributions") { value, path in
                try JSONRead.object(value, path).members.map { ($0.key, try JSONRead.string($0.value, path)) }
            })
        try r.finish()
        return facts
    }
}

/// Startup environment facts (plan D6). Hardware facts carry their source and
/// availability; the intended target machine is recorded separately and never
/// substituted for an observation.
public enum EnvironmentCapture {
    public static let targetHardwareExpectation =
        "fanless Apple M5 MacBook Air with 16 GB unified memory (plan assumption; compare with the observed hardware facts)"

    public static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
    }

    public static func sysctlInt(_ name: String) -> Int64? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        if size == MemoryLayout<Int32>.size { return Int64(Int32(truncatingIfNeeded: value)) }
        return value
    }

    static func fact(_ value: JSONValue?, _ source: String) -> FactObservation {
        value.map { .ok($0, source: source) } ?? .missing(.unavailable, source: source, reason: "sysctl query failed")
    }

    public static var hardware: JSONObject {
        JSONObject([
            ("model", fact(sysctlString("hw.model").map(JSONValue.string), "sysctl hw.model").toJSON()),
            ("chip", fact(sysctlString("machdep.cpu.brand_string").map(JSONValue.string),
                          "sysctl machdep.cpu.brand_string").toJSON()),
            ("memory_bytes", fact(sysctlInt("hw.memsize").map(JSONValue.int), "sysctl hw.memsize").toJSON()),
            ("logical_cpu_count", fact(sysctlInt("hw.logicalcpu").map(JSONValue.int), "sysctl hw.logicalcpu").toJSON()),
        ])
    }

    public static var osVersion: (product: String, build: String) {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return ("\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)", sysctlString("kern.osversion") ?? "unavailable")
    }

    public static var architecture: String {
        var name = utsname()
        uname(&name)
        return withUnsafeBytes(of: &name.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    /// Git revision and dirty flag of the project checkout; nil when unavailable.
    public static func git(projectRoot: URL) -> (revision: String?, dirty: Bool?) {
        func run(_ args: [String]) -> String? {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", projectRoot.path] + args
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let revision = run(["rev-parse", "HEAD"]).flatMap { $0.isEmpty ? nil : $0 }
        let dirty = run(["status", "--porcelain"]).map { !$0.isEmpty }
        return (revision, revision == nil ? nil : dirty)
    }

    public static func fileSHA(_ url: URL) -> String? { try? SHA256Hex.file(url).sha256 }
}

/// Builds `predictions.json` from the frozen runtime prefix only (plan D5):
/// final transcript and speaker events, sorted by media start then stable ID
/// for the prediction view; raw arrival order stays in the trace. Partial text
/// is never concatenated with final text.
public enum PredictionBuilder {
    public static let assemblyPolicy = "media_order_space_join_v1"

    public struct Inputs: Sendable {
        public let runID: String
        public let sourceID: String
        public let mock: Bool
        public let asr: AdapterSelection
        public let diarization: AdapterSelection
        public let sampleRateHz: Int64
        public let durationSamples: Int64
        public let sourceSHA256: String
        public let convertedSHA256: String
        public let transcriptGranularity: TranscriptOutputGranularity
        public let consumedSamples: Int64
        public let droppedRanges: [SampleInterval]
    }

    public static func build(prefixURL: URL, prefix: EventRecorder.PrefixDescriptor, inputs: Inputs) throws -> JSONValue {
        let data = try Data(contentsOf: prefixURL).prefix(Int(prefix.byteCount))
        guard SHA256Hex.digest(Data(data)) == prefix.sha256 else {
            throw RecorderError("runtime prefix bytes do not match the frozen descriptor")
        }
        var transcripts: [(start: Int64?, id: String, value: JSONValue)] = []
        var speakers: [(start: Int64, id: String, value: JSONValue)] = []
        var lines = 0
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: false) where !line.isEmpty {
            lines += 1
            let event = try EventEnvelope.read(try StrictJSON.parse(Data(line)))
            switch event.type {
            case .transcriptFinal:
                let id = try JSONRead.string(event.payload["utterance_id"] ?? .null, "utterance_id")
                transcripts.append((event.mediaStartSample, id, .object(JSONObject([
                    ("utterance_id", .string(id)), ("start_sample", event.mediaStartSample.json),
                    ("end_sample", event.mediaEndSample.json), ("text", event.payload["text"] ?? .null),
                    ("event_ids", .array([.string(event.eventID)])),
                ]))))
            case .speakerSegment:
                let id = try JSONRead.string(event.payload["segment_id"] ?? .null, "segment_id")
                guard let start = event.mediaStartSample, let end = event.mediaEndSample else {
                    throw RecorderError("speaker segment \(id) has no media range")
                }
                speakers.append((start, id, .object(JSONObject([
                    ("segment_id", .string(id)), ("speaker_id", event.payload["speaker_id"] ?? .null),
                    ("start_sample", .int(start)), ("end_sample", .int(end)),
                    ("event_ids", .array([.string(event.eventID)])),
                ]))))
            default:
                break
            }
        }
        guard Int64(lines) == prefix.lineCount else {
            throw RecorderError("prefix holds \(lines) lines; descriptor says \(prefix.lineCount)")
        }
        transcripts.sort { ($0.start ?? -1, $0.id) < ($1.start ?? -1, $1.id) }
        speakers.sort { ($0.start, $0.id) < ($1.start, $1.id) }
        let dropped = inputs.droppedRanges.reduce(0) { $0 + $1.end - $1.start }
        return .object(JSONObject([
            ("schema_version", .string(SchemaVersion.current)), ("run_id", .string(inputs.runID)),
            ("source_id", .string(inputs.sourceID)), ("mock", .bool(inputs.mock)),
            ("adapters", .object(JSONObject([
                ("asr", .object(JSONObject([("id", .string(inputs.asr.id)), ("revision", .string(inputs.asr.revision))]))),
                ("diarization", .object(JSONObject([("id", .string(inputs.diarization.id)),
                                                    ("revision", .string(inputs.diarization.revision))]))),
            ]))),
            ("audio", .object(JSONObject([
                ("sample_rate_hz", .int(inputs.sampleRateHz)), ("duration_samples", .int(inputs.durationSamples)),
                ("source_sha256", .string(inputs.sourceSHA256)), ("converted_sha256", .string(inputs.convertedSHA256)),
            ]))),
            ("transcript_granularity", .string(inputs.transcriptGranularity.rawValue)),
            ("transcript_assembly_policy", .string(assemblyPolicy)),
            ("transcript", .array(transcripts.map(\.value))), ("speakers", .array(speakers.map(\.value))),
            ("coverage", .object(JSONObject([
                ("consumed_samples", .int(inputs.consumedSamples)), ("dropped_samples", .int(dropped)),
                ("dropped_ranges", .array(inputs.droppedRanges.map { $0.toJSON() })),
            ]))),
            ("source_events", prefix.toJSON()),
        ]))
    }
}
