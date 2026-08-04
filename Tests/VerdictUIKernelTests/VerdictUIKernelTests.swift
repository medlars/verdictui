import XCTest

@testable import VerdictUIKernel

final class VerdictUIKernelTests: XCTestCase {
    func testOverlappingSiblingsProduceFailVerdict() {
        let root = SemanticNode(
            id: "root",
            role: "container",
            frame: Rect(x: 0, y: 0, width: 100, height: 100),
            children: [
                SemanticNode(id: "a", role: "button", frame: Rect(x: 0, y: 0, width: 60, height: 40)),
                SemanticNode(id: "b", role: "button", frame: Rect(x: 50, y: 10, width: 60, height: 40)),
            ]
        )
        let verdict = Verdict(findings: LayoutLint.siblingOverlaps(in: root))
        XCTAssertEqual(verdict.status, .fail)
        XCTAssertEqual(verdict.findings.count, 1)
        XCTAssertEqual(verdict.findings[0].rule, "sibling-overlap")
        XCTAssertEqual(verdict.findings[0].nodeID, "b")
    }

    func testDisjointSiblingsProducePassVerdict() {
        let root = SemanticNode(
            id: "root",
            role: "container",
            frame: Rect(x: 0, y: 0, width: 200, height: 100),
            children: [
                SemanticNode(id: "a", role: "button", frame: Rect(x: 0, y: 0, width: 60, height: 40)),
                SemanticNode(id: "b", role: "button", frame: Rect(x: 80, y: 0, width: 60, height: 40)),
            ]
        )
        let verdict = Verdict(findings: LayoutLint.siblingOverlaps(in: root))
        XCTAssertEqual(verdict.status, .pass)
        XCTAssertTrue(verdict.findings.isEmpty)
    }

    func testZeroSizeFramesDoNotTriggerOverlap() {
        let root = SemanticNode(
            id: "root",
            role: "container",
            frame: Rect(x: 0, y: 0, width: 100, height: 100),
            children: [
                SemanticNode(id: "a", role: "spacer", frame: Rect(x: 10, y: 10, width: 0, height: 0)),
                SemanticNode(id: "b", role: "button", frame: Rect(x: 0, y: 0, width: 60, height: 40)),
            ]
        )
        XCTAssertTrue(LayoutLint.siblingOverlaps(in: root).isEmpty)
    }

    func testVerdictRoundTripsThroughJSON() throws {
        let verdict = Verdict(findings: [
            Finding(rule: "sibling-overlap", severity: .error, nodeID: "b", message: "overlap")
        ])
        let data = try JSONEncoder().encode(verdict)
        let decoded = try JSONDecoder().decode(Verdict.self, from: data)
        XCTAssertEqual(decoded, verdict)
    }
}
