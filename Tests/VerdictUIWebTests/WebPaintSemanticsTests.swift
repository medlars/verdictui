import XCTest
import VerdictUIKernel
@testable import VerdictUIWeb

final class WebPaintSemanticsTests: XCTestCase {
    private let viewport = Rect(x: 0, y: 0, width: 800, height: 600)
    private var context: LintContext { LintContext(scenario: "paint", viewport: viewport, requiresProbedNodes: false) }

    private func node(_ id: String, tag: String = "div", role: Role = .container,
                      x: Double = 20, y: Double = 20, width: Double = 100, height: Double = 50,
                      attributes: [String: AttributeValue] = [:], children: [SemanticNode] = []) -> SemanticNode {
        var measured: [String: AttributeValue] = [
            "web.tag": .string(tag), "web.frame": .string("main"),
            "web.interactionMeasured": .bool(true), "web.isClickable": .bool(false), "web.isFocusable": .bool(false),
        ]
        measured.merge(attributes) { _, supplied in supplied }
        return SemanticNode(id: id, role: role, frame: Rect(x: x, y: y, width: width, height: height),
                            attributes: measured, children: children)
    }

    private func tree(_ children: [SemanticNode]) -> SemanticNode {
        SemanticNode(id: "web/root", role: .container, frame: viewport, children: children).withAssignedStructuralPaths()
    }

    private func report(_ children: [SemanticNode]) throws -> Verdict {
        try WebLint.run(tree: tree(children), scenario: "paint", viewport: viewport)
    }

    private func overlaps(_ verdict: Verdict) -> [Finding] {
        verdict.findings.filter { [SiblingOverlapRule.id, ContentOverlapRule.id].contains($0.rule) }
    }

    private func positioning(_ node: SemanticNode, depth: Int, root: Int? = nil, block: Int? = nil) -> SemanticNode {
        var result = node
        result.attributes["web.domDepth"] = .number(Double(depth))
        if let root { result.attributes["web.positioningRootDepth"] = .number(Double(root)) }
        if let block { result.attributes["web.containingBlockDepth"] = .number(Double(block)) }
        return result
    }

    func testPositionedEscapeKeepsVisibleControlAndInheritedTextCollision() throws {
        for position in ["absolute", "fixed"] {
            for block in [1, 2] {
                let text = positioning(node("glyph", tag: "#text", role: .text, x: 200,
                    attributes: ["web.position": .string(position)]), depth: 4, root: 3, block: block)
                let escaping = positioning(node("escaping", tag: "button", role: .button, x: 200,
                    attributes: ["web.position": .string(position)], children: [text]), depth: 3, root: 3, block: block)
                let clip = positioning(node("clip", x: 0, width: 100, attributes: ["web.overflowX": .string("hidden"),
                    "web.fixedContainer": .bool(block == 2)], children: [escaping]), depth: 2)
                let outer = positioning(node("outer", x: 0, width: 500,
                    attributes: ["web.fixedContainer": .bool(true)], children: [clip]), depth: 1)
                let outside = positioning(node("outside", tag: "button", role: .button, x: 200), depth: 2)
                let verdict = try report([outer, outside])
                XCTAssertEqual(overlaps(verdict).contains { $0.nodeID == "outside" && $0.message.contains("escaping") }, block == 1)
                for id in ["escaping", "glyph"] {
                    XCTAssertEqual(verdict.findings.contains { $0.rule == ClippedContentRule.id && $0.nodeID == id }, block == 2)
                }
                XCTAssertEqual(verdict.tree, tree([outer, outside]))
            }
        }
    }

    func testPositionedRootOwnClipAndNestedClipsRemainEffective() throws {
        let leaf = positioning(node("leaf", tag: "button", role: .button, x: 250), depth: 5, root: 4, block: 3)
        let nested = positioning(node("nested", x: 200, width: 100, attributes: ["web.position": .string("absolute")], children: [leaf]),
                                 depth: 4, root: 4, block: 3)
        let escaping = positioning(node("escaping", x: 200, width: 100, attributes: ["web.position": .string("absolute")], children: [nested]),
                                   depth: 3, root: 3, block: 1)
        let clip = positioning(node("clip", x: 0, width: 100, attributes: ["web.overflowX": .string("clip")], children: [escaping]), depth: 2)
        let outer = positioning(node("outer", width: 500, children: [clip]), depth: 1)
        XCTAssertTrue(overlaps(try report([outer, node("outside", tag: "button", role: .button, x: 250)])).contains { $0.nodeID == "outside" })
        for depth in [3, 4] {
            var own = escaping
            if depth == 3 { own.attributes["web.overflowX"] = .string("hidden"); own.frame.width = 20 }
            else { own.children[0].attributes["web.overflowX"] = .string("hidden"); own.children[0].frame.width = 20 }
            var chain = outer; chain.children[0].children = [own]
            let verdict = try report([chain, node("outside", tag: "button", role: .button, x: 250)])
            XCTAssertTrue(verdict.findings.contains { $0.rule == ClippedContentRule.id && $0.nodeID == "leaf" })
            XCTAssertFalse(overlaps(verdict).contains { $0.nodeID == "outside" && $0.message.contains("leaf") })
        }
    }

    func testPositionedEscapeKeepsMeasuredFragmentsBeyondStaticClip() throws {
        var text = positioning(node("text", tag: "#text", role: .text, x: 200,
            attributes: ["web.position": .string("absolute"), "web.textFragmentCount": .number(1)]), depth: 3, root: 3, block: 1)
        WebLint.store(text.frame, key: "web.textFragment0", in: &text.attributes)
        let clip = positioning(node("clip", x: 0, width: 100, attributes: ["web.overflowX": .string("hidden")], children: [text]), depth: 2)
        let verdict = try report([positioning(node("outer", width: 500, children: [clip]), depth: 1),
                                 node("outside", tag: "button", role: .button, x: 200)])
        XCTAssertTrue(overlaps(verdict).contains { $0.nodeID == "outside" && $0.message.contains("text") })
        XCTAssertFalse(verdict.findings.contains { $0.rule == ClippedContentRule.id && $0.nodeID == "text" })
    }

    func testStaticScrollEscapeUsesEnclosingReachabilityAndSkipsExtraScrollComparisons() throws {
        let escaping = positioning(node("escaping", tag: "button", role: .button, y: 250,
            attributes: ["web.position": .string("absolute")]), depth: 4, root: 4, block: 1)
        let wrapper = positioning(node("wrapper", x: 0, y: 0, width: 100, height: 100, children: [escaping]), depth: 3)
        var scroll = positioning(node("scroll", x: 0, y: 0, width: 100, height: 100,
            attributes: ["web.overflowY": .string("auto")], children: [wrapper]), depth: 2)
        WebLint.store(scroll.frame, key: "web.scrollViewport", in: &scroll.attributes)
        WebLint.store(scroll.frame, key: "web.scrollBounds", in: &scroll.attributes)
        var outer = positioning(node("outer", x: 0, y: 0, width: 500, height: 500, children: [scroll]), depth: 1)
        let outside = node("outside", tag: "button", role: .button, y: 250)
        let verdict = try report([outer, outside])
        XCTAssertTrue(overlaps(verdict).contains { $0.nodeID == "outside" && $0.message.contains("escaping") })
        XCTAssertFalse(verdict.findings.contains { $0.rule == OffscreenRule.id && $0.nodeID == "escaping" })
        let flow = positioning(node("flow", tag: "button", role: .button, y: 250), depth: 3)
        scroll.children.append(flow)
        WebLint.store(Rect(x: 0, y: 0, width: 100, height: 500), key: "web.scrollBounds", in: &scroll.attributes)
        outer.children = [scroll]
        let separated = try report([outer])
        XCTAssertFalse(overlaps(separated).contains { $0.message.contains("escaping") && $0.message.contains("flow") })
        var retained = escaping; retained.attributes["web.containingBlockDepth"] = .number(2)
        outer.children[0].children[0].children = [retained]
        XCTAssertTrue(overlaps(try report([outer])).contains { $0.message.contains("escaping") && $0.message.contains("flow") })
    }

    func testPositioningProofRequiresFiniteOrderedSameFrameDepths() {
        let owner = positioning(node("clip"), depth: 2)
        let boundary = WebPaintSemantics.Boundary(WebPaintSemantics.Clip(owner.frame), owner: owner)
        let valid = positioning(node("target"), depth: 4, root: 3, block: 1)
        XCTAssertTrue(boundary.escaped(by: valid))
        for (key, value) in [("web.domDepth", AttributeValue.number(.infinity)), ("web.domDepth", .number(257)),
            ("web.domDepth", .number(2)), ("web.positioningRootDepth", .number(3.5)),
            ("web.containingBlockDepth", .number(-2)), ("web.containingBlockDepth", .number(3)),
            ("web.frame", .string("other")), ("web.frame", .string(""))] {
            var invalid = valid; invalid.attributes[key] = value
            XCTAssertFalse(boundary.escaped(by: invalid), key)
            if key != "web.frame" { XCTAssertNil(WebPaintSemantics.positioningRange(invalid), key) }
        }
        for key in ["web.domDepth", "web.positioningRootDepth", "web.containingBlockDepth", "web.frame"] {
            var missing = valid; missing.attributes.removeValue(forKey: key)
            XCTAssertFalse(boundary.escaped(by: missing), key)
        }
        for depth in [-1.0, 1, 3, 257, .infinity] {
            var changed = owner; changed.attributes["web.domDepth"] = .number(depth)
            XCTAssertFalse(WebPaintSemantics.Boundary(WebPaintSemantics.Clip(changed.frame), owner: changed).escaped(by: valid))
        }
        var emptyOwner = owner; emptyOwner.attributes["web.frame"] = .string("")
        var emptyTarget = valid; emptyTarget.attributes["web.frame"] = .string("")
        XCTAssertFalse(WebPaintSemantics.Boundary(WebPaintSemantics.Clip(emptyOwner.frame), owner: emptyOwner).escaped(by: emptyTarget))
        var viewportFixed = valid; viewportFixed.attributes["web.containingBlockDepth"] = .number(-1)
        XCTAssertTrue(boundary.escaped(by: viewportFixed))
    }

    func testStaticScrollerEscapeStillHonorsGenuineOuterClip() throws {
        let escaping = positioning(node("escaping", tag: "button", role: .button, y: 250,
            attributes: ["web.position": .string("absolute")]), depth: 3, root: 3, block: 1)
        var scroll = positioning(node("scroll", x: 0, y: 0, width: 100, height: 100,
            attributes: ["web.overflowY": .string("auto")], children: [escaping]), depth: 2)
        WebLint.store(scroll.frame, key: "web.scrollViewport", in: &scroll.attributes)
        WebLint.store(scroll.frame, key: "web.scrollBounds", in: &scroll.attributes)
        let outer = positioning(node("outer", x: 0, y: 0, width: 500, height: 150,
            attributes: ["web.overflowY": .string("hidden")], children: [scroll]), depth: 1)
        let verdict = try report([outer, node("outside", tag: "button", role: .button, y: 250)])
        XCTAssertTrue(verdict.findings.contains { $0.rule == ClippedContentRule.id && $0.nodeID == "escaping" })
        XCTAssertFalse(overlaps(verdict).contains { $0.message.contains("escaping") })
    }

    func testControlAndImageBorderOverlapCannotHideBehindSeparatedGlyphs() throws {
        for role in [Role.button, .textField, .image] {
            let first = node("first", tag: "button", role: role, x: 100, width: 120,
                children: [node("first-glyph", tag: "#text", role: .text, x: 105, width: 20)])
            let second = node("second", tag: "button", role: role, x: 200, width: 120,
                children: [node("second-glyph", tag: "#text", role: .text, x: 280, width: 20)])
            let wrapper = node("ordinary-wrapper", x: 0, width: 80, children: [first])
            let verdict = try report([wrapper, second])
            XCTAssertTrue(overlaps(verdict).contains { $0.rule == ContentOverlapRule.id && $0.nodeID == "second" && $0.message.contains("first") })
            XCTAssertEqual(verdict.tree, tree([wrapper, second]))
            var layered = first; layered.zIndex = 1
            var layeredWrapper = wrapper; layeredWrapper.children = [layered]
            XCTAssertFalse(overlaps(try report([layeredWrapper, second])).contains { $0.message.contains("first") })
            let siblings = try report([first, second])
            XCTAssertTrue(overlaps(siblings).contains { $0.rule == SiblingOverlapRule.id })
            XCTAssertFalse(overlaps(siblings).contains { $0.rule == ContentOverlapRule.id })
        }
    }

    func testEscapingScrollScopeCannotResurrectEarlierClipsForNestedPositionedControls() throws {
        let first = positioning(node("first", tag: "button", role: .button, x: 220, y: 300,
            attributes: ["web.position": .string("absolute")]), depth: 4, root: 4, block: 3)
        var second = first; second.id = "second"
        var scroll = positioning(node("scroll", x: 200, y: 0, width: 200, height: 100,
            attributes: ["web.position": .string("absolute"), "web.overflowY": .string("auto")], children: [first, second]), depth: 3, root: 3, block: 1)
        WebLint.store(scroll.frame, key: "web.scrollViewport", in: &scroll.attributes)
        WebLint.store(Rect(x: 200, y: 0, width: 200, height: 500), key: "web.scrollBounds", in: &scroll.attributes)
        let clip = positioning(node("clip", x: 0, y: 0, width: 100, height: 100,
            attributes: ["web.overflowX": .string("hidden")], children: [scroll]), depth: 2)
        let outer = positioning(node("outer", x: 0, y: 0, width: 600, height: 600, children: [clip]), depth: 1)
        XCTAssertTrue(overlaps(try report([outer])).contains { $0.nodeID == "second" && $0.message.contains("first") })
    }

    func testMeasuredFixedContainingBlockSurvivesOmittedSemanticAncestor() throws {
        let fixed = positioning(node("fixed", tag: "button", role: .button, y: 700,
            attributes: ["web.position": .string("fixed")]), depth: 3, root: 3, block: 1)
        var document = positioning(node("document", x: 0, y: 0, width: 800, height: 1000, children: [fixed]), depth: 0)
        WebLint.store(document.frame, key: "web.documentBounds", in: &document.attributes)
        WebLint.store(viewport, key: "web.documentViewport", in: &document.attributes)
        XCTAssertFalse(try report([document]).findings.contains { $0.rule == OffscreenRule.id && $0.nodeID == "fixed" })
        document.children[0].attributes["web.containingBlockDepth"] = .number(-1)
        XCTAssertTrue(try report([document]).findings.contains { $0.rule == OffscreenRule.id && $0.nodeID == "fixed" })
    }

    func testIndividualTransformsAndWillChangeEstablishContainingBlocks() {
        var styles = Array(repeating: "none", count: 36)
        XCTAssertFalse(WebLint.establishesFixedContainer(styles: styles))
        for (index, value) in [(33, "0px"), (34, "0deg"), (35, "1")] {
            styles[index] = value
            XCTAssertTrue(WebLint.establishesFixedContainer(styles: styles), "individual transform \(index)")
            styles[index] = "none"
        }
        for property in ["translate", "rotate", "scale"] {
            styles[13] = property
            XCTAssertTrue(WebLint.establishesFixedContainer(styles: styles), property)
        }
        styles[13] = "opacity"
        XCTAssertFalse(WebLint.establishesFixedContainer(styles: styles))
        XCTAssertFalse(WebLint.establishesFixedContainer(styles: Array(styles.prefix(14))))
    }

    func testOverlapScopeDiscoveryAndReachableCopiesShareWorkBudget() throws {
        let single = tree([node("single")])
        XCTAssertThrowsError(try WebLint.run(tree: single, scenario: "bounded", viewport: viewport, overlapLimit: 0))
        var nested = node("leaf")
        for index in 0..<5 {
            var scroll = node("scroll-\(index)", x: 0, y: 0, width: 200, height: 100,
                attributes: ["web.overflowY": .string("auto")], children: [nested])
            WebLint.store(scroll.frame, key: "web.scrollViewport", in: &scroll.attributes)
            WebLint.store(scroll.frame, key: "web.scrollBounds", in: &scroll.attributes)
            nested = scroll
        }
        let source = tree([nested])
        XCTAssertThrowsError(try WebLint.run(tree: source, scenario: "bounded", viewport: viewport, overlapLimit: 7)) { error in
            guard case WebBrowserError.invalidWebOperation = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(try WebLint.run(tree: source, scenario: "bounded", viewport: viewport, overlapLimit: 100).status, .pass)
    }

    func testPassiveSVGCompositionIsAtomicButOwnerStillCollides() throws {
        let svg = node("icon", tag: "svg", role: .image, children: [node("path-a", tag: "path"), node("path-b", tag: "path")])
        let source = tree([svg])
        let verdict = try WebLint.run(tree: source, scenario: "svg", viewport: viewport)
        XCTAssertTrue(overlaps(verdict).isEmpty, "\(verdict.findings)")
        XCTAssertEqual(verdict.tree, source)
        XCTAssertEqual(verdict.tree?.flattened().map(\.id), ["web/root", "icon", "path-a", "path-b"])
        let ownerCollision = try report([svg, node("button", tag: "button", role: .button)])
        XCTAssertTrue(overlaps(ownerCollision).contains { $0.nodeID == "button" && $0.severity == .error })
        XCTAssertFalse(ownerCollision.findings.contains { $0.rule == WebPaintSemantics.unverifiedRule })
    }

    func testSVGTextLinksForeignContentLabelsAndInteractionPreventAtomicity() {
        var labelled = node("labelled", tag: "path")
        labelled.attributes["accessibilityLabel"] = .string("chart series")
        var text = node("glyphs", tag: "text")
        text.text = "data"
        let controls = [
            node("text", tag: "#text", role: .text), text,
            node("link", tag: "a", role: .button), node("foreign", tag: "foreignobject"),
            node("reference", tag: "use"), node("role-control", tag: "path", role: .button),
            node("group", tag: "g", children: [node("nested-text", tag: "#text", role: .text)]),
            node("click", tag: "path", attributes: ["web.isClickable": .bool(true)]),
            node("focus", tag: "path", attributes: ["web.isFocusable": .bool(true)]), labelled,
            node("unmeasured", tag: "path", attributes: ["web.interactionMeasured": .bool(false)]),
        ]
        for control in controls {
            let svg = node("icon", tag: "svg", role: .image, children: [node("shape", tag: "path"), control])
            let projected = WebPaintSemantics.project(svg, context: context)
            XCTAssertEqual(projected.tree.children.count, 2, control.id)
            XCTAssertFalse(WebPaintSemantics.isPresentation(projected.tree), control.id)
        }
    }

    func testSVGInsideControlKeepsOwnerWhileGenericInteractiveDescendantsRemainMeaningful() {
        let svg = node("icon", tag: "svg", role: .image, children: [node("path", tag: "path")])
        for interactive in [node("button", tag: "button", role: .button),
                            node("click", attributes: ["web.isClickable": .bool(true)]),
                            node("focus", attributes: ["web.isFocusable": .bool(true)]),
                            node("omitted-ancestor", attributes: ["web.hasInteractiveAncestor": .bool(true)])] {
            var source = interactive
            source.children = [svg, node("control-part")]
            let projected = WebPaintSemantics.project(source, context: context).tree
            XCTAssertFalse(WebPaintSemantics.isPresentation(projected))
            XCTAssertEqual(projected.children.map(\.id), ["icon", "control-part"])
            XCTAssertTrue(projected.children[0].children.isEmpty)
            XCTAssertFalse(WebPaintSemantics.isPresentation(projected.children[1]))
        }
    }

    func testPresentationClippingAndOpaquePointerInertOverlayStayUnverified() throws {
        // Pointer transparency says nothing about an opaque layer's occlusion.
        let mesh = node("mesh", x: 0, y: 0, width: 150, height: 100,
                        attributes: ["web.pointerEvents": .string("none"), "web.backgroundColor": .string("rgb(0, 0, 0)")])
        let owner = node("clip", width: 100, height: 100, attributes: ["web.overflowX": .string("hidden")], children: [mesh])
        let verdict = try report([owner, node("button", tag: "button", role: .button, x: 40, y: 40)])
        let uncertain = verdict.findings.filter { $0.rule == WebPaintSemantics.unverifiedRule }
        XCTAssertTrue(uncertain.contains { $0.nodeID == "mesh" && $0.message.contains("clipping") })
        XCTAssertTrue(uncertain.contains { $0.nodeID == "button" && $0.message.contains("overlaps") })
        XCTAssertTrue(uncertain.allSatisfy { $0.severity == .warning && $0.message.contains("unverified") })
        XCTAssertTrue(overlaps(verdict).isEmpty)
        XCTAssertFalse(verdict.findings.contains { $0.rule == ClippedContentRule.id && $0.nodeID == "mesh" })
        XCTAssertEqual(verdict.tree, tree([owner, node("button", tag: "button", role: .button, x: 40, y: 40)]))
    }

    func testMeaningfulOrUnmeasuredContentNeverBecomesPresentation() throws {
        var labelled = node("labelled")
        labelled.attributes["accessibilityLabel"] = .string("loading status")
        var directText = node("direct-text"); directText.text = "visible"
        let controls = [labelled, directText,
                        node("text", tag: "#text", role: .text), node("role-text", role: .text), node("image", tag: "img", role: .image),
                        node("button", tag: "button", role: .button),
                        node("click", attributes: ["web.isClickable": .bool(true)]),
                        node("focus", attributes: ["web.isFocusable": .bool(true)]),
                        node("unknown", attributes: ["web.interactionMeasured": .bool(false)]),
                        node("canvas", tag: "canvas")]
        for child in controls {
            let source = node("wrapper", children: [child])
            let projected = WebPaintSemantics.project(source, context: context).tree
            XCTAssertFalse(WebPaintSemantics.isPresentation(projected), child.id)
            XCTAssertFalse(WebPaintSemantics.isPresentation(projected.children[0]), child.id)
            let clip = node("clip", x: 40, width: 20, attributes: ["web.overflowX": .string("hidden")], children: [source])
            XCTAssertTrue(try report([clip]).findings.contains {
                $0.rule == ClippedContentRule.id && $0.nodeID == "wrapper" && $0.severity == .error
            }, child.id)
        }
    }

    func testCSSPaintClipsOnlySpecifiedAxisAndKeepsRealClippedContentError() throws {
        let text = node("text", tag: "#text", role: .text, x: 120, y: 120)
        for axis in ["X", "Y"] {
            let clip = node("clip", x: 0, y: 0, width: 100, height: 100,
                            attributes: ["web.overflow" + axis: .string("hidden")], children: [text])
            let verdict = try report([clip, node("outside", tag: "button", role: .button, x: 120, y: 120)])
            XCTAssertTrue(overlaps(verdict).isEmpty, "\(verdict.findings)")
            XCTAssertTrue(verdict.findings.contains { $0.rule == ClippedContentRule.id && $0.nodeID == "text" && $0.severity == .error })
            var unclippedAxis = text
            if axis == "X" { unclippedAxis.frame.x = 20 } else { unclippedAxis.frame.y = 20 }
            var changed = clip; changed.children = [unclippedAxis]
            var outside = node("outside", tag: "button", role: .button)
            outside.frame = unclippedAxis.frame
            XCTAssertTrue(try report([changed, outside]).findings.contains { $0.rule == ContentOverlapRule.id && $0.nodeID == "outside" })
        }
    }

    func testCSSClipAlsoAppliesToTextFragmentPaint() throws {
        var text = node("text", tag: "#text", role: .text, x: 0, y: 0, width: 300, height: 100)
        text.attributes["web.textFragmentCount"] = .number(2)
        WebLint.store(Rect(x: 0, y: 0, width: 50, height: 50), key: "web.textFragment0", in: &text.attributes)
        WebLint.store(Rect(x: 150, y: 60, width: 100, height: 40), key: "web.textFragment1", in: &text.attributes)
        let clip = node("clip", x: 0, y: 0, width: 100, height: 100, attributes: ["web.overflowX": .string("clip")], children: [text])
        let outside = node("outside", tag: "button", role: .button, x: 160, y: 60)
        XCTAssertTrue(overlaps(try report([clip, outside])).isEmpty)
        let inside = node("inside", tag: "button", role: .button, x: 10, y: 10)
        XCTAssertTrue(try report([clip, inside]).findings.contains { $0.rule == ContentOverlapRule.id && $0.nodeID == "inside" })
    }

    func testFixedPaintEscapesOrdinaryCSSClipButNotTransformedClip() throws {
        let fixed = node("fixed", tag: "button", role: .button, y: 200, attributes: ["web.position": .string("fixed")])
        for transformed in [false, true] {
            let clip = node("clip", x: 0, y: 0, width: 200, height: 100,
                            attributes: ["web.overflowY": .string("hidden"), "web.fixedContainer": .bool(transformed)], children: [fixed])
            let verdict = try report([clip, node("outside", tag: "button", role: .button, y: 200)])
            XCTAssertEqual(overlaps(verdict).contains { $0.nodeID == "outside" }, !transformed)
            XCTAssertEqual(verdict.findings.contains { $0.rule == ClippedContentRule.id && $0.nodeID == "fixed" }, transformed)
        }
    }

    func testFixedChildCannotEscapeOuterCSSClipThroughIframe() throws {
        var fixed = node("fixed", tag: "button", role: .button, y: 200,
                         attributes: ["web.position": .string("fixed"), "web.frame": .string("child")])
        let childViewport = Rect(x: 0, y: 0, width: 300, height: 400)
        WebLint.store(childViewport, key: "web.documentViewport", in: &fixed.attributes)
        WebLint.store(childViewport, key: "web.documentBounds", in: &fixed.attributes)
        let iframe = node("iframe", tag: "iframe", x: 0, y: 0, width: 300, height: 400, children: [fixed])
        let clip = node("clip", x: 0, y: 0, width: 300, height: 100,
                        attributes: ["web.overflowY": .string("clip")], children: [iframe])
        let verdict = try report([clip, node("outside", tag: "button", role: .button, y: 200)])
        XCTAssertFalse(overlaps(verdict).contains { $0.nodeID == "outside" && $0.message.contains("fixed") })
        XCTAssertTrue(verdict.findings.contains { $0.rule == ClippedContentRule.id && $0.nodeID == "iframe" })
    }

    func testSVGInternalClipRemainsUnverifiedAndOwnerClipStillErrors() throws {
        let path = node("stroke", tag: "path", x: 19, width: 102)
        let svg = node("icon", tag: "svg", role: .image, attributes: ["web.overflowX": .string("hidden")], children: [path])
        let verdict = try report([svg])
        XCTAssertTrue(verdict.findings.contains { $0.rule == WebPaintSemantics.unverifiedRule && $0.nodeID == "stroke" && $0.severity == .warning })
        XCTAssertFalse(verdict.findings.contains { $0.rule == ClippedContentRule.id && $0.nodeID == "stroke" })
        var suppressed = svg
        suppressed.children[0].attributes[LintContext.suppressionKey] = .string(ClippedContentRule.id)
        XCTAssertFalse(try report([suppressed]).findings.contains { $0.rule == WebPaintSemantics.unverifiedRule })
        let clip = node("clip", x: 30, width: 50, attributes: ["web.overflowX": .string("hidden")], children: [svg])
        XCTAssertTrue(try report([clip]).findings.contains { $0.rule == ClippedContentRule.id && $0.nodeID == "icon" && $0.severity == .error })
    }

    func testTextCollisionAndCrossRowControlsRemainErrors() throws {
        for role in [Role.text, .button, .image] {
            let first = node("first", tag: "content", role: role)
            let second = node("second", tag: "content", role: role)
            let rows = [node("row-a", children: [first]), node("row-b", children: [second])]
            XCTAssertTrue(try report(rows).findings.contains { $0.rule == ContentOverlapRule.id && $0.nodeID == "second" && $0.severity == .error })
        }
    }

    func testClassificationCannotBeForgedAndWarningsHonorSuppression() throws {
        let forged = node("button", tag: "button", role: .button, attributes: [WebPaintSemantics.presentationKey: .bool(true)])
        XCTAssertFalse(WebPaintSemantics.isPresentation(WebPaintSemantics.project(forged, context: context).tree))
        let decoration = WebPaintSemantics.project(node("mesh"), context: context).tree
        for rule in [WebPaintSemantics.unverifiedRule, SiblingOverlapRule.id] {
            var second = decoration; second.attributes[LintContext.suppressionKey] = .string(rule)
            let finding = WebPaintSemantics.finding(rule: SiblingOverlapRule.id, node: second, other: forged,
                                                   message: "collision", suggestion: "inspect", context: context)
            XCTAssertNil(finding, rule)
        }
        XCTAssertThrowsError(try WebLint.run(tree: tree([node("mesh"), forged]), scenario: "budget", viewport: viewport, overlapLimit: 0))
        let empty = try report([])
        XCTAssertTrue(empty.findings.contains { $0.rule == "vacuous-verdict" && $0.severity == .error })
    }

    func testReachableScrollScopeRetainsHiddenAxisWithoutLosingScrollableAxis() throws {
        for axis in ["X", "Y"] {
            for hidden in [false, true] {
                let x = axis == "X" ? (hidden ? 150.0 : 20) : 200
                let y = axis == "Y" ? (hidden ? 150.0 : 20) : 200
                let children = [node("first", tag: "button", role: .button, x: x, y: y, width: 50),
                                node("second", tag: "button", role: .button, x: x, y: y, width: 50)]
                var panel = node("panel", x: 0, y: 0, width: 100, height: 100,
                    attributes: ["web.overflow" + axis: .string("hidden"),
                                 "web.overflow" + (axis == "X" ? "Y" : "X"): .string("scroll")], children: children)
                WebLint.store(Rect(x: 0, y: 0, width: 500, height: 500), key: "web.scrollBounds", in: &panel.attributes)
                WebLint.store(panel.frame, key: "web.scrollViewport", in: &panel.attributes)
                XCTAssertEqual(overlaps(try report([panel])).contains { $0.nodeID == "second" }, !hidden, axis)
            }
        }
    }

    func testReachableScrollScopeRetainsAncestorClipOnItsNonScrollingAxis() throws {
        for axis in ["X", "Y"] {
            let x = axis == "X" ? 150.0 : 20
            var panel = node("panel", x: 0, y: 0, width: 100, height: 100,
                             attributes: ["web.overflowY": .string("scroll")], children: [
                                node("first", tag: "button", role: .button, x: x, y: 200),
                                node("second", tag: "button", role: .button, x: x, y: 200),
                             ])
            WebLint.store(Rect(x: 0, y: 0, width: 500, height: 500), key: "web.scrollBounds", in: &panel.attributes)
            WebLint.store(panel.frame, key: "web.scrollViewport", in: &panel.attributes)
            let ancestor = node("ancestor", x: 0, y: 0, width: 100, height: 100,
                                attributes: ["web.overflow" + axis: .string("clip")], children: [panel])
            XCTAssertEqual(overlaps(try report([ancestor])).contains { $0.nodeID == "second" }, axis == "Y")
        }
    }

    func testViewportFixedScrollScopeEscapesAncestorCSSClip() throws {
        var panel = node("panel", x: 150, y: 0, width: 100, height: 100,
                         attributes: ["web.overflowY": .string("scroll"), "web.position": .string("fixed")], children: [
                            node("first", tag: "button", role: .button, x: 150, y: 200),
                            node("second", tag: "button", role: .button, x: 150, y: 200),
                         ])
        WebLint.store(Rect(x: 150, y: 0, width: 100, height: 500), key: "web.scrollBounds", in: &panel.attributes)
        WebLint.store(panel.frame, key: "web.scrollViewport", in: &panel.attributes)
        let ancestor = node("ancestor", x: 0, y: 0, width: 100, height: 500,
                            attributes: ["web.overflowX": .string("hidden")], children: [panel])
        XCTAssertTrue(overlaps(try report([ancestor])).contains { $0.nodeID == "second" })
    }

    func testReachableScrollScopeRetainsFixedContainerAncestry() throws {
        for transformed in [false, true] {
            var panel = node("panel", x: 0, y: 0, width: 100, height: 100,
                attributes: ["web.overflowX": .string("hidden"), "web.overflowY": .string("scroll")], children: [
                    node("first", tag: "button", role: .button, x: 150, y: 200, attributes: ["web.position": .string("fixed")]),
                    node("second", tag: "button", role: .button, x: 150, y: 200, attributes: ["web.position": .string("fixed")]),
                ])
            WebLint.store(Rect(x: 0, y: 0, width: 500, height: 500), key: "web.scrollBounds", in: &panel.attributes)
            WebLint.store(panel.frame, key: "web.scrollViewport", in: &panel.attributes)
            let ancestor = node("ancestor", x: 0, y: 0, width: 500, height: 500,
                                attributes: ["web.fixedContainer": .bool(transformed)], children: [panel])
            XCTAssertEqual(overlaps(try report([ancestor])).contains { $0.nodeID == "second" }, !transformed)
        }
    }

    func testIndependentDocumentScopeKeepsItsReachableInternalCollisions() throws {
        let children = ["first", "second"].map { id in
            var child = node(id, tag: "button", role: .button, x: 150, y: 200, attributes: ["web.frame": .string("child")])
            WebLint.store(Rect(x: 0, y: 0, width: 500, height: 500), key: "web.documentBounds", in: &child.attributes)
            WebLint.store(Rect(x: 0, y: 0, width: 100, height: 100), key: "web.documentViewport", in: &child.attributes)
            return child
        }
        var iframe = node("iframe", tag: "iframe", x: 0, y: 0, width: 100, height: 100,
            attributes: ["web.overflowX": .string("hidden"), "web.overflowY": .string("scroll")], children: children)
        WebLint.store(Rect(x: 0, y: 0, width: 500, height: 500), key: "web.scrollBounds", in: &iframe.attributes)
        WebLint.store(iframe.frame, key: "web.scrollViewport", in: &iframe.attributes)
        XCTAssertTrue(overlaps(try report([iframe])).contains { $0.nodeID == "second" })
        var panel = node("inner-panel", x: 0, y: 0, width: 500, height: 100,
                         attributes: ["web.frame": .string("child"), "web.overflowY": .string("scroll")], children: children)
        for key in ["web.documentBounds", "web.scrollBounds"] {
            WebLint.store(Rect(x: 0, y: 0, width: 500, height: 500), key: key, in: &panel.attributes)
        }
        WebLint.store(panel.frame, key: "web.scrollViewport", in: &panel.attributes)
        WebLint.store(Rect(x: 0, y: 0, width: 100, height: 100), key: "web.documentViewport", in: &panel.attributes)
        iframe.children = [panel]
        XCTAssertTrue(overlaps(try report([iframe])).contains { $0.nodeID == "second" })
    }

    private func fontNode(_ id: String, fragments: [Rect], inline: Bool = false,
                          frame: Rect = Rect(x: 0, y: 0, width: 200, height: 120)) -> SemanticNode {
        var result = node(id, tag: inline ? "span" : "#text", role: inline ? .container : .text,
            attributes: ["web.inlineFormattingContext": .string("main/42"), "web.fontBoxOnly": .bool(true)])
        result.frame = frame; result.text = "Heading"
        let key = inline ? "web.inlineFragment" : "web.textFragment"
        if inline { result.attributes["web.inlineCandidate"] = .bool(true) }
        result.attributes[key + "Count"] = .number(Double(fragments.count))
        for (index, rect) in fragments.enumerated() { WebLint.store(rect, key: key + String(index), in: &result.attributes) }
        return result
    }

    func testNormalFlowFontIntersectionUsesActualFragmentsAndStaysUnverified() throws {
        let first = fontNode("first", fragments: [Rect(x: 0, y: 0, width: 100, height: 30)])
        for inline in [false, true] {
            // Both union origins are zero; the actual intersecting lines differ.
            let second = fontNode("second", fragments: [Rect(x: 0, y: 20, width: 100, height: 30)], inline: inline)
            let verdict = try report([first, second])
            XCTAssertTrue(overlaps(verdict).isEmpty)
            XCTAssertTrue(verdict.findings.contains {
                $0.rule == WebPaintSemantics.unverifiedRule && $0.nodeID == "second" && $0.severity == .warning && $0.message.contains("glyph paint")
            })
            XCTAssertEqual(verdict.tree, tree([first, second]))
        }
    }

    func testLaterSameLineFragmentCollisionOverridesEarlierUncertainFontOverlap() throws {
        let first = fontNode("first", fragments: [Rect(x: 0, y: 0, width: 100, height: 30), Rect(x: 0, y: 80, width: 100, height: 30)])
        let second = fontNode("second", fragments: [Rect(x: 0, y: 20, width: 100, height: 30), Rect(x: 0, y: 80, width: 100, height: 30)])
        let verdict = try report([first, second])
        XCTAssertTrue(verdict.findings.contains { $0.rule == SiblingOverlapRule.id && $0.nodeID == "second" && $0.severity == .error })
        XCTAssertFalse(verdict.findings.contains { $0.rule == WebPaintSemantics.unverifiedRule })
        let pair = tree([first, second])
        var budget = WebLint.OverlapBudget()
        _ = try WebLint.overlapFindings(pair, context: context, budget: &budget)
        XCTAssertGreaterThanOrEqual(budget.fragmentComparisons, 2, "uncertain matches must not short circuit later candidates")
        var insufficient = WebLint.OverlapBudget(limit: 10)
        XCTAssertThrowsError(try WebLint.overlapFindings(pair, context: context, budget: &insufficient))
    }

    func testSameLineFontCollisionUsesFragmentsInsteadOfDifferentUnionOrigins() throws {
        let line = Rect(x: 0, y: 40, width: 100, height: 30)
        let first = fontNode("first", fragments: [line])
        let second = fontNode("second", fragments: [line], frame: Rect(x: 0, y: 20, width: 200, height: 100))
        XCTAssertTrue(try report([first, second]).findings.contains { $0.rule == SiblingOverlapRule.id && $0.severity == .error })
    }

    func testFontWarningRequiresBothMeasurementsSameContextAndTextOnlyRoles() throws {
        let first = fontNode("first", fragments: [Rect(x: 0, y: 0, width: 100, height: 30)])
        let second = fontNode("second", fragments: [Rect(x: 0, y: 20, width: 100, height: 30)])
        var cases: [SemanticNode] = []
        for attributes: [String: AttributeValue] in [
            ["web.fontBoxOnly": .bool(false), "web.position": .string("absolute")],
            ["web.fontBoxOnly": .bool(false), "web.borderTopWidth": .string("1px")],
            ["web.inlineFormattingContext": .string("main/99")], ["web.inlineFormattingContext": .string("")],
            ["web.frame": .string("other")],
        ] {
            var candidate = second; candidate.attributes.merge(attributes) { _, supplied in supplied }; cases.append(candidate)
        }
        var missing = second; missing.attributes.removeValue(forKey: "web.fontBoxOnly"); cases.append(missing)
        for role in [Role.button, .image, .container] {
            var candidate = second
            candidate.role = role
            candidate.frame = Rect(x: 0, y: 20, width: 200, height: 100)
            cases.append(candidate)
        }
        for candidate in cases {
            // Check both argument orders; one unqualified subject blocks warning.
            for pair in [[first, candidate], [candidate, first]] {
                XCTAssertTrue(try report(pair).findings.contains { $0.rule == SiblingOverlapRule.id && $0.severity == .error }, "\(candidate.attributes)")
            }
        }
        for key in ["web.inlineFormattingContext", "web.frame"] {
            var a = first, b = second
            a.attributes[key] = .string(""); b.attributes[key] = .string("")
            XCTAssertTrue(try report([a, b]).findings.contains { $0.rule == SiblingOverlapRule.id && $0.severity == .error })
        }
    }

    func testQualifiedFontUncertaintySurvivesCrossParentComparison() throws {
        let firstBox = Rect(x: 0, y: 0, width: 100, height: 30)
        let secondBox = Rect(x: 0, y: 20, width: 100, height: 30)
        var first = fontNode("branch1", fragments: [firstBox], inline: true)
        var second = fontNode("branch2", fragments: [secondBox], inline: true)
        first.children = [fontNode("first", fragments: [firstBox])]
        second.children = [fontNode("second", fragments: [secondBox])]
        let verdict = try report([first, second])
        XCTAssertTrue(overlaps(verdict).isEmpty)
        XCTAssertTrue(verdict.findings.contains {
            $0.rule == WebPaintSemantics.unverifiedRule && $0.nodeID == "second" && $0.message.contains("across different parents")
        })
    }

    func testFontUncertaintyCannotSuppressActualCSSClippingOrCrossRowErrors() throws {
        let first = fontNode("first", fragments: [Rect(x: 0, y: 0, width: 100, height: 30)])
        let second = fontNode("second", fragments: [Rect(x: 0, y: 20, width: 100, height: 30)])
        let clip = node("clip", x: 0, y: 0, width: 50, height: 120, attributes: ["web.overflowX": .string("hidden")], children: [first, second])
        XCTAssertTrue(try report([clip]).findings.contains { $0.rule == ClippedContentRule.id && $0.nodeID == "second" && $0.severity == .error })
        var otherRow = second; otherRow.attributes["web.inlineFormattingContext"] = .string("main/row2")
        let rows = [node("row1", children: [first]), node("row2", children: [otherRow])]
        XCTAssertTrue(try report(rows).findings.contains { $0.rule == ContentOverlapRule.id && $0.nodeID == "second" && $0.severity == .error })
    }
}
