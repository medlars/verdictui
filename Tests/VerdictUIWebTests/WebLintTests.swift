import XCTest
import VerdictUIKernel
@testable import VerdictUIWeb

final class WebLintTests: XCTestCase {
    let viewport = Rect(x: 0, y: 0, width: 800, height: 600)

    func node(_ id: String, x: Double = 20, y: Double, frame: String = "main", position: String = "static",
              children: [SemanticNode] = []) -> SemanticNode {
        SemanticNode(id: id, role: .button, frame: Rect(x: x, y: y, width: 120, height: 44),
                     attributes: ["web.frame": .string(frame), "web.position": .string(position)], children: children)
    }

    func document(_ nodes: [SemanticNode], height: Double = 3276, scroll: Double = 0) -> SemanticNode {
        let roots = nodes.map { source in
            var node = source
            WebLint.store(Rect(x: 0, y: -scroll, width: 800, height: height), key: "web.documentBounds", in: &node.attributes)
            WebLint.store(viewport, key: "web.documentViewport", in: &node.attributes)
            return node
        }
        return SemanticNode(id: "web/root", role: .container, frame: viewport, children: roots).withAssignedStructuralPaths()
    }

    func testLongDocumentAndNonzeroScrollRetainFullEvidence() throws {
        for scroll in [0.0, 2400] {
            let tree = document([node("top", y: 20 - scroll), node("bottom", y: 3000 - scroll)], scroll: scroll)
            let report = WebLint.run(tree: tree, scenario: "long", viewport: viewport)
            XCTAssertEqual(report.status, .pass, "\(report.findings)")
            XCTAssertEqual(report.tree, tree)
            XCTAssertEqual(report.tree?.frame, viewport, "input viewport must not become document extent")
            XCTAssertTrue(try XCTUnwrap(report.tree?.flattened().first { $0.id == "bottom" }).isVisible)
        }
    }

    func testNegativeAndFixedDisplacementStillFailWithOriginalIDs() {
        let tree = document([node("negative", x: -150, y: 100), node("fixed", y: 1000, position: "fixed")])
        let report = WebLint.run(tree: tree, scenario: "displaced", viewport: viewport)
        XCTAssertEqual(Set(report.findings.filter { $0.rule == "offscreen" }.map(\.nodeID)), ["negative", "fixed"])
        XCTAssertEqual(report.tree, tree)
    }

    func testFixedAndFlowOverlapRemainObservableAcrossLintScopes() {
        for pair in [[node("first", y: 30, position: "fixed"), node("second", y: 30, position: "fixed")],
                     [node("first", y: 30), node("second", y: 30, position: "fixed")]] {
            let report = WebLint.run(tree: document(pair), scenario: "overlap", viewport: viewport)
            XCTAssertTrue(report.findings.contains { $0.rule == "sibling-overlap" && $0.nodeID == "second" })
        }
    }

    func testEmbeddedDocumentDoesNotClipAtOwnerButOwnerRemainsChecked() throws {
        var child = node("child", y: 1400, frame: "child")
        WebLint.store(Rect(x: 10, y: 100, width: 500, height: 2000), key: "web.documentBounds", in: &child.attributes)
        WebLint.store(Rect(x: 10, y: 100, width: 500, height: 300), key: "web.documentViewport", in: &child.attributes)
        var owner = SemanticNode(id: "owner", role: .container, frame: Rect(x: 10, y: 100, width: 500, height: 300),
                                 attributes: ["web.frame": .string("main")], children: [child])
        let tree = document([owner])
        XCTAssertEqual(WebLint.run(tree: tree, scenario: "frame", viewport: viewport).status, .pass)
        owner.frame.x = -600
        let broken = WebLint.run(tree: document([owner]), scenario: "owner", viewport: viewport)
        XCTAssertTrue(broken.findings.contains { $0.rule == "offscreen" && $0.nodeID == "owner" })
        var hidden = owner; hidden.isVisible = false
        let embedded = try WebFrameGeometry.embedding(child, in: hidden)
        XCTAssertFalse(embedded.isVisible)
        let visible = try WebFrameGeometry.embedding(child, in: owner)
        XCTAssertTrue(visible.isVisible, "scroll position must not hide CSS-visible child")
    }

    func testScrollPanelRetainsOwnerAndSeparatesContentClipping() {
        var owner = SemanticNode(id: "panel", role: .container, frame: Rect(x: 10, y: 100, width: 500, height: 300),
                                 attributes: ["web.frame": .string("main")], children: [node("bottom", y: 1400)])
        WebLint.store(Rect(x: 10, y: 100, width: 500, height: 2000), key: "web.scrollBounds", in: &owner.attributes)
        XCTAssertEqual(WebLint.run(tree: document([owner]), scenario: "panel", viewport: viewport).status, .pass)
        owner.attributes = ["web.frame": .string("main")]
        let clipped = WebLint.run(tree: document([owner]), scenario: "card", viewport: viewport)
        XCTAssertTrue(clipped.findings.contains { $0.rule == "clipped-content" && $0.nodeID == "bottom" })
    }

    func testOffPanelAndOffFrameContentCannotPaintOverOuterContent() throws {
        for isFrame in [false, true] {
            var child = node("inner", y: 1400, frame: isFrame ? "child" : "main")
            var owner = SemanticNode(id: "owner", role: .container, frame: Rect(x: 10, y: 100, width: 500, height: 200),
                attributes: ["web.frame": .string("main")])
            let extent = Rect(x: 10, y: 100, width: 500, height: 2000)
            if isFrame {
                WebLint.store(extent, key: "web.documentBounds", in: &child.attributes)
                WebLint.store(owner.frame, key: "web.documentViewport", in: &child.attributes)
            } else {
                WebLint.store(extent, key: "web.scrollBounds", in: &owner.attributes)
                WebLint.store(owner.frame, key: "web.scrollViewport", in: &owner.attributes)
            }
            owner.children = [child]
            let tree = document([owner, node("outside", y: 1400)])
            let report = WebLint.run(tree: tree, scenario: "isolated paint", viewport: viewport)
            XCTAssertEqual(report.status, .pass, "\(report.findings)")
            XCTAssertTrue(try XCTUnwrap(report.tree?.flattened().first { $0.id == "inner" }).isVisible)
        }
    }

    func testFixedChildCannotEscapeOuterScrollPanelThroughIframe() {
        var fixed = node("fixed-child", y: 250, frame: "child", position: "fixed")
        let frameBounds = Rect(x: 10, y: 110, width: 500, height: 300)
        WebLint.store(frameBounds, key: "web.documentBounds", in: &fixed.attributes)
        WebLint.store(frameBounds, key: "web.documentViewport", in: &fixed.attributes)
        let iframe = SemanticNode(id: "iframe", role: .container, frame: frameBounds,
                                  attributes: ["web.frame": .string("main")], children: [fixed])
        var panel = SemanticNode(id: "panel", role: .container, frame: Rect(x: 10, y: 100, width: 500, height: 100),
                                 attributes: ["web.frame": .string("main")], children: [iframe])
        WebLint.store(Rect(x: 10, y: 100, width: 500, height: 1000), key: "web.scrollBounds", in: &panel.attributes)
        WebLint.store(panel.frame, key: "web.scrollViewport", in: &panel.attributes)
        let report = WebLint.run(tree: document([panel, node("outside", y: 250)]), scenario: "nested clip", viewport: viewport)
        XCTAssertEqual(report.status, .pass, "\(report.findings)")
    }

    func testTransformedAncestorPreventsViewportFixedClassification() {
        var ancestor = SemanticNode(id: "transform", role: .container, frame: Rect(x: 10, y: 1300, width: 500, height: 200),
                                    attributes: ["web.frame": .string("main"), "web.fixedContainer": .bool(true)],
                                    children: [node("fixed", y: 1320, position: "fixed")])
        XCTAssertEqual(WebLint.run(tree: document([ancestor]), scenario: "transform", viewport: viewport).status, .pass)
        ancestor.attributes["web.fixedContainer"] = .bool(false)
        XCTAssertTrue(WebLint.run(tree: document([ancestor]), scenario: "viewport", viewport: viewport).findings.contains {
            $0.rule == "offscreen" && $0.nodeID == "fixed"
        })
    }

    func testEmptyDocumentRemainsVacuousAndZeroExtentIsValid() throws {
        XCTAssertEqual(try WebLint.checkedRect(x: 0, y: 0, width: 0, height: 0), Rect(x: 0, y: 0, width: 0, height: 0))
        let report = WebLint.run(tree: document([], height: 0), scenario: "empty", viewport: viewport)
        XCTAssertEqual(report.status, .fail)
        XCTAssertEqual(report.findings.map(\.rule), ["vacuous-verdict"])
    }

    func testHiddenOnlyFrameCannotSupplyVisibleEvidence() {
        var child = node("hidden-button", y: 40, frame: "child")
        child.isVisible = false
        let owner = SemanticNode(id: "", role: .container, frame: viewport,
                                 attributes: ["web.frame": .string("main")], isVisible: false, children: [child])
        let hiddenTree = document([owner])
        let hidden = WebLint.run(tree: hiddenTree, scenario: "hidden", viewport: viewport)
        XCTAssertEqual(hidden.status, .fail)
        XCTAssertTrue(hidden.findings.contains { $0.rule == "vacuous-verdict" })
        XCTAssertEqual(hidden.tree, hiddenTree)
        var visible = owner; visible.isVisible = true; visible.children[0].isVisible = true
        XCTAssertEqual(WebLint.run(tree: document([visible]), scenario: "visible frame", viewport: viewport).status, .pass)
    }

    func testInvalidAndOverflowedExtentsFailClosed() {
        for rect in [[Double.nan, 0, 1, 1], [0, Double.infinity, 1, 1], [0, 0, -1, 1], [0, 0, 1, -1],
                     [0, 0, Double.infinity, 1], [0, 0, 1, Double.nan], [Double.greatestFiniteMagnitude, 0, Double.greatestFiniteMagnitude, 1],
                     [0, Double.greatestFiniteMagnitude, 1, Double.greatestFiniteMagnitude]] {
            XCTAssertThrowsError(try WebLint.checkedRect(x: rect[0], y: rect[1], width: rect[2], height: rect[3]))
        }
        var owner = node("owner", y: 0)
        owner.attributes["web.scaleX"] = .number(Double.greatestFiniteMagnitude)
        XCTAssertThrowsError(try WebFrameGeometry.embedding(node("child", y: 10), in: owner))
    }

    func testHitTestUsesRendererDocumentScrollAndRejectsOverflow() throws {
        let attributes: [String: AttributeValue] = ["web.inputScrollX": .number(25), "web.inputScrollY": .number(900)]
        XCTAssertEqual(try WebFrameGeometry.hitPoint(x: 40, y: 54, attributes: attributes), ["x": .integer(65), "y": .integer(954)])
        XCTAssertThrowsError(try WebFrameGeometry.hitPoint(x: 1, y: 1, attributes: [:]))
        for coordinate in [Double.nan, .infinity, 1e20] {
            XCTAssertThrowsError(try WebFrameGeometry.hitPoint(x: coordinate, y: 1, attributes: attributes))
            XCTAssertThrowsError(try WebFrameGeometry.hitPoint(x: 1, y: coordinate, attributes: attributes))
        }
    }

    func testEmbeddedViewportUsesOwnerClientSizeAndTransformedBounds() throws {
        var child = node("child", y: 1400, frame: "child")
        WebLint.store(Rect(x: 0, y: -600, width: 500, height: 2000), key: "web.documentBounds", in: &child.attributes)
        WebLint.store(viewport, key: "web.documentViewport", in: &child.attributes)
        var owner = node("owner", x: 100, y: 200)
        owner.attributes["web.contentX"] = .number(106); owner.attributes["web.contentY"] = .number(206)
        owner.attributes["web.contentWidth"] = .number(500); owner.attributes["web.contentHeight"] = .number(300)
        owner.attributes["web.scaleX"] = .number(2); owner.attributes["web.scaleY"] = .number(2)
        let embedded = try WebFrameGeometry.embedding(child, in: owner)
        XCTAssertEqual(WebLint.rect(key: "web.documentViewport", in: embedded.attributes), Rect(x: 106, y: 206, width: 1000, height: 600))
        XCTAssertEqual(WebLint.rect(key: "web.documentBounds", in: embedded.attributes), Rect(x: 106, y: -994, width: 1000, height: 4000))
    }

    func testEmptyClipOnlyHidesSupportedComputedFormsAndRestoresOnFocus() {
        let frame = Rect(x: -1, y: -1, width: 1, height: 1)
        XCTAssertTrue(WebLint.emptyPaint(position: "absolute", clip: "auto", clipPath: "inset(50%)", frame: frame))
        XCTAssertFalse(WebLint.emptyPaint(position: "fixed", clip: "auto", clipPath: "none", frame: frame))
        for position in ["absolute", "fixed"] {
            XCTAssertTrue(WebLint.emptyPaint(position: position, clip: "rect(0px, 0px, 0px, 0px)", clipPath: "none", frame: frame))
        }
        XCTAssertFalse(WebLint.emptyPaint(position: "static", clip: "rect(0px, 0px, 0px, 0px)", clipPath: "none", frame: frame))
        for clip in ["rect(NaNpx, 0px, 0px, 0px)", "rect(0px, 1px, 1px, 0px)", "rect(auto, 0px, 0px, 0px)"] {
            XCTAssertFalse(WebLint.emptyPaint(position: "absolute", clip: clip, clipPath: "none", frame: frame))
        }
        for path in ["inset(49%)", "inset(10px)", "inset(100px)", "inset(NaN%)", "inset(50% round 2px)", "polygon(0 0,0 0,0 0)", "unsupported"] {
            XCTAssertFalse(WebLint.emptyPaint(position: "absolute", clip: "auto", clipPath: path, frame: frame))
        }
    }
}
