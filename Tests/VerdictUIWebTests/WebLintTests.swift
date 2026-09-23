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

    func testInlineBorderFragmentsAvoidUnionOverlapAndRetainPaddingCollisions() throws {
        var first = node("label", x: 20, y: 20); first.frame = Rect(x: 20, y: 20, width: 80, height: 20)
        var detail = SemanticNode(id: "detail", role: .container, frame: Rect(x: 20, y: 20, width: 280, height: 44),
                                  attributes: ["web.inlineCandidate": .bool(true), "web.inlineFragmentCount": .number(2)])
        WebLint.store(Rect(x: 100, y: 20, width: 200, height: 20), key: "web.inlineFragment0", in: &detail.attributes)
        WebLint.store(Rect(x: 20, y: 44, width: 100, height: 20), key: "web.inlineFragment1", in: &detail.attributes)
        let context = LintContext(viewport: viewport)
        var budget = WebLint.OverlapBudget()
        XCTAssertTrue(try WebLint.overlapFindings(document([first, detail]), context: context, budget: &budget).isEmpty)
        // Measured border padding really overlaps the label; descendant text
        // substitution would lose this collision.
        WebLint.store(Rect(x: 94, y: 18, width: 206, height: 24), key: "web.inlineFragment0", in: &detail.attributes)
        budget = WebLint.OverlapBudget()
        XCTAssertTrue(try WebLint.overlapFindings(document([first, detail]), context: context, budget: &budget)
            .contains { $0.nodeID == "detail" && $0.rule == "sibling-overlap" })
        detail.attributes.removeValue(forKey: "web.inlineFragment1Width")
        budget = WebLint.OverlapBudget()
        XCTAssertThrowsError(try WebLint.overlapFindings(document([first, detail]), context: context, budget: &budget))
        detail.attributes.removeValue(forKey: "web.inlineFragmentCount")
        budget = WebLint.OverlapBudget()
        XCTAssertThrowsError(try WebLint.overlapFindings(document([first, detail]), context: context, budget: &budget))
    }

    func testLongDocumentAndNonzeroScrollRetainFullEvidence() throws {
        for scroll in [0.0, 2400] {
            let tree = document([node("top", y: 20 - scroll), node("bottom", y: 3000 - scroll)], scroll: scroll)
            let report = try WebLint.run(tree: tree, scenario: "long", viewport: viewport)
            XCTAssertEqual(report.status, .pass, "\(report.findings)")
            XCTAssertEqual(report.tree, tree)
            XCTAssertEqual(report.tree?.frame, viewport, "input viewport must not become document extent")
            XCTAssertTrue(try XCTUnwrap(report.tree?.flattened().first { $0.id == "bottom" }).isVisible)
        }
    }

    func testNegativeAndFixedDisplacementStillFailWithOriginalIDs() throws {
        let tree = document([node("negative", x: -150, y: 100), node("fixed", y: 1000, position: "fixed")])
        let report = try WebLint.run(tree: tree, scenario: "displaced", viewport: viewport)
        XCTAssertEqual(Set(report.findings.filter { $0.rule == "offscreen" }.map(\.nodeID)), ["negative", "fixed"])
        XCTAssertEqual(report.tree, tree)
    }

    func testFixedAndFlowOverlapRemainObservableAcrossLintScopes() throws {
        for pair in [[node("first", y: 30, position: "fixed"), node("second", y: 30, position: "fixed")],
                     [node("first", y: 30), node("second", y: 30, position: "fixed")]] {
            let report = try WebLint.run(tree: document(pair), scenario: "overlap", viewport: viewport)
            XCTAssertTrue(report.findings.contains { $0.rule == "sibling-overlap" && $0.nodeID == "second" })
        }
    }

    func testEmbeddedDocumentDoesNotClipAtOwnerButOwnerRemainsChecked() throws {
        var child = node("child", y: 1400, frame: "child")
        WebLint.store(Rect(x: 10, y: 100, width: 500, height: 2000), key: "web.documentBounds", in: &child.attributes)
        WebLint.store(Rect(x: 10, y: 100, width: 500, height: 300), key: "web.documentViewport", in: &child.attributes)
        var owner = SemanticNode(id: "owner", role: .container, frame: Rect(x: 10, y: 100, width: 500, height: 300),
                                 attributes: ["web.frame": .string("main")], children: [child])
        let tree = document([owner], height: 600)
        XCTAssertEqual(try WebLint.run(tree: tree, scenario: "frame", viewport: viewport).status, .pass)
        owner.frame.x = -600
        let broken = try WebLint.run(tree: document([owner]), scenario: "owner", viewport: viewport)
        XCTAssertTrue(broken.findings.contains { $0.rule == "offscreen" && $0.nodeID == "owner" })
        var hidden = owner; hidden.isVisible = false
        let embedded = try WebFrameGeometry.embedding(child, in: hidden)
        XCTAssertFalse(embedded.isVisible)
        let visible = try WebFrameGeometry.embedding(child, in: owner)
        XCTAssertTrue(visible.isVisible, "scroll position must not hide CSS-visible child")
    }

    func testScrollPanelRetainsOwnerAndSeparatesContentClipping() throws {
        var owner = SemanticNode(id: "panel", role: .container, frame: Rect(x: 10, y: 100, width: 500, height: 300),
                                 attributes: ["web.frame": .string("main")], children: [node("bottom", y: 1400)])
        WebLint.store(Rect(x: 10, y: 100, width: 500, height: 2000), key: "web.scrollBounds", in: &owner.attributes)
        XCTAssertEqual(try WebLint.run(tree: document([owner], height: 600), scenario: "panel", viewport: viewport).status, .pass)
        owner.attributes = ["web.frame": .string("main"), "web.overflowY": .string("hidden")]
        let clipped = try WebLint.run(tree: document([owner]), scenario: "card", viewport: viewport)
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
            let report = try WebLint.run(tree: tree, scenario: "isolated paint", viewport: viewport)
            XCTAssertEqual(report.status, .pass, "\(report.findings)")
            XCTAssertTrue(try XCTUnwrap(report.tree?.flattened().first { $0.id == "inner" }).isVisible)
        }
    }

    func testFixedChildCannotEscapeOuterScrollPanelThroughIframe() throws {
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
        let report = try WebLint.run(tree: document([panel, node("outside", y: 250)]), scenario: "nested clip", viewport: viewport)
        XCTAssertEqual(report.status, .pass, "\(report.findings)")
    }

    func testTransformedAncestorPreventsViewportFixedClassification() throws {
        var ancestor = SemanticNode(id: "transform", role: .container, frame: Rect(x: 10, y: 1300, width: 500, height: 200),
                                    attributes: ["web.frame": .string("main"), "web.fixedContainer": .bool(true)],
                                    children: [node("fixed", y: 1320, position: "fixed")])
        XCTAssertEqual(try WebLint.run(tree: document([ancestor]), scenario: "transform", viewport: viewport).status, .pass)
        ancestor.attributes["web.fixedContainer"] = .bool(false)
        XCTAssertTrue(try WebLint.run(tree: document([ancestor]), scenario: "viewport", viewport: viewport).findings.contains {
            $0.rule == "offscreen" && $0.nodeID == "fixed"
        })
    }

    func testEmptyDocumentRemainsVacuousAndZeroExtentIsValid() throws {
        XCTAssertEqual(try WebLint.checkedRect(x: 0, y: 0, width: 0, height: 0), Rect(x: 0, y: 0, width: 0, height: 0))
        let report = try WebLint.run(tree: document([], height: 0), scenario: "empty", viewport: viewport)
        XCTAssertEqual(report.status, .fail)
        XCTAssertEqual(report.findings.map(\.rule), ["vacuous-verdict"])
    }

    func testHiddenOnlyFrameCannotSupplyVisibleEvidence() throws {
        var child = node("hidden-button", y: 40, frame: "child")
        child.isVisible = false
        let owner = SemanticNode(id: "", role: .container, frame: viewport,
                                 attributes: ["web.frame": .string("main")], isVisible: false, children: [child])
        let hiddenTree = document([owner])
        let hidden = try WebLint.run(tree: hiddenTree, scenario: "hidden", viewport: viewport)
        XCTAssertEqual(hidden.status, .fail)
        XCTAssertTrue(hidden.findings.contains { $0.rule == "vacuous-verdict" })
        XCTAssertEqual(hidden.tree, hiddenTree)
        var visible = owner; visible.isVisible = true; visible.children[0].isVisible = true
        XCTAssertEqual(try WebLint.run(tree: document([visible]), scenario: "visible frame", viewport: viewport).status, .pass)
    }

    func testInvalidAndOverflowedExtentsFailClosed() throws {
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

    func testVisibleFontInkIsNotClippedButHiddenAxisStillFails() throws {
        let ink = SemanticNode(id: "heading-text", role: .text, frame: Rect(x: 20, y: 99, width: 200, height: 38), text: "Heading")
        var heading = SemanticNode(id: "heading", role: .container, frame: Rect(x: 20, y: 100, width: 250, height: 36),
                                   attributes: ["web.frame": .string("main"), "web.overflowX": .string("visible"), "web.overflowY": .string("visible")], children: [ink])
        heading.children[0].attributes["web.frame"] = .string("main")
        XCTAssertEqual(try WebLint.run(tree: document([heading]), scenario: "ink", viewport: viewport).status, .pass)
        heading.attributes["web.overflowY"] = .string("hidden")
        let clipped = try WebLint.run(tree: document([heading]), scenario: "clip", viewport: viewport)
        XCTAssertTrue(clipped.findings.contains { $0.rule == "clipped-content" && $0.nodeID == "heading-text" })
        heading.attributes["web.overflowY"] = .string("visible")
        heading.attributes["web.overflowX"] = .string("clip")
        XCTAssertEqual(try WebLint.run(tree: document([heading]), scenario: "independent axes", viewport: viewport).status, .pass)
    }

    func testScrollPanelInsideHiddenCardDoesNotClipReachableContent() throws {
        var panel = SemanticNode(id: "panel", role: .container, frame: Rect(x: 20, y: 120, width: 400, height: 200),
            attributes: ["web.frame": .string("main"), "web.overflowX": .string("auto"), "web.overflowY": .string("auto")],
            children: [node("reachable", y: 1400)])
        WebLint.store(Rect(x: 20, y: 120, width: 400, height: 2000), key: "web.scrollBounds", in: &panel.attributes)
        WebLint.store(panel.frame, key: "web.scrollViewport", in: &panel.attributes)
        var card = SemanticNode(id: "card", role: .container, frame: Rect(x: 10, y: 100, width: 500, height: 300),
            attributes: ["web.frame": .string("main"), "web.overflowX": .string("hidden"), "web.overflowY": .string("hidden")], children: [panel])
        let report = try WebLint.run(tree: document([card], height: 600), scenario: "card panel", viewport: viewport)
        XCTAssertEqual(report.status, .pass, "\(report.findings)")
        card.children[0].frame.x = -50
        XCTAssertTrue(try WebLint.run(tree: document([card]), scenario: "clipped owner", viewport: viewport).findings.contains {
            $0.rule == "clipped-content" && $0.nodeID == "panel"
        })
    }

    func testTextFragmentsAvoidUnionOverlapAndRetainRealCollisionEvidence() throws {
        func text(_ id: String, _ frame: Rect) -> SemanticNode {
            SemanticNode(id: id, role: .text, frame: frame, text: id, attributes: ["web.frame": .string("main")])
        }
        let first = text("first", Rect(x: 20, y: 20, width: 100, height: 20))
        let codeText = text("code-text", Rect(x: 120, y: 20, width: 80, height: 20))
        let code = SemanticNode(id: "code", role: .container, frame: codeText.frame,
                                attributes: ["web.frame": .string("main")], children: [codeText])
        var wrapped = text("wrapped", Rect(x: 20, y: 20, width: 280, height: 50))
        wrapped.attributes["web.textFragmentCount"] = .number(2)
        WebLint.store(Rect(x: 200, y: 20, width: 100, height: 20), key: "web.textFragment0", in: &wrapped.attributes)
        WebLint.store(Rect(x: 20, y: 50, width: 140, height: 20), key: "web.textFragment1", in: &wrapped.attributes)
        let clean = document([first, code, wrapped])
        XCTAssertEqual(try WebLint.run(tree: clean, scenario: "inline", viewport: viewport).status, .pass)
        WebLint.store(Rect(x: 150, y: 20, width: 150, height: 20), key: "web.textFragment0", in: &wrapped.attributes)
        let broken = document([first, code, wrapped])
        let report = try WebLint.run(tree: broken, scenario: "collision", viewport: viewport)
        XCTAssertEqual(report.status, .fail)
        XCTAssertTrue(report.findings.contains { $0.nodeID == "wrapped" && ($0.rule == "sibling-overlap" || $0.rule == "content-overlap") })
        XCTAssertEqual(Set(report.findings.filter { $0.rule == "sibling-overlap" || $0.rule == "content-overlap" }.map(\.nodeID)), ["wrapped"])
        XCTAssertEqual(report.tree, broken)
        XCTAssertFalse(report.findings.contains { $0.nodeID.contains("paint-fragment") || $0.message.contains("paint-fragment") })
    }

    func testLineBreakIsLayoutOnlyAndCannotFabricateEvidence() throws {
        let br = SemanticNode(id: "br", role: .spacer, frame: Rect(x: 20, y: 20, width: 0, height: 75))
        let report = try WebLint.run(tree: document([br, node("button", y: 100)]), scenario: "line break", viewport: viewport)
        XCTAssertEqual(report.status, .pass)
        XCTAssertFalse(report.findings.contains { $0.rule == "zero-size" })
        XCTAssertTrue(try WebLint.run(tree: document([br]), scenario: "empty breaks", viewport: viewport).findings.contains { $0.rule == "vacuous-verdict" })
    }

    func testComputedContainingBlockPropertiesHaveIndependentWitnesses() throws {
        let defaults = ["block", "visible", "1", "auto", "static", "auto", "none", "visible", "visible", "none", "none", "none", "none", "auto"]
        XCTAssertFalse(WebLint.establishesFixedContainer(styles: defaults))
        for (index, value) in [(9, "matrix(1,0,0,1,0,0)"), (10, "blur(1px)"), (11, "100px"),
                               (12, "layout"), (12, "paint"), (12, "strict"), (12, "content"),
                               (13, "transform"), (13, "opacity, filter"), (13, "perspective"), (13, "contain")] {
            var styles = defaults; styles[index] = value
            XCTAssertTrue(WebLint.establishesFixedContainer(styles: styles), "\(index): \(value)")
        }
        var styles = defaults; styles[13] = "opacity"
        XCTAssertFalse(WebLint.establishesFixedContainer(styles: styles))
    }

    func fragmentedText(_ id: String, lines: Int, offset: Double = 0) -> SemanticNode {
        var text = SemanticNode(id: id, role: .text, frame: Rect(x: 20, y: offset, width: 100, height: Double(lines) * 20),
                                text: "Long text", attributes: ["web.frame": .string("main"), "web.textFragmentCount": .number(Double(lines))])
        for line in 0..<lines {
            WebLint.store(Rect(x: 20, y: offset + Double(line) * 20, width: 100, height: 8), key: "web.textFragment\(line)", in: &text.attributes)
        }
        return text
    }

    func testLongTextDoesNotExpandSubjectsOrCompareItsOwnFragments() throws {
        var text = fragmentedText("long", lines: 10_000)
        var budget = WebLint.OverlapBudget()
        let context = LintContext(viewport: viewport)
        XCTAssertTrue(try WebLint.overlapFindings(document([text], height: 200_100), context: context, budget: &budget).isEmpty)
        XCTAssertEqual(budget.originalPairs, 0)
        XCTAssertEqual(budget.fragmentComparisons, 0)
        XCTAssertEqual(budget.fragmentEvents, 0)
        XCTAssertEqual(budget.consumed, 0)
        // Measured same-original line ink can overlap by2px. It is still one
        // text subject and must never report that the node overlaps itself.
        text = fragmentedText("wrapped", lines: 2)
        WebLint.store(Rect(x: 20, y: 6, width: 100, height: 8), key: "web.textFragment1", in: &text.attributes)
        let report = try WebLint.run(tree: document([text]), scenario: "same text ink", viewport: viewport)
        XCTAssertEqual(report.status, .pass, "\(report.findings)")
    }

    func testInterleavedLongTextsUseBoundedSortedEvents() throws {
        let tree = document([fragmentedText("first", lines: 10_000), fragmentedText("second", lines: 10_000, offset: 10)], height: 200_100)
        var budget = WebLint.OverlapBudget()
        let findings = try WebLint.overlapFindings(tree, context: LintContext(viewport: viewport), budget: &budget)
        XCTAssertTrue(findings.isEmpty)
        XCTAssertEqual(budget.originalPairs, 1)
        XCTAssertEqual(budget.fragmentEvents, 20_000)
        XCTAssertEqual(budget.fragmentComparisons, 0)
        XCTAssertLessThanOrEqual(budget.consumed, 40_010)
    }

    func testOverlapBudgetExhaustionIsUnavailableAndNeverPartialPass() throws {
        let tree = document([node("first", y: 20), node("second", y: 20)])
        XCTAssertThrowsError(try WebLint.run(tree: tree, scenario: "budget", viewport: viewport, overlapLimit: 0)) { error in
            XCTAssertTrue(String(describing: error).contains("bounded work budget"))
        }
        var budget = WebLint.OverlapBudget(limit: 1)
        XCTAssertThrowsError(try WebLint.overlapFindings(tree, context: LintContext(viewport: viewport), budget: &budget))
        var siblingsOnly = LintContext(viewport: viewport)
        siblingsOnly.disabledRules = [ContentOverlapRule.id]
        budget = WebLint.OverlapBudget(limit: 0)
        let separated = document([node("first", y: 20), node("second", y: 100)])
        XCTAssertThrowsError(try WebLint.overlapFindings(separated, context: siblingsOnly, budget: &budget))
        // Disjoint fragment events still consume work before any comparison.
        let disjoint = document([fragmentedText("a", lines: 2), fragmentedText("b", lines: 2, offset: 10)])
        budget = WebLint.OverlapBudget(limit: 1)
        XCTAssertThrowsError(try WebLint.overlapFindings(disjoint, context: LintContext(viewport: viewport), budget: &budget))
        // One original pair plus its two events fit; the actual comparison does not.
        budget = WebLint.OverlapBudget(limit: 3)
        XCTAssertThrowsError(try WebLint.overlapFindings(tree, context: siblingsOnly, budget: &budget))
        var suppressed = tree
        suppressed.children[1].attributes[LintContext.suppressionKey] = .string("sibling-overlap")
        budget = WebLint.OverlapBudget()
        XCTAssertTrue(try WebLint.overlapFindings(suppressed, context: LintContext(viewport: viewport), budget: &budget).isEmpty)
        var context = LintContext(viewport: viewport)
        context.disabledRules = [SiblingOverlapRule.id, ContentOverlapRule.id]
        budget = WebLint.OverlapBudget(limit: 0)
        XCTAssertTrue(try WebLint.overlapFindings(tree, context: context, budget: &budget).isEmpty)
        suppressed.children[1].attributes.removeValue(forKey: LintContext.suppressionKey)
        suppressed.children[1].zIndex = 0
        budget = WebLint.OverlapBudget()
        XCTAssertTrue(try WebLint.overlapFindings(suppressed, context: LintContext(viewport: viewport), budget: &budget).isEmpty)
    }

    func testFindingDeduplicationPreservesEveryFieldAndHasLinearChargedWork() throws {
        let base = Finding(rule: "sibling-overlap", severity: .error, nodeID: "node", message: "collision", suggestion: "repair")
        var variations = [base]
        var value = base; value.rule = "content-overlap"; variations.append(value)
        value = base; value.severity = .warning; variations.append(value)
        value = base; value.nodeID = "other"; variations.append(value)
        value = base; value.message = "another collision"; variations.append(value)
        value = base; value.suggestion = nil; variations.append(value)
        var accumulator = WebLint.FindingAccumulator()
        var budget = WebLint.OverlapBudget(limit: variations.count * 2)
        try accumulator.append(variations + variations, budget: &budget)
        XCTAssertEqual(accumulator.values, variations)
        XCTAssertEqual(budget.consumed, variations.count * 2)
        XCTAssertThrowsError(try accumulator.append([base], budget: &budget))

        let count = 300
        let tree = document((0..<count).map { node("dense-\($0)", y: 20) })
        let report = try WebLint.run(tree: tree, scenario: "dense original nodes", viewport: viewport)
        XCTAssertEqual(report.findings.filter { $0.rule == "sibling-overlap" }.count, count * (count - 1) / 2)
        XCTAssertEqual(report.status, .fail)
    }

    func testFragmentPaintClipAppliesToActualBoxesNotOnlyUnion() throws {
        var wrapped = fragmentedText("wrapped", lines: 2)
        // The union intersects the visible window, but its first fragment is
        // horizontally outside the window and must not hit outside content.
        wrapped.frame = Rect(x: 0, y: 0, width: 200, height: 50)
        WebLint.store(Rect(x: 100, y: 0, width: 100, height: 10), key: "web.textFragment0", in: &wrapped.attributes)
        WebLint.store(Rect(x: 0, y: 30, width: 50, height: 10), key: "web.textFragment1", in: &wrapped.attributes)
        WebLint.store(Rect(x: 0, y: 0, width: 50, height: 50), key: "web.paintClip", in: &wrapped.attributes)
        let other = SemanticNode(id: "other", role: .text, frame: Rect(x: 120, y: 0, width: 50, height: 10), text: "outside")
        var budget = WebLint.OverlapBudget()
        XCTAssertTrue(try WebLint.overlapFindings(document([wrapped, other]), context: LintContext(viewport: viewport), budget: &budget).isEmpty)
    }

    func testClippedFragmentsConsumeRawWorkBeforeDecodingEvenWhenNoneSurvive() throws {
        for clip in [Rect(x: 20, y: 0, width: 100, height: 8), Rect(x: 400, y: 0, width: 20, height: 8)] {
            var text = fragmentedText("long clipped", lines: 10_000)
            WebLint.store(clip, key: "web.paintClip", in: &text.attributes)
            let tree = document([text, node("other", y: 0)], height: 200_100)
            var budget = WebLint.OverlapBudget(limit: 100)
            XCTAssertThrowsError(try WebLint.overlapFindings(tree, context: LintContext(viewport: viewport), budget: &budget))
            XCTAssertEqual(budget.consumed, 1, "raw fragment preflight must fail before decoding or filtering")
        }
    }

    func testEmptyClipOnlyHidesSupportedComputedFormsAndRestoresOnFocus() throws {
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
