import AudioCore
import BenchmarkSupport
import Foundation

/// Observations for one chunk. Real stamps share the run clock; virtual stamps are step-only.
public struct ChunkRecord: Sendable, Equatable {
    public enum Outcome: String, Sendable { case accepted, dropped }

    public let index: Int64
    public let startSample: Int64
    public let endSample: Int64
    /// Real/accelerated: anchor + media offset. Nil in step mode.
    public let plannedDeadlineNS: Int64?
    /// Step: media deadline in virtual time. Nil in real/accelerated mode.
    public let virtualDeadlineNS: Int64?
    /// Scheduler wake / offer instant, captured before the queue operation.
    public let offerNS: Int64
    public let outcome: Outcome
    public let entryNS: Int64?
    public let blocked: Bool
    public let depthAfterEntry: Int?
    public var dequeueNS: Int64?
    public var finishNS: Int64?
    public let deliveredVirtualNS: Int64?

    public var sampleCount: Int64 { endSample - startSample }
    /// `offer - planned`: scheduler wake error, before admission (signed ns).
    public var wakeErrorNS: Int64? { plannedDeadlineNS.map { offerNS - $0 } }
    /// `entry - planned`: delivery jitter including backpressure (signed ns).
    public var deliveryErrorNS: Int64? {
        guard let planned = plannedDeadlineNS, let entryNS else { return nil }
        return entryNS - planned
    }
}

public struct SampleRange: Sendable, Equatable, JSONRepresentable {
    public let start: Int64
    public let end: Int64

    public func toJSON() -> JSONValue {
        .object(JSONObject([("start_sample", .int(start)), ("end_sample", .int(end))]))
    }
}

public struct CoverageError: Error, CustomStringConvertible {
    public let message: String
    public init(message: String) { self.message = message }
    public var description: String { "coverage violation: \(message)" }
}

/// Complete replay trace with exact sample accounting (plan D2 item 7, V04/V11).
public struct ReplayTrace: Sendable {
    public let mode: ReplayMode
    public let sampleRateHz: Int64
    public let frameSamples: Int64
    public let speed: ReplaySpeed?
    public let totalFrames: Int64
    public let overflow: OverflowPolicy
    public let queueCapacity: Int
    public let anchorNS: Int64
    public let elapsedNS: Int64
    public let records: [ChunkRecord]
    /// Chunk indices in the order the consumer finished them.
    public let consumptionOrder: [Int64]
    public let maxQueueDepth: Int

    public var producedSamples: Int64 { records.reduce(0) { $0 + $1.sampleCount } }
    public var admittedSamples: Int64 { records.filter { $0.outcome == .accepted }.reduce(0) { $0 + $1.sampleCount } }
    public var consumedSamples: Int64 { records.filter { $0.finishNS != nil }.reduce(0) { $0 + $1.sampleCount } }
    public var droppedSamples: Int64 { records.filter { $0.outcome == .dropped }.reduce(0) { $0 + $1.sampleCount } }

    /// Union of dropped ranges, merged where adjacent.
    public var droppedRanges: [SampleRange] {
        var merged: [SampleRange] = []
        for record in records where record.outcome == .dropped {
            if let last = merged.last, last.end == record.startSample {
                merged[merged.count - 1] = SampleRange(start: last.start, end: record.endSample)
            } else {
                merged.append(SampleRange(start: record.startSample, end: record.endSample))
            }
        }
        return merged
    }

    /// Verifies the tiling and accounting invariants; `lossless` additionally forbids drops.
    public func verifyCoverage(lossless: Bool) throws {
        var expectedStart: Int64 = 0
        for (offset, record) in records.enumerated() {
            guard record.index == Int64(offset) else { throw CoverageError(message: "chunk index \(record.index) at position \(offset)") }
            guard record.startSample == expectedStart else {
                throw CoverageError(message: "chunk \(record.index) starts at \(record.startSample); expected \(expectedStart)")
            }
            guard record.endSample > record.startSample else { throw CoverageError(message: "chunk \(record.index) is empty") }
            guard record.sampleCount <= frameSamples else { throw CoverageError(message: "chunk \(record.index) exceeds frame size") }
            if record.endSample != totalFrames, record.sampleCount != frameSamples {
                throw CoverageError(message: "non-final chunk \(record.index) is partial")
            }
            switch record.outcome {
            case .accepted:
                guard record.entryNS != nil, record.dequeueNS != nil, record.finishNS != nil else {
                    throw CoverageError(message: "accepted chunk \(record.index) was not consumed")
                }
            case .dropped:
                guard record.entryNS == nil, record.dequeueNS == nil, record.finishNS == nil else {
                    throw CoverageError(message: "dropped chunk \(record.index) reached the consumer")
                }
            }
            expectedStart = record.endSample
        }
        guard expectedStart == totalFrames else {
            throw CoverageError(message: "chunks cover [0, \(expectedStart)); source has \(totalFrames) frames")
        }
        guard consumptionOrder == records.filter({ $0.outcome == .accepted }).map(\.index) else {
            throw CoverageError(message: "consumer order differs from FIFO admission order")
        }
        guard producedSamples == totalFrames, admittedSamples + droppedSamples == totalFrames,
              consumedSamples == admittedSamples else {
            throw CoverageError(message: "accounting mismatch produced=\(producedSamples) admitted=\(admittedSamples) consumed=\(consumedSamples) dropped=\(droppedSamples)")
        }
        if lossless, droppedSamples != 0 {
            throw CoverageError(message: "\(droppedSamples) samples dropped in a run that must be lossless")
        }
        guard maxQueueDepth <= queueCapacity else {
            throw CoverageError(message: "queue depth \(maxQueueDepth) exceeded capacity \(queueCapacity)")
        }
    }

    /// One JSON object per chunk using the D5 `audio.*` payload field names (evidence only;
    /// the versioned event envelopes are written by the M4 recorder).
    public func evidenceLines() throws -> [String] {
        try records.map { record in
            let value = JSONValue.object(JSONObject([
                ("chunk_index", .int(record.index)), ("start_sample", .int(record.startSample)),
                ("end_sample", .int(record.endSample)), ("deadline_convention", .string(SampleClock.deadlineConvention)),
                ("planned_deadline_ns", record.plannedDeadlineNS.json),
                ("media_deadline_virtual_ns", record.virtualDeadlineNS.json), ("offer_ns", .int(record.offerNS)),
                ("outcome", .string(record.outcome.rawValue)), ("entry_ns", record.entryNS.json),
                ("blocked", .bool(record.blocked)),
                ("queue_depth_after_entry", record.depthAfterEntry.map { .int(Int64($0)) } ?? .null),
                ("dequeue_ns", record.dequeueNS.json), ("finish_ns", record.finishNS.json),
                ("delivered_virtual_ns", record.deliveredVirtualNS.json), ("wake_error_ns", record.wakeErrorNS.json),
                ("deadline_error_ns", record.deliveryErrorNS.json),
            ]))
            return String(decoding: try JSONWriter.compact(value), as: UTF8.self)
        }
    }

    public func summaryJSON() -> JSONValue {
        .object(JSONObject([
            ("mode", .string(mode.rawValue)), ("sample_rate_hz", .int(sampleRateHz)),
            ("frame_samples", .int(frameSamples)), ("speed", speed.toJSON()), ("total_frames", .int(totalFrames)),
            ("overflow", .string(overflow.rawValue)), ("queue_capacity", .int(Int64(queueCapacity))),
            ("chunks", .int(Int64(records.count))), ("produced_samples", .int(producedSamples)),
            ("admitted_samples", .int(admittedSamples)), ("consumed_samples", .int(consumedSamples)),
            ("dropped_samples", .int(droppedSamples)), ("dropped_ranges", .array(droppedRanges.map { $0.toJSON() })),
            ("max_queue_depth", .int(Int64(maxQueueDepth))), ("elapsed_ns", .int(elapsedNS)),
        ]))
    }
}
