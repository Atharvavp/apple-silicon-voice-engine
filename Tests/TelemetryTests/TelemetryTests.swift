import BenchmarkSupport
import Foundation
import os
import Telemetry
import Testing

enum Evidence {
    static func write(_ name: String, _ value: JSONValue) {
        guard let root = ProcessInfo.processInfo.environment["VOICEBENCH_EVIDENCE_DIR"],
              let data = try? JSONWriter.pretty(value) else { return }
        let url = URL(fileURLWithPath: root).appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url)
    }
}

/// Collects sampler output lines.
final class Lines: Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: [JSONObject]())
    func append(_ data: Data) throws {
        guard case .object(let object) = try StrictJSON.parse(data) else { throw ValidationError("$", "not an object") }
        lock.withLock { $0.append(object) }
    }
    var all: [JSONObject] { lock.withLock { $0 } }
}

private func measurement(_ sample: JSONObject, _ key: String) -> JSONObject {
    guard case .object(let measurements)? = sample["measurements"], case .object(let value)? = measurements[key] else {
        fatalError("missing \(key)")
    }
    return value
}

struct ProcessSamplerTests {
    @Test func cpuCountersAreCumulativeAndMonotone() {
        let first = ProcessProbe.read()
        var spin = 0.0
        for i in 0..<2_000_000 { spin += Double(i).squareRoot() }
        let second = ProcessProbe.read()
        #expect(spin > 0)
        let a = try! #require(first.cpuTotalNS)
        let b = try! #require(second.cpuTotalNS)
        #expect(b >= a, "cumulative user+system time never decreases")
        #expect(first.cpuError == nil && second.cpuError == nil)
    }

    @Test func currentResidentMemoryIsPositiveOnThisMachine() {
        let reading = ProcessProbe.read()
        #expect((reading.residentBytes ?? 0) > 0)
        #expect(reading.memoryError == nil)
        // phys_footprint is reported only when task_info returned a structure that contains it.
        #expect((reading.footprintBytes != nil) == (reading.footprintReason == nil))
        Evidence.write("V12/process-reading.json", .object(JSONObject([
            ("cpu_user_ns", reading.cpuUserNS.json), ("cpu_system_ns", reading.cpuSystemNS.json),
            ("resident_bytes", reading.residentBytes.json), ("footprint_bytes", reading.footprintBytes.json),
            ("thermal_state", .string(reading.thermalState)),
        ])))
    }

    @Test func buildFactsComeFromTheCompiler() {
        #expect(BuildFacts.sdkVersion != "unavailable")
        // Package.swift declares macOS 13 for the default graph and raises it for the SDK graphs.
        let graph = ProcessInfo.processInfo.environment["PHASE1_FRAMEWORKS"] ?? "none"
        let floor = ["none": "13.0", "fluid": "14.0", "speech": "15.0", "both": "15.0"][graph]
        #expect(BuildFacts.deploymentTarget == floor, "Package.swift platform floor for PHASE1_FRAMEWORKS=\(graph)")
        #expect(BuildFacts.swiftVersion.contains("compile-time"))
    }
}

struct TelemetryStatusTests {
    @Test func capabilitiesAreExplicitAndNeverGuessed() throws {
        let capabilities = Dictionary(uniqueKeysWithValues: TelemetryCapabilities.probe())
        #expect(capabilities["cpu_time"]?.status == .ok)
        #expect(capabilities["resident_memory"]?.status == .ok)
        for key in ["gpu_utilization", "ane_utilization", "power"] {
            #expect(capabilities[key]?.status == .unsupported)
            #expect(capabilities[key]?.value == .null && capabilities[key]?.reason?.isEmpty == false)
        }
        #expect(capabilities["thermal_state"]?.source.contains("nominal can also mean unsupported") == true)
        Evidence.write("V12/capabilities.json", .object(JSONObject(capabilities.sorted { $0.key < $1.key }
            .map { ($0.key, $0.value.toJSON()) })))
    }

    @Test func firstSampleCPUIsNotComputableAndLaterSamplesAre() async throws {
        let lines = Lines()
        let sampler = TelemetrySampler(runID: "t", intervalMS: 100, clock: ContinuousRunClock()) { try lines.append($0) }
        try await sampler.start()
        try await Task.sleep(nanoseconds: 350_000_000)
        let summary = try await sampler.stop()
        let samples = lines.all
        #expect(Int64(samples.count) == summary.samples)
        #expect(samples.count >= 3, "start, at least one periodic, end")
        #expect(measurement(samples[0], "cpu_percent")["status"] == .string("not_computable"))
        #expect(measurement(samples[0], "cpu_percent")["reason"] == .string("first_sample_has_no_interval"))
        #expect(samples.dropFirst().allSatisfy { measurement($0, "cpu_percent")["status"] == .string("ok") })
        for sample in samples {
            #expect(measurement(sample, "rss_bytes")["status"] == .string("ok"))
            #expect(measurement(sample, "gpu_utilization")["status"] == .string("unsupported"))
            #expect(measurement(sample, "gpu_utilization")["value"] == .null)
        }
        #expect(samples.first?["phase"] == .string("start") && samples.last?["phase"] == .string("end"))
        Evidence.write("V12/telemetry-samples.json", .array(samples.map(JSONValue.object)))
    }
}

struct StageTimingTests {
    @Test func periodicSamplesUseAbsoluteDeadlinesWithoutCatchUp() async throws {
        let clock = FakeRunClock()
        let lines = Lines()
        let sampler = TelemetrySampler(runID: "t", intervalMS: 1_000, clock: clock) { try lines.append($0) }
        try await sampler.start()
        // The fake clock jumps to each deadline; wait (bounded) until a few periodic samples exist.
        for _ in 0..<500 where lines.all.count < 6 { try await Task.sleep(nanoseconds: 1_000_000) }
        let summary = try await sampler.stop()
        let scheduled = lines.all.compactMap { sample -> Int64? in
            guard sample["phase"] != .string("start"), sample["phase"] != .string("end"),
                  case .int(let value)? = sample["scheduled_ns"] else { return nil }
            return value
        }
        try #require(scheduled.count >= 3)
        #expect(scheduled == (1...Int64(scheduled.count)).map { $0 * 1_000_000_000 },
                "deadlines are anchor + k * interval, never reset to now")
        #expect(clock.recordedSleeps.prefix(scheduled.count).elementsEqual(scheduled))
        #expect(summary.periodicSamples == Int64(scheduled.count))
    }

    @Test func lateWakesAreCountedNotCaughtUp() async throws {
        // A clock that advances 2.5 intervals per read: every wake is late, so ticks are skipped.
        let clock = FakeRunClock(startNS: 0, stepPerRead: 2_500_000_000)
        let lines = Lines()
        let sampler = TelemetrySampler(runID: "t", intervalMS: 1_000, clock: clock) { try lines.append($0) }
        try await sampler.start()
        for _ in 0..<500 where lines.all.count < 6 { try await Task.sleep(nanoseconds: 1_000_000) }
        let summary = try await sampler.stop()
        #expect(summary.missedIntervals > 0)
        #expect(summary.periodicSamples < summary.expectedPeriodicSamples, "no catch-up samples were taken")
    }
}

struct TelemetryErrorTests {
    struct SinkFailure: Error {}

    @Test func sinkFailureIsReportedNotSwallowed() async throws {
        let sampler = TelemetrySampler(runID: "t", intervalMS: 100, clock: ContinuousRunClock()) { _ in throw SinkFailure() }
        await #expect(throws: SinkFailure.self) { try await sampler.start() }
    }

    @Test func periodicSinkFailureSurfacesAtStop() async throws {
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let sampler = TelemetrySampler(runID: "t", intervalMS: 100, clock: ContinuousRunClock()) { _ in
            let n = calls.withLock { value -> Int in
                value += 1
                return value
            }
            if n > 1 { throw SinkFailure() }
        }
        try await sampler.start()
        try await Task.sleep(nanoseconds: 300_000_000)
        await #expect(throws: SinkFailure.self) { _ = try await sampler.stop() }
    }
}
