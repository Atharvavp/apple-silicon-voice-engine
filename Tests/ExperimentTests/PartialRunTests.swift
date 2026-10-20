import AdapterContracts
import BenchmarkSupport
import Experiment
import Foundation
import Testing

/// Failure injection: a failed or cancelled run must never look completed,
/// must keep its partial trace with exactly one terminal event, and must report
/// the right category (plan G3).
struct PartialRunTests {
    private func fault(_ role: String, _ stage: String, chunk: Int64? = nil) -> @Sendable (inout JSONObject) -> Void {
        { script in
            script.set("faults", .array([.object(JSONObject([("role", .string(role)), ("stage", .string(stage)),
                                                             ("chunk_index", chunk.json)]))]))
        }
    }

    private func assertFailedRun(_ runDir: URL, category: ErrorCategory, terminal: EventType = .experimentFailed) throws {
        let status = try RunStatus.read(try StrictJSON.parseFile(runDir.appendingPathComponent("status.json")))
        #expect(status.state == (terminal == .experimentCancelled ? .cancelled : .failed))
        #expect(status.failure?.category == category)
        #expect(!FileManager.default.fileExists(atPath: runDir.appendingPathComponent("events.jsonl").path),
                "a failed trace keeps its .partial name")
        let events = try readEvents(runDir.appendingPathComponent("events.jsonl.partial"))
        #expect(events.filter { $0.type.isTerminal }.count == 1, "exactly one terminal event")
        #expect(events.last?.type == terminal)
        #expect(events.map(\.sequence) == (0..<Int64(events.count)).map { $0 })
        #expect(status.lastEventSequence == events.last?.sequence)
        #expect(!FileManager.default.fileExists(atPath: runDir.appendingPathComponent("metrics.json").path))
    }

    @Test(arguments: [("asr", "prepare", nil), ("diarization", "prepare", nil), ("asr", "consume", 7 as Int64?),
                      ("diarization", "consume", 0 as Int64?), ("asr", "flush", nil), ("diarization", "shutdown", nil)])
    func adapterFaultsFailTheRunWithRuntimeCategory(_ role: String, _ stage: String, _ chunk: Int64?) async throws {
        var variant = Variant()
        variant.mutateScript = fault(role, stage, chunk: chunk)
        let (request, runDir) = try variant.request()
        let outcome = await ExperimentRunner().run(request)
        #expect(outcome.exitCode == ExitCodes.runtime, "\(String(describing: outcome.failure))")
        try assertFailedRun(runDir, category: .runtime)
        let events = try readEvents(runDir.appendingPathComponent("events.jsonl.partial"))
        if stage != "shutdown" {
            #expect(events.contains { $0.type == .adapterFailed }, "the failing adapter is named in the trace")
        }
        // Shutdown is still called exactly once per prepared adapter, after the failure.
        let stopped = events.filter { $0.type == .adapterStopped }.map(\.producerID)
        #expect(Set(stopped).count == stopped.count)
        if stage == "consume" { #expect(stopped.count == 2) }
        Evidence.copy(runDir, as: "M4/failures/\(role)-\(stage)")
    }

    @Test func invalidRevisionTransitionIsAContractFailure() async throws {
        var variant = Variant()
        variant.mutateScript = { script in
            guard case .array(var asr)? = script["asr"], case .object(var entry) = asr[1] else { return }
            entry.set("revision", .int(0)) // final with revision 0 after partial 0: no increase
            asr[1] = .object(entry)
            script.set("asr", .array(asr))
        }
        let (request, runDir) = try variant.request()
        let outcome = await ExperimentRunner().run(request)
        #expect(outcome.exitCode == ExitCodes.runtime)
        #expect(outcome.failure?.message.contains("revision") == true)
        try assertFailedRun(runDir, category: .runtime)
    }

    @Test func preflightFailuresCreateNoRunDirectory() async throws {
        // Required reference missing -> dataset error (exit 3).
        var noReference = Variant()
        noReference.mutateItem = { item in
            item.set("speaker_segments_path", .null)
            item.set("speaker_segments_sha256", .null)
            item.set("coverage", .object(JSONObject([("transcript", .bool(true)), ("speakers", .bool(false)),
                                                     ("joint_words", .bool(false))])))
            item.set("reference_sha256", .string(DatasetItem.referenceDescriptorHash(
                transcriptSHA256: "0974d8b4578f730de9754a86dba13af5eb48e0caf3a882f92a7a9567e4c71c25", speakersSHA256: nil)))
        }
        // Audio hash mismatch -> dataset error (exit 3).
        var badHash = Variant()
        badHash.mutateItem = { $0.set("audio_sha256", .string(String(repeating: "a", count: 64))) }
        // Unknown adapter -> invalid input (exit 2).
        var unknownAdapter = Variant()
        unknownAdapter.asrID = "no-such-adapter"
        for (variant, code) in [(noReference, ExitCodes.dataset), (badHash, ExitCodes.dataset),
                                (unknownAdapter, ExitCodes.invalidInput)] {
            let (request, runDir) = try variant.request()
            let outcome = await ExperimentRunner().run(request)
            #expect(outcome.exitCode == code, "\(String(describing: outcome.failure))")
            #expect(!FileManager.default.fileExists(atPath: runDir.path), "no success-looking artifacts")
        }
    }

    @Test func pendingDatasetCannotBeSelected() async throws {
        let scratch = try makeScratch()
        var yaml = try String(contentsOf: repoURL("configs/mock-step.yaml"), encoding: .utf8)
        yaml = yaml.replacingOccurrences(of: "../datasets/manifests/synthetic.json",
                                         with: repoURL("datasets/manifests/hindi-pending.json").path)
            .replacingOccurrences(of: "../.venv/bin/python", with: repoURL(".venv/bin/python").path)
        let config = scratch.appendingPathComponent("c.yaml")
        try Data(yaml.utf8).write(to: config)
        let outcome = await ExperimentRunner().run(RunRequest(configURL: config, runsDirectory: scratch.appendingPathComponent("runs"),
                                                              runID: "pending", projectRoot: repositoryRoot))
        #expect(outcome.exitCode == ExitCodes.dataset)
        #expect(outcome.failure?.message.contains("pending") == true)
    }

    @Test func existingRunDirectoryIsNeverOverwritten() async throws {
        let (request, runDir) = try Variant().request(runID: "fixed-id")
        try FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: runDir.appendingPathComponent("marker"))
        let outcome = await ExperimentRunner().run(request)
        #expect(outcome.exitCode == ExitCodes.invalidInput)
        #expect(try String(contentsOf: runDir.appendingPathComponent("marker"), encoding: .utf8) == "keep")
    }

    @Test func strictEndpointPolicyRefusesACorrectedConversion() async throws {
        var variant = Variant()
        variant.item = "endpoint-trim-en"
        variant.endpointPolicy = "strict"
        let (request, runDir) = try variant.request()
        let outcome = await ExperimentRunner().run(request)
        #expect(outcome.exitCode == ExitCodes.audio)
        try assertFailedRun(runDir, category: .audio)
    }

    @Test func cancellationProducesACancelledRunWithoutOrphans() async throws {
        var variant = Variant()
        variant.mode = "realtime" // 12 s of paced audio: long enough to cancel mid-replay
        let (request, runDir) = try variant.request()
        let task = Task { await ExperimentRunner().run(request) }
        // Wait until replay is running, then cancel.
        for _ in 0..<200 {
            if let status = try? RunStatus.read(try StrictJSON.parseFile(runDir.appendingPathComponent("status.json"))),
               status.state == .running { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        task.cancel()
        let outcome = await task.value
        #expect(outcome.exitCode == ExitCodes.interrupted, "\(String(describing: outcome.failure))")
        try assertFailedRun(runDir, category: .cancelled, terminal: .experimentCancelled)
        let events = try readEvents(runDir.appendingPathComponent("events.jsonl.partial"))
        #expect(events.filter { $0.type == .adapterStopped }.count == 2, "both adapters shut down after cancellation")
        Evidence.copy(runDir, as: "M4/failures/cancelled")
    }
}
