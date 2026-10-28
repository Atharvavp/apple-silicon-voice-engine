// swift-tools-version: 6.2
// Benchmark harness (module map and data path: docs/architecture.md). Dependency DAG (no cycles):
//   BenchmarkSupport <- AudioCore <- Replay
//   BenchmarkSupport, AudioCore <- AdapterContracts <- MockAdapters
//   CTelemetry (C shim) <- Telemetry
//   all of the above <- Experiment <- BenchmarkCLI
//
// Phase 1 adds real-framework wrappers (docs/phase1/README.md):
//   AdapterContracts <- RealAdapterSupport <- FluidAudioAdapters / SpeechSwiftAdapters <- BenchmarkCLI
// `PHASE1_FRAMEWORKS=none|fluid|speech|both` (default `none`) selects which pinned SDKs are
// resolved, compiled and registered, so a framework that cannot build does not block the other.
// `none` is the Phase 0 mock-only graph and keeps its macOS 13 floor. The tools-6.2 manifest is
// needed for FluidAudio's package traits; FluidAudio requires macOS 14 and speech-swift macOS 15,
// so framework builds raise the floor accordingly (other OS versions are untested).
import Foundation
import PackageDescription

let frameworks = ProcessInfo.processInfo.environment["PHASE1_FRAMEWORKS"] ?? "none"
guard ["none", "fluid", "speech", "both"].contains(frameworks) else {
    fatalError("PHASE1_FRAMEWORKS must be none, fluid, speech or both (got \(frameworks))")
}
let useFluid = frameworks == "fluid" || frameworks == "both"
let useSpeech = frameworks == "speech" || frameworks == "both"

// Pinned source candidates (one-shot plan, stage 1). Never advance silently.
let fluidRevision = "61d41b3ca04833d1cb80632c82ba401f117a01ef"
let speechRevision = "3f58a58a8f867a4c87b97dbf4d6050d6a88ef665"

var dependencies: [Package.Dependency] = [
    .package(url: "https://github.com/apple/swift-argument-parser.git", exact: "1.8.2"),
    .package(url: "https://github.com/jpsim/Yams.git", exact: "6.2.2"),
]
var cliDependencies: [Target.Dependency] = [
    "BenchmarkSupport", "AudioCore", "Replay", "AdapterContracts", "MockAdapters", "Telemetry", "Experiment",
    "RealAdapterSupport",
    .product(name: "ArgumentParser", package: "swift-argument-parser"),
]
var cliSettings: [SwiftSetting] = []
var phase1Targets: [Target] = []

if useFluid {
    // Only the Diarizer trait: no TTS subsystem, no prebuilt NeMo text-normalization binary.
    dependencies.append(.package(url: "https://github.com/FluidInference/FluidAudio.git", revision: fluidRevision,
                                 traits: ["Diarizer"]))
    phase1Targets.append(.target(
        name: "FluidAudioAdapters",
        dependencies: ["RealAdapterSupport", "AdapterContracts", "AudioCore", "BenchmarkSupport",
                       .product(name: "FluidAudio", package: "FluidAudio")]))
    cliDependencies.append("FluidAudioAdapters")
    cliSettings.append(.define("PHASE1_FLUID"))
}
if useSpeech {
    // Narrow products only: no umbrella speech/CLI/server product, no WhisperKit adapter.
    // Owned copy of the pinned commit (`scripts/run_phase1.py vendor-speech`): speech-swift's
    // benchmark-only `BenchmarkSupport` target collides with ours, so one manifest-only patch
    // (patches/speech-swift-3f58a58a-*.patch, vendor/speech-swift) renames it. Same pinned sources otherwise.
    _ = speechRevision
    dependencies.append(.package(path: "vendor/speech-swift"))
    phase1Targets.append(.target(
        name: "SpeechSwiftAdapters",
        dependencies: ["RealAdapterSupport", "AdapterContracts", "AudioCore", "BenchmarkSupport",
                       .product(name: "SpeechVAD", package: "speech-swift"),
                       .product(name: "ParakeetStreamingASR", package: "speech-swift"),
                       .product(name: "AudioCommon", package: "speech-swift")]))
    cliDependencies.append("SpeechSwiftAdapters")
    cliSettings.append(.define("PHASE1_SPEECH"))
    // Model-free checks of the unmodified native EOU session (stub MLModels with scripted
    // token/EOU outputs; Phase 1 follow-up Step 0). Test-only: the executable is unaffected.
    phase1Targets.append(.testTarget(
        name: "SpeechNativeEOUTests",
        dependencies: ["SpeechSwiftAdapters", "RealAdapterSupport",
                       .product(name: "ParakeetStreamingASR", package: "speech-swift")]))
}

let package = Package(
    name: "VoiceBench",
    platforms: [useSpeech ? .macOS(.v15) : useFluid ? .macOS(.v14) : .macOS(.v13)],
    products: [
        .executable(name: "voicebench", targets: ["BenchmarkCLI"]),
    ],
    dependencies: dependencies,
    targets: [
        .target(
            name: "BenchmarkSupport",
            dependencies: [.product(name: "Yams", package: "Yams")]
        ),
        .target(name: "AudioCore", dependencies: ["BenchmarkSupport"]),
        .target(name: "Replay", dependencies: ["AudioCore", "BenchmarkSupport"]),
        .target(name: "AdapterContracts", dependencies: ["AudioCore", "BenchmarkSupport"]),
        .target(name: "MockAdapters", dependencies: ["AdapterContracts", "AudioCore", "BenchmarkSupport"]),
        .target(name: "CTelemetry"),
        .target(name: "Telemetry", dependencies: ["CTelemetry", "BenchmarkSupport"]),
        .target(
            name: "Experiment",
            dependencies: ["BenchmarkSupport", "AudioCore", "Replay", "AdapterContracts", "MockAdapters", "Telemetry"]
        ),
        .target(name: "RealAdapterSupport", dependencies: ["AdapterContracts", "AudioCore", "BenchmarkSupport"]),
        .executableTarget(name: "BenchmarkCLI", dependencies: cliDependencies, swiftSettings: cliSettings),
        .testTarget(name: "BenchmarkSupportTests", dependencies: ["BenchmarkSupport"]),
        .testTarget(name: "AudioCoreTests", dependencies: ["AudioCore", "Replay", "BenchmarkSupport"]),
        .testTarget(name: "ReplayTests", dependencies: ["Replay", "AudioCore", "BenchmarkSupport"]),
        .testTarget(name: "BenchmarkCLITests", dependencies: ["BenchmarkSupport"]),
        .testTarget(name: "TelemetryTests", dependencies: ["Telemetry", "BenchmarkSupport"]),
        .testTarget(name: "ExperimentTests",
                    dependencies: ["Experiment", "AdapterContracts", "MockAdapters", "Replay", "AudioCore",
                                   "Telemetry", "BenchmarkSupport"]),
        .testTarget(name: "AdapterContractTests",
                    dependencies: ["AdapterContracts", "MockAdapters", "AudioCore", "BenchmarkSupport"]),
        .testTarget(name: "RealAdapterTests",
                    dependencies: ["RealAdapterSupport", "AdapterContracts", "AudioCore", "BenchmarkSupport",
                                   "Experiment", "MockAdapters"]),
    ] + phase1Targets
)
