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
