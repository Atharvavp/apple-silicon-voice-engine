import AdapterContracts
import AudioCore
import BenchmarkSupport
import Foundation
import RealAdapterSupport

let repositoryRoot: URL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

func repoURL(_ relative: String) -> URL { repositoryRoot.appendingPathComponent(relative) }

func makeScratch() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("voicebench-tests/\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func object(_ value: JSONValue) -> JSONObject {
    guard case .object(let object) = value else { fatalError("expected object, got \(value.typeName)") }
    return object
}

let fakeFrameworkRevision = String(repeating: "a", count: 40)

/// Writes a profile and its one model file into a scratch root; returns the roots and revision.
struct ProfileFixture {
    let roots: Phase1Roots
    let revision: String
    let modelFile: URL

    static func make(adapterID: String, role: AdapterRole, settings: [(String, JSONValue)] = [],
                     tolerance: Int64? = 1_280, frameworkRevision: String = fakeFrameworkRevision,
                     mutate: ((inout JSONObject) -> Void)? = nil) throws -> ProfileFixture {
        let scratch = try makeScratch()
        let profiles = scratch.appendingPathComponent("profiles", isDirectory: true)
        let assets = scratch.appendingPathComponent("assets", isDirectory: true)
        let modelDirectory = assets.appendingPathComponent("model.bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: profiles, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
        let modelFile = modelDirectory.appendingPathComponent("weights.bin")
        let bytes = Data("fake weights for \(adapterID)".utf8)
        try bytes.write(to: modelFile)
        var profile = JSONObject([
            ("profile_version", .int(1)), ("adapter_id", .string(adapterID)), ("role", .string(role.rawValue)),
            ("framework", .object(JSONObject([("name", .string("FakeFramework")), ("source", .string("test")),
                                              ("revision", .string(frameworkRevision)), ("dependency_lock_sha256", .null)]))),
            ("model", .object(JSONObject([
                ("repository", .string("test/fake-model")), ("revision", .string(String(repeating: "b", count: 40))),
                ("licenses", .array([.string("test-only")])), ("precision", .string("fp32")),
                ("load_path", .string("model.bundle")),
                ("files", .array([.object(JSONObject([("path", .string("model.bundle/weights.bin")),
                                                      ("sha256", .string(SHA256Hex.digest(bytes))),
                                                      ("bytes", .int(Int64(bytes.count)))]))])),
            ]))),
            ("compute_units", .string("all")),
            ("settings", .object(JSONObject(settings))),
            ("output", .object(JSONObject([("projection", .string(role == .asr ? "recording_text" : "final_timeline_at_flush")),
                                           ("eos_tail_tolerance_samples", tolerance.json)]))),
            ("notes", .string("test fixture")),
        ])
        mutate?(&profile)
        let data = try JSONWriter.pretty(.object(profile))
        try data.write(to: profiles.appendingPathComponent("\(adapterID).json"))
        return ProfileFixture(roots: Phase1Roots(profiles: profiles, assets: assets),
                              revision: "p1:\(SHA256Hex.digest(data))", modelFile: modelFile)
    }
}

struct NoDelays: AdapterDelayService {
    func delay(milliseconds: Int64) async throws {}
}

struct FixedClock: RunClock {
    func nowNS() -> Int64 { 1 }
    func sleep(untilNS: Int64) async throws {}
}

func context(role: AdapterRole, adapterID: String, revision: String, durationSamples: Int64,
             sampleRate: Int64 = 16_000, delayMS: Int64 = 0, fixture: FixtureScriptReference? = nil) -> AdapterContext {
    AdapterContext(role: role, selection: AdapterSelection(id: adapterID, revision: revision, delayMS: delayMS),
                   runID: "run", streamID: "stream", sourceID: "item", format: PCMFormat(sampleRateHz: sampleRate),
                   durationSamples: durationSamples, frameSamples: 320, mode: .step, seed: 1, fixtureScript: fixture,
                   delays: NoDelays(), clock: FixedClock())
}

func chunk(_ index: Int64, start: Int64, count: Int64, rate: Int64 = 16_000) throws -> AudioChunk {
    try AudioChunk(runID: "run", streamID: "stream", sourceID: "item", chunkIndex: index, sampleRateHz: rate,
                   startSample: start, endSample: start + count, replayMode: .step,
                   samples: OwnedMonoPCM(copying: [Float](repeating: 0.01, count: Int(count))))
}

func consumeContext(_ index: Int64) -> ConsumeContext {
    ConsumeContext(invocationID: "inv-\(index)", scheduledMonotonicNS: nil, deliveredMonotonicNS: 1,
                   queueExitMonotonicNS: 1, mediaDeadlineVirtualNS: nil, deliveredVirtualNS: nil)
}

func streamEnd(_ samples: Int64, reason: StreamEnd.Reason = .normal, dropped: [SampleInterval] = []) -> StreamEnd {
    StreamEnd(invocationID: "inv-flush", finalSample: samples, consumedSamples: samples - dropped.reduce(0) { $0 + $1.end - $1.start },
              droppedRanges: dropped, reason: reason)
}

/// Sink with the production output validator; optional per-emit delay (backpressure) and failure.
actor CollectingSink: AdapterEventSink {
    private var validator: AdapterOutputValidator
    private(set) var events: [AdapterEvent] = []
    private let delayNS: UInt64
    private let failAfter: Int?

    init(role: AdapterRole, adapterID: String, durationSamples: Int64, granularity: TranscriptOutputGranularity?,
         delayNS: UInt64 = 0, failAfter: Int? = nil) {
        validator = AdapterOutputValidator(role: role, adapterID: adapterID, durationSamples: durationSamples,
                                           transcriptGranularity: granularity)
        self.delayNS = delayNS
        self.failAfter = failAfter
    }

    struct SinkFailure: Error {}

    func emit(_ event: AdapterEvent) async throws {
        if let failAfter, events.count >= failAfter { throw SinkFailure() }
        if delayNS > 0 { try await Task.sleep(nanoseconds: delayNS) }
        try validator.check(event)
        events.append(event)
    }
}

/// Model-free diarization backend: records calls, returns a scripted final timeline.
actor FakeDiarizationBackend: DiarizationBackend {
    private(set) var pushedSamples = 0
    private(set) var pushes = 0
    private(set) var finishCalls = 0
    private(set) var released = 0
    private(set) var loaded = false
    let timeline: [NativeSpeakerSegment]
    let failLoad: Bool

    init(timeline: [NativeSpeakerSegment], failLoad: Bool = false) {
        self.timeline = timeline
        self.failLoad = failLoad
    }

    struct LoadFailure: Error {}

    func load() async throws {
        if failLoad { throw LoadFailure() }
        loaded = true
    }

    func push(_ samples: [Float]) async throws {
        pushes += 1
        pushedSamples += samples.count
    }

    func finish() async throws -> [NativeSpeakerSegment] {
        finishCalls += 1
        return timeline
    }

    func release() async { released += 1 }
}

/// Model-free ASR backend: returns scripted updates per push and at finish.
actor FakeASRBackend: StreamingASRBackend {
    nonisolated let accumulatorMode: RecordingTranscriptAccumulator.Mode
    private var script: [[ASRNativeUpdate]]
    private let finishUpdates: [ASRNativeUpdate]
    private(set) var released = 0

    init(mode: RecordingTranscriptAccumulator.Mode, perPush: [[ASRNativeUpdate]], finish: [ASRNativeUpdate]) {
        accumulatorMode = mode
        script = perPush
        finishUpdates = finish
    }

    func load() async throws {}

    func push(_ samples: [Float]) async throws -> [ASRNativeUpdate] {
        script.isEmpty ? [] : script.removeFirst()
    }

    func finish() async throws -> [ASRNativeUpdate] { finishUpdates }

    func release() async { released += 1 }
}

/// Holds the backend a factory closure created so a test can inspect it afterwards.
final class BackendBox<B: Sendable>: @unchecked Sendable {
    var backend: B?
}
