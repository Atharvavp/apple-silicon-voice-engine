import AdapterContracts
import BenchmarkSupport
import Experiment
import Foundation
import RealAdapterSupport
import Testing

/// A real wrapper (with a model-free backend) plus a passive counterpart through the
/// unchanged runner, recorder, scorer and sealing, on role-specific manifests.
struct RunnerIntegrationTests {
    /// Copies the synthetic `two-speaker-en` item with only one reference kind and no fixture script.
    func manifest(keep: AnnotationKind, in scratch: URL) throws -> URL {
        let datasets = repoURL("datasets")
        var manifest = object(try StrictJSON.parseFile(datasets.appendingPathComponent("manifests/synthetic.json")))
        guard case .array(let items)? = manifest["items"] else { fatalError("no items") }
        var item = items.map(object).first { $0["item_id"] == .string("two-speaker-en") }!
        for key in ["audio_path", "reference_text_path", "speaker_segments_path"] {
            if case .string(let locator)? = item[key] {
                item.set(key, .string(datasets.appendingPathComponent("manifests").appendingPathComponent(locator)
                    .standardizedFileURL.path))
            }
        }
        let dropped = keep == .transcript ? "speaker_segments" : "reference_text"
        item.set("\(dropped)_path", .null)
        item.set("\(dropped)_sha256", .null)
        item.set("fixture_script_path", .null)
        item.set("fixture_script_sha256", .null)
        var coverage = object(item["coverage"]!)
        coverage.set(keep == .transcript ? "speakers" : "transcript", .bool(false))
        item.set("coverage", .object(coverage))
        item.set("annotation_type", .string(keep == .transcript ? "utterances" : "speaker_segments"))
        func hash(_ key: String) -> String? { if case .string(let v)? = item[key] { return v } else { return nil } }
        item.set("reference_sha256", .string(DatasetItem.referenceDescriptorHash(
            transcriptSHA256: hash("reference_text_sha256"), speakersSHA256: hash("speaker_segments_sha256"))))
        manifest.set("items", .array([.object(item)]))
        let url = scratch.appendingPathComponent("manifest-\(keep.rawValue).json")
        try JSONWriter.pretty(.object(manifest)).write(to: url)
        return url
    }

    func config(manifest: URL, asr: (String, String), diarization: (String, String), in scratch: URL) throws -> URL {
        let yaml = """
        schema_version: "1.0"
        experiment_name: phase1-integration
        dataset:
          manifest_path: \(manifest.path)
          item_id: two-speaker-en
        audio:
          target_sample_rate_hz: 16000
          downmix_policy: arithmetic_mean_v1
          conversion_policy: apple_normal_max_half_up_v1
          endpoint_policy: allow_one_frame_v1
        replay:
          mode: step
          frame_ms: 20
          speed: null
          queue_capacity: 32
          overflow: block
        adapters:
          asr: {id: \(asr.0), revision: "\(asr.1)", delay_ms: 0}
          diarization: {id: \(diarization.0), revision: "\(diarization.1)", delay_ms: 0}
        seed: 42
        scoring:
          references: optional
          text_policy: nfc_casefold_punct_space_cp_v1
          diarization_policy: pyannote_c0_overlap_uem_v1
        telemetry:
          enabled: true
          interval_ms: 100
        runtime:
          python_executable: \(repoURL(".venv/bin/python").path)
          cleanup_timeout_s: 5
          analysis_timeout_s: 120
          max_output_bytes: 1073741824
        notes:
          warm_state: fresh_process_model_loaded_in_prepare
          background_load: swift-test-parallel
        """
        let url = scratch.appendingPathComponent("config-\(UUID().uuidString.prefix(6)).yaml")
        try Data(yaml.utf8).write(to: url)
        return url
    }

    func factory(_ extra: [String: AdapterFactory.Entry]) -> AdapterFactory {
        var entries = AdapterFactory.builtIn.entries
        entries[PassiveAdapterIDs.asr] = .init(role: .asr, requestedPlacement: .unspecified, isMock: false) { PassiveASRAdapter() }
        entries[PassiveAdapterIDs.diarization] = .init(role: .diarization, requestedPlacement: .unspecified, isMock: false) {
            PassiveDiarizationAdapter()
        }
        entries.merge(extra) { $1 }
        return AdapterFactory(entries: entries)
    }

    func metrics(_ run: URL) throws -> JSONObject { object(try StrictJSON.parseFile(run.appendingPathComponent("metrics.json"))) }

    func accuracy(_ metrics: JSONObject, _ key: String) -> (String, Double?) {
        let record = object(object(metrics["accuracy"]!)[key]!)
        guard case .string(let status)? = record["status"] else { return ("?", nil) }
        if case .double(let value)? = record["value"] { return (status, value) }
        if case .int(let value)? = record["value"] { return (status, Double(value)) }
        return (status, nil)
    }

    @Test func realDiarizerWithPassiveASROnSpeakerOnlyManifest() async throws {
        let scratch = try makeScratch()
        let profile = try ProfileFixture.make(adapterID: "fake-real-diar", role: .diarization)
        let timeline = [NativeSpeakerSegment(slot: 0, start: .seconds(0), end: .seconds(4)),
                        NativeSpeakerSegment(slot: 1, start: .seconds(4), end: .seconds(8))]
        let entry = AdapterFactory.Entry(role: .diarization, requestedPlacement: .unspecified, isMock: false) {
            FinalTimelineDiarizationAdapter(adapterID: "fake-real-diar", frameworkRevision: fakeFrameworkRevision,
                                            roots: profile.roots) { _, _ in FakeDiarizationBackend(timeline: timeline) }
        }
        let configURL = try config(manifest: try manifest(keep: .speakers, in: scratch),
                                   asr: (PassiveAdapterIDs.asr, PassiveAdapterIDs.revision),
                                   diarization: ("fake-real-diar", profile.revision), in: scratch)
        let runs = scratch.appendingPathComponent("runs")
        let outcome = await ExperimentRunner(factory: factory(["fake-real-diar": entry]))
            .run(RunRequest(configURL: configURL, runsDirectory: runs, runID: "diar", projectRoot: repositoryRoot))
        #expect(outcome.exitCode == 0, "\(String(describing: outcome.failure))")
        let m = try metrics(runs.appendingPathComponent("diar"))
        #expect(m["mock"] == .bool(false))
        #expect(accuracy(m, "der").0 == "ok" && accuracy(m, "der").1 == 0)
        #expect(accuracy(m, "wer").0 == "not_computable")
        let predictions = object(try StrictJSON.parseFile(runs.appendingPathComponent("diar/predictions.json")))
        guard case .array(let speakers)? = predictions["speakers"] else { Issue.record("no speakers"); return }
        #expect(speakers.count == 2)
    }

    @Test func realASRWithPassiveDiarizerOnTranscriptOnlyManifest() async throws {
        let scratch = try makeScratch()
        let profile = try ProfileFixture.make(adapterID: "fake-real-asr", role: .asr, tolerance: nil)
        let entry = AdapterFactory.Entry(role: .asr, requestedPlacement: .unspecified, isMock: false) {
            RecordingTranscriptASRAdapter(adapterID: "fake-real-asr", frameworkRevision: fakeFrameworkRevision,
                                          roots: profile.roots) { _, _ in
                FakeASRBackend(mode: .cumulative, perPush: [[.cumulative("hello")], [], [.cumulative("hello world a b")]],
                               finish: [.cumulative("hello world a b c")])
            }
        }
        let configURL = try config(manifest: try manifest(keep: .transcript, in: scratch),
                                   asr: ("fake-real-asr", profile.revision),
                                   diarization: (PassiveAdapterIDs.diarization, PassiveAdapterIDs.revision), in: scratch)
        let runs = scratch.appendingPathComponent("runs")
        let outcome = await ExperimentRunner(factory: factory(["fake-real-asr": entry]))
            .run(RunRequest(configURL: configURL, runsDirectory: runs, runID: "asr", projectRoot: repositoryRoot))
        #expect(outcome.exitCode == 0, "\(String(describing: outcome.failure))")
        let m = try metrics(runs.appendingPathComponent("asr"))
        #expect(accuracy(m, "wer").0 == "ok" && accuracy(m, "wer").1 == 0)
        #expect(accuracy(m, "der").0 == "not_computable")
    }

    @Test func mismatchedRevisionFailsTheRunAtPrepare() async throws {
        let scratch = try makeScratch()
        let profile = try ProfileFixture.make(adapterID: "fake-real-diar", role: .diarization)
        let entry = AdapterFactory.Entry(role: .diarization, requestedPlacement: .unspecified, isMock: false) {
            FinalTimelineDiarizationAdapter(adapterID: "fake-real-diar", frameworkRevision: fakeFrameworkRevision,
                                            roots: profile.roots) { _, _ in FakeDiarizationBackend(timeline: []) }
        }
        let configURL = try config(manifest: try manifest(keep: .speakers, in: scratch),
                                   asr: (PassiveAdapterIDs.asr, PassiveAdapterIDs.revision),
                                   diarization: ("fake-real-diar", "p1:" + String(repeating: "f", count: 64)), in: scratch)
        let runs = scratch.appendingPathComponent("runs")
        let outcome = await ExperimentRunner(factory: factory(["fake-real-diar": entry]))
            .run(RunRequest(configURL: configURL, runsDirectory: runs, runID: "bad", projectRoot: repositoryRoot))
        #expect(outcome.exitCode == 5)
        #expect(FileManager.default.fileExists(atPath: runs.appendingPathComponent("bad/status.json").path),
                "the failed attempt is retained")
    }
}
