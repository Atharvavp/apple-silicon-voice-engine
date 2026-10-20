import AdapterContracts
import AudioCore
import BenchmarkSupport
import Experiment
import Foundation
import Testing

struct ProvenanceTests {
    @Test func frozenDocumentsRecordHashesOfTheBytesActuallyUsed() async throws {
        let (request, runDir) = try Variant().request()
        let (outcome, _) = await ExperimentRunner().runtimeOnly(request)
        #expect(outcome.failure == nil, "\(String(describing: outcome.failure))")
        let config = try readJSON(runDir.appendingPathComponent("config.json"))
        let inputs = object(config["inputs"]!)
        let manifestItem = object(try StrictJSON.parseFile(repoURL("datasets/manifests/synthetic.json")))
        guard case .array(let items)? = manifestItem["items"] else { Issue.record("no items"); return }
        let item = object(items.first { object($0)["item_id"] == .string("two-speaker-en") }!)

        // Inputs: audio, references, script and manifest snapshot hashes match the files on disk.
        #expect(inputs["audio_sha256"] == item["audio_sha256"])
        #expect(inputs["fixture_script_sha256"] == .string(try SHA256Hex.file(runDir.appendingPathComponent("inputs/fixture_script.json")).sha256))
        let transcript = try SHA256Hex.file(runDir.appendingPathComponent("references/transcript.json")).sha256
        let speakers = try SHA256Hex.file(runDir.appendingPathComponent("references/speakers.json")).sha256
        #expect(inputs["reference_sha256"] == .string(DatasetItem.referenceDescriptorHash(transcriptSHA256: transcript,
                                                                                          speakersSHA256: speakers)))
        #expect(inputs["manifest_sha256"] == .string(try SHA256Hex.file(runDir.appendingPathComponent("dataset_manifest_snapshot.json")).sha256))
        // Settings preimage: the persisted bytes hash to the recorded digest.
        #expect(config["settings_sha256"] == .string(try SHA256Hex.file(runDir.appendingPathComponent("config_settings.json")).sha256))
        // Schema bundle digest is recorded (DEC-008/DEC-050).
        let bundle = object(config["schema_bundle"]!)
        #expect(bundle["sha256"] == .string(try SchemaBundle.compute(projectRoot: repositoryRoot).sha256))
        #expect(object(config["policy_ids"]!)["endpoint"] == .string("allow_one_frame_v1"))
        #expect(object(config["requested_placement"]!)["asr"] == .string("cpu"))

        // Environment: build/lock provenance, availability-tagged hardware, requested vs observed placement.
        let environment = try readJSON(runDir.appendingPathComponent("environment.json"))
        let python = object(environment["python"]!)
        #expect(python["lock_sha256"] == .string(try SHA256Hex.file(repoURL("analysis/requirements-macos-arm64-py312.lock")).sha256))
        guard case .object(let distributions)? = python["distributions"] else { Issue.record("no distributions"); return }
        #expect(distributions["jiwer"] == .string("4.0.0"))
        #expect((distributions["pyannote-metrics"] ?? distributions["pyannote.metrics"]) == .string("4.2.0"))
        let hardware = object(environment["hardware"]!)
        for key in ["model", "chip", "memory_bytes", "logical_cpu_count"] {
            let fact = object(hardware[key]!)
            #expect(fact["status"] == .string("ok") || fact["reason"] != .null, "\(key) is observed or explains why not")
        }
        let placement = object(environment["placement"]!)
        let observed = object(object(placement["observed"]!)["asr"]!)
        #expect(observed["status"] == .string("unavailable"), "mocks never claim an observed placement")
        let capabilities = object(environment["telemetry_capabilities"]!)
        for counter in ["gpu_utilization", "ane_utilization", "power"] {
            #expect(object(capabilities[counter]!)["status"] == .string("unsupported"))
        }
        #expect(object(capabilities["cpu_time"]!)["status"] == .string("ok"))
        #expect(object(capabilities["resident_memory"]!)["status"] == .string("ok"))
        Evidence.write("V14/provenance-config.json", .object(config))
        Evidence.write("V14/provenance-environment.json", .object(environment))
    }

    @Test func inputChangedAfterPreflightIsDetected() async throws {
        // A fixture script whose bytes differ from the manifest hash fails preflight (exit 3).
        var variant = Variant()
        variant.mutateItem = { $0.set("fixture_script_sha256", .string(String(repeating: "b", count: 64))) }
        let (request, _) = try variant.request()
        let outcome = await ExperimentRunner().run(request)
        #expect(outcome.exitCode == ExitCodes.dataset)
        #expect(outcome.failure?.message.contains("fixture script") == true)
    }

    @Test func zeroLengthSourceClosesCleanly() async throws {
        // An empty but structurally valid WAV: no chunks, start/end events only, empty predictions.
        let scratch = try makeScratch()
        let wav = repoURL("datasets/fixtures/audio/mono16k_pcm16_empty.wav")
        let script = JSONValue.object(JSONObject([
            ("schema_version", .string("1.0")), ("kind", .string("mock_fixture_script")), ("source_id", .string("empty")),
            ("sample_rate_hz", .int(16_000)), ("duration_samples", .int(0)), ("perturbation", .null),
            ("faults", .array([])), ("asr", .array([])), ("diarization", .array([])),
        ]))
        let scriptData = try JSONWriter.pretty(script)
        try scriptData.write(to: scratch.appendingPathComponent("script.json"))
        var variant = Variant()
        variant.references = "optional"
        variant.mutateItem = { item in
            item.set("item_id", .string("empty"))
            item.set("audio_path", .string(wav.path))
            item.set("audio_sha256", .string(try! SHA256Hex.file(wav).sha256))
            item.set("sample_rate_hz", .int(16_000))
            item.set("channels", .int(1))
            item.set("duration_samples", .int(0))
            for key in ["reference_text_path", "reference_text_sha256", "speaker_segments_path",
                        "speaker_segments_sha256", "reference_sha256"] { item.set(key, .null) }
            item.set("coverage", .object(JSONObject([("transcript", .bool(false)), ("speakers", .bool(false)),
                                                     ("joint_words", .bool(false))])))
            item.set("fixture_script_path", .string(scratch.appendingPathComponent("script.json").path))
            item.set("fixture_script_sha256", .string(SHA256Hex.digest(scriptData)))
        }
        variant.item = "two-speaker-en"
        let config = try variant.write(in: scratch)
        let yaml = try String(contentsOf: config, encoding: .utf8).replacingOccurrences(of: "item_id: two-speaker-en",
                                                                                        with: "item_id: empty")
        try Data(yaml.utf8).write(to: config)
        let request = RunRequest(configURL: config, runsDirectory: scratch.appendingPathComponent("runs"), runID: "empty",
                                 projectRoot: repositoryRoot)
        let (outcome, runtime) = await ExperimentRunner().runtimeOnly(request)
        #expect(outcome.failure == nil, "\(String(describing: outcome.failure))")
        let trace = try #require(runtime).trace
        #expect(trace.records.isEmpty && trace.totalFrames == 0)
        let events = try readEvents(scratch.appendingPathComponent("runs/empty/events.jsonl.partial"))
        #expect(!events.contains { $0.type == .audioChunkScheduled })
        #expect(events.last?.type == .experimentRuntimeCompleted)
    }
}
