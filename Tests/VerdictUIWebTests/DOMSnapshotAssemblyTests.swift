import XCTest
import VerdictUIKernel
@testable import VerdictUIWeb

final class DOMSnapshotAssemblyTests: XCTestCase {
    let viewport = Rect(x: 0, y: 0, width: 800, height: 600)

    func snapshot() -> [String: CDPValue] {
        let integer: (Int) -> CDPValue = { .integer(Int64($0)) }
        var payload: [String: CDPValue] = ["strings": .array(["#document", "BUTTON", "#text", "", "Save", "block", "visible", "1", "auto", "id", "save"].map(CDPValue.string)),
                "documents": .array([.object([
                    "nodes": .object([
                        "parentIndex": .array([-1, 0, 1].map(integer)), "nodeType": .array([9, 1, 3].map(integer)),
                        "nodeName": .array([0, 1, 2].map(integer)), "nodeValue": .array([3, 3, 4].map(integer)),
                        "backendNodeId": .array([1, 2, 3].map(integer)),
                        "attributes": .array([.array([]), .array([9, 10].map(integer)), .array([])])]),
                    "layout": .object(["nodeIndex": .array([1, 2].map(integer)),
                                       "bounds": .array([.array([20, 20, 120, 44].map(integer)), .array([30, 30, 35, 20].map(integer))]),
                                       "styles": .array([.array([5, 6, 7, 8].map(integer)), .array([5, 6, 7, 8].map(integer))])]),
                    "textBoxes": .object(["layoutIndex": .array([1].map(integer)), "bounds": .array([.array([30, 30, 35, 20].map(integer))])])])])]
        enrich(&payload)
        return payload
    }

    private func enrich(_ payload: inout [String: CDPValue]) {
        guard case var .array(strings) = payload["strings"], case var .array(documents) = payload["documents"] else { return }
        let extra = strings.count
        let additions = ["static", "auto", "none", "visible", "visible", "none", "none", "none", "none", "auto"] + DOMSnapshotAssembly.fontFlowDefaults
        strings += additions.map(CDPValue.string)
        for index in documents.indices {
            guard case var .object(document) = documents[index], case var .object(layout) = document["layout"],
                case let .array(styles) = layout["styles"] else { continue }
            document["contentWidth"] = .number(800); document["contentHeight"] = .number(600)
            document["scrollOffsetX"] = .number(0); document["scrollOffsetY"] = .number(0)
            layout["styles"] = .array(styles.map { row in
                guard case let .array(values) = row else { return row }
                return .array(values + (extra..<(extra + additions.count)).map { .integer(Int64($0)) })
            })
            document["layout"] = .object(layout); documents[index] = .object(document)
        }
        payload["strings"] = .array(strings); payload["documents"] = .array(documents)
    }

    private func snapshotWithUnlaidOwner(tag: String = "IFRAME", embedded: Bool = false) -> [String: CDPValue] {
        var payload = snapshot()
        guard case var .array(strings) = payload["strings"], case var .array(documents) = payload["documents"],
            case var .object(document) = documents[0], case var .object(nodes) = document["nodes"] else {
            preconditionFailure("invalid fixture")
        }
        let extra = strings.count
        strings += [.string(tag), .string("parent-frame"), .string("child-frame")]
        document["frameId"] = .integer(Int64(extra + 1))
        nodes["nodeName"] = .array([.integer(0), .integer(Int64(extra)), .integer(2)])
        // The owner has no layout box, while its raw DOM identity remains present.
        document["layout"] = .object(["nodeIndex": .array([]), "bounds": .array([]), "styles": .array([])])
        document["textBoxes"] = .object(["layoutIndex": .array([]), "bounds": .array([])])
        if embedded {
            nodes["contentDocumentIndex"] = .object(["index": .array([.integer(1)]), "value": .array([.integer(1)])])
            guard case var .object(child) = documents[0] else { preconditionFailure("invalid child fixture") }
            child["frameId"] = .integer(Int64(extra + 2))
            documents.append(.object(child))
        }
        document["nodes"] = .object(nodes); documents[0] = .object(document)
        payload["strings"] = .array(strings); payload["documents"] = .array(documents)
        return payload
    }

    func testInlineBorderFragmentsPreserveUnionAndRejectIncompleteOrChangedGeometry() throws {
        var payload = snapshot()
        guard case var .array(strings) = payload["strings"], case var .array(documents) = payload["documents"],
              case var .object(document) = documents[0] else { return XCTFail("fixture") }
        strings[5] = .string("inline")
        let first: CDPValue = .array([20, 20, 120, 20].map { .integer(Int64($0)) })
        let second: CDPValue = .array([20, 44, 50, 20].map { .integer(Int64($0)) })
        document["verdictInlineFragments"] = .object(["2": .array([first, second])])
        documents[0] = .object(document); payload["strings"] = .array(strings); payload["documents"] = .array(documents)
        let tree = try DOMSnapshotAssembly.assemble(payload, viewport: viewport)
        let button = try XCTUnwrap(tree.children.first)
        XCTAssertEqual(button.frame, Rect(x: 20, y: 20, width: 120, height: 44))
        XCTAssertEqual(button.attributes["web.inlineFragmentCount"], .number(2))
        XCTAssertEqual(WebLint.rect(key: "web.inlineFragment1", in: button.attributes), Rect(x: 20, y: 44, width: 50, height: 20))
        let owner = SemanticNode(id: "frame", role: .container, frame: Rect(x: 200, y: 300, width: 200, height: 200),
                                attributes: ["web.scaleX": .number(2), "web.scaleY": .number(2)])
        let embedded = try WebFrameGeometry.embedding(button, in: owner)
        XCTAssertEqual(WebLint.rect(key: "web.inlineFragment1", in: embedded.attributes), Rect(x: 240, y: 388, width: 100, height: 40))
        for malformed: CDPValue in [.object([:]), .object(["2": .array([])]), .object(["2": .array([first])]),
                                   .object(["2": .array([first, second]), "99": .null]),
                                   .object(["2": .array([.array([.number(.infinity), .integer(0), .integer(1), .integer(1)])])]),
                                   .object(["2": .array(Array(repeating: first, count: 100_001))])] {
            document["verdictInlineFragments"] = malformed; documents[0] = .object(document); payload["documents"] = .array(documents)
            XCTAssertThrowsError(try DOMSnapshotAssembly.assemble(payload, viewport: viewport))
        }
    }

    private func containingBlockSnapshot(position: String = "absolute", middlePosition: String = "static",
        outerTag: String = "DIV", outerTransform: String = "none", middleTransform: String = "none",
        unlaidMiddle: Bool = false) -> [String: CDPValue] {
        var payload = snapshot()
        guard case var .array(strings) = payload["strings"], case var .array(documents) = payload["documents"],
              case var .object(document) = documents[0], case let .object(layout) = document["layout"],
              case let .array(rows) = layout["styles"], case let .array(base) = rows[0] else { preconditionFailure("fixture") }
        func intern(_ text: String) -> CDPValue { let index = strings.count; strings.append(.string(text)); return .integer(Int64(index)) }
        let outer = intern(outerTag), middle = intern("DIV"), button = intern("BUTTON")
        var outerStyle = base, middleStyle = base, positionedStyle = base
        outerStyle[4] = intern("relative"); outerStyle[9] = intern(outerTransform)
        middleStyle[4] = intern(middlePosition); middleStyle[9] = intern(middleTransform)
        middleStyle[7] = intern("hidden"); middleStyle[8] = intern("hidden")
        positionedStyle[4] = intern(position)
        let ints: ([Int]) -> CDPValue = { .array($0.map { .integer(Int64($0)) }) }
        document["nodes"] = .object([
            "parentIndex": ints([-1, 0, 1, 2, 3]), "nodeType": ints([9, 1, 1, 1, 3]),
            "nodeName": .array([.integer(0), outer, middle, button, .integer(2)]),
            "nodeValue": ints([3, 3, 3, 3, 4]), "backendNodeId": ints([1, 2, 3, 4, 5]),
            "attributes": .array(Array(repeating: .array([]), count: 5))])
        let boxes = [ints([20, 20, 500, 300]), ints([20, 20, 100, 60]), ints([200, 20, 120, 44]), ints([210, 30, 35, 20])]
        let nodeRows = unlaidMiddle ? [1, 3, 4] : [1, 2, 3, 4]
        let styleRows = [outerStyle, middleStyle, positionedStyle, positionedStyle]
        document["layout"] = .object(["nodeIndex": ints(nodeRows),
            "bounds": .array(nodeRows.map { boxes[$0 - 1] }), "styles": .array(nodeRows.map { .array(styleRows[$0 - 1]) })])
        document["textBoxes"] = .object(["layoutIndex": ints([]), "bounds": .array([])])
        documents[0] = .object(document); payload["documents"] = .array(documents); payload["strings"] = .array(strings)
        return payload
    }

    func testContainingBlockDepthUsesRawDOMAndPropagatesToText() throws {
        for (outerTag, unlaid) in [("DIV", false), ("BODY", false), ("DIV", true)] {
            let tree = try DOMSnapshotAssembly.assemble(containingBlockSnapshot(outerTag: outerTag, unlaidMiddle: unlaid), viewport: viewport)
            let button = try XCTUnwrap(tree.flattened().first { $0.attributes["web.backendID"] == .number(4) })
            let text = try XCTUnwrap(tree.flattened().first { $0.attributes["web.backendID"] == .number(5) })
            XCTAssertEqual(button.attributes["web.domDepth"], .number(3))
            XCTAssertEqual(text.attributes["web.domDepth"], .number(4))
            for node in [button, text] {
                XCTAssertEqual(node.attributes["web.positioningRootDepth"], .number(3))
                XCTAssertEqual(node.attributes["web.containingBlockDepth"], .number(1))
            }
        }
    }

    func testContainingBlockDepthDistinguishesPositionAndTransformForAbsoluteAndFixed() throws {
        for (position, middle, outerTransform, middleTransform, expected) in [
            ("absolute", "relative", "none", "none", 2),
            ("absolute", "sticky", "none", "none", 2),
            ("absolute", "absolute", "none", "none", 2),
            ("absolute", "fixed", "none", "none", 2),
            ("absolute", "static", "none", "matrix(1, 0, 0, 1, 0, 0)", 2),
            ("fixed", "relative", "matrix(1, 0, 0, 1, 0, 0)", "none", 1),
            ("fixed", "relative", "none", "none", -1),
            ("fixed", "static", "none", "matrix(1, 0, 0, 1, 0, 0)", 2),
        ] {
            let tree = try DOMSnapshotAssembly.assemble(containingBlockSnapshot(position: position, middlePosition: middle,
                outerTransform: outerTransform, middleTransform: middleTransform), viewport: viewport)
            let button = try XCTUnwrap(tree.flattened().first { $0.attributes["web.backendID"] == .number(4) })
            XCTAssertEqual(button.attributes["web.containingBlockDepth"], .number(Double(expected)), "\(position)/\(middle)/\(outerTransform)/\(middleTransform)")
            let text = try XCTUnwrap(button.children.first)
            XCTAssertEqual(text.attributes["web.positioningRootDepth"], .number(3), "text must inherit, not create a positioned box from its inherited style")
        }
    }

    func testUnlaidContainingBoxesAndUnknownPositionsCannotInventEscapeProof() throws {
        let unlaid = try DOMSnapshotAssembly.assemble(containingBlockSnapshot(middlePosition: "relative", unlaidMiddle: true), viewport: viewport)
        let button = try XCTUnwrap(unlaid.flattened().first { $0.attributes["web.backendID"] == .number(4) })
        XCTAssertEqual(button.attributes["web.containingBlockDepth"], .number(1), "display:contents cannot establish a containing box")
        for position in ["absolute", "fixed"] {
            let unknown = try DOMSnapshotAssembly.assemble(containingBlockSnapshot(position: position, middlePosition: "unknown"), viewport: viewport)
            for node in unknown.flattened() where [4, 5].contains(node.attributes["web.backendID"]?.numberValue ?? 0) {
                XCTAssertNil(node.attributes["web.containingBlockDepth"], "unknown ancestry preserves ordinary clipping")
                XCTAssertNil(node.attributes["web.positioningRootDepth"])
            }
        }
    }

    private func fontFlowSnapshot(spanStyles: [Int: String] = [:], blockStyles: [Int: String] = [:],
                                  clickable: Bool = false, spanTag: String = "SPAN") -> [String: CDPValue] {
        var payload = snapshot()
        guard case var .array(strings) = payload["strings"], case var .array(documents) = payload["documents"],
              case var .object(document) = documents[0], case let .object(layout) = document["layout"],
              case let .array(rows) = layout["styles"], case let .array(base) = rows[0] else { preconditionFailure("fixture") }
        func intern(_ text: String) -> CDPValue { let index = strings.count; strings.append(.string(text)); return .integer(Int64(index)) }
        let h1 = intern("H1"), span = intern(spanTag), inline = intern("inline")
        var blockStyle = base, spanStyle = base; spanStyle[0] = inline
        for (index, value) in blockStyles { blockStyle[index] = intern(value) }
        for (index, value) in spanStyles { spanStyle[index] = intern(value) }
        let ints: ([Int]) -> CDPValue = { .array($0.map { .integer(Int64($0)) }) }
        document["nodes"] = .object([
            "parentIndex": ints([-1, 0, 1, 1, 3]), "nodeType": ints([9, 1, 3, 1, 3]),
            "nodeName": .array([.integer(0), h1, .integer(2), span, .integer(2)]),
            "nodeValue": ints([3, 3, 4, 3, 4]), "backendNodeId": ints([1, 2, 3, 4, 5]),
            "attributes": .array(Array(repeating: .array([]), count: 5)),
            "isClickable": .object(["index": ints(clickable ? [3] : [])])])
        document["layout"] = .object([
            "nodeIndex": ints([1, 2, 3, 4]),
            "bounds": .array([ints([20, 20, 600, 192]), ints([20, 20, 400, 110]),
                              ints([20, 116, 400, 110]), ints([20, 116, 400, 110])]),
            "styles": .array([.array(blockStyle), .array(blockStyle), .array(spanStyle), .array(spanStyle)])])
        document["textBoxes"] = .object(["layoutIndex": ints([1, 3]),
            "bounds": .array([ints([20, 20, 400, 110]), ints([20, 116, 400, 110])])])
        documents[0] = .object(document); payload["documents"] = .array(documents); payload["strings"] = .array(strings)
        return payload
    }

    func testInlineInventoryMatchesRetainedEditableEvidenceWithoutExposingValues() throws {
        for (attribute, value, childTag) in [("contenteditable", "true", "SPAN"), ("role", "textbox", "EM")] {
            var payload = fontFlowSnapshot(spanTag: childTag)
            guard case var .array(strings) = payload["strings"], case var .array(documents) = payload["documents"],
                  case var .object(document) = documents[0], case var .object(nodes) = document["nodes"],
                  case var .array(attributes) = nodes["attributes"] else { return XCTFail("fixture") }
            let secret = "private-editable-inline-sentinel"
            strings[4] = .string(secret)
            func intern(_ text: String) -> CDPValue { let index = strings.count; strings.append(.string(text)); return .integer(Int64(index)) }
            attributes[1] = .array([intern(attribute), intern(value), intern("aria-label"), intern("Message")])
            nodes["attributes"] = .array(attributes); document["nodes"] = .object(nodes)
            document["verdictInlineFragments"] = .object([:])
            documents[0] = .object(document); payload["documents"] = .array(documents); payload["strings"] = .array(strings)
            let tree = try DOMSnapshotAssembly.assemble(payload, viewport: viewport)
            let editor = try XCTUnwrap(tree.flattened().first { $0.role == .textField })
            XCTAssertEqual(editor.text, "Message")
            XCTAssertEqual(editor.attributes["web.value"], .string("[REDACTED]"))
            XCTAssertTrue(editor.children.isEmpty)
            XCTAssertFalse(String(decoding: try JSONEncoder().encode(tree), as: UTF8.self).contains(secret))
            document["verdictInlineFragments"] = .object(["4": .null])
            documents[0] = .object(document); payload["documents"] = .array(documents)
            XCTAssertThrowsError(try DOMSnapshotAssembly.assemble(payload, viewport: viewport), "pruned identities are not accepted as measured evidence")
        }
        var ordinary = fontFlowSnapshot()
        guard case var .array(documents) = ordinary["documents"], case var .object(document) = documents[0] else { return XCTFail("fixture") }
        document["verdictInlineFragments"] = .object([:]); documents[0] = .object(document); ordinary["documents"] = .array(documents)
        XCTAssertThrowsError(try DOMSnapshotAssembly.assemble(ordinary, viewport: viewport), "retained inline content must still have complete measurements")
    }

    func testFontBoxMetadataRequiresOneMeasuredNormalInlineFormattingContext() throws {
        for spanStyles in [[Int: String](), [27: "3px", 40: "none"], [30: "linear-gradient(red, blue)", 31: "text"]] {
            let tree = try DOMSnapshotAssembly.assemble(fontFlowSnapshot(spanStyles: spanStyles), viewport: viewport)
            let nodes = tree.flattened().filter { [3, 4, 5].contains($0.attributes["web.backendID"]?.numberValue ?? 0) }
            XCTAssertEqual(nodes.count, 3)
            XCTAssertTrue(nodes.allSatisfy { $0.attributes["web.fontBoxOnly"] == .bool(true) })
            XCTAssertEqual(Set(nodes.compactMap { $0.attributes["web.inlineFormattingContext"]?.stringValue }), ["main/2"])
            XCTAssertEqual(nodes.first?.frame.height, 110, "font boxes remain measured evidence")
        }
        for identity in ["matrix(1, 0, 0, 1, 0, 0)", "matrix3d(1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1)"] {
            let tree = try DOMSnapshotAssembly.assemble(fontFlowSnapshot(blockStyles: [9: identity]), viewport: viewport)
            XCTAssertEqual(tree.flattened().filter { $0.attributes["web.fontBoxOnly"] == .bool(true) }.count, 3)
        }
        let mixed = try DOMSnapshotAssembly.assemble(fontFlowSnapshot(spanStyles: [0: "block"]), viewport: viewport)
        let first = try XCTUnwrap(mixed.flattened().first { $0.attributes["web.backendID"] == .number(3) })
        let second = try XCTUnwrap(mixed.flattened().first { $0.attributes["web.backendID"] == .number(5) })
        XCTAssertNil(first.attributes["web.inlineFormattingContext"], "mixed block and inline runs need separate contexts")
        XCTAssertNotEqual(first.attributes["web.inlineFormattingContext"], second.attributes["web.inlineFormattingContext"])
    }

    func testPositionFloatTransformAndOffsetsCannotClaimNormalFontFlow() throws {
        for overrides in [[4: "relative"], [4: "absolute"], [14: "left"], [9: "matrix(1, 0, 0, 1, 10, 0)"], [9: "matrix(1, 0, 0, 1, 0, 1)"],
                          [10: "blur(2px)"], [11: "100px"], [33: "10px"], [34: "10deg"], [35: "2"], [18: "-10px"],
                          [18: "10px"], [32: "-10px"], [36: "5px"], [15: "unknown"]] {
            let tree = try DOMSnapshotAssembly.assemble(fontFlowSnapshot(spanStyles: overrides), viewport: viewport)
            let nodes = tree.flattened().filter { [4, 5].contains($0.attributes["web.backendID"]?.numberValue ?? 0) }
            XCTAssertTrue(nodes.allSatisfy { $0.attributes["web.fontBoxOnly"] != .bool(true) }, "\(overrides)")
            XCTAssertTrue(nodes.allSatisfy { $0.attributes["web.inlineFormattingContext"] == nil }, "\(overrides)")
        }
        for overrides in [[9: "matrix(1, 0, 0, 1, 10, 0)"], [15: "-5px"], [15: "infpx"]] {
            let tree = try DOMSnapshotAssembly.assemble(fontFlowSnapshot(blockStyles: overrides), viewport: viewport)
            XCTAssertFalse(tree.flattened().contains { $0.attributes["web.fontBoxOnly"] == .bool(true) })
        }
    }

    func testPaintedPaddedInteractiveAndReplacedInlineBoxesRemainOrdinaryEvidence() throws {
        for overrides in [[19: "2px"], [23: "2px"], [27: "2px", 40: "solid"], [28: "black 0px 0px 2px"],
                          [29: "rgb(255, 0, 0)"], [30: "linear-gradient(red, blue)"], [19: "unknown"]] {
            let tree = try DOMSnapshotAssembly.assemble(fontFlowSnapshot(spanStyles: overrides), viewport: viewport)
            let span = try XCTUnwrap(tree.flattened().first { $0.attributes["web.backendID"] == .number(4) })
            XCTAssertEqual(span.attributes["web.fontBoxOnly"], .bool(false), "\(overrides)")
        }
        for tag in ["BUTTON", "IMG", "INPUT"] {
            let tree = try DOMSnapshotAssembly.assemble(fontFlowSnapshot(spanTag: tag), viewport: viewport)
            let span = try XCTUnwrap(tree.flattened().first { $0.attributes["web.backendID"] == .number(4) })
            XCTAssertNotEqual(span.attributes["web.fontBoxOnly"], .bool(true), tag)
        }
        let clickable = try DOMSnapshotAssembly.assemble(fontFlowSnapshot(clickable: true), viewport: viewport)
        XCTAssertFalse(clickable.flattened().filter { [4, 5].contains($0.attributes["web.backendID"]?.numberValue ?? 0) }
            .contains { $0.attributes["web.fontBoxOnly"] == .bool(true) })
    }

    func testOmittedAncestorsRetainClickAndFocusEvidenceOnDescendants() throws {
        for (tag, unlaid, click, focus) in [("BODY", false, true, false), ("HTML", false, false, true),
                                          ("DIV", true, true, false), ("DIV", true, false, true),
                                          ("DIV", true, false, false)] {
            var payload = snapshot()
            guard case var .array(strings) = payload["strings"], case var .array(documents) = payload["documents"],
                  case var .object(document) = documents[0], case var .object(nodes) = document["nodes"],
                  case var .object(layout) = document["layout"], case let .array(styles) = layout["styles"] else {
                return XCTFail("fixture")
            }
            strings[1] = .string(tag)
            if focus { strings[9] = .string("tabindex"); strings[10] = .string("-1") }
            nodes["isClickable"] = .object(["index": .array(click ? [.integer(1)] : [])])
            if unlaid {
                layout["nodeIndex"] = .array([.integer(2)])
                layout["bounds"] = .array([.array([30, 30, 35, 20].map { .integer(Int64($0)) })])
                layout["styles"] = .array([styles[1]])
                document["textBoxes"] = .object(["layoutIndex": .array([]), "bounds": .array([])])
            }
            document["nodes"] = .object(nodes); document["layout"] = .object(layout)
            documents[0] = .object(document); payload["documents"] = .array(documents); payload["strings"] = .array(strings)
            let tree = try DOMSnapshotAssembly.assemble(payload, viewport: viewport)
            let text = try XCTUnwrap(tree.flattened().first { $0.role == .text })
            XCTAssertEqual(text.attributes["web.hasInteractiveAncestor"], .bool(click || focus))
            XCTAssertEqual(text.attributes["web.isClickable"], .bool(false))
            XCTAssertEqual(text.attributes["web.isFocusable"], .bool(false))
            XCTAssertFalse(tree.flattened().contains { $0.attributes["web.backendID"] == .number(2) })
        }
    }

    func testFocusabilityUsesExplicitDOMEvidenceConservatively() throws {
        for (tag, attribute, value, expected) in [
            ("DIV", "tabindex", "-1", true), ("DIV", "contenteditable", "", true),
            ("DIV", "contenteditable", "false", false), ("A", "href", "/local", true),
            ("A", "id", "link", false), ("DIV", "role", "button", true),
            ("DIV", "role", "presentation", false), ("VIDEO", "controls", "", true),
            ("SUMMARY", "id", "summary", true), ("SPAN", "id", "passive", false)] {
            var payload = snapshot()
            guard case var .array(strings) = payload["strings"], case var .array(documents) = payload["documents"],
                  case var .object(document) = documents[0], case var .object(nodes) = document["nodes"] else { return XCTFail("fixture") }
            strings[1] = .string(tag); strings[9] = .string(attribute); strings[10] = .string(value)
            nodes["isClickable"] = .object(["index": .array([])])
            document["nodes"] = .object(nodes); documents[0] = .object(document)
            payload["documents"] = .array(documents); payload["strings"] = .array(strings)
            let node = try XCTUnwrap(DOMSnapshotAssembly.assemble(payload, viewport: viewport).children.first)
            XCTAssertEqual(node.attributes["web.isFocusable"], .bool(expected), "\(tag) \(attribute)")
            XCTAssertEqual(node.attributes["web.isClickable"], .bool(false))
        }
    }

    func testClickableIndicesAndConservativeFocusableEvidenceAreValidated() throws {
        let unmeasured = try DOMSnapshotAssembly.assemble(snapshot(), viewport: viewport)
        XCTAssertEqual(unmeasured.children.first?.attributes["web.interactionMeasured"], .bool(false))
        var payload = snapshot()
        guard case var .array(documents) = payload["documents"], case var .object(document) = documents[0],
              case var .object(nodes) = document["nodes"] else { return XCTFail("fixture") }
        nodes["isClickable"] = .object(["index": .array([.integer(1)])])
        document["nodes"] = .object(nodes); documents[0] = .object(document); payload["documents"] = .array(documents)
        let tree = try DOMSnapshotAssembly.assemble(payload, viewport: viewport)
        let button = try XCTUnwrap(tree.children.first)
        XCTAssertEqual(button.attributes["web.isClickable"], .bool(true))
        XCTAssertEqual(button.attributes["web.isFocusable"], .bool(true))
        XCTAssertEqual(button.attributes["web.interactionMeasured"], .bool(true))
        XCTAssertEqual(button.children.first?.attributes["web.isClickable"], .bool(false))
        XCTAssertEqual(button.children.first?.attributes["web.isFocusable"], .bool(false))
        for invalid in [[-1], [3], [1, 1]] {
            nodes["isClickable"] = .object(["index": .array(invalid.map { .integer(Int64($0)) })])
            document["nodes"] = .object(nodes); documents[0] = .object(document); payload["documents"] = .array(documents)
            XCTAssertThrowsError(try DOMSnapshotAssembly.assemble(payload, viewport: viewport))
        }
    }

    func testUnlaidFrameOwnersPreserveIdentityWithoutInventingVisibleEvidence() throws {
        for tag in ["IFRAME", "FRAME"] {
            let tree = try DOMSnapshotAssembly.assemble(snapshotWithUnlaidOwner(tag: tag), viewport: viewport)
            let owner = try XCTUnwrap(tree.children.first)
            XCTAssertEqual(owner.attributes["web.backendID"], .number(2))
            XCTAssertEqual(owner.attributes["web.frame"], .string("parent-frame"))
            XCTAssertEqual(owner.attributes["web.id"], .string("save"))
            XCTAssertEqual(owner.role, .container)
            XCTAssertEqual(owner.id, "")
            XCTAssertTrue(owner.frame.isEmpty)
            XCTAssertFalse(owner.isVisible)
            let report = RuleEngine.run(rules: RuleEngine.standardRules, on: tree, context: LintContext(viewport: viewport))
            XCTAssertEqual(report.status, .fail)
            XCTAssertTrue(report.findings.contains { $0.rule == "vacuous-verdict" })
        }
    }

    func testUnlaidSameProcessFrameKeepsEmbeddedDocumentHidden() throws {
        let tree = try DOMSnapshotAssembly.assemble(snapshotWithUnlaidOwner(embedded: true), viewport: viewport)
        let owner = try XCTUnwrap(tree.children.first)
        XCTAssertEqual(owner.attributes["web.documentIndex"], .number(1))
        XCTAssertEqual(owner.children.first?.role, .button)
        XCTAssertFalse(owner.children.isEmpty)
        XCTAssertTrue(owner.flattened().allSatisfy { !$0.isVisible })
    }

    func testUnlaidRemoteFrameUsesExactOwnerAndNeverAcceptsUnknownOwner() throws {
        let tree = try DOMSnapshotAssembly.assemble(snapshotWithUnlaidOwner(), viewport: viewport)
        let child = SemanticNode(id: "child-button", role: .button, frame: Rect(x: 10, y: 20, width: 100, height: 44))
        let (joined, found) = try WebFrameGeometry.graft([child], ownerBackend: 2, ownerFrame: "parent-frame", into: tree)
        XCTAssertTrue(found)
        let nested = try XCTUnwrap(joined.flattened().first { $0.id == child.id })
        XCTAssertFalse(nested.isVisible)
        for (backend, frame) in [(3.0, "parent-frame"), (2.0, "wrong-parent")] {
            let (unchanged, accepted) = try WebFrameGeometry.graft([child], ownerBackend: backend, ownerFrame: frame, into: tree)
            XCTAssertFalse(accepted, "a missing or mismatched raw owner must remain unavailable")
            XCTAssertEqual(unchanged, tree)
        }
    }

    func testGenericUnlaidContainersDoNotHideVisibleDescendants() throws {
        var payload = snapshot()
        guard case var .array(strings) = payload["strings"], case var .array(documents) = payload["documents"],
            case var .object(document) = documents[0], case var .object(nodes) = document["nodes"],
            case var .object(layout) = document["layout"] else { return XCTFail("invalid fixture") }
        strings[1] = .string("DIV")
        nodes["nodeName"] = .array([.integer(0), .integer(1), .integer(2)])
        layout["nodeIndex"] = .array([.integer(2)])
        layout["bounds"] = .array([.array([30, 30, 35, 20].map { .integer(Int64($0)) })])
        if case let .array(styles) = layout["styles"] { layout["styles"] = .array([styles[0]]) }
        document["nodes"] = .object(nodes); document["layout"] = .object(layout)
        document["textBoxes"] = .object(["layoutIndex": .array([]), "bounds": .array([])])
        documents[0] = .object(document); payload["documents"] = .array(documents); payload["strings"] = .array(strings)
        let tree = try DOMSnapshotAssembly.assemble(payload, viewport: viewport)
        XCTAssertEqual(tree.children.count, 1)
        XCTAssertEqual(tree.children.first?.text, "Save")
        XCTAssertTrue(try XCTUnwrap(tree.children.first).isVisible, "display:contents does not hide rendered descendants")
    }

    func testSnapshotRolesGeometryTextAndMetrics() throws {
        let tree = try DOMSnapshotAssembly.assemble(snapshot(), viewport: viewport)
        let button = try XCTUnwrap(tree.children.first)
        XCTAssertEqual(button.role, .button)
        XCTAssertEqual(button.id, "web/2")
        XCTAssertEqual(button.attributes["web.id"], .string("save"))
        XCTAssertEqual(button.frame, Rect(x: 20, y: 20, width: 120, height: 44))
        let text = try XCTUnwrap(button.children.first)
        XCTAssertEqual(text.text, "Save")
        XCTAssertTrue(text.isVisible)
        XCTAssertEqual(text.textMetrics, TextMetrics(intrinsicWidth: 35, renderedLineCount: 1, idealLineCount: 1))
        XCTAssertFalse(text.structuralPath.isEmpty)
        XCTAssertEqual(RuleEngine.run(rules: RuleEngine.standardRules, on: tree,
                                     context: LintContext(viewport: viewport)).status, .pass)
    }

    private func fragmentedSnapshot(
        _ frames: [[Double]], tag: String = "#text", nodeType: Int = 3,
        textBoxRows: [Int] = [], opacity: String = "1", zIndex: String = "auto"
    ) -> [String: CDPValue] {
        let integers: ([Int]) -> CDPValue = { .array($0.map { .integer(Int64($0)) }) }
        let rectangles: ([[Double]]) -> CDPValue = { .array($0.map { .array($0.map(CDPValue.number)) }) }
        var payload: [String: CDPValue] = [
            "strings": .array(["#document", tag, "", "Save", "block", "visible", opacity, zIndex].map(CDPValue.string)),
            "documents": .array([.object([
                "nodes": .object([
                    "parentIndex": integers([-1, 0]), "nodeType": integers([9, nodeType]),
                    "nodeName": integers([0, 1]), "nodeValue": integers([2, nodeType == 3 ? 3 : 2]),
                    "backendNodeId": integers([1, 2]), "attributes": .array([.array([]), .array([])]),
                ]),
                "layout": .object([
                    "nodeIndex": integers(Array(repeating: 1, count: frames.count)),
                    "bounds": rectangles(frames),
                    "styles": .array(Array(repeating: integers([4, 5, 6, 7]), count: frames.count)),
                ]),
                "textBoxes": .object([
                    "layoutIndex": integers(textBoxRows),
                    "bounds": rectangles(textBoxRows.map { frames[$0] }),
                ]),
            ])]),
        ]
        enrich(&payload)
        return payload
    }

    func testDocumentExtentRequiredFiniteAndZeroDimensionsRemainValid() throws {
        for key in ["contentWidth", "contentHeight", "scrollOffsetX", "scrollOffsetY"] {
            for value in [CDPValue.number(.nan), .number(.infinity), .string("bad")] {
                var payload = snapshot()
                guard case var .array(documents) = payload["documents"], case var .object(document) = documents[0] else { return XCTFail("fixture") }
                document[key] = value; documents[0] = .object(document); payload["documents"] = .array(documents)
                XCTAssertThrowsError(try DOMSnapshotAssembly.assemble(payload, viewport: viewport), key)
            }
            var payload = snapshot()
            guard case var .array(documents) = payload["documents"], case var .object(document) = documents[0] else { return XCTFail("fixture") }
            document.removeValue(forKey: key); documents[0] = .object(document); payload["documents"] = .array(documents)
            XCTAssertThrowsError(try DOMSnapshotAssembly.assemble(payload, viewport: viewport), key)
        }
        var payload = snapshot()
        guard case var .array(documents) = payload["documents"], case var .object(document) = documents[0] else { return XCTFail("fixture") }
        document["contentWidth"] = .number(0); document["contentHeight"] = .number(0)
        document["layout"] = .object(["nodeIndex": .array([]), "bounds": .array([]), "styles": .array([])])
        document["textBoxes"] = .object(["layoutIndex": .array([]), "bounds": .array([])])
        documents[0] = .object(document); payload["documents"] = .array(documents)
        let tree = try DOMSnapshotAssembly.assemble(payload, viewport: viewport)
        XCTAssertTrue(tree.children.isEmpty)
        XCTAssertEqual(try WebLint.run(tree: tree, scenario: "empty", viewport: viewport).findings.map(\.rule), ["vacuous-verdict"])
    }

    func testTextFragmentGeometryTracksScrollAndFrameTransforms() throws {
        var payload = fragmentedSnapshot([[30, 40, 35, 20], [20, 70, 50, 20]], textBoxRows: [0, 1])
        guard case var .array(documents) = payload["documents"], case var .object(document) = documents[0] else { return XCTFail("fixture") }
        document["scrollOffsetY"] = .number(10); documents[0] = .object(document); payload["documents"] = .array(documents)
        let tree = try DOMSnapshotAssembly.assemble(payload, viewport: viewport)
        let text = try XCTUnwrap(tree.children.first)
        XCTAssertEqual(text.attributes["web.textFragmentCount"], .number(2))
        XCTAssertEqual(WebLint.rect(key: "web.textFragment0", in: text.attributes), Rect(x: 30, y: 30, width: 35, height: 20))
        let owner = SemanticNode(id: "frame", role: .container, frame: Rect(x: 100, y: 200, width: 500, height: 300))
        let embedded = try WebFrameGeometry.embedding(text, in: owner)
        XCTAssertEqual(WebLint.rect(key: "web.textFragment1", in: embedded.attributes), Rect(x: 120, y: 260, width: 50, height: 20))
    }

    func testTextBoxBudgetAndLineBreakRoles() throws {
        XCTAssertEqual(DOMSnapshotAssembly.role(tag: "br", attributes: [:]), .spacer)
        XCTAssertEqual(DOMSnapshotAssembly.role(tag: "wbr", attributes: [:]), .spacer)
        var payload = fragmentedSnapshot([[30, 40, 35, 20]])
        guard case var .array(documents) = payload["documents"], case var .object(document) = documents[0] else { return XCTFail("fixture") }
        document["textBoxes"] = .object(["layoutIndex": .array(Array(repeating: .integer(0), count: 100_001)), "bounds": .array([])])
        documents[0] = .object(document); payload["documents"] = .array(documents)
        XCTAssertThrowsError(try DOMSnapshotAssembly.assemble(payload, viewport: viewport)) { error in
            XCTAssertTrue(String(describing: error).contains("oversized text box index column"))
        }
    }

    func testMeasuredEmptyPaintClipHidesDescendantsAndFocusRestoresThem() throws {
        for (clipPath, expected) in [("inset(50%)", false), ("none", true), ("polygon(0 0, 0 0, 0 0)", true)] {
            var payload = snapshot()
            guard case var .array(strings) = payload["strings"], case var .array(documents) = payload["documents"],
                  case var .object(document) = documents[0], case var .object(layout) = document["layout"],
                  case var .array(styles) = layout["styles"], case var .array(buttonStyle) = styles[0] else { return XCTFail("fixture") }
            let next = strings.count; strings += [.string("absolute"), .string(clipPath)]
            buttonStyle[4] = .integer(Int64(next)); buttonStyle[6] = .integer(Int64(next + 1)); styles[0] = .array(buttonStyle)
            layout["styles"] = .array(styles); document["layout"] = .object(layout); documents[0] = .object(document)
            payload["strings"] = .array(strings); payload["documents"] = .array(documents)
            let tree = try DOMSnapshotAssembly.assemble(payload, viewport: viewport)
            XCTAssertEqual(tree.children.first?.isVisible, expected)
            XCTAssertEqual(tree.children.first?.children.first?.isVisible, expected)
        }
    }

    func testMeasuredPseudoElementCanHaveMultipleLayoutRows() throws {
        // Reduced from Chrome's capture of the published VerdictUI page:
        // ::before has a full-page box plus an empty anonymous layout child.
        let payload = fragmentedSnapshot(
            [[0, 0, 1280, 900], [0, 0, 0, 0]], tag: "::before", nodeType: 1,
            opacity: "0.02", zIndex: "9999"
        )
        let tree = try DOMSnapshotAssembly.assemble(payload, viewport: viewport)
        XCTAssertEqual(tree.children.count, 1)
        let node = try XCTUnwrap(tree.children.first)
        XCTAssertEqual(node.frame, Rect(x: 0, y: 0, width: 1280, height: 900))
        XCTAssertEqual(node.attributes["web.tag"], .string("::before"))
        XCTAssertEqual(node.attributes["web.backendID"], .number(2))
        XCTAssertTrue(node.isVisible)
        XCTAssertEqual(node.zIndex, 9999)
        XCTAssertNil(node.text)
    }

    func testLayoutFragmentsPreserveUnionTextAndLayoutRowTextBoxes() throws {
        var payload = fragmentedSnapshot(
            [[30, 40, 35, 20], [20, 70, 50, 20], [35, 45, 10, 10]], textBoxRows: [0, 1]
        )
        guard case var .array(documents) = payload["documents"],
            case var .object(document) = documents[0] else { return XCTFail("invalid fixture") }
        document["scrollOffsetX"] = .number(5)
        document["scrollOffsetY"] = .number(10)
        documents[0] = .object(document); payload["documents"] = .array(documents)
        let tree = try DOMSnapshotAssembly.assemble(payload, viewport: viewport)
        XCTAssertEqual(tree.children.count, 1, "layout fragments must not duplicate DOM identities")
        let node = try XCTUnwrap(tree.children.first)
        XCTAssertEqual(node.id, "web/2")
        XCTAssertEqual(node.text, "Save")
        XCTAssertEqual(node.frame, Rect(x: 15, y: 30, width: 50, height: 50))
        XCTAssertEqual(node.textMetrics, TextMetrics(intrinsicWidth: 85, renderedLineCount: 2, idealLineCount: 2))
        XCTAssertEqual(node.attributes["web.inputX"], .number(15))
    }

    func testEmptyLayoutFragmentsDoNotExpandDisplacedGeometry() throws {
        let nonempty: [Double] = [100, 200, 30, 20]
        let empty: [[Double]] = [[0, 0, 0, 0], [0, 0, 10, 0], [0, 0, 0, 10]]
        for frames in [[nonempty] + empty, empty + [nonempty]] {
            let tree = try DOMSnapshotAssembly.assemble(fragmentedSnapshot(frames), viewport: viewport)
            XCTAssertEqual(tree.children.first?.frame, Rect(x: 100, y: 200, width: 30, height: 20))
        }
        let emptyTree = try DOMSnapshotAssembly.assemble(
            fragmentedSnapshot([[60, 70, 0, 0], [0, 0, 0, 0]]), viewport: viewport
        )
        XCTAssertEqual(emptyTree.children.first?.frame, Rect(x: 60, y: 70, width: 0, height: 0))
    }

    func testDuplicateLayoutRowsStillValidateEveryRectangleAndStyle() throws {
        for invalid in [[Double.nan, 0, 0, 0], [0, 0, -1, 0], [0, 0, 1]] {
            XCTAssertThrowsError(try DOMSnapshotAssembly.assemble(
                fragmentedSnapshot([[10, 20, 30, 40], invalid]), viewport: viewport
            ))
        }
        for style in [CDPValue.array([]), .array([.integer(4), .integer(5), .integer(6), .integer(99)]),
                      .array([.integer(4), .integer(5), .integer(5), .integer(7)])] {
            var payload = fragmentedSnapshot([[10, 20, 30, 40], [0, 0, 0, 0]])
            guard case var .array(documents) = payload["documents"],
                case var .object(document) = documents[0], case var .object(layout) = document["layout"],
                case var .array(styles) = layout["styles"] else { return XCTFail("invalid fixture") }
            if case let .array(row) = style, row.count == 4, case let .array(valid) = styles[0] {
                styles[1] = .array(row + valid.dropFirst(4))
            } else { styles[1] = style }
            layout["styles"] = .array(styles)
            document["layout"] = .object(layout); documents[0] = .object(document)
            payload["documents"] = .array(documents)
            XCTAssertThrowsError(try DOMSnapshotAssembly.assemble(payload, viewport: viewport))
        }
    }

    func testLayoutRowBudgetStillAppliesWhenDOMIndicesRepeat() throws {
        let payload = fragmentedSnapshot(Array(repeating: [10, 20, 30, 40], count: 100_001))
        XCTAssertThrowsError(try DOMSnapshotAssembly.assemble(payload, viewport: viewport)) { error in
            XCTAssertTrue(String(describing: error).contains("oversized layout index column"))
        }
    }

    func testFiniteRectangleInputsCannotOverflowDerivedGeometry() throws {
        let large = Double.greatestFiniteMagnitude
        for frames in [
            [[-large, 0, 1, 1], [large, 0, 1, 1]],
            [[0, -large, 1, 1], [0, large, 1, 1]],
            [[large, 0, large, 1]],
            [[0, large, 1, large]],
        ] {
            XCTAssertThrowsError(try DOMSnapshotAssembly.assemble(fragmentedSnapshot(frames), viewport: viewport))
        }
        for axis in ["scrollOffsetX", "scrollOffsetY"] {
            var payload = fragmentedSnapshot([[large, large, 1, 1]])
            guard case var .array(documents) = payload["documents"],
                case var .object(document) = documents[0] else { return XCTFail("invalid fixture") }
            document[axis] = .number(-large)
            documents[0] = .object(document); payload["documents"] = .array(documents)
            XCTAssertThrowsError(try DOMSnapshotAssembly.assemble(payload, viewport: viewport))
        }
    }

    func testTextBoxLineCoordinatesOutsideIntegerRangeFailWithoutTrapping() throws {
        for y in [1e20, 1e308, -1e20, -1e308] {
            let payload = fragmentedSnapshot([[0, y, 1, 1]], textBoxRows: [0])
            XCTAssertThrowsError(try DOMSnapshotAssembly.assemble(payload, viewport: viewport)) { error in
                XCTAssertTrue(String(describing: error).contains("text box line coordinate out of range"))
            }
        }
    }

    func testImplicitAndAriaRolesAreMapped() throws {
        XCTAssertEqual(DOMSnapshotAssembly.role(tag: "input", attributes: ["type": "password"]), .textField)
        XCTAssertEqual(DOMSnapshotAssembly.role(tag: "input", attributes: ["type": "checkbox"]), .toggle)
        XCTAssertEqual(DOMSnapshotAssembly.role(tag: "a", attributes: ["href": "/"]), .button)
        XCTAssertEqual(DOMSnapshotAssembly.role(tag: "div", attributes: ["role": "navigation"]), .navigation)
        XCTAssertEqual(DOMSnapshotAssembly.role(tag: "div", attributes: ["role": "slider"]), .slider)
        XCTAssertEqual(DOMSnapshotAssembly.role(tag: "div", attributes: ["role": "unknown"]), .custom("web.unknown"))
    }

    func testMalformedColumnsAndInvalidTopologyFailClosed() throws {
        var payload = snapshot()
        payload["strings"] = .array([.integer(1)])
        XCTAssertThrowsError(try DOMSnapshotAssembly.assemble(payload, viewport: viewport))
        for (table, key, value) in [
            ("nodes", "parentIndex", CDPValue.array([.integer(-1), .integer(2), .integer(1)])),
            ("nodes", "backendNodeId", .array([.integer(1), .integer(2), .integer(2)])),
            ("nodes", "nodeName", .array([.integer(0), .integer(99), .integer(2)])),
            ("nodes", "attributes", .array([.array([]), .array([.integer(9)]), .array([])])),
            ("nodes", "nodeValue", .array([])),
            ("layout", "nodeIndex", .array([.integer(20), .integer(2)])),
            ("layout", "bounds", .array([.array([.integer(0), .integer(0), .integer(-1), .integer(10)]), .array([.integer(0), .integer(0), .integer(20), .integer(10)])])),
            ("layout", "styles", .array([.array([]), .array([])])),
            ("textBoxes", "layoutIndex", .array([.integer(99)])),
        ] {
            var invalid = snapshot()
            guard case let .array(documents) = invalid["documents"], case var .object(document) = documents[0],
                case var .object(fields) = document[table] else { return XCTFail("invalid test fixture") }
            fields[key] = value; document[table] = .object(fields); invalid["documents"] = .array([.object(document)])
            XCTAssertThrowsError(try DOMSnapshotAssembly.assemble(invalid, viewport: viewport), "\(table).\(key)")
        }
    }

    func testRedactionRemovesReflectionsAndSensitiveURLs() throws {
        let credential = UUID().uuidString
        XCTAssertEqual(WebRedaction.clean("echo \(credential)", secrets: [credential]), "echo [REDACTED]")
        XCTAssertEqual(WebRedaction.clean("visit https://user:pass@example.org/path?token=abc#secret"), "visit https://example.org/path")
        var payload = snapshot()
        if case var .array(strings) = payload["strings"] {
            strings[4] = .string(credential); payload["strings"] = .array(strings)
        }
        let tree = try DOMSnapshotAssembly.assemble(payload, viewport: viewport, redacting: [credential])
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(tree), as: UTF8.self).contains(credential))
    }
    func testOrphanedEmbeddedDocumentIsUnavailable() throws {
        var payload = snapshot()
        if case let .array(documents) = payload["documents"] { payload["documents"] = .array(documents + documents) }
        XCTAssertThrowsError(try DOMSnapshotAssembly.assemble(payload, viewport: viewport))
    }

    func testHiddenAncestorHidesTextAndEmptyContainersDoNotCountAsEvidence() throws {
        var payload = snapshot()
        if case var .array(strings) = payload["strings"] {
            strings[1] = .string("DIV"); strings[7] = .string("0"); payload["strings"] = .array(strings)
        }
        let tree = try DOMSnapshotAssembly.assemble(payload, viewport: viewport)
        XCTAssertEqual(tree.children.first?.id, "")
        XCTAssertEqual(tree.children.first?.isVisible, false)
        XCTAssertEqual(tree.children.first?.children.first?.isVisible, false)
    }

    func testControlNameSurvivesCompactTextAndNeverUsesValueChildren() throws {
        var payload = snapshot()
        guard case var .array(strings) = payload["strings"], case var .array(documents) = payload["documents"],
            case var .object(document) = documents[0], case var .object(nodes) = document["nodes"],
            case var .array(attributes) = nodes["attributes"] else { return XCTFail("invalid fixture") }
        strings[1] = .string("INPUT"); strings[4] = .string("private-existing-field-value")
        let extra = strings.count
        strings += [.string("aria-label"), .string("Password")]
        attributes[1] = .array([.integer(Int64(extra)), .integer(Int64(extra + 1))])
        nodes["attributes"] = .array(attributes); document["nodes"] = .object(nodes)
        documents[0] = .object(document); payload["documents"] = .array(documents); payload["strings"] = .array(strings)
        let tree = try DOMSnapshotAssembly.assemble(payload, viewport: viewport)
        let field = try XCTUnwrap(tree.children.first)
        XCTAssertEqual(field.role, .textField)
        XCTAssertEqual(field.text, "Password", "compact outputs preserve text but omit custom attributes")
        XCTAssertEqual(field.attributes["accessibilityLabel"], .string("Password"))
        XCTAssertTrue(field.children.isEmpty)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(tree), as: UTF8.self).contains("private-existing-field-value"))
    }

    func testEmptyBooleanAttributeUsesCDPAbsentStringSentinel() throws {
        var payload = snapshot()
        guard case var .array(strings) = payload["strings"], case var .array(documents) = payload["documents"],
            case var .object(document) = documents[0], case var .object(nodes) = document["nodes"],
            case var .array(attributes) = nodes["attributes"] else { return XCTFail("invalid fixture") }
        let extra = strings.count
        strings += [.string("disabled")]
        attributes[1] = .array([.integer(Int64(extra)), .integer(-1)])
        nodes["attributes"] = .array(attributes); document["nodes"] = .object(nodes)
        documents[0] = .object(document); payload["documents"] = .array(documents); payload["strings"] = .array(strings)
        let tree = try DOMSnapshotAssembly.assemble(payload, viewport: viewport)
        XCTAssertEqual(tree.children.first?.attributes["web.enabled"], .bool(false))
    }

    func testAccessibleLabelsExcludeEditableValues() throws {
        let names = DOMAccessibleNames.resolve(tags: ["label", "#text", "textarea", "#text"],
            types: [1, 3, 1, 3], values: ["", "Private notes", "", "private-existing-value"],
            attributes: [[:], [:], [:], [:]], parents: [-1, 0, 0, 2])
        XCTAssertEqual(names[2], "Private notes")
        XCTAssertFalse(names.compactMap { $0 }.joined().contains("private-existing-value"))
    }

    func testAssociatedLabelsAndAriaNamesHaveDeterministicPriority() throws {
        let tags = ["#document", "label", "#text", "input", "label", "#text", "input", "span", "#text", "input", "input", "input"]
        let parents = [-1, 0, 1, 0, 0, 4, 4, 0, 7, 0, 0, 0]
        let attrs: [[String: String]] = [[:], ["for": "username"], [:], ["id": "username", "value": "private"],
            [:], [:], ["placeholder": "lower priority"], ["id": "name"], [:],
            ["aria-labelledby": "name", "aria-label": "lower priority"], ["aria-label": "Password", "placeholder": "lower priority"],
            ["placeholder": "Search"]]
        let names = DOMAccessibleNames.resolve(tags: tags, types: tags.map { $0 == "#text" ? 3 : 1 },
            values: ["", "", " User name ", "", "", " Wrapped label ", "", "", " Referenced name ", "", "", ""],
            attributes: attrs, parents: parents)
        XCTAssertEqual(names[3], "User name")
        XCTAssertEqual(names[6], "Wrapped label")
        XCTAssertEqual(names[9], "Referenced name")
        XCTAssertEqual(names[10], "Password")
        XCTAssertEqual(names[11], "Search")
    }

    func testCredentialReflectedIntoCustomRoleIsRedacted() throws {
        let secret = UUID().uuidString
        var payload = snapshot()
        guard case var .array(strings) = payload["strings"], case var .array(documents) = payload["documents"],
            case var .object(document) = documents[0], case var .object(nodes) = document["nodes"],
            case var .array(attributes) = nodes["attributes"] else { return XCTFail("invalid fixture") }
        let extra = strings.count
        strings += [.string("role"), .string(secret)]
        attributes[1] = .array([.integer(Int64(extra)), .integer(Int64(extra + 1))])
        nodes["attributes"] = .array(attributes); document["nodes"] = .object(nodes)
        documents[0] = .object(document); payload["documents"] = .array(documents); payload["strings"] = .array(strings)
        let tree = try DOMSnapshotAssembly.assemble(payload, viewport: viewport, redacting: [secret])
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(tree), as: UTF8.self).contains(secret))
    }

}
