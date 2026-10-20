import AdapterContracts
import AudioCore
import os
import BenchmarkSupport
import Foundation
import Replay
import Telemetry

/// What the runtime stage produced (plan M4 `RuntimeArtifacts`): the frozen
/// prefix and closed runtime files. It never claims a completed status; only
/// the production coordinator seals a run, after scoring.
public struct RuntimeArtifacts: Sendable {
    public let directory: RunDirectory
    public let prefix: EventRecorder.PrefixDescriptor
    public let closedArtifacts: [ArtifactDigest]
    public let trace: ReplayTrace
    public let conversion: ConversionRecord
    public let dataLoss: Bool
    public let recorder: EventRecorder
}

public struct RunOutcome: Sendable {
    public let runID: String?
    public let directory: URL?
    public let state: RunState
    public let failure: ExperimentError?
    public let summary: JSONValue?

    public var exitCode: Int32 { failure?.exitCode ?? ExitCodes.success }
}

/// Runs one experiment (one item, one stream) per process (plan D4).
public struct ExperimentRunner: Sendable {
    public let factory: AdapterFactory

    public init(factory: AdapterFactory = .builtIn) { self.factory = factory }

    /// Production path: preflight, runtime stage, scoring, sealing.
    public func run(_ request: RunRequest) async -> RunOutcome {
        await execute(request, scoring: true).outcome
    }

    /// M4 test path: preflight and runtime stage only. The run stays in a
    /// nonterminal state (`flushing`) with no metrics; nothing is sealed.
    public func runtimeOnly(_ request: RunRequest) async -> (outcome: RunOutcome, runtime: RuntimeArtifacts?) {
        await execute(request, scoring: false)
    }

    private func execute(_ request: RunRequest, scoring: Bool) async -> (outcome: RunOutcome, runtime: RuntimeArtifacts?) {
        let plan: RunPlan
        do { plan = try RunPlanner.plan(request, factory: factory) } catch {
            let failure = ExperimentError.classify(error, stage: .created)
            return (RunOutcome(runID: request.runID, directory: nil, state: .failed, failure: failure, summary: nil), nil)
        }
        let directory: RunDirectory
        do { directory = try RunDirectory.create(runsDirectory: request.runsDirectory, runID: plan.runID) } catch {
            return (RunOutcome(runID: plan.runID, directory: nil, state: .failed,
                               failure: ExperimentError.classify(error, stage: .created), summary: nil), nil)
        }
        let session = RunSession(plan: plan, directory: directory, factory: factory)
        return await session.execute(scoring: scoring)
    }
}

/// Mutable lifecycle state of one run.
actor RunSession {
    let plan: RunPlan
    let directory: RunDirectory
    let factory: AdapterFactory
    let clock = ContinuousRunClock()
    let virtualClock: VirtualClock?
    let identityRate: Int64

    private var state: RunState = .created
    var setupStartNS: Int64 = 0
    var phases: [(String, Int64, Int64)] = []
    private var durations: [(String, Int64)] = []
    private var closed: [ArtifactDigest] = []
    private var recorder: EventRecorder?
    private var runnerChannel: ProducerChannel?
    private var telemetryStream: JSONLStream?
    private var sampler: TelemetrySampler?
    private var adapters: [any StreamingAdapter] = []
    private var adapterChannels: [String: ProducerChannel] = [:]
    var shutdownReports: [AdapterRole: AdapterShutdownReport] = [:]
    private var lastSampleID: Int64 = 0

    init(plan: RunPlan, directory: RunDirectory, factory: AdapterFactory) {
        self.plan = plan
        self.directory = directory
        self.factory = factory
        virtualClock = plan.config.mode == .step ? VirtualClock() : nil
        identityRate = plan.config.targetSampleRateHz
    }

    var identity: RunIdentity { RunIdentity(runID: plan.runID, sourceID: plan.item.itemID, sampleRateHz: identityRate) }

    // MARK: Lifecycle

    func execute(scoring: Bool) async -> (outcome: RunOutcome, runtime: RuntimeArtifacts?) {
        setupStartNS = clock.nowNS()
        do {
            try writeStatus(.created)
            let runtime = try await runtimeStage()
            guard scoring else {
                return (RunOutcome(runID: plan.runID, directory: directory.url, state: state, failure: nil, summary: nil),
                        runtime)
            }
            let summary = try await scoreAndSeal(runtime)
            return (RunOutcome(runID: plan.runID, directory: directory.url, state: .completed, failure: nil,
                               summary: summary), runtime)
        } catch {
            var failure = ExperimentError.classify(error, stage: state)
            if Task.isCancelled, failure.category != .cancelled {
                failure = ExperimentError(.cancelled, stage: state, "run cancelled (\(failure.message))")
            }
            let note = await cleanupAfterFailure(failure)
            failure.cleanupNote = note
            return (RunOutcome(runID: plan.runID, directory: directory.url,
                               state: failure.category == .cancelled ? .cancelled : .failed, failure: failure,
                               summary: nil), nil)
        }
    }

    private func writeStatus(_ next: RunState) throws {
        guard next == .created || state.canTransition(to: next) else {
            throw ExperimentError(.runtime, stage: state, "illegal lifecycle transition \(state.rawValue) -> \(next.rawValue)")
        }
        state = next
        try directory.writeStatus(RunStatus(runID: plan.runID, state: next, updatedWallTime: WallClock.now(),
                                            failure: nil, lastEventSequence: nil, artifacts: nil))
    }

    private func phase<T>(_ name: String, _ body: () async throws -> T) async rethrows -> T {
        let start = clock.nowNS()
        let value = try await body()
        let end = clock.nowNS()
        phases.append((name, start, end))
        return value
    }

    // MARK: Runtime stage (plan C3 steps 1-5)

    func runtimeStage() async throws -> RuntimeArtifacts {
        let config = plan.config
        let bridge = PythonBridge(python: plan.pythonExecutable, projectRoot: plan.projectRoot,
                                  timeoutSeconds: config.analysisTimeoutS)

        // Freeze inputs: python facts, reference/script copies, manifest snapshot, settings, config.
        let envResult = try await bridge.run("env-info", [], logDirectory: directory.path("logs"), label: "env-info")
        guard envResult.succeeded else {
            throw ExperimentError(.analysis, stage: state, "env-info failed (exit \(envResult.exitCode)): \(envResult.stderrTail())")
        }
        let python: PythonFacts
        do { python = try PythonFacts.read(envResult.stdout()) } catch {
            throw ExperimentError(.analysis, stage: state, "env-info output is invalid: \(error)")
        }
        try freezeInputs()
        closed.append(try directory.writeArtifact("config_settings.json", try plan.loaded.settingsBytesAndHash().bytes))
        closed.append(try directory.writeJSON("config.json", try frozenConfig(python: python)))
        try writeStatus(.validated)

        // Recorder and telemetry.
        let recorder = try EventRecorder(directory: directory, clock: clock, maxBytes: config.maxOutputBytes)
        await recorder.start()
        self.recorder = recorder
        let runner = ProducerChannel(producerID: "runner", identity: identity, stream: recorder.stream)
        runnerChannel = runner
        try await runner.emit(.experimentStarted, payload: JSONObject([
            ("mode", .string(config.mode.rawValue)), ("settings_sha256", .string(try plan.loaded.settingsBytesAndHash().sha256)),
            ("manifest_sha256", .string(plan.manifestSHA256)), ("audio_sha256", .string(plan.audio.sha256)),
            ("schema_bundle_sha256", .string(plan.schemaBundle.sha256)),
        ]), emittedNS: clock.nowNS(), virtualNS: await virtualClock?.nowNS)
        if config.telemetryEnabled { try await startTelemetry(runner) }

        // Audio preparation (decode -> mono -> SRC -> spool), then the pre-replay integrity check.
        let prepared = try await phase("prepare_audio") { try prepareAudio() }
        try await runner.emit(.stageCompleted, payload: stagePayload("prepare_audio"), emittedNS: clock.nowNS(),
                              virtualNS: await virtualClock?.nowNS)

        // Adapters: ASR then diarization (plan C3 step 2).
        let pipeline = try await phase("adapter_prepare") { try await prepareAdapters(prepared) }
        try await runner.emit(.stageCompleted, payload: stagePayload("adapter_prepare"), emittedNS: clock.nowNS(),
                              virtualNS: await virtualClock?.nowNS)
        closed.append(try directory.writeJSON("environment.json", try environment(python: python,
                                                                                  capabilities: pipeline.capabilities)))
        try writeStatus(.prepared)

        // Replay (plan C3 step 3).
        try writeStatus(.running)
        await sampler?.setPhase("running")
        let replayConfiguration = try ReplayConfiguration(
            mode: config.mode, frameSamples: config.frameSamples!, speed: config.speed,
            queueCapacity: Int(config.queueCapacity), overflow: config.overflow, runID: plan.runID,
            sourceID: plan.item.itemID)
        let replayChannel = ProducerChannel(producerID: "replay", identity: identity, stream: recorder.stream)
        let observer = ReplayEventObserver(channel: replayChannel, clock: clock, virtualClock: virtualClock,
                                           capacity: Int(config.queueCapacity))
        let worker = pipeline.worker
        let trace = try await ReplayScheduler.run(spool: prepared.spool, configuration: replayConfiguration, clock: clock,
                                                  virtualClock: virtualClock ?? VirtualClock(), observer: observer) {
            try await worker.consume($0, $1)
        }
        phases.append(("replay", trace.anchorNS, trace.anchorNS + trace.elapsedNS))
        try trace.verifyCoverage(lossless: config.overflow == .block)

        // Flush, telemetry stop, shutdown, freeze (plan C3 step 4-5).
        try writeStatus(.flushing)
        await sampler?.setPhase("flushing")
        let dropped = try trace.droppedRanges.map { try SampleInterval(start: $0.start, end: $0.end) }
        try await phase("flush") {
            for adapter in adapters {
                let invocation = "\(adapter.role.rawValue)/flush"
                let start = clock.nowNS()
                let virtualStart = await virtualClock?.nowNS
                do {
                    try await adapter.flush(endOfStream: StreamEnd(
                        invocationID: invocation, finalSample: trace.totalFrames, consumedSamples: trace.consumedSamples,
                        droppedRanges: dropped, reason: .normal))
                } catch {
                    await pipeline.worker.reportFailure(adapter, stage: "flush", error)
                    throw error
                }
                let virtualEnd = await virtualClock?.nowNS
                try await pipeline.worker.stage("\(adapter.role.rawValue).flush", start: start, end: clock.nowNS(),
                                                virtual: virtualStart.flatMap { s in virtualEnd.map { $0 - s } },
                                                invocation: invocation, chunk: nil, virtualNow: virtualEnd)
            }
        }
        let samplerSummary = try await stopTelemetry(runner)
        try await phase("shutdown") { try await shutdownAdapters(strict: true) }
        try await runner.emit(.experimentRuntimeCompleted, payload: JSONObject([
            ("produced_samples", .int(trace.producedSamples)), ("admitted_samples", .int(trace.admittedSamples)),
            ("consumed_samples", .int(trace.consumedSamples)), ("dropped_samples", .int(trace.droppedSamples)),
            ("dropped_ranges", .array(dropped.map { $0.toJSON() })), ("last_media_sample", .int(trace.totalFrames)),
            ("replay_elapsed_ns", .int(trace.elapsedNS)),
        ]), emittedNS: clock.nowNS(), virtualNS: await virtualClock?.nowNS)
        let drainStart = clock.nowNS()
        let prefix = try await recorder.freezeRuntimePrefix()
        let telemetryDigest = try await closeTelemetry()
        let drainEnd = clock.nowNS()
        phases.append(("drain", drainStart, drainEnd))

        let eventMaxDepth = await recorder.stream.maxDepth
        let telemetryMaxDepth = await telemetryStream?.maxDepth ?? 0
        let recorderStats = try await recorder.stream.writer.snapshot()
        let summary = runtimeSummary(prepared: prepared, trace: trace, prefix: prefix, telemetry: telemetryDigest,
                                     sampler: samplerSummary, recorder: recorderStats, eventMaxDepth: eventMaxDepth,
                                     telemetryMaxDepth: telemetryMaxDepth, drainEnd: drainEnd)
        closed.append(try directory.writeJSON("runtime_summary.json", summary))
        let predictions = try PredictionBuilder.build(
            prefixURL: directory.path(EventRecorder.partialName), prefix: prefix,
            inputs: PredictionBuilder.Inputs(
                runID: plan.runID, sourceID: plan.item.itemID, mock: pipeline.mock, asr: config.asr,
                diarization: config.diarization, sampleRateHz: prepared.spool.sampleRateHz,
                durationSamples: prepared.spool.frameCount, sourceSHA256: prepared.source.sha256,
                convertedSHA256: prepared.spool.sha256,
                transcriptGranularity: pipeline.capabilities[.asr]?.transcriptGranularity ?? .utterances,
                consumedSamples: trace.consumedSamples, droppedRanges: dropped))
        closed.append(try directory.writeJSON("predictions.json", predictions))
        return RuntimeArtifacts(directory: directory, prefix: prefix, closedArtifacts: closed, trace: trace,
                                conversion: prepared.conversion, dataLoss: trace.droppedSamples > 0, recorder: recorder)
    }

    private func stagePayload(_ name: String) -> JSONObject {
        let (start, end) = phases.last.map { ($0.1, $0.2) } ?? (0, 0)
        return JSONObject([("stage", .string(name)), ("start_ns", .int(start)), ("end_ns", .int(end)),
                           ("duration_ns", .int(end - start)), ("virtual_duration_ns", .null)])
    }

    private func freezeInputs() throws {
        func copy(_ input: VerifiedInput?, to relative: String) throws {
            guard let input else { return }
            let data = try Data(contentsOf: input.url)
            guard SHA256Hex.digest(data) == input.sha256 else {
                throw ExperimentError(.dataset, stage: state, "\(input.url.lastPathComponent) changed after preflight")
            }
            closed.append(try directory.writeArtifact(relative, data))
        }
        try copy(plan.transcript, to: "references/transcript.json")
        try copy(plan.speakers, to: "references/speakers.json")
        try copy(plan.script, to: "inputs/fixture_script.json")
        let manifest = try Data(contentsOf: plan.manifestURL)
        guard SHA256Hex.digest(manifest) == plan.manifestSHA256 else {
            throw ExperimentError(.dataset, stage: state, "manifest changed after preflight")
        }
        closed.append(try directory.writeArtifact("dataset_manifest_snapshot.json", manifest))
    }

    private func prepareAudio() throws -> PreparedAudio {
        let config = plan.config
        let prepared = try AudioPreparer.prepare(source: plan.audio.url, sourceID: plan.item.itemID,
                                                 targetRateHz: config.targetSampleRateHz,
                                                 scratchDirectory: directory.path("scratch"),
                                                 endpointPolicy: config.endpointPolicy)
        // The bytes actually decoded must be the bytes the manifest describes.
        guard prepared.source.sha256 == plan.audio.sha256 else {
            throw ExperimentError(.dataset, stage: state, "audio changed between preflight and decode")
        }
        guard prepared.source.sampleRateHz == plan.item.sampleRateHz, Int64(prepared.source.channels) == plan.item.channels,
              prepared.source.frameCount == plan.item.durationSamples else {
            throw ExperimentError(.dataset, stage: state,
                                  "WAV is \(prepared.source.sampleRateHz) Hz, \(prepared.source.channels) ch, \(prepared.source.frameCount) frames; the manifest declares \(plan.item.sampleRateHz) Hz, \(plan.item.channels) ch, \(plan.item.durationSamples) frames")
        }
        try prepared.conversion.validate()
        // Pre-replay integrity: the spool on disk must still hash to the recorded digest.
        let (onDisk, bytes) = try SHA256Hex.file(prepared.spool.url)
        guard onDisk == prepared.spool.sha256, bytes == prepared.spool.frameCount * 4 else {
            throw ExperimentError(.runtime, stage: state, "pre-replay spool verification failed: \(onDisk) != \(prepared.spool.sha256)")
        }
        return prepared
    }

    struct PreparedPipeline {
        let worker: PipelineWorker
        let capabilities: [AdapterRole: AdapterCapabilities]
        let mock: Bool
    }

    private func prepareAdapters(_ prepared: PreparedAudio) async throws -> PreparedPipeline {
        let config = plan.config
        guard let recorder else { throw RecorderError("recorder not started") }
        let delays: any AdapterDelayService = virtualClock.map { VirtualClockDelays(virtualClock: $0) }
            ?? RunClockDelays(clock: clock)
        var capabilities: [AdapterRole: AdapterCapabilities] = [:]
        var mock = false
        let scriptReference = plan.script.map {
            FixtureScriptReference(url: directory.path("inputs/fixture_script.json"), sha256: $0.sha256)
        }
        for (role, selection) in [(AdapterRole.asr, config.asr), (.diarization, config.diarization)] {
            guard let entry = factory.entry(selection.id) else {
                throw ExperimentError(.invalidInput, stage: state, "unknown adapter \(selection.id)")
            }
            let adapter = entry.make()
            guard adapter.role == role, adapter.adapterID == selection.id else {
                throw ExperimentError(.runtime, stage: state, "factory entry \(selection.id) built \(adapter.adapterID) (\(adapter.role.rawValue))")
            }
            adapters.append(adapter)
            mock = mock || entry.isMock
            let channel = ProducerChannel(producerID: adapter.adapterID, identity: identity, stream: recorder.stream)
            adapterChannels[adapter.adapterID] = channel
            let sink = RecordingAdapterSink(channel: channel, role: role, adapterID: adapter.adapterID,
                                            durationSamples: prepared.spool.frameCount, clock: clock,
                                            virtualClock: virtualClock)
            let context = AdapterContext(
                role: role, selection: selection, runID: plan.runID, streamID: identity.streamID,
                sourceID: plan.item.itemID, format: PCMFormat(sampleRateHz: prepared.spool.sampleRateHz),
                durationSamples: prepared.spool.frameCount, frameSamples: config.frameSamples!, mode: config.mode,
                seed: config.seed, fixtureScript: scriptReference, delays: delays, clock: clock)
            let capability: AdapterCapabilities
            do { capability = try await adapter.prepare(context: context, sink: sink) } catch {
                try? await channel.emit(.adapterFailed, payload: JSONObject([
                    ("role", .string(role.rawValue)), ("adapter_id", .string(adapter.adapterID)),
                    ("stage", .string("prepare")), ("message", .string(String(describing: error))),
                ]), emittedNS: clock.nowNS(), virtualNS: await virtualClock?.nowNS)
                throw error
            }
            let problems = capability.incompatibilities(sampleRateHz: prepared.spool.sampleRateHz, channels: 1,
                                                        frameSamples: config.frameSamples!)
            guard capability.role == role, problems.isEmpty, capability.requestedPlacement == entry.requestedPlacement else {
                throw ExperimentError(.runtime, stage: state,
                                      "adapter \(adapter.adapterID) cannot consume this stream: \(problems.joined(separator: "; "))")
            }
            await sink.configure(capabilities: capability, durationSamples: prepared.spool.frameCount)
            capabilities[role] = capability
            try await channel.emit(.adapterStarted, payload: JSONObject([
                ("role", .string(role.rawValue)), ("adapter_id", .string(adapter.adapterID)),
                ("revision", .string(capability.revision)), ("capabilities", capability.toJSON()),
            ]), emittedNS: clock.nowNS(), virtualNS: await virtualClock?.nowNS)
        }
        let pipelineChannel = ProducerChannel(producerID: "pipeline", identity: identity, stream: recorder.stream)
        return PreparedPipeline(
            worker: PipelineWorker(adapters: adapters, channel: pipelineChannel, adapterChannels: adapterChannels,
                                   clock: clock, virtualClock: virtualClock),
            capabilities: capabilities, mock: mock)
    }

    /// Calls `shutdown` exactly once per adapter (also after failures), emitting `adapter.stopped`.
    private func shutdownAdapters(strict: Bool) async throws {
        for adapter in adapters where shutdownReports[adapter.role] == nil {
            let report = await adapter.shutdown()
            shutdownReports[adapter.role] = report
            if let channel = adapterChannels[adapter.adapterID] {
                let emit = {
                    try await channel.emit(.adapterStopped, payload: JSONObject([
                        ("role", .string(adapter.role.rawValue)), ("adapter_id", .string(adapter.adapterID)),
                        ("shutdown", report.toJSON()),
                    ]), emittedNS: self.clock.nowNS(), virtualNS: await self.virtualClock?.nowNS)
                }
                if strict { try await emit() } else { try? await emit() }
            }
            if strict, report.status != .ok || report.pendingTasks != 0 {
                throw ExperimentError(.runtime, stage: state,
                                      "adapter \(adapter.adapterID) shutdown reported \(report.status.rawValue): \(report.message ?? "pending tasks \(report.pendingTasks)")")
            }
        }
    }

    // MARK: Telemetry

    private func startTelemetry(_ runner: ProducerChannel) async throws {
        let stream = try JSONLStream(url: directory.path("telemetry.jsonl.partial"), capacity: 64,
                                     maxRecordBytes: 1 << 20, maxBytes: plan.config.maxOutputBytes, clock: clock)
        await stream.start()
        telemetryStream = stream
        let sampler = TelemetrySampler(runID: plan.runID, intervalMS: plan.config.telemetryIntervalMS, clock: clock) { data in
            try await stream.admit(PendingLine { _, _ in data })
        }
        self.sampler = sampler
        try await sampler.start()
        try await runner.emit(.telemetrySample, payload: JSONObject([("sample_id", .string("t00000")), ("phase", .string("start"))]),
                              emittedNS: clock.nowNS(), virtualNS: await virtualClock?.nowNS)
    }

    private func stopTelemetry(_ runner: ProducerChannel) async throws -> TelemetrySampler.Summary? {
        guard let sampler else { return nil }
        let summary = try await sampler.stop()
        self.sampler = nil
        try await runner.emit(.telemetrySample, payload: JSONObject([
            ("sample_id", .string(String(format: "t%05lld", summary.samples - 1))), ("phase", .string("end")),
        ]), emittedNS: clock.nowNS(), virtualNS: await virtualClock?.nowNS)
        return summary
    }

    private func closeTelemetry() async throws -> ArtifactDigest? {
        guard let stream = telemetryStream else { return nil }
        _ = try await stream.drainAndSync()
        try await stream.writer.close()
        guard renamex_np(directory.path("telemetry.jsonl.partial").path, directory.path("telemetry.jsonl").path,
                         UInt32(RENAME_EXCL)) == 0 else {
            throw RecorderError("cannot finalize telemetry.jsonl: \(String(cString: strerror(errno)))")
        }
        telemetryStream = nil
        let digest = try directory.digest("telemetry.jsonl")
        closed.append(digest)
        return digest
    }

    // MARK: Scoring and sealing (plan C3 step 6)

    func scoreAndSeal(_ runtime: RuntimeArtifacts) async throws -> JSONValue {
        try writeStatus(.scoring)
        let bridge = PythonBridge(python: plan.pythonExecutable, projectRoot: plan.projectRoot,
                                  timeoutSeconds: plan.config.analysisTimeoutS)
        let result = try await bridge.run("score", ["--run", directory.url.path, "--analysis-id", "initial"],
                                          logDirectory: directory.path("logs"), label: "analysis")
        guard result.succeeded else {
            let reason = result.timedOut ? "timed out after \(plan.config.analysisTimeoutS) s"
                : result.outputLimitHit ? "exceeded the log output limit" : "exit \(result.exitCode)"
            throw ExperimentError(.analysis, stage: state, "scoring \(reason): \(result.stderrTail())")
        }
        for name in ["metrics.json", "validation.json"] where !directory.exists(name) {
            throw ExperimentError(.analysis, stage: state, "scoring did not write \(name)")
        }
        let validation = try StrictJSON.parseFile(directory.path("validation.json"))
        guard case .object(let report) = validation, report["status"] == .string("pass") else {
            throw ExperimentError(.validation, stage: state, "initial validation did not pass; see validation.json")
        }
        let metrics = try directory.digest("metrics.json")
        let validationDigest = try directory.digest("validation.json")
        let sealed = runtime.closedArtifacts + [metrics, validationDigest]
        guard let recorder else { throw RecorderError("recorder missing at sealing") }
        try await recorder.appendTerminal { sequence, now in
            EventEnvelope(eventID: "\(self.plan.item.itemID)/runner/experiment.completed/0", runID: self.plan.runID,
                          streamID: "audio-0", sourceID: self.plan.item.itemID, sequence: sequence, producerID: "runner",
                          producerSequence: sequence, type: .experimentCompleted, mediaStartSample: nil,
                          mediaEndSample: nil, sampleRateHz: self.identityRate, monotonicEmittedNS: now,
                          monotonicRecordedNS: now, virtualEmittedNS: nil, causeChunkIndex: nil, invocationID: nil,
                          payload: JSONObject([("artifacts", .array(sealed.map { $0.toJSON() }))]))
        }
        let trace = try await recorder.finalize(success: true)
        let artifacts = sealed + [trace]
        state = .completed
        try directory.writeStatus(RunStatus(runID: plan.runID, state: .completed, updatedWallTime: WallClock.now(),
                                            failure: nil, lastEventSequence: await recorder.lastSequence,
                                            artifacts: artifacts))
        // Scratch is removed only after the terminal status is durable; its hash and count stay in runtime_summary.
        try? FileManager.default.removeItem(at: directory.path("scratch/\(AudioPreparer.convertedSpoolName)"))
        return try StrictJSON.parseFile(directory.path("metrics.json"))
    }

    // MARK: Failure path

    /// Bounded cleanup (plan C3): stop sampling, shut adapters down, append one
    /// terminal event if the writer is usable, then write a failed/cancelled
    /// status. Runs detached so a cancelled run task can still clean up.
    private func cleanupAfterFailure(_ failure: ExperimentError) async -> String? {
        let budget = plan.config.cleanupTimeoutS
        let outcome = await Race.first(timeoutNS: budget * 1_000_000_000) { await self.cleanup(failure) }
        switch outcome {
        case .finished(let note):
            return note
        case .timedOut:
            // The trace could not be closed in time; the status still records the primary cause.
            let note = "cleanup exceeded \(budget) s"
            var recorded = failure
            recorded.cleanupNote = note
            try? directory.writeStatus(RunStatus(runID: plan.runID,
                                                 state: failure.category == .cancelled ? .cancelled : .failed,
                                                 updatedWallTime: WallClock.now(), failure: recorded.failure,
                                                 lastEventSequence: nil, artifacts: nil))
            return note
        }
    }

    private func cleanup(_ failure: ExperimentError) async -> String? {
        var notes: [String] = []
        if let sampler {
            _ = try? await sampler.stop()
            self.sampler = nil
        }
        do { try await shutdownAdapters(strict: false) } catch { notes.append("adapter shutdown: \(error)") }
        var lastSequence: Int64?
        if let recorder, await !recorder.hasTerminal {
            let terminal: EventType = failure.category == .cancelled ? .experimentCancelled : .experimentFailed
            do {
                let envelope = try await recorder.appendTerminal { sequence, now in
                    EventEnvelope(eventID: "\(self.plan.item.itemID)/runner/\(terminal.rawValue)/0", runID: self.plan.runID,
                                  streamID: "audio-0", sourceID: self.plan.item.itemID, sequence: sequence,
                                  producerID: "runner", producerSequence: sequence, type: terminal,
                                  mediaStartSample: nil, mediaEndSample: nil, sampleRateHz: self.identityRate,
                                  monotonicEmittedNS: now, monotonicRecordedNS: now, virtualEmittedNS: nil,
                                  causeChunkIndex: nil, invocationID: nil, payload: JSONObject([
                                      ("failure", failure.failure.toJSON()),
                                      ("last_valid_sequence", sequence > 0 ? .int(sequence - 1) : .null),
                                  ]))
                }
                lastSequence = envelope.sequence
            } catch { notes.append("terminal event not written: \(error)") }
            do { _ = try await recorder.finalize(success: false) } catch { notes.append("trace close: \(error)") }
        } else if let recorder {
            lastSequence = await recorder.lastSequence
        }
        if let stream = telemetryStream {
            _ = try? await stream.drainAndSync()
            try? await stream.writer.close()
        }
        var artifacts: [ArtifactDigest] = []
        for name in ["config.json", "config_settings.json", "environment.json", "dataset_manifest_snapshot.json",
                     "runtime_summary.json", "predictions.json", "metrics.json", "validation.json",
                     EventRecorder.partialName, "telemetry.jsonl.partial", "telemetry.jsonl"] where directory.exists(name) {
            if let digest = try? directory.digest(name) { artifacts.append(digest) }
        }
        let note = notes.isEmpty ? nil : notes.joined(separator: "; ")
        var recorded = failure
        recorded.cleanupNote = note
        let status = RunStatus(runID: plan.runID, state: failure.category == .cancelled ? .cancelled : .failed,
                               updatedWallTime: WallClock.now(), failure: recorded.failure, lastEventSequence: lastSequence,
                               artifacts: artifacts.isEmpty ? nil : artifacts)
        state = status.state
        do { try directory.writeStatus(status) } catch {
            FileHandle.standardError.write(Data("voicebench: cannot write failure status: \(error)\n".utf8))
            notes.append("status write failed: \(error)")
        }
        return notes.isEmpty ? nil : notes.joined(separator: "; ")
    }
}

/// Runs `work` in a detached task and returns its result, or `.timedOut` after
/// `timeoutNS` without waiting for the work to finish (a task group would wait).
enum Race {
    enum Outcome<T: Sendable>: Sendable {
        case finished(T)
        case timedOut
    }

    static func first<T: Sendable>(timeoutNS: Int64, _ work: @escaping @Sendable () async -> T) async -> Outcome<T> {
        await withCheckedContinuation { (continuation: CheckedContinuation<Outcome<T>, Never>) in
            let done = OSAllocatedUnfairLock(initialState: false)
            let finish: @Sendable (Outcome<T>) -> Void = { outcome in
                let first = done.withLock { flag -> Bool in
                    defer { flag = true }
                    return !flag
                }
                if first { continuation.resume(returning: outcome) }
            }
            Task.detached { finish(.finished(await work())) }
            Task.detached {
                try? await Task.sleep(nanoseconds: UInt64(max(timeoutNS, 0)))
                finish(.timedOut)
            }
        }
    }
}
