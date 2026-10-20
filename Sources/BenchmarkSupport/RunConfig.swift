import Foundation

public enum ReplayMode: String, Sendable, CaseIterable {
    case realtime, accelerated, step
}

public enum OverflowPolicy: String, Sendable, CaseIterable {
    case block
    case dropNewest = "drop_newest"
}

public enum DownmixPolicy: String, Sendable, CaseIterable {
    case arithmeticMeanV1 = "arithmetic_mean_v1"
}

/// How a native SRC output count that differs from the policy count is handled
/// (DEC-025/DEC-026). Selected per run by `audio.endpoint_policy`.
public enum EndpointPolicy: String, Sendable, CaseIterable {
    /// Plan D2 item 5 (owner-approved default, DEC-026): a native count off by
    /// exactly one frame is trimmed or zero-extended at the tail and disclosed;
    /// anything larger is an error.
    case allowOneFrame = "allow_one_frame_v1"
    /// Any endpoint correction is a `conversionContract` error.
    case strict
}

public enum ConversionPolicy: String, Sendable, CaseIterable {
    case appleNormalMaxHalfUpV1 = "apple_normal_max_half_up_v1"
}

public enum ReferencePolicy: String, Sendable, CaseIterable {
    case required, optional
}

public enum TextPolicy: String, Sendable, CaseIterable {
    case nfcCasefoldPunctSpaceCPV1 = "nfc_casefold_punct_space_cp_v1"
}

public enum DiarizationPolicy: String, Sendable, CaseIterable {
    case pyannoteC0OverlapUEMV1 = "pyannote_c0_overlap_uem_v1"
}

/// Harness safety limits (plan C2). These bound the harness, not models.
public enum ConfigLimits {
    public static let frameSizesMS: Set<Int64> = [10, 20, 40, 80]
    public static let queueCapacity: ClosedRange<Int64> = 1...4096
    public static let sampleRateHz: ClosedRange<Int64> = 1...768_000
    public static let telemetryIntervalMS: ClosedRange<Int64> = 100...60_000
    public static let cleanupTimeoutS: ClosedRange<Int64> = 1...600
    public static let analysisTimeoutS: ClosedRange<Int64> = 1...3600
    public static let maxOutputBytes: ClosedRange<Int64> = (1 << 20)...(1 << 40)
    public static let delayMS: ClosedRange<Int64> = 0...600_000
}

public struct AdapterSelection: Sendable, Equatable, JSONRepresentable {
    public var id: String
    public var revision: String
    public var delayMS: Int64

    public init(id: String, revision: String, delayMS: Int64) {
        self.id = id
        self.revision = revision
        self.delayMS = delayMS
    }

    static func read(_ value: JSONValue, _ path: String) throws -> AdapterSelection {
        var reader = try FieldReader(value, path: path)
        let id = try reader.required("id", Identifiers.stableID)
        let revision = try reader.nonEmptyString("revision")
        let delay = try reader.int("delay_ms", in: ConfigLimits.delayMS)
        try reader.finish()
        return AdapterSelection(id: id, revision: revision, delayMS: delay)
    }

    public func toJSON() -> JSONValue {
        .object(JSONObject([("id", .string(id)), ("revision", .string(revision)), ("delay_ms", .int(delayMS))]))
    }
}

/// Typed form of the authored YAML (plan D3 example). Field order follows the schema.
public struct RunConfig: Sendable, Equatable {
    public var schemaVersion: String
    public var experimentName: String
    public var manifestPath: String
    public var itemID: String
    public var targetSampleRateHz: Int64
    public var downmixPolicy: DownmixPolicy
    public var conversionPolicy: ConversionPolicy
    public var endpointPolicy: EndpointPolicy
    public var mode: ReplayMode
    public var frameMS: Int64
    public var speed: ReplaySpeed?
    public var queueCapacity: Int64
    public var overflow: OverflowPolicy
    public var asr: AdapterSelection
    public var diarization: AdapterSelection
    public var seed: Int64
    public var references: ReferencePolicy
    public var textPolicy: TextPolicy
    public var diarizationPolicy: DiarizationPolicy
    public var telemetryEnabled: Bool
    public var telemetryIntervalMS: Int64
    public var pythonExecutable: String
    public var cleanupTimeoutS: Int64
    public var analysisTimeoutS: Int64
    public var maxOutputBytes: Int64
    public var warmState: String
    public var backgroundLoad: String

    /// Samples per replay frame at the target rate; nil when not integral.
    public var frameSamples: Int64? {
        let product = targetSampleRateHz * frameMS
        return product % 1000 == 0 ? product / 1000 : nil
    }

    /// Strict structural read followed by cross-field semantic validation.
    public static func read(_ value: JSONValue) throws -> RunConfig {
        var root = try FieldReader(value, path: "$")
        let schemaVersion = try root.required("schema_version", SchemaVersion.check)
        let experimentName = try root.required("experiment_name", Identifiers.stableID)

        var dataset = try FieldReader(try root.raw("dataset"), path: "$.dataset")
        let manifestPath = try dataset.nonEmptyString("manifest_path")
        let itemID = try dataset.required("item_id", Identifiers.stableID)
        try dataset.finish()

        var audio = try FieldReader(try root.raw("audio"), path: "$.audio")
        let rate = try audio.int("target_sample_rate_hz", in: ConfigLimits.sampleRateHz)
        let downmix = try audio.enumeration("downmix_policy", DownmixPolicy.self)
        let conversion = try audio.enumeration("conversion_policy", ConversionPolicy.self)
        let endpoint = try audio.enumeration("endpoint_policy", EndpointPolicy.self)
        try audio.finish()

        var replay = try FieldReader(try root.raw("replay"), path: "$.replay")
        let mode = try replay.enumeration("mode", ReplayMode.self)
        let frameMS = try replay.int("frame_ms")
        let speed = try replay.nullable("speed", ReplaySpeed.read)
        let capacity = try replay.int("queue_capacity", in: ConfigLimits.queueCapacity)
        let overflow = try replay.enumeration("overflow", OverflowPolicy.self)
        try replay.finish()

        var adapters = try FieldReader(try root.raw("adapters"), path: "$.adapters")
        let asr = try adapters.required("asr", AdapterSelection.read)
        let diarization = try adapters.required("diarization", AdapterSelection.read)
        try adapters.finish()

        let seed = try root.int("seed", in: 0...Int64.max)

        var scoring = try FieldReader(try root.raw("scoring"), path: "$.scoring")
        let references = try scoring.enumeration("references", ReferencePolicy.self)
        let textPolicy = try scoring.enumeration("text_policy", TextPolicy.self)
        let diarizationPolicy = try scoring.enumeration("diarization_policy", DiarizationPolicy.self)
        try scoring.finish()

        var telemetry = try FieldReader(try root.raw("telemetry"), path: "$.telemetry")
        let telemetryEnabled = try telemetry.bool("enabled")
        let interval = try telemetry.int("interval_ms", in: ConfigLimits.telemetryIntervalMS)
        try telemetry.finish()

        var runtime = try FieldReader(try root.raw("runtime"), path: "$.runtime")
        let python = try runtime.nonEmptyString("python_executable")
        let cleanup = try runtime.int("cleanup_timeout_s", in: ConfigLimits.cleanupTimeoutS)
        let analysis = try runtime.int("analysis_timeout_s", in: ConfigLimits.analysisTimeoutS)
        let maxBytes = try runtime.int("max_output_bytes", in: ConfigLimits.maxOutputBytes)
        try runtime.finish()

        var notes = try FieldReader(try root.raw("notes"), path: "$.notes")
        let warm = try notes.string("warm_state")
        let background = try notes.string("background_load")
        try notes.finish()
        try root.finish()

        let config = RunConfig(
            schemaVersion: schemaVersion, experimentName: experimentName, manifestPath: manifestPath,
            itemID: itemID, targetSampleRateHz: rate, downmixPolicy: downmix, conversionPolicy: conversion,
            endpointPolicy: endpoint, mode: mode, frameMS: frameMS, speed: speed, queueCapacity: capacity, overflow: overflow,
            asr: asr, diarization: diarization, seed: seed, references: references, textPolicy: textPolicy,
            diarizationPolicy: diarizationPolicy, telemetryEnabled: telemetryEnabled,
            telemetryIntervalMS: interval, pythonExecutable: python, cleanupTimeoutS: cleanup,
            analysisTimeoutS: analysis, maxOutputBytes: maxBytes, warmState: warm, backgroundLoad: background)
        try config.validateSemantics()
        return config
    }

    /// Cross-field rules that JSON Schema alone cannot express (plan D2 items 7 and 9).
    public func validateSemantics() throws {
        guard ConfigLimits.frameSizesMS.contains(frameMS) else {
            throw ValidationError("$.replay.frame_ms", "must be one of 10, 20, 40, 80 (got \(frameMS))")
        }
        guard frameSamples != nil else {
            throw ValidationError("$.replay.frame_ms",
                                  "\(frameMS) ms is not an integral number of samples at \(targetSampleRateHz) Hz")
        }
        switch (mode, speed) {
        case (.accelerated, nil):
            throw ValidationError("$.replay.speed", "accelerated mode requires a speed fraction {num, den}")
        case (.realtime, .some), (.step, .some):
            throw ValidationError("$.replay.speed", "speed must be null for \(mode.rawValue) mode")
        default:
            break
        }
        if asr.id == diarization.id {
            throw ValidationError("$.adapters", "ASR and diarization must be distinct adapters (both are \"\(asr.id)\")")
        }
    }

    public func toJSON() -> JSONValue {
        .object(JSONObject([
            ("schema_version", .string(schemaVersion)),
            ("experiment_name", .string(experimentName)),
            ("dataset", .object(JSONObject([("manifest_path", .string(manifestPath)), ("item_id", .string(itemID))]))),
            ("audio", .object(JSONObject([
                ("target_sample_rate_hz", .int(targetSampleRateHz)),
                ("downmix_policy", .string(downmixPolicy.rawValue)),
                ("conversion_policy", .string(conversionPolicy.rawValue)),
                ("endpoint_policy", .string(endpointPolicy.rawValue)),
            ]))),
            ("replay", .object(JSONObject([
                ("mode", .string(mode.rawValue)),
                ("frame_ms", .int(frameMS)),
                ("speed", speed.toJSON()),
                ("queue_capacity", .int(queueCapacity)),
                ("overflow", .string(overflow.rawValue)),
            ]))),
            ("adapters", .object(JSONObject([("asr", asr.toJSON()), ("diarization", diarization.toJSON())]))),
            ("seed", .int(seed)),
            ("scoring", .object(JSONObject([
                ("references", .string(references.rawValue)),
                ("text_policy", .string(textPolicy.rawValue)),
                ("diarization_policy", .string(diarizationPolicy.rawValue)),
            ]))),
            ("telemetry", .object(JSONObject([
                ("enabled", .bool(telemetryEnabled)), ("interval_ms", .int(telemetryIntervalMS)),
            ]))),
            ("runtime", .object(JSONObject([
                ("python_executable", .string(pythonExecutable)),
                ("cleanup_timeout_s", .int(cleanupTimeoutS)),
                ("analysis_timeout_s", .int(analysisTimeoutS)),
                ("max_output_bytes", .int(maxOutputBytes)),
            ]))),
            ("notes", .object(JSONObject([
                ("warm_state", .string(warmState)), ("background_load", .string(backgroundLoad)),
            ]))),
        ]))
    }
}

/// Typed CLI overrides (plan D3). Applied after strict YAML loading and before
/// semantic validation, so a flag can never bypass the same checks.
public struct ConfigOverrides: Sendable, Equatable {
    public var mode: ReplayMode?
    public var frameMS: Int64?
    public var speedDecimal: String?
    public var queueCapacity: Int64?
    public var overflow: OverflowPolicy?
    public var seed: Int64?
    public var pythonExecutable: String?

    public init(mode: ReplayMode? = nil, frameMS: Int64? = nil, speedDecimal: String? = nil,
                queueCapacity: Int64? = nil, overflow: OverflowPolicy? = nil, seed: Int64? = nil,
                pythonExecutable: String? = nil) {
        self.mode = mode
        self.frameMS = frameMS
        self.speedDecimal = speedDecimal
        self.queueCapacity = queueCapacity
        self.overflow = overflow
        self.seed = seed
        self.pythonExecutable = pythonExecutable
    }

    /// Applies overrides to a structurally valid config, then re-runs semantic validation.
    ///
    /// Mode rule: overriding to a non-accelerated mode clears an authored speed
    /// (it was not supplied for that mode); `--speed` combined with a
    /// non-accelerated effective mode is rejected.
    public func apply(to base: RunConfig) throws -> RunConfig {
        var config = base
        if let mode {
            config.mode = mode
            if mode != .accelerated { config.speed = nil }
        }
        if let speedDecimal {
            guard config.mode == .accelerated else {
                throw ValidationError("--speed", "speed may only be supplied for accelerated mode (mode is \(config.mode.rawValue))")
            }
            config.speed = try ReplaySpeed.parseDecimal(speedDecimal)
        }
        if let frameMS { config.frameMS = frameMS }
        if let queueCapacity {
            guard ConfigLimits.queueCapacity.contains(queueCapacity) else {
                throw ValidationError("--queue-capacity", "must be in 1...4096 (got \(queueCapacity))")
            }
            config.queueCapacity = queueCapacity
        }
        if let overflow { config.overflow = overflow }
        if let seed {
            guard seed >= 0 else { throw ValidationError("--seed", "must be nonnegative") }
            config.seed = seed
        }
        if let pythonExecutable {
            guard pythonExecutable.hasPrefix("/") else {
                throw ValidationError("--python-executable", "must be an absolute path")
            }
            config.pythonExecutable = pythonExecutable
        }
        try config.validateSemantics()
        return config
    }
}

/// A config after YAML loading, overrides and path resolution.
public struct LoadedConfig: Sendable {
    public let config: RunConfig
    public let sourcePath: String
    public let sourceSHA256: String
    public let resolvedManifestPath: String
    public let resolvedPythonExecutable: String

    /// Exact `config_settings.json` preimage (encoding `settings_json_v1`).
    ///
    /// Contains every authored setting after overrides, with portable
    /// locators as authored; run ID, output location and the digest itself
    /// are excluded so the hash identifies settings, not a particular run.
    public func settingsDocument() -> JSONValue {
        guard case .object(var object) = config.toJSON() else { preconditionFailure("config encodes as object") }
        object.set("settings_encoding", .string(JSONWriter.canonicalEncodingID))
        return .object(object)
    }

    public func settingsBytesAndHash() throws -> (bytes: Data, sha256: String) {
        try JSONWriter.canonicalSHA256(settingsDocument())
    }
}

public enum ConfigLoader {
    /// Loads authored YAML, applies overrides, validates and resolves paths
    /// relative to the YAML file's directory.
    public static func load(yamlAt url: URL, overrides: ConfigOverrides = ConfigOverrides()) throws -> LoadedConfig {
        let data = try Data(contentsOf: url)
        let tree = try StrictYAML.load(data, origin: url.path)
        let config = try overrides.apply(to: try RunConfig.read(tree))
        let base = url.deletingLastPathComponent()
        return LoadedConfig(
            config: config,
            sourcePath: url.standardizedFileURL.path,
            sourceSHA256: SHA256Hex.digest(data),
            resolvedManifestPath: PathResolution.resolve(config.manifestPath, relativeTo: base),
            resolvedPythonExecutable: PathResolution.resolve(config.pythonExecutable, relativeTo: base))
    }
}

public enum PathResolution {
    /// Resolves a locator against a base directory; absolute locators are kept.
    /// No environment-variable or `~` expansion is performed.
    public static func resolve(_ locator: String, relativeTo base: URL) -> String {
        if locator.hasPrefix("/") { return URL(fileURLWithPath: locator).standardizedFileURL.path }
        return URL(fileURLWithPath: locator, relativeTo: base).standardizedFileURL.path
    }
}
