import AVFAudio
import Darwin
import Foundation
import Testing

/// M1 task 6: compile-and-call probes for public platform APIs that later
/// milestones rely on. Observed values are printed for docs/api-verification.md;
/// assertions only check documented invariants, never performance.
struct APIProbeTests {
    @Test func avAudioSignaturesCompile() throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1,
                                                interleaved: false))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096))
        #expect(buffer.frameCapacity == 4096)
        #expect(buffer.floatChannelData != nil)
        #expect(buffer.stride == 1)
        let target = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1,
                                                interleaved: false))
        let converter = try #require(AVAudioConverter(from: format, to: target))
        converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Normal
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        converter.primeMethod = .normal
        print("probe.avaudioconverter.prime_info leading=\(converter.primeInfo.leadingFrames) trailing=\(converter.primeInfo.trailingFrames)")
        // `AVAudioFile(forReading:commonFormat:interleaved:)` is exercised against real WAV fixtures in AudioCoreTests.
        let initializer: (URL, AVAudioCommonFormat, Bool) throws -> AVAudioFile = AVAudioFile.init(forReading:commonFormat:interleaved:)
        _ = initializer
    }

    @Test func getrusageReportsCumulativeCPU() {
        var usage = rusage()
        #expect(getrusage(RUSAGE_SELF, &usage) == 0)
        let userNS = Int64(usage.ru_utime.tv_sec) * 1_000_000_000 + Int64(usage.ru_utime.tv_usec) * 1_000
        let systemNS = Int64(usage.ru_stime.tv_sec) * 1_000_000_000 + Int64(usage.ru_stime.tv_usec) * 1_000
        print("probe.getrusage user_ns=\(userNS) system_ns=\(systemNS)")
        #expect(userNS + systemNS > 0)
    }

    @Test func taskVMInfoReportsResidentSize() {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        #expect(result == KERN_SUCCESS)
        let footprintCovered = count >= mach_msg_type_number_t(
            MemoryLayout.offset(of: \task_vm_info_data_t.phys_footprint)! / MemoryLayout<natural_t>.size + 2)
        print("probe.task_vm_info resident_size=\(info.resident_size) returned_count=\(count) phys_footprint=\(footprintCovered ? String(info.phys_footprint) : "not_covered")")
        #expect(info.resident_size > 0)
    }

    @Test func thermalStateAndClockResolution() {
        let state = ProcessInfo.processInfo.thermalState
        print("probe.thermal_state raw=\(state.rawValue) (OS-reported; nominal may also mean unsupported)")
        #expect((0...3).contains(state.rawValue))
        print("probe.continuous_clock.minimum_resolution=\(ContinuousClock().minimumResolution)")
    }
}
