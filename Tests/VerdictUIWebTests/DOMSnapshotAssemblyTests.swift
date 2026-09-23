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
        strings += ["static", "auto", "none", "visible", "visible", "none", "none", "none", "none", "auto"].map(CDPValue.string)
        for index in documents.indices {
            guard case var .object(document) = documents[index], case var .object(layout) = document["layout"],
                case let .array(styles) = layout["styles"] else { continue }
            document["contentWidth"] = .number(800); document["contentHeight"] = .number(600)
            document["scrollOffsetX"] = .number(0); document["scrollOffsetY"] = .number(0)
            layout["styles"] = .array(styles.map { row in
                guard case let .array(values) = row else { return row }
                return .array(values + (extra..<(extra + 10)).map { .integer(Int64($0)) })
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
        XCTAssertEqual(WebLint.run(tree: tree, scenario: "empty", viewport: viewport).findings.map(\.rule), ["vacuous-verdict"])
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

    func testDuplicateLayoutRowsStillValidateEveryRectangleAndStyle() {
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

    func testLayoutRowBudgetStillAppliesWhenDOMIndicesRepeat() {
        let payload = fragmentedSnapshot(Array(repeating: [10, 20, 30, 40], count: 100_001))
        XCTAssertThrowsError(try DOMSnapshotAssembly.assemble(payload, viewport: viewport)) { error in
            XCTAssertTrue(String(describing: error).contains("oversized layout index column"))
        }
    }

    func testFiniteRectangleInputsCannotOverflowDerivedGeometry() {
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

    func testTextBoxLineCoordinatesOutsideIntegerRangeFailWithoutTrapping() {
        for y in [1e20, 1e308, -1e20, -1e308] {
            let payload = fragmentedSnapshot([[0, y, 1, 1]], textBoxRows: [0])
            XCTAssertThrowsError(try DOMSnapshotAssembly.assemble(payload, viewport: viewport)) { error in
                XCTAssertTrue(String(describing: error).contains("text box line coordinate out of range"))
            }
        }
    }

    func testImplicitAndAriaRolesAreMapped() {
        XCTAssertEqual(DOMSnapshotAssembly.role(tag: "input", attributes: ["type": "password"]), .textField)
        XCTAssertEqual(DOMSnapshotAssembly.role(tag: "input", attributes: ["type": "checkbox"]), .toggle)
        XCTAssertEqual(DOMSnapshotAssembly.role(tag: "a", attributes: ["href": "/"]), .button)
        XCTAssertEqual(DOMSnapshotAssembly.role(tag: "div", attributes: ["role": "navigation"]), .navigation)
        XCTAssertEqual(DOMSnapshotAssembly.role(tag: "div", attributes: ["role": "slider"]), .slider)
        XCTAssertEqual(DOMSnapshotAssembly.role(tag: "div", attributes: ["role": "unknown"]), .custom("web.unknown"))
    }

    func testMalformedColumnsAndInvalidTopologyFailClosed() {
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
    func testOrphanedEmbeddedDocumentIsUnavailable() {
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

    func testAccessibleLabelsExcludeEditableValues() {
        let names = DOMAccessibleNames.resolve(tags: ["label", "#text", "textarea", "#text"],
            types: [1, 3, 1, 3], values: ["", "Private notes", "", "private-existing-value"],
            attributes: [[:], [:], [:], [:]], parents: [-1, 0, 0, 2])
        XCTAssertEqual(names[2], "Private notes")
        XCTAssertFalse(names.compactMap { $0 }.joined().contains("private-existing-value"))
    }

    func testAssociatedLabelsAndAriaNamesHaveDeterministicPriority() {
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
