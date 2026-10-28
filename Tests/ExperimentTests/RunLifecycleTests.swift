import AdapterContracts
import BenchmarkSupport
import Experiment
import Foundation
import Testing

struct RunLifecycleTests {
    @Test func runtimeStageProducesValidUnsealedArtifacts() async throws {
        let (request, runDir) = try Variant().request()
        let (outcome, runtime) = await ExperimentRunner().runtimeOnly(request)
        #expect(outcome.failure == nil, "\(String(describing: outcome.failure))")
        let runtimeArtifacts = try #require(runtime)

        // Nonterminal: the runtime stage never claims completion and writes no metrics.
        let status = try RunStatus.read(try StrictJSON.parseFile(runDir.appendingPathComponent("status.json")))
        #expect(status.state == .flushing)
        #expect(status.artifacts == nil)
        #expect(!FileManager.default.fileExists(atPath: runDir.appendingPathComponent("metrics.json").path))
        #expect(!FileManager.default.fileExists(atPath: runDir.appendingPathComponent("events.jsonl").path),
                "the trace keeps its .partial name until sealing")

        // The prefix descriptor identifies exactly the bytes on disk.
        let partial = runDir.appendingPathComponent("events.jsonl.partial")
        let data = try Data(contentsOf: partial)
        #expect(Int64(data.count) == runtimeArtifacts.prefix.byteCount)
        #expect(SHA256Hex.digest(data) == runtimeArtifacts.prefix.sha256)
        let events = try readEvents(partial)
        #expect(Int64(events.count) == runtimeArtifacts.prefix.lineCount)
        #expect(events.map(\.sequence) == (0..<Int64(events.count)).map { $0 }, "contiguous sequence from 0")
        #expect(events.first?.type == .experimentStarted)
        #expect(events.last?.type == .experimentRuntimeCompleted, "runtime_completed is the last runtime event")
        #expect(!events.contains { $0.type.isTerminal })
        // Recorded time follows emission and is nondecreasing in sequence order.
        #expect(events.allSatisfy { $0.monotonicRecordedNS >= $0.monotonicEmittedNS })
        #expect(zip(events, events.dropFirst()).allSatisfy { $0.monotonicRecordedNS <= $1.monotonicRecordedNS })

        // Step mode: 600 chunks, each scheduled, delivered and consumed, ASR before diarization.
        let count = { (type: EventType) in events.filter { $0.type == type }.count }
        #expect(count(.audioChunkScheduled) == 600 && count(.audioChunkDelivered) == 600 && count(.audioChunkConsumed) == 600)
        #expect(count(.stageCompleted) == 600 * 2 + 2 + 2, "2 consumes per chunk, 2 flushes, prepare_audio, adapter_prepare")
        #expect(count(.adapterStarted) == 2 && count(.adapterStopped) == 2)
        #expect(count(.transcriptPartial) == 2 && count(.transcriptFinal) == 2 && count(.speakerSegment) == 2)
        #expect(count(.telemetrySample) == 2, "only start/end summaries go into the trace")
        // Acknowledgment barrier: within a chunk, scheduled < delivered < adapter output < consumed.
        let chunk99 = events.filter { $0.causeChunkIndex == 99 }.map(\.type)
        #expect(chunk99 == [.audioChunkScheduled, .audioChunkDelivered, .transcriptPartial, .stageCompleted,
                            .stageCompleted, .audioChunkConsumed])

        // Runtime summary carries the conversion disclosure (DEC-026) and integrity checks.
        let summary = try readJSON(runDir.appendingPathComponent("runtime_summary.json"))
        let conversion = object(summary["conversion"]!)
        #expect(conversion["endpoint_policy"] == .string("allow_one_frame_v1"))
        #expect(conversion["endpoint_status"] == .string("bypassed"))
        #expect(summary["data_loss"] == .bool(false))
        #expect(object(summary["integrity"]!)["pre_replay_verified"] == .bool(true))
        #expect(summary["events_prefix"] == runtimeArtifacts.prefix.toJSON())
        Evidence.copy(runDir, as: "M4/runtime-stage-step")
    }

    @Test func predictionsAreBuiltFromFinalsInMediaOrder() async throws {
        let (request, runDir) = try Variant().request()
        let (outcome, _) = await ExperimentRunner().runtimeOnly(request)
        #expect(outcome.failure == nil, "\(String(describing: outcome.failure))")
        let predictions = try readJSON(runDir.appendingPathComponent("predictions.json"))
        guard case .array(let transcript)? = predictions["transcript"], case .array(let speakers)? = predictions["speakers"] else {
            Issue.record("missing arrays")
            return
        }
        #expect(transcript.map { object($0)["text"] } == [.string("hello world"), .string("a x c d")],
                "finals only; partial text is never concatenated")
        #expect(transcript.map { object($0)["start_sample"] } == [.int(0), .int(64_000)])
        #expect(speakers.map { object($0)["speaker_id"] } == [.string("X"), .string("Y")], "sorted by media start")
        #expect(predictions["mock"] == .bool(true))
        #expect(object(predictions["coverage"]!)["dropped_samples"] == .int(0))
    }

    @Test func productionRunSealsACompletedRun() async throws {
        let (request, runDir) = try Variant().request()
        let outcome = await ExperimentRunner().run(request)
        #expect(outcome.exitCode == 0, "\(String(describing: outcome.failure))")
        let status = try RunStatus.read(try StrictJSON.parseFile(runDir.appendingPathComponent("status.json")))
        #expect(status.state == .completed)
        #expect(!FileManager.default.fileExists(atPath: runDir.appendingPathComponent("events.jsonl.partial").path))
        let events = try readEvents(runDir.appendingPathComponent("events.jsonl"))
        #expect(events.last?.type == .experimentCompleted)
        #expect(events.filter { $0.type.isTerminal }.count == 1)
        #expect(status.lastEventSequence == events.last?.sequence)
        // Every sealed digest matches the bytes on disk.
        for artifact in status.artifacts ?? [] {
            let (sha, bytes) = try SHA256Hex.file(runDir.appendingPathComponent(artifact.path))
            #expect(sha == artifact.sha256 && bytes == artifact.byteCount, "\(artifact.path)")
        }
        #expect(status.artifacts?.contains { $0.path == "metrics.json" } == true)
        #expect(!FileManager.default.fileExists(atPath: runDir.appendingPathComponent("scratch/converted.f32le").path),
                "scratch is removed only after the terminal status is durable")
        let metrics = try readJSON(runDir.appendingPathComponent("metrics.json"))
        #expect(metrics["mock"] == .bool(true))
        Evidence.copy(runDir, as: "M5/sealed-step-run")
    }

    @Test func scoringFailureFailsTheRunAndKeepsRawArtifacts() async throws {
        // An interpreter wrapper that serves env-info but fails the score operation.
        let scratch = try makeScratch()
        let wrapper = scratch.appendingPathComponent("python")
        try Data("#!/bin/sh\nif [ \"$3\" = score ]; then echo scorer exploded >&2; exit 3; fi\nexec \(repoURL(".venv/bin/python").path) \"$@\"\n".utf8)
            .write(to: wrapper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        var variant = Variant()
        variant.pythonExecutable = wrapper.path
        let (request, runDir) = try variant.request()
        let outcome = await ExperimentRunner().run(request)
        #expect(outcome.exitCode == ExitCodes.analysis)
        #expect(outcome.failure?.message.contains("scorer exploded") == true)
        let status = try RunStatus.read(try StrictJSON.parseFile(runDir.appendingPathComponent("status.json")))
        #expect(status.state == .failed && status.failure?.stage == .scoring)
        for name in ["runtime_summary.json", "predictions.json", "events.jsonl.partial"] {
            #expect(FileManager.default.fileExists(atPath: runDir.appendingPathComponent(name).path), "\(name) retained")
        }
        #expect(!FileManager.default.fileExists(atPath: runDir.appendingPathComponent("metrics.json").path))
        let events = try readEvents(runDir.appendingPathComponent("events.jsonl.partial"))
        #expect(events.last?.type == .experimentFailed, "terminal event appended after the frozen prefix")
    }
}
