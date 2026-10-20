import os
import BenchmarkSupport
import Foundation

let repositoryRoot: URL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

func repoURL(_ relative: String) -> URL { repositoryRoot.appendingPathComponent(relative) }

func fixtureURL(_ name: String) -> URL { repoURL("datasets/fixtures/audio/\(name).wav") }

/// Fresh, exclusive scratch directory for one test.
func makeScratch() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("voicebench-tests/\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Writes evidence when the checkpoint runner sets VOICEBENCH_EVIDENCE_DIR; otherwise a no-op.
enum Evidence {
    static func write(_ name: String, _ value: JSONValue) {
        guard ProcessInfo.processInfo.environment["VOICEBENCH_EVIDENCE_DIR"] != nil else { return }
        write(name, (try? JSONWriter.pretty(value)) ?? Data())
    }

    static func write(_ name: String, lines: [String]) {
        guard ProcessInfo.processInfo.environment["VOICEBENCH_EVIDENCE_DIR"] != nil else { return }
        write(name, Data((lines.joined(separator: "\n") + "\n").utf8))
    }

    private static func write(_ name: String, _ data: Data) {
        guard let root = ProcessInfo.processInfo.environment["VOICEBENCH_EVIDENCE_DIR"] else { return }
        let url = URL(fileURLWithPath: root).appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url)
    }
}

/// Fixture generation manifest and count goldens written by scripts/generate_fixtures.py.
struct FixtureCatalog {
    struct Valid {
        let name: String
        let sampleRateHz: Int64
        let channels: Int
        let bits: Int
        let encoding: String
        let frames: Int64
    }

    struct Malformed {
        let name: String
        let expectedError: String
    }

    let valid: [Valid]
    let malformed: [Malformed]
    let convertedFrames: [String: Int64]

    static let shared: FixtureCatalog = {
        func object(_ value: JSONValue) -> JSONObject {
            guard case .object(let object) = value else { fatalError("expected object") }
            return object
        }
        func array(_ value: JSONValue?) -> [JSONValue] {
            guard case .array(let elements)? = value else { fatalError("expected array") }
            return elements
        }
        func string(_ value: JSONValue?) -> String {
            guard case .string(let text)? = value else { fatalError("expected string") }
            return text
        }
        func int(_ value: JSONValue?) -> Int64 {
            guard case .int(let number)? = value else { fatalError("expected int") }
            return number
        }
        let manifest = object(try! StrictJSON.parseFile(repoURL("datasets/fixtures/audio/fixtures.json")))
        let goldens = object(object(try! StrictJSON.parseFile(repoURL("testdata/goldens/audio-counts.json")))["fixtures"]!)
        return FixtureCatalog(
            valid: array(manifest["valid"]).map { entry in
                let e = object(entry)
                return Valid(name: string(e["name"]), sampleRateHz: int(e["sample_rate_hz"]), channels: Int(int(e["channels"])),
                             bits: Int(int(e["bits_per_sample"])), encoding: string(e["encoding"]), frames: int(e["frames"]))
            },
            malformed: array(manifest["malformed"]).map { entry in
                let e = object(entry)
                return Malformed(name: string(e["name"]), expectedError: string(e["expected_error"]))
            },
            convertedFrames: Dictionary(uniqueKeysWithValues: goldens.members.map {
                ($0.key, int(object($0.value)["converted_frames"]))
            }))
    }()
}

struct TimeoutError: Error, CustomStringConvertible {
    let label: String
    let seconds: Double
    var description: String { "\(label) did not finish within \(seconds) s (lost wakeup or deadlock)" }
}

/// Runs `operation` with a wall-clock bound. On timeout the operation task is
/// cancelled and abandoned, so a lost continuation fails the test instead of
/// hanging the whole run.
func withTimeout<T: Sendable>(_ seconds: Double, _ label: String,
                              _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
        let resumed = OSAllocatedUnfairLock(initialState: false)
        let finish: @Sendable (Result<T, Error>) -> Void = { result in
            let first = resumed.withLock { done -> Bool in
                defer { done = true }
                return !done
            }
            if first { continuation.resume(with: result) }
        }
        let work = Task {
            do { finish(.success(try await operation())) } catch { finish(.failure(error)) }
        }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            work.cancel()
            finish(.failure(TimeoutError(label: label, seconds: seconds)))
        }
    }
}
