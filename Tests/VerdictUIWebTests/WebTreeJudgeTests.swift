import Foundation
import VerdictUIKernel
import XCTest
@testable import VerdictUIWeb

/// Labelled data fixtures test admission; real WKWebView capture is a separate gate.
final class WebTreeJudgeTests: XCTestCase {
    private func node(_ id: String, depth: Int = 1, x: Double = 20, role: Role = .button,
                      tag: String = "button", children: [SemanticNode] = []) -> SemanticNode {
        SemanticNode(id: id, role: role, frame: Rect(x: x, y: 20, width: 100, height: 50),
            attributes: ["web.tag": .string(tag), "web.frame": .string("main"), "web.domDepth": .number(Double(depth)),
                "web.position": .string("static"), "web.overflowX": .string("visible"), "web.overflowY": .string("visible"),
                "web.interactionMeasured": .bool(false), "web.isClickable": .bool(role == .button),
                "web.isFocusable": .bool(role == .button), "web.hasInteractiveAncestor": .bool(false)], children: children)
    }
    private func tree(_ children: [SemanticNode]) -> SemanticNode {
        var root = node("root", depth: 0, role: .container, tag: "body", children: children)
        root.frame = Rect(x: 0, y: 0, width: 800, height: 600)
        return root
    }
    func testCleanMeasuredTreePassesAndKeepsRawObservation() throws {
        let raw = tree([node("save"), node("cancel", x: 200)])
        let verdict = try WebTreeJudge.judge(data: JSONEncoder().encode(raw), scenario: "owned")
        XCTAssertEqual(verdict.status, .pass)
        XCTAssertEqual(verdict.tree, raw.withAssignedStructuralPaths())
    }
    func testMeaningfulOverlapRemainsFailure() throws {
        let verdict = try WebTreeJudge.judge(tree: tree([node("save"), node("cancel", x: 50)]), scenario: "owned")
        XCTAssertEqual(verdict.status, .fail)
        XCTAssertTrue(verdict.findings.contains { $0.rule == "sibling-overlap" && $0.severity == .error })
        var unnamed = tree([node(""), node("", x: 50)])
        unnamed.id = ""
        let observed = try WebTreeJudge.judge(tree: unnamed, scenario: "unnamed")
        XCTAssertTrue(observed.findings.contains { $0.severity == .error })
        XCTAssertTrue(observed.findings.allSatisfy { !$0.nodeID.isEmpty })
    }
    func testActualClippedControlRemainsFailure() throws {
        var container = node("panel", role: .container, tag: "div", children: [node("save", depth: 2, x: 200)])
        container.attributes["web.overflowX"] = .string("hidden")
        let verdict = try WebTreeJudge.judge(tree: tree([container]), scenario: "owned")
        XCTAssertEqual(verdict.status, .fail)
        XCTAssertTrue(verdict.findings.contains { $0.rule == "clipped-content" && $0.nodeID == "save" })
    }
    func testInertPresentationRemainsPaintQualified() throws {
        var first = node("art-a", role: .container, tag: "div")
        first.attributes["web.interactionMeasured"] = .bool(true)
        var second = first; second.id = "art-b"
        let verdict = try WebTreeJudge.judge(tree: tree([first, second, node("save", x: 300)]), scenario: "owned")
        XCTAssertEqual(verdict.status, .pass)
        XCTAssertTrue(verdict.findings.contains { $0.rule == "web-paint-unverified" })
        first.attributes["web.interactionMeasured"] = .bool(false)
        second.attributes["web.interactionMeasured"] = .bool(false)
        XCTAssertEqual(try WebTreeJudge.judge(tree: tree([first, second]), scenario: "unknown").status, .fail)
    }
    func testMissingDOMMetadataIsUnavailable() throws {
        var raw = tree([node("save")]); raw.children[0].attributes.removeValue(forKey: "web.overflowX")
        XCTAssertThrowsError(try WebTreeJudge.judge(tree: raw, scenario: "owned"))
    }
    func testMalformedAncestryAndBoundsAreUnavailable() throws {
        for mutation in 0..<4 {
            var raw = tree([node("save")])
            switch mutation {
            case 0: raw.children[0].attributes["web.domDepth"] = .number(0)
            case 1: raw.children[0].attributes["web.scrollViewportX"] = .number(20)
            case 2: raw.frame.width = 0
            default: raw.children[0].frame.x = .infinity
            }
            XCTAssertThrowsError(try WebTreeJudge.judge(tree: raw, scenario: "owned"))
        }
    }
    func testByteAndNodeBudgetsAreEnforced() throws {
        XCTAssertThrowsError(try WebTreeJudge.judge(data: Data(repeating: 32, count: 8 * 1024 * 1024 + 1), scenario: "owned"))
        var children = (0..<10_001).map { node("node-\($0)") }
        for index in children.indices { children[index].isVisible = false }
        XCTAssertThrowsError(try WebTreeJudge.judge(tree: tree(children), scenario: "owned"))
    }
    func testCanonicalCaptureRoundTripKeepsViewportScaffold() throws {
        let fixtures = DOMSnapshotAssemblyTests()
        let captured = try DOMSnapshotAssembly.assemble(fixtures.snapshot(), viewport: Rect(x: 0, y: 0, width: 800, height: 600))
        XCTAssertNil(captured.attributes["web.domDepth"])
        let expected = try WebLint.run(tree: captured, scenario: "canonical", viewport: captured.frame)
        let actual = try WebTreeJudge.judge(data: JSONEncoder().encode(captured), scenario: "canonical")
        XCTAssertEqual(actual.status, expected.status)
        XCTAssertEqual(actual.findings, expected.findings)
        XCTAssertEqual(actual.tree, captured)
        let forged = tree([captured])
        XCTAssertThrowsError(try WebTreeJudge.judge(tree: forged, scenario: "nested-scaffold"))
        var empty = captured; empty.children = []
        XCTAssertEqual(try WebTreeJudge.judge(tree: empty, scenario: "empty").status, .fail)
    }

    func testChildDocumentDepthResetRequiresRealFrameBoundaryAndKeepsDefects() throws {
        for fault in [false, true] {
            var first = node("save", depth: 4), second = node("cancel", depth: 4, x: fault ? 40 : 200)
            first.attributes["web.frame"] = .string("nested"); second.attributes["web.frame"] = .string("nested")
            var child = node("document", depth: 3, role: .container, tag: "div", children: [first, second])
            child.attributes["web.frame"] = .string("nested"); child.frame = Rect(x: 0, y: 0, width: 400, height: 300)
            WebLint.store(child.frame, key: "web.documentBounds", in: &child.attributes)
            WebLint.store(child.frame, key: "web.documentViewport", in: &child.attributes)
            var owner = node("owner", depth: 4, role: .container, tag: "iframe")
            owner.frame = Rect(x: 20, y: 20, width: 400, height: 300)
            owner.children = [try WebFrameGeometry.embedding(child, in: owner)]
            let valid = tree([owner])
            let report = try WebTreeJudge.judge(tree: valid, scenario: "nested")
            XCTAssertEqual(report.status, fault ? .fail : .pass)
            if fault { XCTAssertTrue(report.findings.contains { $0.rule == "sibling-overlap" && !$0.nodeID.isEmpty }) }
            owner.attributes["web.tag"] = .string("div")
            XCTAssertThrowsError(try WebTreeJudge.judge(tree: tree([owner]), scenario: "forged-boundary"))
            owner.attributes["web.tag"] = .string("iframe")
            owner.children[0].attributes.removeValue(forKey: "web.documentViewportWidth")
            XCTAssertThrowsError(try WebTreeJudge.judge(tree: tree([owner]), scenario: "missing-viewport"))
        }
    }

    func testOnlyNonpaintingFrameAnchorsCanLackCSS() throws {
        var anchor = node("anchor", role: .container, tag: "iframe")
        anchor.isVisible = false; anchor.frame = Rect(x: 0, y: 0, width: 0, height: 0)
        for key in ["web.position", "web.overflowX", "web.overflowY"] { anchor.attributes.removeValue(forKey: key) }
        anchor.attributes["web.backendID"] = .number(3)
        XCTAssertEqual(try WebTreeJudge.judge(tree: tree([node("save"), anchor]), scenario: "hidden").status, .pass)
        var visibleChild = node("hidden-child", depth: 2)
        anchor.children = [visibleChild]
        XCTAssertThrowsError(try WebTreeJudge.judge(tree: tree([anchor]), scenario: "visible-descendant"))
        visibleChild.isVisible = false; anchor.children = [visibleChild]
        XCTAssertEqual(try WebTreeJudge.judge(tree: tree([node("save"), anchor]), scenario: "hidden-descendant").status, .pass)
        anchor.children = []
        anchor.isVisible = true
        XCTAssertThrowsError(try WebTreeJudge.judge(tree: tree([anchor]), scenario: "visible"))
        anchor.isVisible = false; anchor.attributes["web.tag"] = .string("div")
        XCTAssertThrowsError(try WebTreeJudge.judge(tree: tree([anchor]), scenario: "not-a-frame"))
    }

}
