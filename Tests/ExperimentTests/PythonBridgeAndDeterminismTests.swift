import AdapterContracts
import AudioCore
import BenchmarkSupport
import Experiment
import Foundation
import Testing

struct PythonBridgeTests {
    private func bridge(timeout: Int64 = 30, maxLog: Int64 = 64 << 20) -> PythonBridge {
        PythonBridge(python: repoURL(".venv/bin/python"), projectRoot: repositoryRoot, timeoutSeconds: timeout,
                     maxLogBytes: maxLog)
    }

    @Test func childFailureIsReportedWithItsStderr() async throws {
        let logs = try makeScratch()
        let result = try await bridge().runRaw(["-c", "import sys; sys.stderr.write('boom'); sys.exit(3)"],
                                               logDirectory: logs, label: "fail")
        #expect(result.exitCode == 3 && !result.succeeded)
        #expect(result.stderrTail() == "boom")
    }

    @Test func timeoutTerminatesTheChild() async throws {
        let logs = try makeScratch()
        let start = Date()
        let result = try await bridge(timeout: 1).runRaw(["-c", "import time; time.sleep(30)"], logDirectory: logs,
                                                         label: "slow")
        #expect(result.timedOut && !result.succeeded)
        #expect(Date().timeIntervalSince(start) < 10, "the parent does not wait for the child's sleep")
    }

    @Test func largeOutputCannotHangTheParent() async throws {
        let logs = try makeScratch()
        // 8 MiB of stderr would fill any pipe; output goes to files, and the cap stops a runaway child.
        let result = try await bridge(maxLog: 1 << 20).runRaw(
            ["-c", "import sys\nfor _ in range(4096): sys.stderr.write('x' * 2048)\nimport time; time.sleep(30)"],
            logDirectory: logs, label: "spew")
        #expect(result.outputLimitHit && !result.succeeded)
    }

    @Test func environmentIsExplicitAndOffline() async throws {
        let logs = try makeScratch()
        let result = try await bridge().runRaw(
            ["-c", "import os, json; print(json.dumps({k: os.environ.get(k) for k in ['PYTHONPATH', 'HF_HUB_OFFLINE', 'PYTHONNOUSERSITE', 'HOME']}))"],
            logDirectory: logs, label: "env")
        #expect(result.succeeded)
        let env = object(try StrictJSON.parse(result.stdout()))
        #expect(env["PYTHONPATH"] == .string(repoURL("analysis/src").path))
        #expect(env["HF_HUB_OFFLINE"] == .string("1") && env["PYTHONNOUSERSITE"] == .string("1"))
        #expect(env["HOME"] == .null, "the child does not inherit the caller's environment")
    }
}

struct StepDeterminismTests {
    @Test func threeStepRunsProduceIdenticalLogicalTraces() async throws {
        var views: [[JSONValue]] = []
        var predictions: [JSONValue] = []
        // One config, three runs (G2): only run IDs and output paths differ.
        let scratch = try makeScratch()
        let config = try Variant().write(in: scratch)
        for n in 0..<3 {
            let runDir = scratch.appendingPathComponent("runs/step-\(n)")
            let request = RunRequest(configURL: config, runsDirectory: scratch.appendingPathComponent("runs"),
                                     runID: "step-\(n)", projectRoot: repositoryRoot)
            let (outcome, _) = await ExperimentRunner().runtimeOnly(request)
            #expect(outcome.failure == nil, "\(String(describing: outcome.failure))")
            views.append(logicalView(try readEvents(runDir.appendingPathComponent("events.jsonl.partial"))))
            var prediction = try readJSON(runDir.appendingPathComponent("predictions.json"))
            prediction.set("run_id", .null)
            prediction.set("source_events", .null)
            predictions.append(.object(prediction))
        }
        #expect(views[0] == views[1] && views[1] == views[2])
        #expect(predictions[0] == predictions[1] && predictions[1] == predictions[2])
        #expect(views[0].count > 1_800, "the projection keeps chunk and adapter events")
    }

    @Test func stepDelayIsVirtualOnly() async throws {
        var variant = Variant()
        variant.asrDelayMS = 50
        let (request, runDir) = try variant.request()
        let start = Date()
        let (outcome, _) = await ExperimentRunner().runtimeOnly(request)
        #expect(outcome.failure == nil)
        #expect(Date().timeIntervalSince(start) < 15, "600 x 50 ms = 30 s of virtual delay must not sleep")
        let events = try readEvents(runDir.appendingPathComponent("events.jsonl.partial"))
        let asrStages = events.filter { $0.type == .stageCompleted && $0.payload["stage"] == .string("asr.consume") }
        #expect(asrStages.allSatisfy { $0.payload["virtual_duration_ns"] == .int(50_000_000) })
        // Virtual time runs ahead of media time; delivery happens at max(now, deadline):
        // chunk k is delivered at 20 ms + k * 50 ms (hand-derived: each consume adds 50 ms).
        let delivered = events.filter { $0.type == .audioChunkDelivered }.map { $0.payload["delivered_virtual_ns"] }
        #expect(delivered.count == 600)
        #expect(delivered.enumerated().allSatisfy { $0.element == .int(20_000_000 + Int64($0.offset) * 50_000_000) })
    }
}

/// An adapter not known to the runner, substituted through the factory table:
/// proves a new adapter needs no runner changes (V20 through the full pipeline).
actor FixedSpeakerDiarization: DiarizationAdapter {
    nonisolated let adapterID = "test-fixed-speaker"
    nonisolated var role: AdapterRole { .diarization }
    private var lifecycle = AdapterLifecycle(adapterID: "test-fixed-speaker")
    private var sink: (any AdapterEventSink)?
    private var end: Int64 = 0
    private let acceptedRate: Int64

    init(acceptedRate: Int64 = 16_000) { self.acceptedRate = acceptedRate }

    func prepare(context: AdapterContext, sink: any AdapterEventSink) async throws -> AdapterCapabilities {
        try lifecycle.beginPrepare()
        self.sink = sink
        return try AdapterCapabilities(role: .diarization, revision: "t", sampleRatesHz: [acceptedRate], channels: 1,
                                       frameMultipleSamples: 160, incremental: true, emitsPartials: false,
                                       emitsFinals: true, transcriptGranularity: nil, requestedPlacement: .cpu,
                                       observedPlacement: .missing(.unavailable, source: "test", reason: "no backend"))
    }

    func consume(_ chunk: AudioChunk, context: ConsumeContext) async throws {
        try lifecycle.checkConsume(chunkIndex: chunk.chunkIndex)
        end = chunk.endSample
    }

    func flush(endOfStream: StreamEnd) async throws {
        try lifecycle.beginFlush()
        try await sink?.emit(AdapterEvent(.speakerSegment(segmentID: "all", speakerID: "S"),
                                          media: try SampleInterval(start: 0, end: end),
                                          cause: .flush(invocationID: endOfStream.invocationID)))
    }

    func shutdown() async -> AdapterShutdownReport {
        _ = lifecycle.beginShutdown()
        return .clean
    }
}

struct RunnerExtensionTests {
    @Test func aSubstitutedAdapterRunsThroughTheUnchangedRunner() async throws {
        var factory = AdapterFactory.builtIn
        factory.entries["test-fixed-speaker"] = .init(role: .diarization, requestedPlacement: .cpu, isMock: true) {
            FixedSpeakerDiarization()
        }
        var variant = Variant()
        variant.diarizationID = "test-fixed-speaker"
        let (request, runDir) = try variant.request()
        let (outcome, _) = await ExperimentRunner(factory: factory).runtimeOnly(request)
        #expect(outcome.failure == nil, "\(String(describing: outcome.failure))")
        let predictions = try readJSON(runDir.appendingPathComponent("predictions.json"))
        guard case .array(let speakers)? = predictions["speakers"] else { Issue.record("no speakers"); return }
        #expect(speakers.count == 1 && object(speakers[0])["end_sample"] == .int(192_000))
        #expect(object(object(predictions["adapters"]!)["diarization"]!)["id"] == .string("test-fixed-speaker"))
    }

    @Test func incompatibleCapabilitiesAreRejectedBeforeReplay() async throws {
        var factory = AdapterFactory.builtIn
        factory.entries["test-fixed-speaker"] = .init(role: .diarization, requestedPlacement: .cpu, isMock: true) {
            FixedSpeakerDiarization(acceptedRate: 48_000)
        }
        var variant = Variant()
        variant.diarizationID = "test-fixed-speaker"
        let (request, runDir) = try variant.request()
        let (outcome, _) = await ExperimentRunner(factory: factory).runtimeOnly(request)
        #expect(outcome.exitCode == ExitCodes.runtime)
        #expect(outcome.failure?.message.contains("48000") == true)
        let events = try readEvents(runDir.appendingPathComponent("events.jsonl.partial"))
        #expect(!events.contains { $0.type == .audioChunkScheduled }, "rejected before replay started")
        #expect(events.filter { $0.type == .adapterStopped }.count == 2, "both adapters still shut down")
    }
}
