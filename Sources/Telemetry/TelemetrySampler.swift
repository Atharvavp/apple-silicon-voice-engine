import BenchmarkSupport
import Foundation

/// Paced runner-process telemetry written to the `telemetry.jsonl` sidecar
/// (plan C2/D6). Samples are taken at start, at absolute deadlines
/// `anchor + k * interval`, and at stop. A late wake never triggers catch-up
/// samples: missed ticks are counted and lateness recorded instead. Each
/// observation states status, source, unit and scope; the first interval's CPU
/// percentage is `not_computable`, and unsupported counters stay explicit.
public actor TelemetrySampler {
    public struct Summary: Sendable, Equatable {
        public let samples: Int64
        public let periodicSamples: Int64
        public let expectedPeriodicSamples: Int64
        public let missedIntervals: Int64
        public let maxLatenessNS: Int64
        public let totalCollectionNS: Int64
    }

    /// Emits one encoded JSONL line (bounded, blocking admission).
    public typealias Sink = @Sendable (Data) async throws -> Void

    private let runID: String
    private let intervalNS: Int64
    private let clock: any RunClock
    private let sink: Sink
    private var phase = "setup"
    private var previous: (measuredNS: Int64, cpuNS: Int64?)?
    private var count: Int64 = 0
    private var periodic: Int64 = 0
    private var missed: Int64 = 0
    private var maxLateness: Int64 = 0
    private var collection: Int64 = 0
    private var anchor: Int64 = 0
    private var loop: Task<Void, Error>?
    private var failure: Error?

    public init(runID: String, intervalMS: Int64, clock: any RunClock, sink: @escaping Sink) {
        self.runID = runID
        intervalNS = intervalMS * 1_000_000
        self.clock = clock
        self.sink = sink
    }

    public func setPhase(_ phase: String) { self.phase = phase }

    /// Takes the start sample and begins periodic sampling.
    public func start() async throws {
        anchor = clock.nowNS()
        try await sample(kind: "start", scheduledNS: anchor)
        loop = Task { [intervalNS, clock, anchor] in
            var k: Int64 = 1
            while !Task.isCancelled {
                let scheduled = anchor + k * intervalNS
                try await clock.sleep(untilNS: scheduled)
                try await self.periodicSample(scheduledNS: scheduled)
                let now = clock.nowNS()
                // Skip ticks whose deadline already passed; count them, never catch up.
                let next = max(k + 1, (now - anchor) / intervalNS + 1)
                self.addMissed(next - k - 1)
                k = next
            }
        }
    }

    private func addMissed(_ n: Int64) { missed += n }

    private func periodicSample(scheduledNS: Int64) async throws {
        try await sample(kind: "periodic", scheduledNS: scheduledNS)
        periodic += 1
    }

    /// Stops periodic sampling and takes the final sample.
    public func stop() async throws -> Summary {
        loop?.cancel()
        if let loop {
            do { try await loop.value } catch is CancellationError {} catch { failure = error }
        }
        loop = nil
        if let failure { throw failure }
        let end = clock.nowNS()
        try await sample(kind: "end", scheduledNS: nil)
        let expected = intervalNS > 0 ? max((end - anchor) / intervalNS, 0) : 0
        return Summary(samples: count, periodicSamples: periodic, expectedPeriodicSamples: expected,
                       missedIntervals: missed, maxLatenessNS: maxLateness, totalCollectionNS: collection)
    }

    private func sample(kind: String, scheduledNS: Int64?) async throws {
        let start = clock.nowNS()
        let reading = ProcessProbe.read()
        let measured = clock.nowNS()
        let duration = measured - start
        collection += duration
        if let scheduledNS, kind == "periodic" { maxLateness = max(maxLateness, start - scheduledNS) }

        let cpuPercent: JSONValue
        if let previous, let cpu = reading.cpuTotalNS, let before = previous.cpuNS, measured > previous.measuredNS {
            let value = 100.0 * Double(cpu - before) / Double(measured - previous.measuredNS)
            cpuPercent = observation(.ok, .double(value), "percent_one_core", TelemetrySources.cpu, nil)
        } else if reading.cpuTotalNS == nil {
            cpuPercent = observation(.unavailable, .null, "percent_one_core", TelemetrySources.cpu, reading.cpuError)
        } else {
            cpuPercent = observation(.notComputable, .null, "percent_one_core", TelemetrySources.cpu,
                                     "first_sample_has_no_interval")
        }
        func counter(_ value: Int64?, _ unit: String, _ source: String, _ reason: String?) -> JSONValue {
            value.map { observation(.ok, .int($0), unit, source, nil) }
                ?? observation(.unavailable, .null, unit, source, reason ?? "probe failed")
        }
        let unsupported = observation(.unsupported, .null, "percent", "none", TelemetrySources.unsupportedReason)
        let measurements = JSONObject([
            ("cpu_user_ns", counter(reading.cpuUserNS, "ns_cumulative", TelemetrySources.cpu, reading.cpuError)),
            ("cpu_system_ns", counter(reading.cpuSystemNS, "ns_cumulative", TelemetrySources.cpu, reading.cpuError)),
            ("cpu_percent", cpuPercent),
            ("rss_bytes", counter(reading.residentBytes, "bytes", TelemetrySources.memory, reading.memoryError)),
            ("physical_footprint_bytes", counter(reading.footprintBytes, "bytes", TelemetrySources.footprint,
                                                 reading.footprintReason)),
            ("thermal_state", observation(.ok, .string(reading.thermalState), "enum", TelemetrySources.thermal, nil,
                                          scope: "machine")),
            ("gpu_utilization", withScope(unsupported, "machine")),
            ("ane_utilization", withScope(unsupported, "machine")),
            ("power_watts", observation(.unsupported, .null, "watts", "none", TelemetrySources.unsupportedReason,
                                        scope: "machine")),
            ("sampler_missed_intervals", observation(.ok, .int(missed), "count", "telemetry_sampler", nil)),
        ])
        let record = JSONValue.object(JSONObject([
            ("schema_version", .string(SchemaVersion.current)), ("run_id", .string(runID)),
            ("sample_id", .string(String(format: "t%05lld", count))), ("phase", .string(kind == "periodic" ? phase : kind)),
            ("measured_ns", .int(measured)), ("scheduled_ns", scheduledNS.json),
            ("interval_ns", previous.map { .int(measured - $0.measuredNS) } ?? .null),
            ("collection_duration_ns", .int(duration)), ("measurements", .object(measurements)),
        ]))
        try await sink(try JSONWriter.compact(record))
        // Counted only once admitted, so the summary matches the lines on disk.
        count += 1
        previous = (measured, reading.cpuTotalNS)
    }

    private func observation(_ status: MetricStatus, _ value: JSONValue, _ unit: String, _ source: String,
                             _ reason: String?, scope: String = "runner_process") -> JSONValue {
        .object(JSONObject([("status", .string(status.rawValue)), ("value", value), ("unit", .string(unit)),
                            ("source", .string(source)), ("scope", .string(scope)), ("reason", reason.json)]))
    }

    private func withScope(_ value: JSONValue, _ scope: String) -> JSONValue {
        guard case .object(var object) = value else { return value }
        object.set("scope", .string(scope))
        return .object(object)
    }

    public var sampleCount: Int64 { count }
}
