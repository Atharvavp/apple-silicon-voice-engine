import BenchmarkSupport
import Foundation
import Testing

/// Swift half of the shared corpus check (V13). Python validates the same files
/// against JSON Schema and validates Swift's re-encoded output.
struct SchemaRoundTripTests {
    static let swiftKinds: [String: DocumentKind] = [
        "config-authored": .config, "dataset": .dataset, "annotations": .annotations,
        "event": .event, "metric-record": .metric, "status": .status,
    ]

    static var validCases: [String] {
        swiftKinds.keys.sorted().flatMap { target in
            jsonFiles("testdata/schemas/valid/\(target)").map { "\(target)/\($0.lastPathComponent)" }
        }
    }

    static var rejectedCases: [String] {
        ["invalid", "semantic-invalid"].flatMap { group in
            swiftKinds.keys.sorted().flatMap { target in
                jsonFiles("testdata/schemas/\(group)/\(target)").map { "\(group)/\(target)/\($0.lastPathComponent)" }
            }
        }
    }

    @Test func corpusIsPresent() {
        #expect(Self.validCases.count >= 15)
        #expect(Self.rejectedCases.count >= 40)
    }

    @Test(arguments: validCases)
    func validDocumentRoundTripsLosslessly(_ relative: String) throws {
        let target = String(relative.split(separator: "/")[0])
        let kind = try #require(Self.swiftKinds[target])
        let original = try StrictJSON.parseFile(repoURL("testdata/schemas/valid/\(relative)"))
        let reencoded = try kind.roundTrip(original)
        #expect(reencoded.keySorted == original.keySorted, "Swift re-encode changed \(relative)")
        // Persisted bytes must parse back to the same tree.
        let bytes = try JSONWriter.pretty(reencoded)
        #expect(try StrictJSON.parse(bytes) == reencoded)
    }

    /// DEC-010 is closed: Swift validates typed event payloads, so the former
    /// payload-gap files must now be rejected like every other invalid case.
    @Test(arguments: ["invalid/event/final-flag-false.json", "invalid/event/payload-extra-field.json"])
    func formerPayloadGapsAreRejected(_ relative: String) throws {
        let value = try StrictJSON.parseFile(repoURL("testdata/schemas/\(relative)"))
        #expect(throws: (any Error).self) { _ = try DocumentKind.event.roundTrip(value) }
    }

    @Test(arguments: rejectedCases)
    func invalidDocumentIsRejected(_ relative: String) throws {
        let parts = relative.split(separator: "/")
        let kind = try #require(Self.swiftKinds[String(parts[1])])
        let url = repoURL("testdata/schemas/\(relative)")
        #expect(throws: (any Error).self, "Swift accepted \(relative)") {
            _ = try kind.roundTrip(try StrictJSON.parseFile(url))
        }
    }

    @Test func pendingManifestsAreValidButNotRunnable() throws {
        for name in ["english-pending", "hindi-pending"] {
            let manifest = try DatasetManifest.read(
                try StrictJSON.parseFile(repoURL("datasets/manifests/\(name).json")))
            #expect(manifest.status == .pending)
            #expect(manifest.items.isEmpty)
            #expect(throws: ValidationError.self) { try manifest.requireReady() }
            #expect(throws: ValidationError.self) { _ = try manifest.item("anything") }
        }
    }

    @Test func schemaVersionPolicy() throws {
        #expect(try SchemaVersion.check(.string("1.0"), "$") == "1.0")
        #expect(throws: ValidationError.self) { _ = try SchemaVersion.check(.string("1.1"), "$") }
        #expect(throws: ValidationError.self) { _ = try SchemaVersion.check(.string("2.0"), "$") }
        #expect(throws: ValidationError.self) { _ = try SchemaVersion.check(.string("v1"), "$") }
        #expect(throws: ValidationError.self) { _ = try SchemaVersion.check(.int(1), "$") }
    }

    @Test func metricRecordStatusRules() throws {
        #expect(throws: ValidationError.self) {
            _ = try MetricRecord(status: .ok, value: .nan, unit: "ratio", definitionID: "x", sampleCount: 1,
                                 clockDomain: .none, reason: nil)
        }
        #expect(throws: ValidationError.self) {
            _ = try MetricRecord(status: .unavailable, value: 0, unit: "bytes", definitionID: "x", sampleCount: 0,
                                 clockDomain: .none, reason: "sensor missing")
        }
        let record = try MetricRecord(status: .notComputable, value: nil, unit: "ratio", definitionID: "wer_v1",
                                      sampleCount: 0, clockDomain: .none, reason: "zero_reference_tokens")
        #expect(record.toJSON().keySorted == (try MetricRecord.read(record.toJSON())).toJSON().keySorted)
    }

    @Test func lifecycleTransitions() {
        let order: [RunState] = [.created, .validated, .prepared, .running, .flushing, .scoring, .completed]
        for (from, to) in zip(order, order.dropFirst()) {
            #expect(from.canTransition(to: to))
        }
        #expect(!RunState.created.canTransition(to: .running))
        #expect(RunState.running.canTransition(to: .failed))
        #expect(RunState.scoring.canTransition(to: .cancelled))
        #expect(!RunState.completed.canTransition(to: .failed))
        #expect(!RunState.failed.canTransition(to: .completed))
    }
}

struct StrictJSONTests {
    @Test(arguments: [
        #"{"a":1,"a":2}"#, #"{"a":NaN}"#, #"{"a":Infinity}"#, #"[1,]"#, #"{"a":01}"#,
        #"{"a":9223372036854775808}"#, #"{"a":1e400}"#, #""\ud800""#, #""\udc00x""#, "\"tab\there\"",
        #"{"a":1} trailing"#, #"{'a':1}"#, "", #"[1.]"#,
    ])
    func rejects(_ text: String) {
        #expect(throws: JSONParseError.self) { _ = try StrictJSON.parse(text) }
    }

    @Test func rejectsInvalidUTF8() {
        #expect(throws: JSONParseError.self) { _ = try StrictJSON.parse(Data([0x22, 0xFF, 0x22])) }
    }

    @Test func preservesIntegersAndUnicode() throws {
        let value = try StrictJSON.parse(#"{"max":9223372036854775807,"min":-9223372036854775808,"f":0.5,"e":1e2,"s":"😀 न/ "}"#)
        guard case .object(let object) = value else { Issue.record("not an object"); return }
        #expect(object["max"] == .int(Int64.max))
        #expect(object["min"] == .int(Int64.min))
        #expect(object["f"] == .double(0.5))
        #expect(object["e"] == .double(100))
        #expect(object["s"] == .string("😀 न/\u{2028}"))
    }

    @Test func reportsLineAndColumn() {
        do {
            _ = try StrictJSON.parse("{\n  \"a\": 1,\n  \"a\": 2\n}")
            Issue.record("expected duplicate-key error")
        } catch let error as JSONParseError {
            #expect(error.line == 3)
            #expect(error.message.contains("duplicate"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }
}

struct CanonicalJSONTests {
    /// Expected bytes are written by hand from the settings_json_v1 rules.
    @Test func escapingRules() throws {
        let value = JSONValue.object(JSONObject([
            ("z", .string("a\"b\\c/d")),
            ("a", .string("\u{01}\u{08}\u{09}\u{0A}\u{0C}\u{0D}\u{1F}\u{7F}")),
            ("m", .string("हिन्दी 🙂 \u{2028}\u{2029}")),
            ("n", .array([.int(-1), .bool(true), .null, .object(JSONObject())])),
        ]))
        let expected = #"{"a":"\u0001\b\t\n\f\r\u001f"# + "\u{7F}" + #"","m":"हिन्दी 🙂 "# + "\u{2028}\u{2029}"
            + #"","n":[-1,true,null,{}],"z":"a\"b\\c/d"}"#
        let bytes = try JSONWriter.canonical(value)
        #expect(String(decoding: bytes, as: UTF8.self) == expected)
    }

    @Test func keysSortByCodePoint() throws {
        let value = JSONValue.object(JSONObject([("é", .int(1)), ("Z", .int(2)), ("a", .int(3)), ("_", .int(4))]))
        #expect(String(decoding: try JSONWriter.canonical(value), as: UTF8.self) == #"{"Z":2,"_":4,"a":3,"é":1}"#)
    }

    @Test func rejectsFloats() {
        #expect(throws: JSONWriteError.self) { _ = try JSONWriter.canonical(.array([.double(1.5)])) }
    }
}
