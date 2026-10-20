import BenchmarkSupport
import CTelemetry
import Foundation

/// One reading of the runner process's own counters (plan B3/E3).
/// CPU is cumulative user+system time (a percentage is derived from two
/// readings); memory is the *current* resident size, not `ru_maxrss`.
public struct ProcessReading: Sendable, Equatable {
    public let cpuUserNS: Int64?
    public let cpuSystemNS: Int64?
    public let cpuError: String?
    public let residentBytes: Int64?
    public let footprintBytes: Int64?
    public let memoryError: String?
    public let footprintReason: String?
    public let thermalState: String

    public var cpuTotalNS: Int64? {
        guard let user = cpuUserNS, let system = cpuSystemNS else { return nil }
        return user + system
    }
}

public enum ProcessProbe {
    public static func read() -> ProcessReading {
        var user: Int64 = 0
        var system: Int64 = 0
        let cpuStatus = vb_process_cpu_ns(&user, &system)
        var resident: Int64 = 0
        var footprint: Int64 = 0
        var hasFootprint: Int32 = 0
        let memoryStatus = vb_process_memory(&resident, &footprint, &hasFootprint)
        return ProcessReading(
            cpuUserNS: cpuStatus == 0 ? user : nil, cpuSystemNS: cpuStatus == 0 ? system : nil,
            cpuError: cpuStatus == 0 ? nil : "getrusage failed with errno \(cpuStatus)",
            residentBytes: memoryStatus == 0 ? resident : nil,
            footprintBytes: memoryStatus == 0 && hasFootprint == 1 ? footprint : nil,
            memoryError: memoryStatus == 0 ? nil : "task_info(TASK_VM_INFO) returned kern_return_t \(memoryStatus)",
            footprintReason: memoryStatus != 0 ? "task_info failed"
                : (hasFootprint == 1 ? nil : "task_info returned a structure without phys_footprint"),
            thermalState: thermalName(ProcessInfo.processInfo.thermalState))
    }

    static func thermalName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown_\(state.rawValue)"
        }
    }
}

public enum TelemetrySources {
    public static let cpu = "getrusage(RUSAGE_SELF)"
    public static let memory = "task_info(TASK_VM_INFO).resident_size"
    public static let footprint = "task_info(TASK_VM_INFO).phys_footprint"
    public static let thermal = "ProcessInfo.thermalState (OS-reported enum; nominal can also mean unsupported, NSProcessInfo.h)"
    public static let unsupportedReason = "no public per-process counter is used in the v1 baseline (no private IOKit APIs, no root)"
}

/// Telemetry capability report written to `environment.json` (plan D6). GPU,
/// ANE and power are explicitly unsupported; nothing is inferred from the
/// architecture or the presence of an accelerator.
public enum TelemetryCapabilities {
    public static func probe() -> [(String, FactObservation)] {
        let reading = ProcessProbe.read()
        func fact(_ ok: Bool, _ value: JSONValue, _ source: String, _ reason: String?) -> FactObservation {
            ok ? .ok(value, source: source) : .missing(.unavailable, source: source, reason: reason ?? "probe failed")
        }
        return [
            ("cpu_time", fact(reading.cpuTotalNS != nil, .string("cumulative_user_system_ns"), TelemetrySources.cpu,
                              reading.cpuError)),
            ("resident_memory", fact(reading.residentBytes != nil, .string("current_bytes"), TelemetrySources.memory,
                                     reading.memoryError)),
            ("physical_footprint", fact(reading.footprintBytes != nil, .string("current_bytes"),
                                        TelemetrySources.footprint, reading.footprintReason)),
            ("thermal_state", .ok(.string("os_reported_enum_support_uncertain"), source: TelemetrySources.thermal)),
            ("gpu_utilization", .missing(.unsupported, source: "none", reason: TelemetrySources.unsupportedReason)),
            ("ane_utilization", .missing(.unsupported, source: "none", reason: TelemetrySources.unsupportedReason)),
            ("power", .missing(.unsupported, source: "none", reason: TelemetrySources.unsupportedReason)),
        ]
    }
}

/// Compile-time build facts (no process spawning, so they hold offline).
public enum BuildFacts {
    public static var sdkVersion: String { versionString(vb_sdk_version_max_allowed()) }
    public static var deploymentTarget: String { versionString(vb_deployment_target()) }

    public static var buildConfiguration: String {
        #if DEBUG
        return "debug"
        #else
        return "release"
        #endif
    }

    public static var swiftVersion: String {
        #if compiler(>=6.5)
        return "6.5 or newer (compile-time check)"
        #elseif compiler(>=6.4)
        return "6.4.x (compile-time check)"
        #elseif compiler(>=6.3)
        return "6.3.x (compile-time check)"
        #elseif compiler(>=6.2)
        return "6.2.x (compile-time check)"
        #elseif compiler(>=6.1)
        return "6.1.x (compile-time check)"
        #else
        return "6.0.x (compile-time check)"
        #endif
    }

    /// `260500` -> `26.5`, `130000` -> `13.0` (patch shown only when nonzero).
    static func versionString(_ encoded: Int64) -> String {
        guard encoded > 0 else { return "unavailable" }
        let major = encoded / 10_000
        let minor = (encoded / 100) % 100
        let patch = encoded % 100
        return patch == 0 ? "\(major).\(minor)" : "\(major).\(minor).\(patch)"
    }
}
