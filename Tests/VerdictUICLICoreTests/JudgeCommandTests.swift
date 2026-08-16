import Foundation
import VerdictUIKernel
import XCTest

@testable import VerdictUICLICore

/// `judge` is the language-agnostic entry point: it decodes a tree the CALLER
/// produced and runs the same rule library `verify` runs.
///
/// Every other verb renders SwiftUI first, which limits the engine to Swift.
/// The kernel never had that limit — it imports only Foundation and
/// `SemanticNode` is `Codable` (`SemanticNode.swift:359`) — so the barrier was
/// the missing verb, not the engine. These tests pin that: the trees below are
/// hand-written JSON, produced by no renderer at all, exactly as a JS, Python
/// or Kotlin producer would emit them.
final class JudgeCommandTests: XCTestCase {

    /// A tree with a text node whose intrinsic width exceeds its frame.
    /// `TruncationRule` must find it, having never seen SwiftUI.
    private let truncatingTreeJSON = """
        {
          "id": "root",
          "role": "container",
          "frame": {"x": 0, "y": 0, "width": 200, "height": 100},
          "children": [
            {
              "id": "label",
              "role": "text",
              "frame": {"x": 0, "y": 0, "width": 100, "height": 20},
              "text": "a string far wider than its frame allows",
              "textMetrics": {"intrinsicWidth": 260, "renderedLineCount": 1, "idealLineCount": 1},
              "children": []
            }
          ]
        }
        """

    /// The same shape with the text comfortably inside its frame.
    ///
    /// CONTROL. Without it, "judge reports findings" is satisfied by an
    /// implementation that reports findings on everything, and the test above
    /// would pass against a broken rule engine.
    private let cleanTreeJSON = """
        {
          "id": "root",
          "role": "container",
          "frame": {"x": 0, "y": 0, "width": 200, "height": 100},
          "children": [
            {
              "id": "label",
              "role": "text",
              "frame": {"x": 0, "y": 0, "width": 180, "height": 20},
              "text": "short",
              "textMetrics": {"intrinsicWidth": 40, "renderedLineCount": 1, "idealLineCount": 1},
              "children": []
            }
          ]
        }
        """

    private func judge(_ json: String) throws -> Verdict {
        let tree = try JSONDecoder().decode(SemanticNode.self, from: Data(json.utf8))
        let context = LintContext.macOS(
            viewport: Rect(x: 0, y: 0, width: 200, height: 100),
            scenario: "judged-tree"
        )
        return RuleEngine.run(rules: RuleEngine.standardRules, on: tree, context: context)
    }

    /// The kernel judges a tree no Swift renderer produced.
    func testJudgeFindsADefectInACallerSuppliedTree() throws {
        let verdict = try judge(truncatingTreeJSON)

        XCTAssertEqual(
            verdict.status, .fail,
            "a text node needing 260 pt in a 100 pt frame must FAIL — got \(verdict)"
        )
        XCTAssertTrue(
            verdict.findings.contains { $0.rule == "truncation" && $0.nodeID == "label" },
            "the truncation finding must cite the offending node by id — got \(verdict.findings)"
        )
    }

    /// CONTROL: a clean caller-supplied tree passes.
    func testJudgePassesACleanCallerSuppliedTree() throws {
        let verdict = try judge(cleanTreeJSON)

        XCTAssertEqual(
            verdict.status, .pass,
            "a tree with no defect must PASS, or the rule engine is firing on everything — got \(verdict)"
        )
        XCTAssertTrue(verdict.findings.isEmpty, "expected no findings, got \(verdict.findings)")
    }

    /// A tree that decodes but carries no probed node must be REFUSED, not passed.
    ///
    /// This is the vacuity guard reaching the foreign-producer path: a producer
    /// that emits an empty shell would otherwise get a clean bill of health for
    /// a screen nobody observed.
    func testJudgeRefusesATreeWithNothingObservable() throws {
        let empty = """
            {"id": "root", "role": "container",
             "frame": {"x": 0, "y": 0, "width": 200, "height": 100}, "children": []}
            """
        let verdict = try judge(empty)

        XCTAssertEqual(
            verdict.status, .fail,
            "an empty tree must be refused as vacuous, never passed — got \(verdict)"
        )
        XCTAssertTrue(
            verdict.findings.contains { $0.rule == RuleEngine.vacuousVerdictRule },
            "the refusal must name vacuous-verdict — got \(verdict.findings)"
        )
    }

    /// Malformed input is a TOOL failure, distinct from a failing verdict.
    func testJudgeRejectsMalformedJSONRatherThanReportingAVerdict() {
        XCTAssertThrowsError(
            try judge("{ not json at all"),
            "undecodable input must throw, not silently produce a verdict about nothing"
        )
    }
}
