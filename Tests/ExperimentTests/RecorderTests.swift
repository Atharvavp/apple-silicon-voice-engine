import BenchmarkSupport
@testable import Experiment
import Foundation
import Testing

private func directory() throws -> RunDirectory {
    RunDirectory(url: try makeScratch(), runID: "rec")
}

private func line(_ text: String) -> PendingLine {
    PendingLine { sequence, recorded in Data("{\"s\":\(sequence),\"r\":\(recorded),\"v\":\"\(text)\"}".utf8) }
}

struct RecorderTests {
    @Test func concurrentProducersGetContiguousAdmissionOrderedSequences() async throws {
        let dir = try directory()
        let stream = try JSONLStream(url: dir.path("t.jsonl"), capacity: 4, maxRecordBytes: 1 << 20, maxBytes: 1 << 30,
                                     clock: ContinuousRunClock())
        await stream.start()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for producer in 0..<6 {
                group.addTask {
                    for n in 0..<200 { try await stream.admit(line("p\(producer)-\(n)")) }
                }
            }
            try await group.waitForAll()
        }
        let next = try await stream.drainAndSync()
        #expect(next == 1_200)
        let records = try Data(contentsOf: dir.path("t.jsonl")).split(separator: 0x0A).map { object(try StrictJSON.parse(Data($0))) }
        #expect(records.map { $0["s"] } == (0..<1_200).map { JSONValue.int(Int64($0)) })
        // Recorded stamps are admission stamps: nondecreasing in sequence order.
        let stamps = records.compactMap { record -> Int64? in if case .int(let v)? = record["r"] { return v } else { return nil } }
        #expect(zip(stamps, stamps.dropFirst()).allSatisfy { $0 <= $1 })
        // Per producer, append order equals emission order.
        for producer in 0..<6 {
            let mine = records.compactMap { record -> String? in
                if case .string(let v)? = record["v"], v.hasPrefix("p\(producer)-") { return v } else { return nil }
            }
            #expect(mine == (0..<200).map { "p\(producer)-\($0)" })
        }
        #expect(await stream.maxDepth <= 4, "bounded: never more than capacity waiting")
        let stats = try await stream.writer.snapshot()
        #expect(stats.lines == 1_200 && stats.batches >= 1)
        #expect(stats.sha256 == SHA256Hex.digest(try Data(contentsOf: dir.path("t.jsonl"))))
    }

    @Test func oversizedRecordFailsTheStreamForLaterProducers() async throws {
        let dir = try directory()
        let stream = try JSONLStream(url: dir.path("t.jsonl"), capacity: 2, maxRecordBytes: 64, maxBytes: 1 << 30,
                                     clock: ContinuousRunClock())
        await stream.start()
        try await stream.admit(PendingLine { _, _ in Data(repeating: 0x61, count: 65) })
        await #expect(throws: RecorderError.self) { _ = try await stream.drainAndSync() }
        await #expect(throws: RecorderError.self) { try await stream.admit(line("after")) }
    }

    @Test func writeFailureWakesBlockedProducers() async throws {
        let dir = try directory()
        // A 10-byte ceiling makes the first batch write fail while hundreds of producers are blocked.
        let stream = try JSONLStream(url: dir.path("t.jsonl"), capacity: 2, maxRecordBytes: 1 << 20, maxBytes: 10,
                                     clock: ContinuousRunClock())
        await stream.start()
        let failures = await withTaskGroup(of: Bool.self) { group -> Int in
            for n in 0..<600 { group.addTask { (try? await stream.admit(line("x\(n)"))) == nil } }
            var count = 0
            for await failed in group where failed { count += 1 }
            return count
        }
        #expect(failures > 0, "blocked producers are woken with an error instead of hanging")
        await #expect(throws: RecorderError.self) { _ = try await stream.drainAndSync() }
    }

    @Test func outputCeilingIsEnforced() async throws {
        let dir = try directory()
        let writer = try SerialFileWriter(url: dir.path("w.jsonl"), maxBytes: 10, clock: ContinuousRunClock())
        try await writer.append(Data("12345\n".utf8), lines: 1)
        await #expect(throws: RecorderError.self) { try await writer.append(Data("12345\n".utf8), lines: 1) }
        #expect(try await writer.snapshot().bytes == 6)
    }

    @Test func frozenRecorderAcceptsExactlyOneTerminalEventAndKeepsThePrefix() async throws {
        let dir = try directory()
        let recorder = try EventRecorder(directory: dir, clock: ContinuousRunClock(), maxBytes: 1 << 30)
        await recorder.start()
        let identity = RunIdentity(runID: "rec", sourceID: "s", sampleRateHz: 16_000)
        let channel = ProducerChannel(producerID: "runner", identity: identity, stream: recorder.stream)
        for n in 0..<3 {
            try await channel.emit(.telemetrySample, payload: JSONObject([("sample_id", .string("t\(n)")), ("phase", .string("x"))]),
                                   emittedNS: 1)
        }
        let prefix = try await recorder.freezeRuntimePrefix()
        #expect(prefix.lineCount == 3)
        await #expect(throws: RecorderError.self) {
            try await channel.emit(.telemetrySample, payload: JSONObject([("sample_id", .string("late")), ("phase", .string("x"))]),
                                   emittedNS: 1)
        }
        let terminal: @Sendable (Int64, Int64) throws -> EventEnvelope = { sequence, now in
            EventEnvelope(eventID: "s/runner/experiment.completed/0", runID: "rec", streamID: "audio-0", sourceID: "s",
                          sequence: sequence, producerID: "runner", producerSequence: sequence, type: .experimentCompleted,
                          mediaStartSample: nil, mediaEndSample: nil, sampleRateHz: 16_000, monotonicEmittedNS: now,
                          monotonicRecordedNS: now, virtualEmittedNS: nil, causeChunkIndex: nil, invocationID: nil,
                          payload: JSONObject([("artifacts", .array([]))]))
        }
        let appended = try await recorder.appendTerminal(terminal)
        #expect(appended.sequence == 3)
        await #expect(throws: RecorderError.self) { _ = try await recorder.appendTerminal(terminal) }
        let digest = try await recorder.finalize(success: true)
        #expect(digest.path == "events.jsonl")
        let bytes = try Data(contentsOf: dir.path("events.jsonl"))
        #expect(SHA256Hex.digest(bytes.prefix(Int(prefix.byteCount))) == prefix.sha256, "appending never changes the prefix")
        #expect(try readEvents(dir.path("events.jsonl")).map(\.sequence) == [0, 1, 2, 3])
    }

    @Test func invalidEventsFailAtTheirProducerBeforeAdmission() async throws {
        let dir = try directory()
        let recorder = try EventRecorder(directory: dir, clock: ContinuousRunClock(), maxBytes: 1 << 30)
        await recorder.start()
        let channel = ProducerChannel(producerID: "runner", identity: RunIdentity(runID: "rec", sourceID: "s", sampleRateHz: 16_000),
                                      stream: recorder.stream)
        await #expect(throws: RecorderError.self) {
            try await channel.emit(.stageCompleted, payload: JSONObject([
                ("stage", .string("x")), ("start_ns", .int(5)), ("end_ns", .int(3)), ("duration_ns", .int(2)),
                ("virtual_duration_ns", .null),
            ]), emittedNS: 1)
        }
        #expect(try await recorder.freezeRuntimePrefix().lineCount == 0)
    }

    @Test func artifactsAreNeverOverwrittenButStatusIsReplacedAtomically() throws {
        let dir = try directory()
        try dir.writeJSON("a.json", .object(JSONObject([("v", .int(1))])))
        #expect(throws: RecorderError.self) { try dir.writeJSON("a.json", .object(JSONObject([("v", .int(2))]))) }
        #expect(try readJSON(dir.path("a.json"))["v"] == .int(1))
        for state in [RunState.created, .validated] {
            try dir.writeStatus(RunStatus(runID: "rec", state: state, updatedWallTime: WallClock.now(), failure: nil,
                                          lastEventSequence: nil, artifacts: nil))
        }
        #expect(try RunStatus.read(try StrictJSON.parseFile(dir.path("status.json"))).state == .validated)
        #expect(throws: ValidationError.self) {
            try dir.writeStatus(RunStatus(runID: "rec", state: .completed, updatedWallTime: WallClock.now(), failure: nil,
                                          lastEventSequence: nil, artifacts: nil))
        }
    }
}
