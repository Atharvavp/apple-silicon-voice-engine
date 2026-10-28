import AdapterContracts
import AudioCore
import BenchmarkSupport
import Foundation
import RealAdapterSupport
import Testing

// MARK: - Passive roles

struct PassiveAdapterTests {
    @Test func passiveRolesEmitNothingAndLoadNothing() async throws {
        for role in AdapterRole.allCases {
            let adapter: any StreamingAdapter = role == .asr ? PassiveASRAdapter() : PassiveDiarizationAdapter()
            let sink = CollectingSink(role: role, adapterID: adapter.adapterID, durationSamples: 640,
                                      granularity: role == .asr ? .recording : nil)
            let caps = try await adapter.prepare(context: context(role: role, adapterID: adapter.adapterID,
                                                                  revision: PassiveAdapterIDs.revision, durationSamples: 640),
                                                 sink: sink)
            #expect(!caps.emitsPartials && !caps.emitsFinals)
            #expect(caps.observedPlacement.status != .ok)
            try await adapter.consume(try chunk(0, start: 0, count: 320), context: consumeContext(0))
            try await adapter.consume(try chunk(1, start: 320, count: 320), context: consumeContext(1))
            try await adapter.flush(endOfStream: streamEnd(640))
            #expect(await sink.events.isEmpty)
            let first = await adapter.shutdown()
            let second = await adapter.shutdown()
            #expect(first == .clean && second == .clean && first.pendingTasks == 0)
        }
    }

    @Test func passiveLifecycleRejectsOutOfOrderCalls() async throws {
        let adapter = PassiveDiarizationAdapter()
        await #expect(throws: AdapterError.self) {
            try await adapter.consume(try chunk(0, start: 0, count: 320), context: consumeContext(0))
        }
        let sink = CollectingSink(role: .diarization, adapterID: adapter.adapterID, durationSamples: 320, granularity: nil)
        _ = try await adapter.prepare(context: context(role: .diarization, adapterID: adapter.adapterID,
                                                       revision: PassiveAdapterIDs.revision, durationSamples: 320), sink: sink)
        await #expect(throws: AdapterError.self) {
            _ = try await adapter.prepare(context: context(role: .diarization, adapterID: adapter.adapterID,
                                                           revision: PassiveAdapterIDs.revision, durationSamples: 320), sink: sink)
        }
    }
}

// MARK: - Profile and asset verification

struct ProfileTests {
    func diarizer(_ fixture: ProfileFixture?, id: String = "fake-diar", box: BackendBox<FakeDiarizationBackend>? = nil,
                  timeline: [NativeSpeakerSegment] = [], failLoad: Bool = false) -> FinalTimelineDiarizationAdapter {
        FinalTimelineDiarizationAdapter(adapterID: id, frameworkRevision: fakeFrameworkRevision, roots: fixture?.roots) { _, _ in
            let backend = FakeDiarizationBackend(timeline: timeline, failLoad: failLoad)
            box?.backend = backend
            return backend
        }
    }

    func prepare(_ adapter: FinalTimelineDiarizationAdapter, revision: String, delayMS: Int64 = 0,
                 fixture: FixtureScriptReference? = nil, rate: Int64 = 16_000) async throws {
        let sink = CollectingSink(role: .diarization, adapterID: adapter.adapterID, durationSamples: 640, granularity: nil)
        _ = try await adapter.prepare(context: context(role: .diarization, adapterID: adapter.adapterID, revision: revision,
                                                       durationSamples: 640, sampleRate: rate, delayMS: delayMS,
                                                       fixture: fixture), sink: sink)
    }

    @Test func verifiedProfileLoadsAndReportsItsRevision() async throws {
        let fixture = try ProfileFixture.make(adapterID: "fake-diar", role: .diarization)
        let box = BackendBox<FakeDiarizationBackend>()
        let adapter = diarizer(fixture, box: box)
        let sink = CollectingSink(role: .diarization, adapterID: "fake-diar", durationSamples: 640, granularity: nil)
        let caps = try await adapter.prepare(context: context(role: .diarization, adapterID: "fake-diar",
                                                              revision: fixture.revision, durationSamples: 640), sink: sink)
        #expect(caps.revision == fixture.revision)
        #expect(caps.sampleRatesHz == [16_000] && caps.incremental && !caps.emitsPartials && caps.emitsFinals)
        #expect(caps.requestedPlacement == .unspecified && caps.observedPlacement.status == .unavailable)
        #expect(await box.backend?.loaded == true)
    }

    @Test func revisionMustBeTheProfileDigest() async throws {
        let fixture = try ProfileFixture.make(adapterID: "fake-diar", role: .diarization)
        await #expect(throws: AdapterError.self) {
            try await prepare(diarizer(fixture), revision: "p1:" + String(repeating: "0", count: 64))
        }
        await #expect(throws: AdapterError.self) { try await prepare(diarizer(fixture), revision: "1") }
    }

    @Test func modifiedMissingOrUnlistedFilesFailBeforeLoading() async throws {
        let modified = try ProfileFixture.make(adapterID: "fake-diar", role: .diarization)
        try Data("tampered".utf8).write(to: modified.modelFile)
        let box = BackendBox<FakeDiarizationBackend>()
        await #expect(throws: AdapterError.self) { try await prepare(diarizer(modified, box: box), revision: modified.revision) }
        #expect(box.backend == nil, "no backend may be created for unverified assets")

        let missing = try ProfileFixture.make(adapterID: "fake-diar", role: .diarization)
        try FileManager.default.removeItem(at: missing.modelFile)
        await #expect(throws: AdapterError.self) { try await prepare(diarizer(missing), revision: missing.revision) }

        let unlisted = try ProfileFixture.make(adapterID: "fake-diar", role: .diarization)
        try Data("extra".utf8).write(to: unlisted.modelFile.deletingLastPathComponent().appendingPathComponent("extra.bin"))
        await #expect(throws: AdapterError.self) { try await prepare(diarizer(unlisted), revision: unlisted.revision) }
    }

    @Test func profileMustMatchAdapterRoleAndPinnedSource() async throws {
        let wrongSource = try ProfileFixture.make(adapterID: "fake-diar", role: .diarization,
                                                  frameworkRevision: String(repeating: "c", count: 40))
        await #expect(throws: AdapterError.self) { try await prepare(diarizer(wrongSource), revision: wrongSource.revision) }
        let wrongRole = try ProfileFixture.make(adapterID: "fake-diar", role: .asr, tolerance: nil)
        await #expect(throws: AdapterError.self) { try await prepare(diarizer(wrongRole), revision: wrongRole.revision) }
        let floating = try ProfileFixture.make(adapterID: "fake-diar", role: .diarization) { profile in
            var model = object(profile["model"]!)
            model.set("revision", .string("main"))
            profile.set("model", .object(model))
        }
        await #expect(throws: AdapterError.self) { try await prepare(diarizer(floating), revision: floating.revision) }
    }

    @Test func missingRootsDelayFixtureOrRateAreRejected() async throws {
        let fixture = try ProfileFixture.make(adapterID: "fake-diar", role: .diarization)
        await #expect(throws: AdapterError.self) { try await prepare(diarizer(nil), revision: fixture.revision) }
        await #expect(throws: AdapterError.self) { try await prepare(diarizer(fixture), revision: fixture.revision, delayMS: 5) }
        let script = FixtureScriptReference(url: fixture.modelFile, sha256: String(repeating: "0", count: 64))
        await #expect(throws: AdapterError.self) { try await prepare(diarizer(fixture), revision: fixture.revision, fixture: script) }
        await #expect(throws: AdapterError.self) { try await prepare(diarizer(fixture), revision: fixture.revision, rate: 8_000) }
    }

    @Test func rootsComeOnlyFromAbsoluteEnvironmentPaths() {
        #expect(Phase1Roots.fromEnvironment([:]) == nil)
        #expect(Phase1Roots.fromEnvironment([Phase1Roots.profilesVariable: "rel", Phase1Roots.assetsVariable: "/a"]) == nil)
        #expect(Phase1Roots.fromEnvironment([Phase1Roots.profilesVariable: "/p", Phase1Roots.assetsVariable: "/a"]) != nil)
    }

    @Test func failedLoadIsCleanedUpByShutdown() async throws {
        let fixture = try ProfileFixture.make(adapterID: "fake-diar", role: .diarization)
        let box = BackendBox<FakeDiarizationBackend>()
        let adapter = diarizer(fixture, box: box, failLoad: true)
        await #expect(throws: (any Error).self) { try await prepare(adapter, revision: fixture.revision) }
        let report = await adapter.shutdown()
        #expect(report == .clean)
        #expect(await box.backend?.released == 1)
        #expect(await adapter.shutdown() == .clean)
        #expect(await box.backend?.released == 1, "shutdown is idempotent")
    }
}

// MARK: - Final-only diarization timeline

struct FinalTimelineTests {
    static let duration: Int64 = 48_000  // 3 s

    func run(_ timeline: [NativeSpeakerSegment], tolerance: Int64 = 1_280, sinkDelayNS: UInt64 = 0,
             failAfter: Int? = nil, chunks: [(Int64, Int64)]? = nil, end: StreamEnd? = nil)
    async throws -> (events: [AdapterEvent], backend: FakeDiarizationBackend, eventsBeforeFlush: Int) {
        let fixture = try ProfileFixture.make(adapterID: "fake-diar", role: .diarization, tolerance: tolerance)
        let box = BackendBox<FakeDiarizationBackend>()
        let adapter = FinalTimelineDiarizationAdapter(adapterID: "fake-diar", frameworkRevision: fakeFrameworkRevision,
                                                      roots: fixture.roots) { _, _ in
            let backend = FakeDiarizationBackend(timeline: timeline)
            box.backend = backend
            return backend
        }
        let sink = CollectingSink(role: .diarization, adapterID: "fake-diar", durationSamples: Self.duration,
                                  granularity: nil, delayNS: sinkDelayNS, failAfter: failAfter)
        _ = try await adapter.prepare(context: context(role: .diarization, adapterID: "fake-diar", revision: fixture.revision,
                                                       durationSamples: Self.duration), sink: sink)
        let plan = chunks ?? stride(from: Int64(0), to: Self.duration, by: 320).map { ($0, 320) }
        for (index, item) in plan.enumerated() {
            try await adapter.consume(try chunk(Int64(index), start: item.0, count: item.1), context: consumeContext(Int64(index)))
        }
        let before = await sink.events.count
        do {
            try await adapter.flush(endOfStream: end ?? streamEnd(Self.duration))
        } catch {
            _ = await adapter.shutdown()
            throw error
        }
        let events = await sink.events
        #expect(await adapter.shutdown() == .clean)
        return (events, box.backend!, before)
    }

    @Test func emitsNothingDuringConsumeAndTheCompleteTimelineOnceAtFlush() async throws {
        // Overlapping different speakers, a same-speaker overlap, and a tail inside the tolerance.
        let timeline: [NativeSpeakerSegment] = [
            .init(slot: 0, start: .frame(0, samplesPerFrame: 1_280), end: .frame(10, samplesPerFrame: 1_280)),
            .init(slot: 1, start: .frame(8, samplesPerFrame: 1_280), end: .frame(20, samplesPerFrame: 1_280)),
            .init(slot: 0, start: .frame(9, samplesPerFrame: 1_280), end: .frame(12, samplesPerFrame: 1_280)),
            .init(slot: 2, start: .seconds(2.5), end: .seconds(3.05)),
        ]
        let result = try await run(timeline)
        #expect(result.eventsBeforeFlush == 0)
        #expect(await result.backend.finishCalls == 1)
        #expect(await result.backend.pushedSamples == Int(Self.duration))
        #expect(result.events.allSatisfy { if case .flush = $0.cause { return true } else { return false } })
        let segments = result.events.compactMap { event -> (String, SampleInterval)? in
            guard case let .speakerSegment(_, speaker) = event.output, let media = event.media else { return nil }
            return (speaker, media)
        }
        #expect(segments.count == 3)
        #expect(segments.contains { $0.0 == "spk0" && $0.1 == (try! SampleInterval(start: 0, end: 15_360)) })
        #expect(segments.contains { $0.0 == "spk1" && $0.1 == (try! SampleInterval(start: 10_240, end: 25_600)) })
        #expect(segments.contains { $0.0 == "spk2" && $0.1 == (try! SampleInterval(start: 40_000, end: Self.duration)) },
                "tail clipped to the stream end")
        let ids = result.events.compactMap { event -> String? in
            if case let .speakerSegment(id, _) = event.output { return id }
            return nil
        }
        #expect(Set(ids).count == ids.count)
    }

    @Test func tailBeyondTheDeclaredToleranceIsRejected() async throws {
        let timeline = [NativeSpeakerSegment(slot: 0, start: .seconds(2.0), end: .seconds(3.2))]
        await #expect(throws: AdapterError.self) { _ = try await run(timeline, tolerance: 1_280) }
    }

    @Test func invalidNativeRangeIsRejected() async throws {
        let timeline = [NativeSpeakerSegment(slot: 0, start: .seconds(1.0), end: .seconds(1.0))]
        await #expect(throws: AdapterError.self) { _ = try await run(timeline) }
    }

    @Test func emptyTimelineEmitsNothing() async throws {
        let result = try await run([])
        #expect(result.events.isEmpty)
    }

    @Test func gappedAudioIsRejected() async throws {
        await #expect(throws: AdapterError.self) {
            _ = try await run([], chunks: [(0, 320), (640, 320)])
        }
    }

    @Test func droppedAudioAtEndOfStreamIsRejected() async throws {
        let dropped = try SampleInterval(start: 47_680, end: 48_000)
        let plan = stride(from: Int64(0), to: 47_680, by: 320).map { ($0, Int64(320)) }
        await #expect(throws: AdapterError.self) {
            _ = try await run([], chunks: plan, end: streamEnd(Self.duration, dropped: [dropped]))
        }
    }

    @Test func cancelledStreamEmitsNothing() async throws {
        let timeline = [NativeSpeakerSegment(slot: 0, start: .seconds(0), end: .seconds(1))]
        let result = try await run(timeline, end: streamEnd(Self.duration, reason: .cancelled))
        #expect(result.events.isEmpty)
        #expect(await result.backend.finishCalls == 0)
    }

    @Test func flushAwaitsEverySinkAdmission() async throws {
        let timeline = (0..<4).map { NativeSpeakerSegment(slot: $0, start: .seconds(Double($0) * 0.5), end: .seconds(Double($0) * 0.5 + 0.4)) }
        let result = try await run(timeline, sinkDelayNS: 20_000_000)
        #expect(result.events.count == 4, "flush returned only after the slow sink admitted every event")
    }

    @Test func sinkFailurePropagates() async throws {
        let timeline = (0..<3).map { NativeSpeakerSegment(slot: $0, start: .seconds(Double($0)), end: .seconds(Double($0) + 0.5)) }
        await #expect(throws: CollectingSink.SinkFailure.self) { _ = try await run(timeline, failAfter: 1) }
    }
}

// MARK: - Projection and quantization

struct ProjectionTests {
    @Test func quantizationIsExactForFramesAndNearestForSeconds() {
        #expect(NativeTime.frame(3, samplesPerFrame: 1_280).sample(rate: 16_000) == 3_840)
        #expect(NativeTime.seconds(0.08).sample(rate: 16_000) == 1_280)
        // speech-swift reports Float seconds: Float(1199.92) is 1199.9200439..., i.e. sample
        // 19_198_720.7, so the nearest sample is one past the 80 ms frame boundary (disclosed).
        #expect(NativeTime.seconds(Double(Float(1199.92))).sample(rate: 16_000) == 19_198_721)
        #expect(NativeTime.seconds(0.00003).sample(rate: 16_000) == 0)
    }

    @Test func unionCheckDetectsADroppedSegment() throws {
        let native = [NativeSpeakerSegment(slot: 0, start: .seconds(0), end: .seconds(1)),
                      NativeSpeakerSegment(slot: 1, start: .seconds(0.5), end: .seconds(1.5))]
        let emitted = [ProjectedSpeakerSegment(segmentID: "seg-1", speakerID: "spk0",
                                               interval: try SampleInterval(start: 0, end: 16_000))]
        #expect(throws: TimelineProjectionError.self) {
            try FinalTimelineProjector.verifyUnion(native: native, emitted: emitted, rate: 16_000, durationSamples: 32_000)
        }
    }

    @Test func differentSpeakerOverlapIsPreservedAndSegmentsAreTimeOrdered() throws {
        let native = [NativeSpeakerSegment(slot: 1, start: .seconds(0.5), end: .seconds(1.5)),
                      NativeSpeakerSegment(slot: 0, start: .seconds(0), end: .seconds(1))]
        let projection = try FinalTimelineProjector.project(native, rate: 16_000, durationSamples: 32_000, tailToleranceSamples: 0)
        #expect(projection.segments.map(\.speakerID) == ["spk0", "spk1"])
        #expect(projection.segments[0].interval.overlaps(projection.segments[1].interval))
        #expect(projection.mergedSameSpeakerOverlaps == 0)
    }
}

// MARK: - Recording transcript

struct TranscriptTests {
    func run(mode: RecordingTranscriptAccumulator.Mode, perPush: [[ASRNativeUpdate]], finish: [ASRNativeUpdate],
             failAfter: Int? = nil) async throws -> [AdapterEvent] {
        let fixture = try ProfileFixture.make(adapterID: "fake-asr", role: .asr, tolerance: nil)
        let adapter = RecordingTranscriptASRAdapter(adapterID: "fake-asr", frameworkRevision: fakeFrameworkRevision,
                                                    roots: fixture.roots) { _, _ in
            FakeASRBackend(mode: mode, perPush: perPush, finish: finish)
        }
        let duration = Int64(perPush.count) * 320
        let sink = CollectingSink(role: .asr, adapterID: "fake-asr", durationSamples: duration, granularity: .recording,
                                  failAfter: failAfter)
        let caps = try await adapter.prepare(context: context(role: .asr, adapterID: "fake-asr", revision: fixture.revision,
                                                              durationSamples: duration), sink: sink)
        #expect(caps.transcriptGranularity == .recording && caps.emitsPartials && caps.emitsFinals)
        for index in 0..<perPush.count {
            try await adapter.consume(try chunk(Int64(index), start: Int64(index) * 320, count: 320),
                                      context: consumeContext(Int64(index)))
        }
        try await adapter.flush(endOfStream: streamEnd(duration))
        #expect(await adapter.shutdown() == .clean)
        return await sink.events
    }

    func transcripts(_ events: [AdapterEvent]) -> [(Int64, String, Bool)] {
        events.compactMap { event in
            guard case let .transcript(utterance, revision, text, isFinal) = event.output else { return nil }
            #expect(utterance == RecordingTranscriptASRAdapter.utteranceID && event.media == nil)
            return (revision, text, isFinal)
        }
    }

    @Test func cumulativePartialsThenExactlyOneUntimedFinal() async throws {
        let events = try await run(mode: .cumulative,
                                   perPush: [[], [.cumulative(" hello")], [.cumulative(" hello")], [.cumulative(" hello world")]],
                                   finish: [.cumulative(" hello world again")])
        let items = transcripts(events)
        #expect(items.map(\.1) == ["hello", "hello world", "hello world again", "hello world again"])
        #expect(items.map(\.0) == [1, 2, 3, 4])
        #expect(items.filter(\.2).count == 1 && items.last?.2 == true)
        if case .flush = events.last!.cause {} else { Issue.record("final must come from flush") }
    }

    @Test func segmentedRepeatsArePreservedAndPartialsReplaced() async throws {
        let events = try await run(mode: .segmented, perPush: [
            [.segment(index: 0, text: "yes", isFinal: false)],
            [.segment(index: 0, text: "yes yes", isFinal: false)],
            [.segment(index: 0, text: "yes yes", isFinal: true)],
            [.segment(index: 1, text: "yes", isFinal: false)],
            [.segment(index: 1, text: "yes yes", isFinal: true)],
        ], finish: [.segment(index: 2, text: "okay", isFinal: true)])
        let items = transcripts(events)
        #expect(items.last?.1 == "yes yes yes yes okay", "repeated utterances are not deduplicated")
        #expect(items.filter(\.2).count == 1)
    }

    @Test func segmentedFinalExcludesSupersededPartial() async throws {
        let events = try await run(mode: .segmented, perPush: [
            [.segment(index: 0, text: "draft", isFinal: false)],
            [.segment(index: 1, text: "next", isFinal: false)],
        ], finish: [.segment(index: 1, text: "next one", isFinal: true)])
        #expect(transcripts(events).last?.1 == "next one")
    }

    @Test func noTextStillEndsWithOneEmptyFinal() async throws {
        let items = transcripts(try await run(mode: .segmented, perPush: [[], []], finish: []))
        #expect(items.count == 1 && items[0].1 == "" && items[0].2)
    }

    @Test func accumulatorRejectsInconsistentUpdates() throws {
        var segmented = RecordingTranscriptAccumulator(mode: .segmented)
        _ = try segmented.apply(.segment(index: 2, text: "a", isFinal: false))
        #expect(throws: ValidationError.self) { _ = try segmented.apply(.segment(index: 1, text: "b", isFinal: false)) }
        _ = try segmented.apply(.segment(index: 2, text: "a", isFinal: true))
        #expect(throws: ValidationError.self) { _ = try segmented.apply(.segment(index: 2, text: "c", isFinal: false)) }
        var cumulative = RecordingTranscriptAccumulator(mode: .cumulative)
        #expect(throws: ValidationError.self) { _ = try cumulative.apply(.segment(index: 0, text: "x", isFinal: true)) }
    }

    @Test func sinkFailureFailsConsume() async throws {
        await #expect(throws: CollectingSink.SinkFailure.self) {
            _ = try await run(mode: .cumulative, perPush: [[.cumulative("a")], [.cumulative("a b")]], finish: [], failAfter: 1)
        }
    }
}

// MARK: - Callback mailbox

struct MailboxTests {
    @Test func boundedMailboxReportsOverflowAndLatePosts() {
        let mailbox = CallbackMailbox<String>(capacity: 2)
        #expect(mailbox.post("a") && mailbox.post("b"))
        #expect(!mailbox.post("c"))
        let drained = mailbox.drain()
        #expect(drained.items == ["a", "b"] && drained.overflowed)
        mailbox.close()
        #expect(!mailbox.post("late"))
        #expect(mailbox.pendingCount == 0)
    }

    @Test func concurrentPostsAreNeitherLostNorDuplicated() async {
        let mailbox = CallbackMailbox<Int>(capacity: 10_000)
        await withTaskGroup(of: Void.self) { group in
            for worker in 0..<8 {
                group.addTask { for i in 0..<1_000 { mailbox.post(worker * 1_000 + i) } }
            }
        }
        let drained = mailbox.drain()
        #expect(!drained.overflowed && Set(drained.items).count == 8_000)
    }
}
