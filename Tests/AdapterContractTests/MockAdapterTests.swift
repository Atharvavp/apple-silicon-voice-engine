import AdapterContracts
import AudioCore
import BenchmarkSupport
import Foundation
import MockAdapters
import Testing

private func golden() throws -> JSONObject {
    guard case .object(let object) = try StrictJSON.parseFile(repoURL("testdata/goldens/mock-events.json")) else {
        fatalError("golden is not an object")
    }
    return object
}

private func goldenArray(_ key: String) throws -> [JSONValue] {
    guard case .array(let items)? = try golden()[key] else { fatalError("golden \(key) missing") }
    return items
}

struct MockASRTests {
    @Test func emitsTheHandDerivedGoldenSequence() async throws {
        let sink = CollectingSink(role: .asr, adapterID: MockAdapterIDs.asr, durationSamples: 192_000)
        let report = try await drive(MockASRAdapter(), StreamSpec(), script: try scriptReference("two-speaker-en"), sink: sink)
        #expect(report == .clean)
        let events = await sink.events
        #expect(events.map { view($0).keySorted } == (try goldenArray("asr")).map(\.keySorted))
        #expect(await sink.unfinalized.isEmpty, "every utterance ends with a final")
        Evidence.write("V20/mock-asr-events.json", .array(events.map(view)))
    }

    @Test func sameScriptAndSeedGiveIdenticalOutputsAcrossThreeRuns() async throws {
        var runs: [[JSONValue]] = []
        for _ in 0..<3 {
            let sink = CollectingSink(role: .asr, adapterID: MockAdapterIDs.asr, durationSamples: 192_000)
            _ = try await drive(MockASRAdapter(), StreamSpec(), script: try scriptReference("two-speaker-en"), sink: sink)
            runs.append(await sink.events.map(view))
        }
        #expect(runs[0] == runs[1] && runs[1] == runs[2])
    }

    @Test func zeroOrSeveralEventsPerConsume() async throws {
        // Two entries share one trigger: a single consume releases both, in script order.
        let reference = try scriptVariant("two-speaker-en") { script in
            guard case .array(var asr)? = script["asr"], case .object(var second) = asr[1] else { return }
            second.set("trigger_sample", .int(64_000))
            asr[1] = .object(second)
            if case .object(var first) = asr[0] {
                first.set("trigger_sample", .int(64_000))
                asr[0] = .object(first)
            }
            script.set("asr", .array(asr))
        }
        let sink = CollectingSink(role: .asr, adapterID: MockAdapterIDs.asr, durationSamples: 192_000)
        _ = try await drive(MockASRAdapter(), StreamSpec(), script: reference, sink: sink)
        let causes = await sink.events.map(\.cause.chunkIndex)
        #expect(causes == [199, 199, 299, nil], "chunks 0-198 emit nothing, chunk 199 emits two events")
    }

    @Test func droppedAudioSuppressesDependentOutputsWithADiagnostic() async throws {
        let sink = CollectingSink(role: .asr, adapterID: MockAdapterIDs.asr, durationSamples: 192_000)
        // Chunk 250 = [80000, 80320) lies inside u1's ranges, so both u1 events are suppressed.
        _ = try await drive(MockASRAdapter(), StreamSpec(), script: try scriptReference("two-speaker-en"), sink: sink,
                            skip: [250])
        let views = await sink.events.map(view)
        #expect(views.count == 4)
        let types = await sink.events.map(\.eventType)
        #expect(types == [.transcriptPartial, .transcriptFinal, .adapterDiagnostic, .adapterDiagnostic])
        let missing = JSONValue.array([.object(JSONObject([("start_sample", .int(80_000)), ("end_sample", .int(80_320))]))])
        for diagnostic in await sink.events.suffix(2) {
            guard case let .diagnostic(code, _, required, gaps) = diagnostic.output else { continue }
            #expect(code == "missing_audio")
            #expect(required.map { $0.start == 64_000 } == true)
            #expect(JSONValue.array(gaps.map { $0.toJSON() }) == missing)
        }
        Evidence.write("V11/mock-suppression.json", .array(views))
    }

    @Test func stepDelayAdvancesVirtualTimeAndNeverSleeps() async throws {
        let clock = FakeRunClock()
        let delays = VirtualDelays()
        var spec = StreamSpec()
        spec.delayMS = 7
        let sink = CollectingSink(role: .asr, adapterID: MockAdapterIDs.asr, durationSamples: 192_000)
        _ = try await drive(MockASRAdapter(), spec, script: try scriptReference("two-speaker-en"), sink: sink,
                            delays: delays)
        #expect(await delays.calls == 601, "one delay per consume (600) plus one at flush")
        #expect(await delays.totalNS == 601 * 7_000_000)
        #expect(clock.recordedSleeps.isEmpty)
        #expect(clock.nowNS() == 0, "virtual delay never moves the real clock")
    }

    @Test func realModeDelaySleepsOnTheRunClock() async throws {
        let clock = FakeRunClock()
        var spec = StreamSpec()
        spec.mode = .realtime
        spec.delayMS = 3
        spec.duration = 3_200
        let reference = try scriptVariant("two-speaker-en") { script in
            script.set("duration_samples", .int(3_200))
            script.set("asr", .array([]))
            script.set("diarization", .array([]))
        }
        let sink = CollectingSink(role: .asr, adapterID: MockAdapterIDs.asr, durationSamples: 3_200)
        _ = try await drive(MockASRAdapter(), spec, script: reference, sink: sink, delays: ClockDelays(clock: clock))
        #expect(clock.recordedSleeps.count == 11, "10 consumes + 1 flush, each sleeping its configured delay")
        #expect(clock.nowNS() == 11 * 3_000_000)
    }

    @Test func wrongScriptHashOrSourceFailsInsteadOfGuessing() async throws {
        let good = try scriptReference("two-speaker-en")
        let tampered = FixtureScriptReference(url: good.url, sha256: String(repeating: "0", count: 64))
        let sink = CollectingSink(role: .asr, adapterID: MockAdapterIDs.asr, durationSamples: 192_000)
        await #expect(throws: AdapterError.self) {
            _ = try await drive(MockASRAdapter(), StreamSpec(), script: tampered, sink: sink)
        }
        var otherSource = StreamSpec()
        otherSource.sourceID = "two-speaker-hi"
        await #expect(throws: AdapterError.self) {
            _ = try await drive(MockASRAdapter(), otherSource, script: good, sink: sink)
        }
        await #expect(throws: AdapterError.self) {
            _ = try await drive(MockASRAdapter(), StreamSpec(), script: nil, sink: sink)
        }
        #expect(await sink.events.isEmpty)
    }

    @Test(arguments: [AdapterStage.prepare, .consume, .flush])
    func fixtureDeclaredFaultsSurfaceAsTypedErrors(_ stage: AdapterStage) async throws {
        let reference = try scriptVariant("two-speaker-en") { script in
            script.set("faults", .array([.object(JSONObject([
                ("role", .string("asr")), ("stage", .string(stage.rawValue)),
                ("chunk_index", stage == .consume ? .int(3) : .null),
            ]))]))
        }
        let sink = CollectingSink(role: .asr, adapterID: MockAdapterIDs.asr, durationSamples: 192_000)
        do {
            _ = try await drive(MockASRAdapter(), StreamSpec(), script: reference, sink: sink)
            Issue.record("expected an injected \(stage) fault")
        } catch let error as AdapterError {
            #expect(error.kind == .injectedFault)
            #expect(error.stage == stage)
            #expect(error.chunkIndex == (stage == .consume ? 3 : nil))
        }
    }

    @Test func shutdownFaultIsReportedNotThrown() async throws {
        let reference = try scriptVariant("two-speaker-en") { script in
            script.set("faults", .array([.object(JSONObject([
                ("role", .string("asr")), ("stage", .string("shutdown")), ("chunk_index", .null),
            ]))]))
        }
        let sink = CollectingSink(role: .asr, adapterID: MockAdapterIDs.asr, durationSamples: 192_000)
        let report = try await drive(MockASRAdapter(), StreamSpec(), script: reference, sink: sink)
        #expect(report.status == .error)
        #expect(report.message != nil)
    }
}

struct MockDiarizationTests {
    @Test func emitsTheHandDerivedGoldenSequenceIncludingOutOfOrderMedia() async throws {
        let sink = CollectingSink(role: .diarization, adapterID: MockAdapterIDs.diarization, durationSamples: 192_000)
        _ = try await drive(MockDiarizationAdapter(), StreamSpec(), script: try scriptReference("two-speaker-en"), sink: sink)
        let events = await sink.events
        #expect(events.map { view($0).keySorted } == (try goldenArray("diarization")).map(\.keySorted))
        // The flush event describes media that precedes the earlier event's media: valid out-of-order emission.
        #expect((events.last?.media?.start ?? 0) < (events.first?.media?.start ?? 0))
        Evidence.write("V20/mock-diarization-events.json", .array(events.map(view)))
    }

    @Test func overlappingSpeakersAreAccepted() async throws {
        let sink = CollectingSink(role: .diarization, adapterID: MockAdapterIDs.diarization, durationSamples: 192_000)
        let cause = EventCause.chunk(index: 1, invocationID: "diarization/consume/1")
        try await sink.emit(AdapterEvent(.speakerSegment(segmentID: "a", speakerID: "A"),
                                         media: try SampleInterval(start: 0, end: 64_000), cause: cause))
        try await sink.emit(AdapterEvent(.speakerSegment(segmentID: "b", speakerID: "B"),
                                         media: try SampleInterval(start: 32_000, end: 96_000), cause: cause))
        #expect(await sink.events.count == 2)
    }

    @Test func seededPerturbationIsDeterministicAndCausal() async throws {
        let reference = try scriptVariant("two-speaker-en") { script in
            script.set("perturbation", .object(JSONObject([("algorithm", .string("splitmix64_v1")),
                                                            ("speaker_boundary_jitter_samples", .int(160))])))
        }
        func ranges(seed: Int64) async throws -> [SampleInterval] {
            var spec = StreamSpec()
            spec.seed = seed
            let sink = CollectingSink(role: .diarization, adapterID: MockAdapterIDs.diarization, durationSamples: 192_000)
            _ = try await drive(MockDiarizationAdapter(), spec, script: reference, sink: sink)
            return await sink.events.compactMap(\.media)
        }
        let first = try await ranges(seed: 42)
        #expect(try await ranges(seed: 42) == first)
        #expect(try await ranges(seed: 43) != first, "a different seed perturbs differently")
        let original: [SampleInterval] = [try SampleInterval(start: 96_000, end: 128_000), try SampleInterval(start: 0, end: 96_000)]
        for (perturbed, base) in zip(first, original) {
            #expect(base.contains(perturbed), "segments only shrink, so triggers stay causal")
            #expect(perturbed.start - base.start <= 160 && base.end - perturbed.end <= 160)
        }
    }

    @Test func splitMix64MatchesItsPublishedReferenceSequence() {
        // SplitMix64 outputs for seed 1234567, computed independently with a Python port of the
        // published algorithm (golden ratio increment, 30/27/31 shifts and the two mix constants).
        var generator = SplitMix64(seed: 1_234_567)
        let expected: [UInt64] = [6_457_827_717_110_365_317, 3_203_168_211_198_807_973, 9_817_491_932_198_370_423,
                                  4_593_380_528_125_082_431, 16_408_922_859_458_223_821]
        #expect((0..<5).map { _ in generator.next() } == expected)
    }

    @Test func hindiItemScriptMatchesItsConvertedStream() async throws {
        var spec = StreamSpec()
        spec.item = "two-speaker-hi"
        spec.sourceID = "two-speaker-hi"
        spec.duration = 128_000
        let sink = CollectingSink(role: .diarization, adapterID: MockAdapterIDs.diarization, durationSamples: 128_000)
        _ = try await drive(MockDiarizationAdapter(), spec, script: try scriptReference("two-speaker-hi"), sink: sink)
        #expect(await sink.events.map(\.cause.chunkIndex) == [199, 399])
    }
}
