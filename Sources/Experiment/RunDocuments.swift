import AdapterContracts
import AudioCore
import BenchmarkSupport
import Foundation
import Replay
import Telemetry

extension RunSession {
    /// `config.json`: frozen before any audio is touched (plan D3).
    func frozenConfig(python: PythonFacts) throws -> JSONValue {
        let config = plan.config
        let (_, settingsSHA) = try plan.loaded.settingsBytesAndHash()
        let git = EnvironmentCapture.git(projectRoot: plan.projectRoot)
        let schemaNames = (try? FileManager.default.contentsOfDirectory(atPath: plan.schemaBundle.directory.path)) ?? []
        let versions = schemaNames.filter { $0.hasSuffix(".schema.json") }.sorted()
            .map { ($0.replacingOccurrences(of: ".schema.json", with: ""), JSONValue.string(SchemaVersion.current)) }
        func placement(_ selection: AdapterSelection) -> JSONValue {
            .string(factory.entry(selection.id)?.requestedPlacement.rawValue ?? PlacementTarget.unspecified.rawValue)
        }
        return .object(JSONObject([
            ("schema_version", .string(SchemaVersion.current)), ("run_id", .string(plan.runID)),
            ("created_wall_time", .string(WallClock.now())),
            ("config_source", .object(JSONObject([("path", .string(plan.loaded.sourcePath)),
                                                  ("sha256", .string(plan.loaded.sourceSHA256))]))),
            ("settings", plan.loaded.settingsDocument()), ("settings_sha256", .string(settingsSHA)),
            ("resolved_paths", .object(JSONObject([
                ("manifest", .string(plan.manifestURL.path)), ("python_executable", .string(plan.pythonExecutable.path)),
                ("project_root", .string(plan.projectRoot.path)),
            ]))),
            ("inputs", .object(JSONObject([
                ("dataset_id", .string(plan.manifest.datasetID)), ("manifest_sha256", .string(plan.manifestSHA256)),
                ("item_id", .string(plan.item.itemID)), ("audio_sha256", .string(plan.audio.sha256)),
                ("reference_sha256", plan.item.referenceSHA256.json),
                ("fixture_script_sha256", plan.item.fixtureScriptSHA256.json),
            ]))),
            ("replay_resolved", .object(JSONObject([
                ("frame_samples", .int(config.frameSamples ?? 0)), ("speed", config.speed.toJSON()),
                ("deadline_convention", .string(SampleClock.deadlineConvention)),
            ]))),
            ("schema_versions", .object(JSONObject(versions))),
            ("schema_bundle", plan.schemaBundle.toJSON()),
            ("policy_ids", .object(JSONObject([
                ("downmix", .string(config.downmixPolicy.rawValue)), ("conversion", .string(config.conversionPolicy.rawValue)),
                ("endpoint", .string(config.endpointPolicy.rawValue)), ("text", .string(config.textPolicy.rawValue)),
                ("diarization", .string(config.diarizationPolicy.rawValue)),
            ]))),
            ("build", .object(JSONObject([
                ("voicebench_version", .string(VoiceBenchVersion.current)), ("git_revision", git.revision.json),
                ("git_dirty", git.dirty.json), ("build_configuration", .string(BuildFacts.buildConfiguration)),
                ("package_resolved_sha256",
                 EnvironmentCapture.fileSHA(plan.projectRoot.appendingPathComponent("Package.resolved")).json),
            ]))),
            ("analysis_version", .string(python.analysisVersion)),
            ("requested_placement", .object(JSONObject([("asr", placement(config.asr)),
                                                        ("diarization", placement(config.diarization))]))),
        ]))
    }

    /// `environment.json`: startup facts with availability, plus requested vs observed placement.
    func environment(python: PythonFacts, capabilities: [AdapterRole: AdapterCapabilities]) throws -> JSONValue {
        let os = EnvironmentCapture.osVersion
        let git = EnvironmentCapture.git(projectRoot: plan.projectRoot)
        let lock = plan.projectRoot.appendingPathComponent("analysis/requirements-macos-arm64-py312.lock")
        var requested = JSONObject()
        var observed = JSONObject()
        for role in AdapterRole.allCases {
            guard let capability = capabilities[role] else { continue }
            requested.set(role.rawValue, .string(capability.requestedPlacement.rawValue))
            observed.set(role.rawValue, capability.observedPlacement.toJSON())
        }
        return .object(JSONObject([
            ("schema_version", .string(SchemaVersion.current)), ("run_id", .string(plan.runID)),
            ("created_wall_time", .string(WallClock.now())),
            ("os", .object(JSONObject([("product_version", .string(os.product)), ("build_version", .string(os.build))]))),
            ("arch", .string(EnvironmentCapture.architecture)),
            ("hardware", .object(EnvironmentCapture.hardware)),
            ("target_hardware_expectation", .string(EnvironmentCapture.targetHardwareExpectation)),
            ("toolchain", .object(JSONObject([
                ("swift_version", .string(BuildFacts.swiftVersion)), ("sdk_version", .string(BuildFacts.sdkVersion)),
                ("deployment_target", .string(BuildFacts.deploymentTarget)),
                ("build_configuration", .string(BuildFacts.buildConfiguration)),
            ]))),
            ("build", .object(JSONObject([
                ("voicebench_version", .string(VoiceBenchVersion.current)), ("git_revision", git.revision.json),
                ("git_dirty", git.dirty.json),
                ("package_resolved_sha256",
                 EnvironmentCapture.fileSHA(plan.projectRoot.appendingPathComponent("Package.resolved")).json),
            ]))),
            ("python", .object(JSONObject([
                ("executable", .string(python.executable)), ("version", .string(python.version)),
                ("lock_sha256", EnvironmentCapture.fileSHA(lock).json),
                ("distributions", .object(JSONObject(python.distributions.map { ($0.0, JSONValue.string($0.1)) }))),
            ]))),
            ("analysis_version", .string(python.analysisVersion)),
            ("locale", .string(Locale.current.identifier.isEmpty ? "unknown" : Locale.current.identifier)),
            ("unicode_version", python.unicodeVersion.json),
            ("clock", .object(JSONObject([("source", .string("ContinuousClock")),
                                          ("minimum_resolution_ns", .int(clock.minimumResolutionNS))]))),
            ("telemetry_capabilities", .object(JSONObject(TelemetryCapabilities.probe().map { ($0.0, $0.1.toJSON()) }))),
            ("run_conditions", .object(JSONObject([("warm_state", .string(plan.config.warmState)),
                                                   ("background_load", .string(plan.config.backgroundLoad))]))),
            ("placement", .object(JSONObject([("requested", .object(requested)), ("observed", .object(observed))]))),
        ]))
    }

    func runtimeSummary(prepared: PreparedAudio, trace: ReplayTrace, prefix: EventRecorder.PrefixDescriptor,
                        telemetry: ArtifactDigest?, sampler: TelemetrySampler.Summary?,
                        recorder: SerialFileWriter.Stats, eventMaxDepth: Int, telemetryMaxDepth: Int,
                        drainEnd: Int64) -> JSONValue {
        let telemetryJSON: JSONValue = telemetry.map { digest in
            let lines = (try? Data(contentsOf: directory.path(digest.path)))?.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) } ?? 0
            return .object(JSONObject([("path", .string(digest.path)), ("line_count", .int(Int64(lines))),
                                       ("sha256", .string(digest.sha256))]))
        } ?? .null
        let samplerJSON: JSONValue = sampler.map {
            .object(JSONObject([
                ("interval_ns", .int(plan.config.telemetryIntervalMS * 1_000_000)), ("samples", .int($0.samples)),
                ("periodic_samples", .int($0.periodicSamples)),
                ("expected_periodic_samples", .int($0.expectedPeriodicSamples)),
                ("missed_intervals", .int($0.missedIntervals)), ("max_lateness_ns", .int($0.maxLatenessNS)),
                ("total_collection_ns", .int($0.totalCollectionNS)),
            ]))
        } ?? .null
        let phaseJSON = phases.map { name, start, end in
            JSONValue.object(JSONObject([("phase", .string(name)), ("start_ns", .int(start)), ("end_ns", .int(end))]))
        }
        var durations = JSONObject([("setup", .int(trace.anchorNS - setupStartNS)),
                                    ("runtime_total", .int(drainEnd - setupStartNS))])
        for (name, start, end) in phases { durations.set(name, .int(end - start)) }
        if let sampler { durations.set("telemetry_collection", .int(sampler.totalCollectionNS)) }
        return .object(JSONObject([
            ("schema_version", .string(SchemaVersion.current)), ("run_id", .string(plan.runID)),
            ("conversion", prepared.conversion.toJSON()),
            ("clock", .object(JSONObject([("minimum_resolution_ns", .int(clock.minimumResolutionNS)),
                                          ("replay_anchor_ns", .int(trace.anchorNS)),
                                          ("setup_start_ns", .int(setupStartNS))]))),
            ("replay", .object(JSONObject([
                ("mode", .string(trace.mode.rawValue)), ("frame_samples", .int(trace.frameSamples)),
                ("speed", trace.speed.toJSON()), ("deadline_convention", .string(SampleClock.deadlineConvention)),
                ("overflow", .string(trace.overflow.rawValue)), ("queue_capacity", .int(Int64(trace.queueCapacity))),
                ("sample_rate_hz", .int(trace.sampleRateHz)), ("total_frames", .int(trace.totalFrames)),
                ("elapsed_ns", .int(trace.elapsedNS)),
            ]))),
            ("phases", .array(phaseJSON)),
            ("events_prefix", prefix.toJSON()),
            ("telemetry", telemetryJSON),
            ("telemetry_sampler", samplerJSON),
            ("coverage", .object(JSONObject([
                ("produced_samples", .int(trace.producedSamples)), ("admitted_samples", .int(trace.admittedSamples)),
                ("consumed_samples", .int(trace.consumedSamples)), ("dropped_samples", .int(trace.droppedSamples)),
                ("dropped_ranges", .array(trace.droppedRanges.map { $0.toJSON() })),
            ]))),
            ("data_loss", .bool(trace.droppedSamples > 0)),
            ("integrity", .object(JSONObject([
                ("spool_sha256", .string(prepared.spool.sha256)), ("spool_frames", .int(prepared.spool.frameCount)),
                ("pre_replay_verified", .bool(true)), ("end_of_stream_verified", .bool(true)),
            ]))),
            ("recorder", .object(JSONObject([
                ("batches", .int(recorder.batches)), ("bytes", .int(recorder.bytes)),
                ("total_write_ns", .int(recorder.totalWriteNS)), ("max_write_ns", .int(recorder.maxWriteNS)),
            ]))),
            ("queues", .object(JSONObject([
                ("audio_max_depth", .int(Int64(trace.maxQueueDepth))), ("event_max_depth", .int(Int64(eventMaxDepth))),
                ("telemetry_max_depth", .int(Int64(telemetryMaxDepth))),
            ]))),
            ("durations_ns", .object(durations)),
            ("shutdown", .object(JSONObject(AdapterRole.allCases.compactMap { role in
                shutdownReports[role].map { (role.rawValue, $0.toJSON()) }
            }))),
        ]))
    }
}
