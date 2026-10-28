import AdapterContracts
import BenchmarkSupport
import Experiment
import Foundation
import MockAdapters
import RealAdapterSupport
#if PHASE1_FLUID
import FluidAudioAdapters
#endif
#if PHASE1_SPEECH
import SpeechSwiftAdapters
#endif

/// The CLI's adapter table: the Phase 0 mocks, the passive counterpart roles, and the
/// real Phase 1 wrappers compiled into this binary (`PHASE1_FRAMEWORKS`). Entries only
/// construct adapters; no model is loaded until the configured adapter's `prepare`.
enum RealAdapterFactory {
    static func make(environment: [String: String] = ProcessInfo.processInfo.environment) -> AdapterFactory {
        var entries = AdapterFactory.builtIn.entries
        entries[PassiveAdapterIDs.asr] = .init(role: .asr, requestedPlacement: .unspecified, isMock: false) {
            PassiveASRAdapter()
        }
        entries[PassiveAdapterIDs.diarization] = .init(role: .diarization, requestedPlacement: .unspecified, isMock: false) {
            PassiveDiarizationAdapter()
        }
        let roots = Phase1Roots.fromEnvironment(environment)
        #if PHASE1_FLUID
        entries[FluidAudioAdapterIDs.sortformer] = .init(role: .diarization, requestedPlacement: .unspecified, isMock: false) {
            FluidSortformerAdapter.make(roots: roots)
        }
        entries[FluidAudioAdapterIDs.eou] = .init(role: .asr, requestedPlacement: .unspecified, isMock: false) {
            FluidEOUASRAdapter.make(roots: roots)
        }
        #endif
        #if PHASE1_SPEECH
        entries[SpeechSwiftAdapterIDs.sortformer] = .init(role: .diarization, requestedPlacement: .unspecified, isMock: false) {
            SpeechSortformerAdapter.make(roots: roots)
        }
        entries[SpeechSwiftAdapterIDs.eou] = .init(role: .asr, requestedPlacement: .unspecified, isMock: false) {
            SpeechEOUASRAdapter.make(roots: roots)
        }
        #endif
        _ = roots
        return AdapterFactory(entries: entries)
    }

    /// Frameworks compiled into this binary, for `--version` and the run summary.
    static var compiledFrameworks: [String] {
        var names: [String] = []
        #if PHASE1_FLUID
        names.append("FluidAudio@\(FluidAudioAdapterIDs.sourceRevision.prefix(12))")
        #endif
        #if PHASE1_SPEECH
        names.append("speech-swift@\(SpeechSwiftAdapterIDs.sourceRevision.prefix(12))")
        #endif
        return names
    }

    /// One-line role description for the run summary: which role ran a real model,
    /// which was passive, and which was a mock.
    static func describe(asrID: String, diarizationID: String) -> String {
        func kind(_ id: String) -> String {
            switch id {
            case PassiveAdapterIDs.asr, PassiveAdapterIDs.diarization: return "passive (no model, no output)"
            case MockAdapterIDs.asr, MockAdapterIDs.diarization: return "MOCK"
            default: return "real"
            }
        }
        return "asr=\(asrID) [\(kind(asrID))], diarization=\(diarizationID) [\(kind(diarizationID))]"
    }
}
