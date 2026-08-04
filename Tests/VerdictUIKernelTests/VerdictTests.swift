import XCTest

@testable import VerdictUIKernel

/// Verdict/Finding semantics: status is derived, never set, and the wire form
/// omits absent fields.
final class VerdictTests: XCTestCase {

    func testAnyErrorMakesTheVerdictFail() {
        let verdict = Verdict(
            scenario: "s",
            findings: [
                Finding(rule: "a", severity: .warning, nodeID: "x", message: "m"),
                Finding(rule: "b", severity: .error, nodeID: "y", message: "m"),
            ]
        )
        XCTAssertEqual(verdict.status, .fail)
    }

    func testWarningsAloneStillPass() {
        let verdict = Verdict(
            scenario: "s",
            findings: [Finding(rule: "a", severity: .warning, nodeID: "x", message: "m")]
        )
        XCTAssertEqual(verdict.status, .pass)
    }

    func testNoFindingsPassesWithTheDefaultScenarioName() {
        let verdict = Verdict(findings: [])
        XCTAssertEqual(verdict.status, .pass)
        XCTAssertEqual(verdict.scenario, "unnamed")
    }

    func testStatusEncodesAsUppercaseStrings() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let json = String(decoding: try encoder.encode(Verdict(findings: [])), as: UTF8.self)
        XCTAssertTrue(json.contains("\"status\":\"PASS\""), json)
    }

    func testFindingOmitsAnAbsentSuggestion() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let bare = Finding(rule: "a", severity: .error, nodeID: "x", message: "m")
        XCTAssertFalse(
            String(decoding: try encoder.encode(bare), as: UTF8.self).contains("suggestion")
        )
        let hinted = Finding(rule: "a", severity: .error, nodeID: "x", message: "m", suggestion: "fix it")
        XCTAssertTrue(
            String(decoding: try encoder.encode(hinted), as: UTF8.self).contains("\"suggestion\":\"fix it\"")
        )
    }

    func testDecodeRejectsAStatusThatContradictsItsFindings() throws {
        // A producer claiming PASS while carrying an error finding is corrupt.
        // Accepting it would let a failing verdict be reported as passing.
        let json = """
            {"schemaVersion":"1.0","scenario":"lying","timestamp":"2026-08-04T00:00:00Z",
             "status":"PASS",
             "findings":[{"rule":"r","severity":"error","nodeID":"x","message":"m"}],
             "timing":{}}
            """
        XCTAssertThrowsError(
            try JSONDecoder().decode(Verdict.self, from: Data(json.utf8))
        ) { error in
            guard case DecodingError.dataCorrupted(let context) = error else {
                return XCTFail("expected dataCorrupted, got \(error)")
            }
            XCTAssertTrue(
                context.debugDescription.contains("contradicts the findings"),
                context.debugDescription
            )
        }
    }

    func testDecodeAcceptsAConsistentFailStatus() throws {
        let json = """
            {"schemaVersion":"1.0","scenario":"honest","timestamp":"2026-08-04T00:00:00Z",
             "status":"FAIL",
             "findings":[{"rule":"r","severity":"error","nodeID":"x","message":"m"}],
             "timing":{}}
            """
        let verdict = try JSONDecoder().decode(Verdict.self, from: Data(json.utf8))
        XCTAssertEqual(verdict.status, .fail)
        XCTAssertEqual(verdict.findings.count, 1)
    }

    func testStatusDerivationIsTheSameRuleForBothDirections() {
        let errored = [Finding(rule: "a", severity: .error, nodeID: "x", message: "m")]
        let warned = [Finding(rule: "a", severity: .warning, nodeID: "x", message: "m")]
        XCTAssertEqual(Verdict.Status.derived(from: errored), .fail)
        XCTAssertEqual(Verdict.Status.derived(from: warned), .pass)
        XCTAssertEqual(Verdict.Status.derived(from: []), .pass)
        XCTAssertEqual(Verdict(findings: errored).status, .fail)
    }

    func testVerdictRoundTripsThroughJSON() throws {
        let verdict = Verdict(
            scenario: "round-trip",
            findings: [
                Finding(
                    rule: "sibling-overlap",
                    severity: .error,
                    nodeID: "b",
                    message: "overlap",
                    suggestion: "separate them"
                )
            ]
        )
        let data = try JSONEncoder().encode(verdict)
        XCTAssertEqual(try JSONDecoder().decode(Verdict.self, from: data), verdict)
    }
}
