import XCTest

@testable import VerdictUIKernel

/// The encoded shape of the envelope is the product's wire contract, pinned by
/// `contracts/verdict-schema.json`: agents, the CLI, and the MCP server all parse
/// it. These tests assert the bytes, not just that a round-trip survives — a
/// symmetric encoder/decoder pair can agree on a shape the schema rejects.
final class VerdictEnvelopeTests: XCTestCase {

    /// 2026-08-04T09:20:31Z — a fixed instant, so nothing here depends on the clock.
    private let instant = Date(timeIntervalSince1970: 1_785_835_231)

    private func json(_ verdict: Verdict) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(verdict), as: UTF8.self)
    }

    private func node(_ id: String) -> SemanticNode {
        SemanticNode(id: id, role: .button, frame: Rect(x: 1, y: 2, width: 30, height: 40))
    }

    // MARK: - timestamp

    func testTimestampEncodesAsISO8601UTCAtWholeSeconds() throws {
        let encoded = try json(Verdict(scenario: "s", findings: [], timestamp: instant))
        XCTAssertTrue(encoded.contains("\"timestamp\":\"2026-08-04T09:20:31Z\""), encoded)
    }

    /// Sub-second precision is dropped at construction, not at encoding, so a
    /// verdict compares equal to its own round-trip instead of drifting by
    /// microseconds the wire form cannot carry.
    func testTimestampIsTruncatedToWholeSecondsOnTheWayIn() throws {
        let verdict = Verdict(
            scenario: "s",
            findings: [],
            timestamp: instant.addingTimeInterval(0.999)
        )
        XCTAssertEqual(verdict.timestamp, instant)
        XCTAssertTrue(try json(verdict).contains("2026-08-04T09:20:31Z"))
    }

    func testTimestampSurvivesTheRoundTripExactly() throws {
        let verdict = Verdict(scenario: "s", findings: [], timestamp: instant)
        let decoded = try JSONDecoder().decode(
            Verdict.self,
            from: try JSONEncoder().encode(verdict)
        )
        XCTAssertEqual(decoded.timestamp, instant)
        XCTAssertEqual(decoded, verdict)
    }

    func testDecodeRejectsATimestampThatIsNotISO8601() {
        let payload = """
            {"schemaVersion":"1.0","scenario":"s","timestamp":"4 Aug 2026",
             "status":"PASS","findings":[],"timing":{}}
            """
        XCTAssertThrowsError(try JSONDecoder().decode(Verdict.self, from: Data(payload.utf8))) {
            error in
            guard case DecodingError.dataCorrupted(let context) = error else {
                return XCTFail("expected dataCorrupted, got \(error)")
            }
            XCTAssertTrue(
                context.debugDescription.contains("expected an ISO-8601 UTC timestamp"),
                context.debugDescription
            )
        }
    }

    // MARK: - tree and delta

    func testAbsentTreeAndDeltaAreOmittedNotNull() throws {
        let encoded = try json(Verdict(scenario: "s", findings: [], timestamp: instant))
        XCTAssertFalse(encoded.contains("tree"), encoded)
        XCTAssertFalse(encoded.contains("delta"), encoded)
        XCTAssertFalse(encoded.contains("null"), "an absent field costs the MCP surface nothing")
    }

    func testTreeIsEmbeddedWhenPresentAndDecodesBack() throws {
        let tree = SemanticNode(
            id: "root",
            role: .container,
            frame: Rect(x: 0, y: 0, width: 100, height: 100),
            children: [node("save")]
        )
        let verdict = Verdict(scenario: "s", findings: [], timestamp: instant, tree: tree)
        let encoded = try json(verdict)
        XCTAssertTrue(encoded.contains("\"tree\":{"), encoded)
        XCTAssertTrue(encoded.contains("\"id\":\"save\""), encoded)

        let decoded = try JSONDecoder().decode(
            Verdict.self,
            from: try JSONEncoder().encode(verdict)
        )
        XCTAssertEqual(decoded.tree, tree)
        XCTAssertNil(decoded.delta)
    }

    func testDeltaIsEmbeddedWhenPresentAndDecodesBack() throws {
        let before = SemanticNode(
            id: "root",
            role: .container,
            frame: Rect(x: 0, y: 0, width: 100, height: 100),
            children: [node("save")]
        )
        var after = before
        after.children[0].frame = Rect(x: 5, y: 2, width: 30, height: 40)
        let delta = TreeDiff.compute(before: before, after: after)
        XCTAssertFalse(delta.isEmpty, "the fixture must actually differ")

        let verdict = Verdict(scenario: "s", findings: [], timestamp: instant, delta: delta)
        let encoded = try json(verdict)
        XCTAssertTrue(encoded.contains("\"delta\":{"), encoded)
        XCTAssertTrue(encoded.contains("\"moved\":["), encoded)

        let decoded = try JSONDecoder().decode(
            Verdict.self,
            from: try JSONEncoder().encode(verdict)
        )
        XCTAssertEqual(decoded.delta, delta)
        XCTAssertNil(decoded.tree)
    }

    func testTreeAndDeltaCanTravelTogether() throws {
        let tree = SemanticNode(id: "root", role: .container, frame: Rect(x: 0, y: 0, width: 1, height: 1))
        let verdict = Verdict(
            scenario: "s",
            findings: [],
            timestamp: instant,
            tree: tree,
            delta: TreeDelta(removed: [NodePath.root.appending("gone")])
        )
        let decoded = try JSONDecoder().decode(
            Verdict.self,
            from: try JSONEncoder().encode(verdict)
        )
        XCTAssertEqual(decoded.tree, tree)
        XCTAssertEqual(decoded.delta?.removed, [NodePath.root.appending("gone")])
    }

    // MARK: - timing

    func testTimingDefaultsToBothFieldsUnmeasured() throws {
        let timing = Verdict.Timing()
        XCTAssertNil(timing.settleMs)
        XCTAssertNil(timing.evaluateMs)
        let encoded = try json(Verdict(scenario: "s", findings: [], timestamp: instant))
        XCTAssertTrue(encoded.contains("\"timing\":{}"), encoded)
    }

    func testTimingCarriesBothFieldsAndOmitsTheUnmeasuredOne() throws {
        let both = Verdict(
            scenario: "s",
            findings: [],
            timestamp: instant,
            timing: Verdict.Timing(settleMs: 12.5, evaluateMs: 0.75)
        )
        let encoded = try json(both)
        XCTAssertTrue(encoded.contains("\"evaluateMs\":0.75"), encoded)
        XCTAssertTrue(encoded.contains("\"settleMs\":12.5"), encoded)

        let evaluateOnly = try json(
            Verdict(
                scenario: "s",
                findings: [],
                timestamp: instant,
                timing: Verdict.Timing(evaluateMs: 0.75)
            )
        )
        XCTAssertFalse(evaluateOnly.contains("settleMs"), "Wave 3 fills settleMs; Wave 1 omits it")
    }

    func testTimingSurvivesTheRoundTripAndIsNotSilentlyDefaulted() throws {
        let timing = Verdict.Timing(settleMs: 3, evaluateMs: 4)
        let decoded = try JSONDecoder().decode(
            Verdict.self,
            from: try JSONEncoder().encode(
                Verdict(scenario: "s", findings: [], timestamp: instant, timing: timing)
            )
        )
        XCTAssertEqual(decoded.timing, timing)
    }

    /// `timing` is the one envelope field the decoder tolerates missing, because
    /// a producer that measured nothing has nothing to report.
    func testDecodeTreatsAMissingTimingAsUnmeasured() throws {
        let payload = """
            {"schemaVersion":"1.0","scenario":"s","timestamp":"2026-08-04T09:20:31Z",
             "status":"PASS","findings":[]}
            """
        let decoded = try JSONDecoder().decode(Verdict.self, from: Data(payload.utf8))
        XCTAssertEqual(decoded.timing, Verdict.Timing())
    }

    // MARK: - envelope invariants

    func testEncodingAlwaysStampsTheKernelsOwnSchemaVersion() throws {
        let verdict = Verdict(scenario: "s", findings: [], timestamp: instant)
        XCTAssertEqual(verdict.schemaVersion, SchemaVersion.current)
        XCTAssertTrue(try json(verdict).contains("\"schemaVersion\":\"1.0\""))
    }

    func testEnvelopeCarriesExactlyTheRequiredKeysWhenNothingIsOptionalPresent() throws {
        let encoded = try json(
            Verdict(
                scenario: "s",
                findings: [Finding(rule: "r", severity: .warning, nodeID: "n", message: "m")],
                timestamp: instant
            )
        )
        let keys = ["findings", "scenario", "schemaVersion", "status", "timestamp", "timing"]
        for key in keys {
            XCTAssertTrue(encoded.contains("\"\(key)\":"), "missing required key \(key)")
        }
        XCTAssertEqual(
            encoded.filter { $0 == "{" }.count,
            3,
            "envelope + one finding + timing — no unexpected nesting"
        )
    }

    func testBothSeveritiesAreAcceptedOnTheWire() throws {
        let severities: [Finding.Severity] = [.error, .warning]
        for severity in severities {
            let verdict = Verdict(
                scenario: "s",
                findings: [Finding(rule: "r", severity: severity, nodeID: "n", message: "m")],
                timestamp: instant
            )
            let decoded = try JSONDecoder().decode(
                Verdict.self,
                from: try JSONEncoder().encode(verdict)
            )
            XCTAssertEqual(decoded.findings.first?.severity, severity)
            XCTAssertEqual(decoded.status, severity == .error ? .fail : .pass)
        }
    }
}
