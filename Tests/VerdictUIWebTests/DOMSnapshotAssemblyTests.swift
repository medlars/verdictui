import XCTest
import VerdictUIKernel
@testable import VerdictUIWeb

final class DOMSnapshotAssemblyTests: XCTestCase {
    let viewport = Rect(x: 0, y: 0, width: 800, height: 600)

    func snapshot() -> [String: CDPValue] {
        let integer: (Int) -> CDPValue = { .integer(Int64($0)) }
        return ["strings": .array(["#document", "BUTTON", "#text", "", "Save", "block", "visible", "1", "auto", "id", "save"].map(CDPValue.string)),
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

    func testCredentialReflectedIntoCustomRoleIsRedacted() throws {
        let secret = UUID().uuidString
        var payload = snapshot()
        guard case var .array(strings) = payload["strings"], case var .array(documents) = payload["documents"],
            case var .object(document) = documents[0], case var .object(nodes) = document["nodes"],
            case var .array(attributes) = nodes["attributes"] else { return XCTFail("invalid fixture") }
        strings += [.string("role"), .string(secret)]
        attributes[1] = .array([.integer(11), .integer(12)])
        nodes["attributes"] = .array(attributes); document["nodes"] = .object(nodes)
        documents[0] = .object(document); payload["documents"] = .array(documents); payload["strings"] = .array(strings)
        let tree = try DOMSnapshotAssembly.assemble(payload, viewport: viewport, redacting: [secret])
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(tree), as: UTF8.self).contains(secret))
    }

}
