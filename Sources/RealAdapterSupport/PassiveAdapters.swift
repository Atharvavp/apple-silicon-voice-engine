import AdapterContracts
import AudioCore
import BenchmarkSupport
import Foundation

/// Adapter IDs of the passive counterpart roles.
public enum PassiveAdapterIDs {
    public static let asr = "passive-asr"
    public static let diarization = "passive-diar"
    public static let revision = "passive-v1"
}

/// Shared no-output behavior: accepts the stream, loads no model, emits nothing.
/// It exists because a v1 run always selects both roles; it is not a mock and makes no
/// recognition claim. Its metrics are not computable (the manifest carries no reference
/// for its role).
struct PassiveCore {
    var lifecycle: AdapterLifecycle
    var shutdownReport: AdapterShutdownReport?

    mutating func prepare(_ context: AdapterContext, role: AdapterRole, adapterID: String) throws -> AdapterCapabilities {
        try lifecycle.beginPrepare()
        guard context.role == role else {
            throw AdapterError(.lifecycle, adapterID: adapterID, stage: .prepare, "configured as \(context.role.rawValue)")
        }
        guard context.selection.delayMS == 0 else {
            throw AdapterError(.incompatibleInput, adapterID: adapterID, stage: .prepare, "a passive role has delay_ms 0")
        }
        return try AdapterCapabilities(
            role: role, revision: context.selection.revision, sampleRatesHz: [context.format.sampleRateHz], channels: 1,
            frameMultipleSamples: nil, incremental: true, emitsPartials: false, emitsFinals: false,
            transcriptGranularity: role == .asr ? .recording : nil, requestedPlacement: .unspecified,
            observedPlacement: .missing(.notComputable, source: "passive_adapter", reason: "passive_role_runs_no_model"))
    }

    mutating func shutdown() -> AdapterShutdownReport {
        if let shutdownReport { return shutdownReport }
        _ = lifecycle.beginShutdown()
        shutdownReport = .clean
        return .clean
    }
}

public actor PassiveASRAdapter: ASRAdapter {
    public nonisolated let adapterID: String
    public nonisolated var role: AdapterRole { .asr }
    private var core: PassiveCore

    public init(adapterID: String = PassiveAdapterIDs.asr) {
        self.adapterID = adapterID
        core = PassiveCore(lifecycle: AdapterLifecycle(adapterID: adapterID))
    }

    public func prepare(context: AdapterContext, sink: any AdapterEventSink) async throws -> AdapterCapabilities {
        try core.prepare(context, role: .asr, adapterID: adapterID)
    }

    public func consume(_ chunk: AudioChunk, context: ConsumeContext) async throws {
        try core.lifecycle.checkConsume(chunkIndex: chunk.chunkIndex)
    }

    public func flush(endOfStream: StreamEnd) async throws { try core.lifecycle.beginFlush() }

    public func shutdown() async -> AdapterShutdownReport { core.shutdown() }
}

public actor PassiveDiarizationAdapter: DiarizationAdapter {
    public nonisolated let adapterID: String
    public nonisolated var role: AdapterRole { .diarization }
    private var core: PassiveCore

    public init(adapterID: String = PassiveAdapterIDs.diarization) {
        self.adapterID = adapterID
        core = PassiveCore(lifecycle: AdapterLifecycle(adapterID: adapterID))
    }

    public func prepare(context: AdapterContext, sink: any AdapterEventSink) async throws -> AdapterCapabilities {
        try core.prepare(context, role: .diarization, adapterID: adapterID)
    }

    public func consume(_ chunk: AudioChunk, context: ConsumeContext) async throws {
        try core.lifecycle.checkConsume(chunkIndex: chunk.chunkIndex)
    }

    public func flush(endOfStream: StreamEnd) async throws { try core.lifecycle.beginFlush() }

    public func shutdown() async -> AdapterShutdownReport { core.shutdown() }
}
