import AdapterContracts
import BenchmarkSupport
import Experiment
import Foundation
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

enum Evidence {
    static func write(_ name: String, _ value: JSONValue) {
        guard let root = ProcessInfo.processInfo.environment["VOICEBENCH_EVIDENCE_DIR"],
              let data = try? JSONWriter.pretty(value) else { return }
        let url = URL(fileURLWithPath: root).appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url)
    }

    static func copy(_ source: URL, as name: String) {
        guard let root = ProcessInfo.processInfo.environment["VOICEBENCH_EVIDENCE_DIR"] else { return }
        let url = URL(fileURLWithPath: root).appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.copyItem(at: source, to: url)
    }
}

func object(_ value: JSONValue) -> JSONObject {
    guard case .object(let object) = value else { fatalError("expected object, got \(value.typeName)") }
    return object
}

func readJSON(_ url: URL) throws -> JSONObject { object(try StrictJSON.parseFile(url)) }

/// Every line of a JSONL file, strictly parsed as an event envelope.
func readEvents(_ url: URL) throws -> [EventEnvelope] {
    let data = try Data(contentsOf: url)
    return try data.split(separator: 0x0A).map { try EventEnvelope.read(try StrictJSON.parse(Data($0))) }
}

/// A config + dataset variant in scratch space. Paths are absolute so the
/// variant can live anywhere; the original audio and references are reused.
struct Variant {
    var item = "two-speaker-en"
    var mode = "step"
    var speed: String? = nil
    var frameMS = 20
    var queueCapacity = 32
    var overflow = "block"
    var asrDelayMS = 0
    var diarizationDelayMS = 0
    var endpointPolicy = "allow_one_frame_v1"
    var telemetry = true
    var references = "required"
    var asrID = "mock-asr-scripted"
    var diarizationID = "mock-diar-scripted"
    var mutateScript: (@Sendable (inout JSONObject) -> Void)? = nil
    var mutateItem: (@Sendable (inout JSONObject) -> Void)? = nil
    var cleanupTimeoutS = 5
    var pythonExecutable: String? = nil

    /// Writes the variant and returns the config URL.
    func write(in scratch: URL) throws -> URL {
        let datasets = repoURL("datasets")
        let manifest = object(try StrictJSON.parseFile(datasets.appendingPathComponent("manifests/synthetic.json")))
        guard case .array(let items)? = manifest["items"] else { fatalError("no items") }
        var selected = items.map(object).first { $0["item_id"] == .string(item) }!
        func absolute(_ key: String) {
            if case .string(let locator)? = selected[key] {
                selected.set(key, .string(datasets.appendingPathComponent("manifests").appendingPathComponent(locator)
                    .standardizedFileURL.path))
            }
        }
        ["audio_path", "reference_text_path", "speaker_segments_path", "fixture_script_path"].forEach(absolute)
        if let mutateScript {
            var script = object(try StrictJSON.parseFile(repoURL("datasets/fixtures/scripts/\(item).json")))
            mutateScript(&script)
            let data = try JSONWriter.pretty(.object(script))
            let url = scratch.appendingPathComponent("script-\(item).json")
            try data.write(to: url)
            selected.set("fixture_script_path", .string(url.path))
            selected.set("fixture_script_sha256", .string(SHA256Hex.digest(data)))
        }
        mutateItem?(&selected)
        var variantManifest = manifest
        variantManifest.set("items", .array([.object(selected)]))
        let manifestURL = scratch.appendingPathComponent("manifest.json")
        try JSONWriter.pretty(.object(variantManifest)).write(to: manifestURL)
        let speedLine = speed.map { "{num: \($0), den: 1}" } ?? "null"
        let yaml = """
        schema_version: "1.0"
        experiment_name: test-\(mode)
        dataset:
          manifest_path: \(manifestURL.path)
          item_id: \(item)
        audio:
          target_sample_rate_hz: 16000
          downmix_policy: arithmetic_mean_v1
          conversion_policy: apple_normal_max_half_up_v1
          endpoint_policy: \(endpointPolicy)
        replay:
          mode: \(mode)
          frame_ms: \(frameMS)
          speed: \(speedLine)
          queue_capacity: \(queueCapacity)
          overflow: \(overflow)
        adapters:
          asr: {id: \(asrID), revision: "1", delay_ms: \(asrDelayMS)}
          diarization: {id: \(diarizationID), revision: "1", delay_ms: \(diarizationDelayMS)}
        seed: 42
        scoring:
          references: \(references)
          text_policy: nfc_casefold_punct_space_cp_v1
          diarization_policy: pyannote_c0_overlap_uem_v1
        telemetry:
          enabled: \(telemetry)
          interval_ms: 100
        runtime:
          python_executable: \(pythonExecutable ?? repoURL(".venv/bin/python").path)
          cleanup_timeout_s: \(cleanupTimeoutS)
          analysis_timeout_s: 120
          max_output_bytes: 1073741824
        notes:
          warm_state: not_applicable_mock
          background_load: swift-test-parallel
        """
        let configURL = scratch.appendingPathComponent("config.yaml")
        try Data(yaml.utf8).write(to: configURL)
        return configURL
    }

    func request(runID: String = "r-\(UUID().uuidString.prefix(8))") throws -> (RunRequest, URL) {
        let scratch = try makeScratch()
        let config = try write(in: scratch)
        let runs = scratch.appendingPathComponent("runs")
        return (RunRequest(configURL: config, runsDirectory: runs, runID: runID, projectRoot: repositoryRoot),
                runs.appendingPathComponent(runID))
    }
}

/// Fields of an event that must be identical across step runs (a Swift-side
/// version of the G2 projection; the authoritative normalizer is Python `trace.py`).
func logicalView(_ events: [EventEnvelope]) -> [JSONValue] {
    let dropped: Set<EventType> = [.stageCompleted, .telemetrySample, .audioQueueBackpressure]
    let volatilePayload: [EventType: Set<String>] = [
        .audioChunkDelivered: ["offer_ns", "entry_ns", "wake_error_ns", "deadline_error_ns"],
        .audioChunkConsumed: ["dequeue_ns", "finish_ns"],
        .experimentRuntimeCompleted: ["replay_elapsed_ns"],
    ]
    return events.filter { !dropped.contains($0.type) }.map { event in
        var payload = event.payload
        for key in volatilePayload[event.type] ?? [] { payload.set(key, .null) }
        return .object(JSONObject([
            ("type", .string(event.type.rawValue)), ("event_id", .string(event.eventID)),
            ("producer_id", .string(event.producerID)), ("producer_sequence", .int(event.producerSequence)),
            ("media", .array([event.mediaStartSample.json, event.mediaEndSample.json])),
            ("cause", event.causeChunkIndex.json), ("invocation", event.invocationID.json),
            ("virtual", event.virtualEmittedNS.json), ("payload", .object(payload)),
        ]))
    }
}
