// swift-tools-version: 6.0
// Phase 0 benchmark harness. Targets follow PHASE_0_CLAUDE_IMPLEMENTATION_PLAN.md
// section C1; dependency DAG (no cycles):
//   BenchmarkSupport <- AudioCore <- Replay
//   BenchmarkSupport, AudioCore <- AdapterContracts <- MockAdapters
//   CTelemetry (C shim) <- Telemetry
//   all of the above <- Experiment <- BenchmarkCLI
import PackageDescription

let package = Package(
    name: "VoiceBench",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "voicebench", targets: ["BenchmarkCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", exact: "1.8.2"),
        .package(url: "https://github.com/jpsim/Yams.git", exact: "6.2.2"),
    ],
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
        .executableTarget(
            name: "BenchmarkCLI",
            dependencies: [
                "BenchmarkSupport", "AudioCore", "Replay", "AdapterContracts", "MockAdapters", "Telemetry", "Experiment",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(name: "BenchmarkSupportTests", dependencies: ["BenchmarkSupport"]),
        .testTarget(name: "AudioCoreTests", dependencies: ["AudioCore", "Replay", "BenchmarkSupport"]),
        .testTarget(name: "ReplayTests", dependencies: ["Replay", "AudioCore", "BenchmarkSupport"]),
        .testTarget(name: "TelemetryTests", dependencies: ["Telemetry", "BenchmarkSupport"]),
        .testTarget(name: "ExperimentTests",
                    dependencies: ["Experiment", "AdapterContracts", "MockAdapters", "Replay", "AudioCore",
                                   "Telemetry", "BenchmarkSupport"]),
        .testTarget(name: "AdapterContractTests",
                    dependencies: ["AdapterContracts", "MockAdapters", "AudioCore", "BenchmarkSupport"]),
    ]
)
