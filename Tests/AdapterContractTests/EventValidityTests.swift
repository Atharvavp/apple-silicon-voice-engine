import AdapterContracts
import BenchmarkSupport
import Foundation
import MockAdapters
import Testing

/// Output-contract rules every sink applies (plan D5): invalid revision
/// transitions fail, out-of-order emission/media does not.
struct EventValidityTests {
    private let cause = EventCause.chunk(index: 0, invocationID: "asr/consume/0")

    private func transcript(_ id: String, _ revision: Int64, final: Bool, _ range: (Int64, Int64)? = (0, 320)) throws -> AdapterEvent {
        AdapterEvent(.transcript(utteranceID: id, revision: revision, text: "x", isFinal: final),
                     media: try range.map { try SampleInterval(start: $0.0, end: $0.1) }, cause: cause)
    }

    private func validator(_ role: AdapterRole = .asr, granularity: TranscriptOutputGranularity? = .utterances)
        -> AdapterOutputValidator {
        AdapterOutputValidator(role: role, adapterID: "a", durationSamples: 16_000,
                               transcriptGranularity: role == .asr ? granularity : nil)
    }

    @Test func increasingPartialsThenOneFinalAreValid() throws {
        var v = validator()
        try v.check(try transcript("u0", 0, final: false))
        try v.check(try transcript("u0", 2, final: false))
        try v.check(try transcript("u0", 3, final: true))
        #expect(v.unfinalizedUtterances.isEmpty)
    }

    @Test func finalWithoutPartialsIsValid() throws {
        var v = validator()
        try v.check(try transcript("u0", 0, final: true))
    }

    @Test(arguments: ["duplicate final", "partial after final", "revision regression", "revision repeat"])
    func invalidTransitionsAreRejected(_ label: String) throws {
        var v = validator()
        let sequence: [(Int64, Bool)]
        switch label {
        case "duplicate final": sequence = [(0, true), (1, true)]
        case "partial after final": sequence = [(0, true), (1, false)]
        case "revision regression": sequence = [(3, false), (2, false)]
        default: sequence = [(1, false), (1, true)]
        }
        try v.check(try transcript("u0", sequence[0].0, final: sequence[0].1))
        do {
            try v.check(try transcript("u0", sequence[1].0, final: sequence[1].1))
            Issue.record("\(label) was accepted")
        } catch let error as AdapterError {
            #expect(error.kind == .contract && error.stage == .emit)
        }
    }

    @Test func utterancesAreIndependentAndMediaMayArriveOutOfOrder() throws {
        var v = validator()
        try v.check(try transcript("u1", 0, final: true, (8_000, 9_000)))
        try v.check(try transcript("u0", 0, final: true, (0, 1_000)))
    }

    @Test func outOfRangeMediaIsRejected() throws {
        var v = validator()
        #expect(throws: AdapterError.self) { try v.check(try transcript("u0", 0, final: true, (15_000, 16_001))) }
    }

    @Test func rolesEmitOnlyTheirOwnOutputs() throws {
        var asr = validator()
        #expect(throws: AdapterError.self) {
            try asr.check(AdapterEvent(.speakerSegment(segmentID: "s", speakerID: "A"),
                                       media: try SampleInterval(start: 0, end: 10), cause: cause))
        }
        var diarization = validator(.diarization)
        #expect(throws: AdapterError.self) { try diarization.check(try transcript("u0", 0, final: true)) }
    }

    @Test func duplicateSpeakerSegmentIDsAreRejected() throws {
        var v = validator(.diarization)
        let segment = AdapterEvent(.speakerSegment(segmentID: "s0", speakerID: "A"),
                                   media: try SampleInterval(start: 0, end: 10), cause: cause)
        try v.check(segment)
        #expect(throws: AdapterError.self) { try v.check(segment) }
    }

    @Test func timedAndUntimedTranscriptsFollowTheDeclaredGranularity() throws {
        var timed = validator()
        #expect(throws: AdapterError.self) { try timed.check(try transcript("u0", 0, final: true, nil)) }
        var untimed = validator(granularity: .recording)
        try untimed.check(try transcript("u0", 0, final: true, nil))
        var untimedWithRange = validator(granularity: .recording)
        #expect(throws: AdapterError.self) { try untimedWithRange.check(try transcript("u1", 0, final: true)) }
    }

    @Test func eventPayloadsValidateAgainstTheEnvelopeRules() throws {
        // A mock output, wrapped the way the M4 sink wraps it, passes the typed envelope validation.
        let event = try transcript("u0", 1, final: true, (0, 64_000))
        let envelope = EventEnvelope(eventID: "two-speaker-en/mock-asr-scripted/transcript.final/0", runID: "r",
                                     streamID: "audio-0", sourceID: "two-speaker-en", sequence: 0,
                                     producerID: MockAdapterIDs.asr, producerSequence: 0, type: event.eventType,
                                     mediaStartSample: 0, mediaEndSample: 64_000, sampleRateHz: 16_000,
                                     monotonicEmittedNS: 1, monotonicRecordedNS: 2, virtualEmittedNS: nil,
                                     causeChunkIndex: 0, invocationID: event.cause.invocationID,
                                     payload: event.payload(role: .asr, adapterID: MockAdapterIDs.asr))
        try envelope.validate()
        #expect(try EventEnvelope.read(envelope.toJSON()) == envelope)
    }

    @Test func capabilitiesRoundTripAndCheckCompatibility() throws {
        let capabilities = try AdapterCapabilities(
            role: .asr, revision: "1", sampleRatesHz: [16_000], channels: 1, frameMultipleSamples: 160,
            incremental: true, emitsPartials: true, emitsFinals: true, transcriptGranularity: .utterances,
            requestedPlacement: .cpu, observedPlacement: .missing(.unavailable, source: "test", reason: "no probe"))
        #expect(try AdapterCapabilities.read(capabilities.toJSON(), "$") == capabilities)
        #expect(capabilities.incompatibilities(sampleRateHz: 16_000, channels: 1, frameSamples: 320).isEmpty)
        #expect(capabilities.incompatibilities(sampleRateHz: 48_000, channels: 1, frameSamples: 320).count == 1)
        #expect(capabilities.incompatibilities(sampleRateHz: 16_000, channels: 1, frameSamples: 100).count == 1)
        #expect(throws: ValidationError.self) {
            _ = try AdapterCapabilities(role: .diarization, revision: "1", sampleRatesHz: [16_000], channels: 1,
                                        frameMultipleSamples: nil, incremental: true, emitsPartials: false,
                                        emitsFinals: true, transcriptGranularity: .utterances, requestedPlacement: .cpu,
                                        observedPlacement: .missing(.unavailable, source: "t", reason: "r"))
        }
    }
}
