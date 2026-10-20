import AdapterContracts
import AudioCore
import BenchmarkSupport
import Foundation
import MockAdapters
import Testing

struct LifecycleTests {
    private func adapters() -> [any StreamingAdapter] { [MockASRAdapter(), MockDiarizationAdapter()] }

    private func sink(_ adapter: any StreamingAdapter) -> CollectingSink {
        CollectingSink(role: adapter.role, adapterID: adapter.adapterID, durationSamples: 192_000)
    }

    @Test func consumeBeforePrepareIsRejected() async throws {
        for adapter in adapters() {
            do {
                try await adapter.consume(try chunk(0, 0, 320, spec: StreamSpec()), context: consumeContext(adapter.role, 0))
                Issue.record("\(adapter.adapterID) accepted consume before prepare")
            } catch let error as AdapterError {
                #expect(error.kind == .lifecycle && error.stage == .consume)
            }
        }
    }

    @Test func consumeAndFlushAfterFlushAreRejected() async throws {
        for adapter in adapters() {
            let spec = StreamSpec()
            _ = try await adapter.prepare(context: context(adapter.role, spec, script: try scriptReference("two-speaker-en"),
                                                           delays: VirtualDelays()),
                                          sink: sink(adapter))
            let end = StreamEnd(invocationID: "\(adapter.role.rawValue)/flush", finalSample: 192_000, consumedSamples: 0,
                                droppedRanges: [], reason: .normal)
            try await adapter.flush(endOfStream: end)
            await #expect(throws: AdapterError.self) {
                try await adapter.consume(try chunk(0, 0, 320, spec: spec), context: consumeContext(adapter.role, 0))
            }
            await #expect(throws: AdapterError.self) { try await adapter.flush(endOfStream: end) }
            #expect(await adapter.shutdown() == .clean)
        }
    }

    @Test func prepareTwiceIsRejected() async throws {
        for adapter in adapters() {
            let ctx = context(adapter.role, StreamSpec(), script: try scriptReference("two-speaker-en"), delays: VirtualDelays())
            _ = try await adapter.prepare(context: ctx, sink: sink(adapter))
            await #expect(throws: AdapterError.self) { _ = try await adapter.prepare(context: ctx, sink: sink(adapter)) }
        }
    }

    @Test func shutdownIsIdempotentAndSafeAfterAFailedPrepare() async throws {
        for adapter in adapters() {
            let ctx = context(adapter.role, StreamSpec(), script: nil, delays: VirtualDelays())
            await #expect(throws: AdapterError.self) { _ = try await adapter.prepare(context: ctx, sink: sink(adapter)) }
            let first = await adapter.shutdown()
            let second = await adapter.shutdown()
            #expect(first == second)
            #expect(first.pendingTasks == 0)
            await #expect(throws: AdapterError.self) {
                try await adapter.consume(try chunk(0, 0, 320, spec: StreamSpec()), context: consumeContext(adapter.role, 0))
            }
        }
    }

    @Test func flushReturnsOnlyAfterEveryFinalOutputWasEmitted() async throws {
        // Every script entry with a null trigger must be in the sink when flush returns.
        for adapter in adapters() {
            let collecting = sink(adapter)
            _ = try await drive(adapter, StreamSpec(), script: try scriptReference("two-speaker-en"), sink: collecting)
            let flushEvents = await collecting.events.filter { $0.cause.chunkIndex == nil }
            #expect(flushEvents.count == 1, "\(adapter.adapterID): one flush-released entry")
        }
    }

    @Test func sinkErrorsPropagateToTheCaller() async throws {
        struct FailingSink: AdapterEventSink {
            struct Boom: Error {}
            func emit(_ event: AdapterEvent) async throws { throw Boom() }
        }
        await #expect(throws: FailingSink.Boom.self) {
            _ = try await drive(MockASRAdapter(), StreamSpec(), script: try scriptReference("two-speaker-en"),
                                sink: FailingSink())
        }
    }

    @Test func emptyStreamEmitsOnlyFlushOutputs() async throws {
        var spec = StreamSpec()
        spec.duration = 0
        let reference = try scriptVariant("two-speaker-en") { script in
            script.set("duration_samples", .int(0))
            script.set("asr", .array([]))
            script.set("diarization", .array([]))
        }
        let collecting = CollectingSink(role: .asr, adapterID: MockAdapterIDs.asr, durationSamples: 0)
        #expect(try await drive(MockASRAdapter(), spec, script: reference, sink: collecting) == .clean)
        #expect(await collecting.events.isEmpty)
    }

    @Test func chunksHandedToAnAdapterCannotBeMutatedThroughIt() throws {
        let original = try chunk(0, 0, 4, spec: StreamSpec(), fill: 0.5)
        var copy = original.samples.values
        copy[0] = 9
        #expect(original.samples[0] == 0.5, "values returns a copy; the chunk's storage is private and immutable")
    }
}
