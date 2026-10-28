import AdapterContracts
import AudioCore
import BenchmarkSupport
import Foundation
import MockAdapters
import os

let repositoryRoot: URL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

func repoURL(_ relative: String) -> URL { repositoryRoot.appendingPathComponent(relative) }

func makeScratch() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("voicebench-tests/\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Writes evidence when the checkpoint runner sets VOICEBENCH_EVIDENCE_DIR; otherwise a no-op.
enum Evidence {
    static func write(_ name: String, _ value: JSONValue) {
        guard let root = ProcessInfo.processInfo.environment["VOICEBENCH_EVIDENCE_DIR"],
              let data = try? JSONWriter.pretty(value) else { return }
        let url = URL(fileURLWithPath: root).appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url)
    }
}

/// Fixture script of a synthetic item, with the hash of its bytes on disk.
func scriptReference(_ item: String) throws -> FixtureScriptReference {
    let url = repoURL("datasets/fixtures/scripts/\(item).json")
    return FixtureScriptReference(url: url, sha256: try SHA256Hex.file(url).sha256)
}

/// Writes a modified copy of a fixture script into a scratch directory.
func scriptVariant(_ item: String, _ mutate: (inout JSONObject) -> Void) throws -> FixtureScriptReference {
    guard case .object(var object) = try StrictJSON.parseFile(repoURL("datasets/fixtures/scripts/\(item).json")) else {
        fatalError("script is not an object")
    }
    mutate(&object)
    let url = try makeScratch().appendingPathComponent("\(item).json")
    let data = try JSONWriter.pretty(.object(object))
    try data.write(to: url)
    return FixtureScriptReference(url: url, sha256: SHA256Hex.digest(data))
}

/// Step-mode delay model: accumulates virtual time, never sleeps.
actor VirtualDelays: AdapterDelayService {
    private(set) var totalNS: Int64 = 0
    private(set) var calls = 0
    func delay(milliseconds: Int64) async throws {
        totalNS += milliseconds * 1_000_000
        calls += 1
    }
}

/// Real/accelerated delay model: sleeps on the run clock.
struct ClockDelays: AdapterDelayService {
    let clock: any RunClock
    func delay(milliseconds: Int64) async throws {
        try await clock.sleep(untilNS: clock.nowNS() + milliseconds * 1_000_000)
    }
}

/// Test sink: applies the production output validator, then records.
actor CollectingSink: AdapterEventSink {
    private var validator: AdapterOutputValidator
    private(set) var events: [AdapterEvent] = []

    init(role: AdapterRole, adapterID: String, durationSamples: Int64,
         granularity: TranscriptOutputGranularity? = nil) {
        validator = AdapterOutputValidator(role: role, adapterID: adapterID, durationSamples: durationSamples,
                                           transcriptGranularity: granularity ?? (role == .asr ? .utterances : nil))
    }

    func emit(_ event: AdapterEvent) async throws {
        try validator.check(event)
        events.append(event)
    }

    var unfinalized: [String] { validator.unfinalizedUtterances }
}

struct StreamSpec: Sendable {
    var item = "two-speaker-en"
    var sourceID = "two-speaker-en"
    var rate: Int64 = 16_000
    var duration: Int64 = 192_000
    var frame: Int64 = 320
    var mode: ReplayMode = .step
    var delayMS: Int64 = 0
    var seed: Int64 = 42
}

func context(_ role: AdapterRole, _ spec: StreamSpec, script: FixtureScriptReference?,
             delays: any AdapterDelayService, clock: any RunClock = FakeRunClock()) -> AdapterContext {
    AdapterContext(role: role,
                   selection: AdapterSelection(id: role == .asr ? MockAdapterIDs.asr : MockAdapterIDs.diarization,
                                               revision: "1", delayMS: spec.delayMS),
                   runID: "test-run", streamID: "audio-0", sourceID: spec.sourceID,
                   format: PCMFormat(sampleRateHz: spec.rate), durationSamples: spec.duration, frameSamples: spec.frame,
                   mode: spec.mode, seed: spec.seed, fixtureScript: script, delays: delays, clock: clock)
}

func chunk(_ index: Int64, _ start: Int64, _ end: Int64, spec: StreamSpec, fill: Float = 0) throws -> AudioChunk {
    try AudioChunk(runID: "test-run", streamID: "audio-0", sourceID: spec.sourceID, chunkIndex: index,
                   sampleRateHz: spec.rate, startSample: start, endSample: end, replayMode: spec.mode,
                   samples: OwnedMonoPCM(copying: [Float](repeating: fill, count: Int(end - start))))
}

func consumeContext(_ role: AdapterRole, _ index: Int64) -> ConsumeContext {
    ConsumeContext(invocationID: "\(role.rawValue)/consume/\(index)", scheduledMonotonicNS: nil,
                   deliveredMonotonicNS: 0, queueExitMonotonicNS: 0, mediaDeadlineVirtualNS: nil,
                   deliveredVirtualNS: nil)
}

/// Minimal driver: prepare, consume every chunk (optionally skipping some, to
/// model dropped audio), flush and shut down — the lifecycle the M4 runner uses.
func drive(_ adapter: any StreamingAdapter, _ spec: StreamSpec, script: FixtureScriptReference?,
           sink: any AdapterEventSink, delays: any AdapterDelayService = VirtualDelays(),
           skip: Set<Int64> = []) async throws -> AdapterShutdownReport {
    let role = adapter.role
    do {
        _ = try await adapter.prepare(context: context(role, spec, script: script, delays: delays), sink: sink)
        let plan = try ChunkPlan(totalFrames: spec.duration, frameSamples: spec.frame)
        var consumed: Int64 = 0
        var dropped: [SampleInterval] = []
        for entry in plan {
            if skip.contains(entry.index) {
                dropped.append(try SampleInterval(start: entry.start, end: entry.end))
                continue
            }
            try await adapter.consume(try chunk(entry.index, entry.start, entry.end, spec: spec),
                                      context: consumeContext(role, entry.index))
            consumed += entry.count
        }
        try await adapter.flush(endOfStream: StreamEnd(invocationID: "\(role.rawValue)/flush", finalSample: spec.duration,
                                                       consumedSamples: consumed, droppedRanges: dropped,
                                                       reason: .normal))
    } catch {
        _ = await adapter.shutdown()
        throw error
    }
    return await adapter.shutdown()
}

/// Compact comparable view of an adapter event (matches testdata/goldens/mock-events.json).
func view(_ event: AdapterEvent) -> JSONValue {
    var members: [(String, JSONValue)] = [
        ("type", .string(event.eventType.rawValue)), ("cause_chunk_index", event.cause.chunkIndex.json),
        ("invocation_id", .string(event.cause.invocationID)),
        ("media", event.media.map { .array([.int($0.start), .int($0.end)]) } ?? .null),
    ]
    switch event.output {
    case let .transcript(utterance, revision, text, _):
        members += [("utterance_id", .string(utterance)), ("revision", .int(revision)), ("text", .string(text))]
    case let .speakerSegment(segment, speaker):
        members += [("segment_id", .string(segment)), ("speaker_id", .string(speaker))]
    case let .diagnostic(code, _, _, missing):
        members += [("code", .string(code)), ("missing", .array(missing.map { $0.toJSON() }))]
    }
    return .object(JSONObject(members))
}

/// Key-order-insensitive form for semantic equality checks.
extension JSONValue {
    var keySorted: JSONValue {
        switch self {
        case .object(let object):
            return .object(JSONObject(object.members.sorted { $0.key < $1.key }.map { ($0.key, $0.value.keySorted) }))
        case .array(let elements):
            return .array(elements.map(\.keySorted))
        default:
            return self
        }
    }
}
