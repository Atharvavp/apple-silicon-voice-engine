import BenchmarkSupport
import Foundation
import Testing

private func yaml(_ text: String) throws -> JSONValue { try StrictYAML.load(Data(text.utf8)) }

private let validYAML = try! String(contentsOf: repoURL("configs/mock-step.yaml"), encoding: .utf8)

/// Replaces one exact line of the reference YAML.
private func editedYAML(_ old: String, _ new: String) -> String {
    precondition(validYAML.contains(old), "fixture line not found: \(old)")
    return validYAML.replacingOccurrences(of: old, with: new)
}

struct ConfigTests {
    @Test func referenceConfigLoadsAndResolves() throws {
        let loaded = try ConfigLoader.load(yamlAt: repoURL("configs/mock-step.yaml"))
        let config = loaded.config
        #expect(config.mode == .step)
        #expect(config.frameMS == 20)
        #expect(config.frameSamples == 320)
        #expect(config.speed == nil)
        #expect(config.asr.id == "mock-asr-scripted")
        #expect(loaded.resolvedManifestPath == repoURL("datasets/manifests/synthetic.json").standardizedFileURL.path)
        #expect(loaded.resolvedPythonExecutable == repoURL(".venv/bin/python").standardizedFileURL.path)
        let (bytes, digest) = try loaded.settingsBytesAndHash()
        #expect(SHA256Hex.isValid(digest))
        #expect(SHA256Hex.digest(bytes) == digest)
        // Same settings -> same digest; the digest ignores run IDs and output paths by construction.
        #expect(try ConfigLoader.load(yamlAt: repoURL("configs/mock-step.yaml")).settingsBytesAndHash().sha256 == digest)
    }

    @Test func yamlAndJSONFormsAgree() throws {
        let fromYAML = try RunConfig.read(try yaml(validYAML))
        let fromJSON = try RunConfig.read(
            try StrictJSON.parseFile(repoURL("testdata/schemas/valid/config-authored/mock-step.json")))
        #expect(fromYAML == fromJSON)
    }

    @Test(arguments: [
        ("duplicate key", validYAML + "seed: 7\n"),
        ("anchor and alias", editedYAML("seed: 42", "seed: &s 42\nextra: *s")),
        ("merge key", editedYAML("notes:\n", "notes:\n  <<: {warm_state: x}\n")),
        ("explicit int tag", editedYAML("seed: 42", "seed: !!int \"42\"")),
        ("custom tag", editedYAML("seed: 42", "seed: !custom 42")),
        ("explicit int tag on quoted scalar", editedYAML("revision: \"1\", delay_ms: 0}\n  diarization",
                                                         "revision: !!int \"1\", delay_ms: 0}\n  diarization")),
        ("custom tag on mapping", editedYAML("telemetry:\n", "telemetry: !t\n")),
        ("second document", validYAML + "---\nseed: 1\n"),
        ("nan", editedYAML("seed: 42", "seed: .nan")),
        ("infinity", editedYAML("seed: 42", "seed: .inf")),
        ("hex integer", editedYAML("seed: 42", "seed: 0x2A")),
        ("int64 overflow", editedYAML("seed: 42", "seed: 9223372036854775808")),
        ("empty document", ""),
    ])
    func yamlStrictnessRejects(_ label: String, _ text: String) {
        #expect(throws: ValidationError.self, "\(label) should be rejected") {
            _ = try RunConfig.read(try yaml(text))
        }
    }

    @Test(arguments: [
        ("unknown key", editedYAML("seed: 42", "seed: 42\nseeed: 1")),
        ("YAML 1.1 boolean word", editedYAML("enabled: true", "enabled: yes")),
        ("quoted integer", editedYAML("frame_ms: 20", "frame_ms: \"20\"")),
        ("float for integer", editedYAML("frame_ms: 20", "frame_ms: 20.0")),
        ("frame size 25", editedYAML("frame_ms: 20", "frame_ms: 25")),
        ("missing nullable key", editedYAML("  speed: null\n", "")),
        ("speed in step mode", editedYAML("speed: null", "speed: {num: 2, den: 1}")),
        ("accelerated without speed", editedYAML("mode: step", "mode: accelerated")),
        ("non-integral frame at 22050", editedYAML("target_sample_rate_hz: 16000", "target_sample_rate_hz: 22050")
            .replacingOccurrences(of: "frame_ms: 20", with: "frame_ms: 10")),
        ("queue capacity above bound", editedYAML("queue_capacity: 32", "queue_capacity: 4097")),
        ("drop_oldest is not in v1", editedYAML("overflow: block", "overflow: drop_oldest")),
        ("negative seed", editedYAML("seed: 42", "seed: -1")),
        ("unknown schema version", editedYAML("schema_version: \"1.0\"", "schema_version: \"1.1\"")),
        ("path traversal experiment name", editedYAML("experiment_name: phase0-synthetic-en", "experiment_name: ../x")),
    ])
    func semanticAndTypeRejections(_ label: String, _ text: String) {
        #expect(throws: ValidationError.self, "\(label) should be rejected") {
            _ = try RunConfig.read(try yaml(text))
        }
    }

    @Test func errorsNameTheField() {
        do {
            _ = try RunConfig.read(try yaml(editedYAML("frame_ms: 20", "frame_ms: 25")))
            Issue.record("expected rejection")
        } catch let error as ValidationError {
            #expect(error.path == "$.replay.frame_ms")
            #expect(error.message.contains("10, 20, 40, 80"))
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func overridesApplyBeforeValidation() throws {
        let base = try RunConfig.read(try yaml(validYAML))
        let accelerated = try ConfigOverrides(mode: .accelerated, speedDecimal: "1.5").apply(to: base)
        #expect(accelerated.speed == (try ReplaySpeed(numerator: 3, denominator: 2)))
        let realtime = try ConfigOverrides(mode: .realtime).apply(to: accelerated)
        #expect(realtime.speed == nil, "switching mode clears an authored speed")
        #expect(throws: ValidationError.self) { _ = try ConfigOverrides(speedDecimal: "2").apply(to: base) }
        #expect(throws: ValidationError.self) { _ = try ConfigOverrides(mode: .accelerated).apply(to: base) }
        #expect(throws: ValidationError.self) { _ = try ConfigOverrides(frameMS: 30).apply(to: base) }
        #expect(throws: ValidationError.self) { _ = try ConfigOverrides(queueCapacity: 0).apply(to: base) }
        #expect(throws: ValidationError.self) { _ = try ConfigOverrides(pythonExecutable: "python3").apply(to: base) }
        let frame = try ConfigOverrides(frameMS: 80, seed: 7).apply(to: base)
        #expect(frame.frameSamples == 1280)
        #expect(frame.seed == 7)
    }

    @Test(arguments: [
        ("4", 4, 1), ("1", 1, 1), ("1.5", 3, 2), ("100", 100, 1), ("2.000001", 2_000_001, 1_000_000),
        ("1.250000", 5, 4), ("99.999999", 99_999_999, 1_000_000),
    ])
    func speedParsing(_ text: String, _ numerator: Int64, _ denominator: Int64) throws {
        let speed = try ReplaySpeed.parseDecimal(text)
        #expect(speed.numerator == numerator && speed.denominator == denominator)
    }

    @Test(arguments: ["0", "0.5", "100.000001", "101", "-1", "nan", "inf", "1e2", "2.0000001", "", "1.", ".5",
                      "99999999999999999999999"])
    func speedRejections(_ text: String) {
        #expect(throws: ValidationError.self) { _ = try ReplaySpeed.parseDecimal(text) }
    }

    @Test func runIdentifierRules() throws {
        #expect(try Identifiers.validateRunID("run_01-a") == "run_01-a")
        for bad in ["", "../x", "a/b", "with space", String(repeating: "a", count: 81), "ü"] {
            #expect(throws: ValidationError.self) { _ = try Identifiers.validateRunID(bad) }
        }
        #expect(Identifiers.generateRunID().count == 36)
    }

    @Test func settingsPreimageIsCanonicalAndExcludesRunIdentity() throws {
        let loaded = try ConfigLoader.load(yamlAt: repoURL("configs/mock-step.yaml"))
        let text = String(decoding: try loaded.settingsBytesAndHash().bytes, as: UTF8.self)
        #expect(text.hasPrefix(#"{"adapters":{"asr":{"delay_ms":0,"id":"mock-asr-scripted","revision":"1"}"#))
        #expect(text.contains(#""settings_encoding":"settings_json_v1""#))
        #expect(!text.contains("run_id"))
        #expect(!text.contains(" "), "compact encoding has no insignificant whitespace")
    }
}
