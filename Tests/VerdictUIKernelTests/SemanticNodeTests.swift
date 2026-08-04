import XCTest

@testable import VerdictUIKernel

/// Task 1 coverage: role vocabulary, attribute primitives, text metrics,
/// node identity/traversal, lenient Codable, and the platform-pure geometry.
final class SemanticNodeTests: XCTestCase {

    // MARK: - Role

    /// Every known case must survive identifier → Role → identifier unchanged,
    /// because that string is the wire contract shared with the AX channel.
    func testRoleIdentifierRoundTripsForEveryKnownCase() {
        let known: [Role] = [
            .container, .text, .button, .toggle, .slider, .textField, .image, .list, .listRow,
            .navigation, .tabBar, .menu, .spacer,
        ]
        for role in known {
            XCTAssertEqual(Role(identifier: role.identifier), role, "role \(role.identifier)")
        }
        XCTAssertEqual(known.count, 13, "role vocabulary size changed — update docs/kernel.md")
    }

    func testRoleUnknownIdentifierBecomesCustom() {
        XCTAssertEqual(Role(identifier: "DisclosureGroup"), .custom("DisclosureGroup"))
        XCTAssertEqual(Role.custom("DisclosureGroup").identifier, "DisclosureGroup")
    }

    func testRoleEncodesAsBareStringAndDecodesBack() throws {
        let encoded = try JSONEncoder().encode([Role.button, .custom("zstack")])
        XCTAssertEqual(String(decoding: encoded, as: UTF8.self), #"["button","zstack"]"#)
        XCTAssertEqual(try JSONDecoder().decode([Role].self, from: encoded), [.button, .custom("zstack")])
    }

    func testRoleInteractiveAndTextBearingClassification() {
        XCTAssertTrue(Role.button.isInteractive)
        XCTAssertTrue(Role.toggle.isInteractive)
        XCTAssertTrue(Role.slider.isInteractive)
        XCTAssertTrue(Role.textField.isInteractive)
        XCTAssertTrue(Role.menu.isInteractive)
        XCTAssertFalse(Role.text.isInteractive)
        XCTAssertFalse(Role.listRow.isInteractive, "rows are platform-sized — see Role.isInteractive")
        XCTAssertFalse(Role.custom("x").isInteractive)

        XCTAssertTrue(Role.text.isTextBearing)
        XCTAssertTrue(Role.button.isTextBearing)
        XCTAssertTrue(Role.textField.isTextBearing)
        XCTAssertFalse(Role.image.isTextBearing)
        XCTAssertFalse(Role.container.isTextBearing)
    }

    // MARK: - AttributeValue

    func testAttributeValueAccessorsIsolateTheWrappedCase() {
        XCTAssertEqual(AttributeValue.string("on").stringValue, "on")
        XCTAssertNil(AttributeValue.string("on").numberValue)
        XCTAssertNil(AttributeValue.string("on").boolValue)

        XCTAssertEqual(AttributeValue.number(0.5).numberValue, 0.5)
        XCTAssertNil(AttributeValue.number(0.5).stringValue)
        XCTAssertNil(AttributeValue.number(0.5).boolValue)

        XCTAssertEqual(AttributeValue.bool(true).boolValue, true)
        XCTAssertNil(AttributeValue.bool(true).stringValue)
        XCTAssertNil(AttributeValue.bool(true).numberValue)
    }

    func testAttributeValueDescriptionTrimsWholeNumbers() {
        XCTAssertEqual(AttributeValue.number(44).description, "44")
        XCTAssertEqual(AttributeValue.number(0.5).description, "0.5")
        XCTAssertEqual(AttributeValue.string("Save").description, "Save")
        XCTAssertEqual(AttributeValue.bool(false).description, "false")
    }

    /// Bool must be probed before Double or `true` would decode as a number.
    func testAttributeValueCodableRoundTripsAllThreeCases() throws {
        let values: [AttributeValue] = [.string("Save"), .number(212.5), .bool(true), .bool(false)]
        let encoded = try JSONEncoder().encode(values)
        XCTAssertEqual(String(decoding: encoded, as: UTF8.self), #"["Save",212.5,true,false]"#)
        XCTAssertEqual(try JSONDecoder().decode([AttributeValue].self, from: encoded), values)
    }

    // MARK: - TextMetrics

    func testTextMetricsDetectsLineTruncation() {
        let truncated = TextMetrics(intrinsicWidth: 212, renderedLineCount: 1, idealLineCount: 3)
        XCTAssertTrue(truncated.isLineTruncated)
        let intact = TextMetrics(intrinsicWidth: 212, renderedLineCount: 3, idealLineCount: 3)
        XCTAssertFalse(intact.isLineTruncated)
    }

    // MARK: - SemanticNode

    func testDefaultsAndIdentityPreferProbeIDOverStructuralPath() {
        let node = SemanticNode(id: "save", role: .button, frame: Rect(x: 0, y: 0, width: 80, height: 30))
        XCTAssertTrue(node.attributes.isEmpty)
        XCTAssertTrue(node.isVisible)
        XCTAssertNil(node.zIndex)
        XCTAssertNil(node.textMetrics)
        XCTAssertTrue(node.structuralPath.isEmpty)
        XCTAssertTrue(node.children.isEmpty)
        XCTAssertEqual(node.identity, "save")

        var unprobed = node
        unprobed.id = ""
        unprobed.structuralPath = "root/container[0]"
        XCTAssertEqual(unprobed.identity, "@container[0]", "sibling-local, namespaces separated")

        var anonymous = unprobed
        anonymous.structuralPath = ""
        XCTAssertEqual(anonymous.identity, "")
    }

    func testEncodingOmitsEmptyCollectionsAndNilFields() throws {
        let node = SemanticNode(id: "a", role: .text, frame: Rect(x: 1, y: 2, width: 3, height: 4))
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let json = String(decoding: try encoder.encode(node), as: UTF8.self)
        XCTAssertFalse(json.contains("attributes"))
        XCTAssertFalse(json.contains("children"))
        XCTAssertFalse(json.contains("structuralPath"))
        XCTAssertFalse(json.contains("\"text\":"), "the role value is also `text` — match the key")
        XCTAssertFalse(json.contains("zIndex"))
        XCTAssertTrue(json.contains("\"isVisible\":true"))
    }

    func testDecodesLenientlyWithDocumentedDefaults() throws {
        let json = #"{"id":"a","role":"text","frame":{"x":0,"y":0,"width":10,"height":10}}"#
        let node = try JSONDecoder().decode(SemanticNode.self, from: Data(json.utf8))
        XCTAssertEqual(node.role, .text)
        XCTAssertTrue(node.isVisible)
        XCTAssertTrue(node.attributes.isEmpty)
        XCTAssertTrue(node.children.isEmpty)
        XCTAssertEqual(node.structuralPath, "")
    }

    func testFullNodeSurvivesCodableRoundTrip() throws {
        let node = SemanticNode(
            id: "title",
            role: .text,
            frame: Rect(x: 0, y: 0, width: 120, height: 20),
            text: "Monthly summary",
            attributes: ["verdict.suppress": .string("truncation"), "lineLimit": .number(1)],
            isVisible: false,
            zIndex: 2,
            textMetrics: TextMetrics(intrinsicWidth: 212, renderedLineCount: 1, idealLineCount: 2),
            structuralPath: "root/text[0]",
            children: [SemanticNode(id: "inner", role: .image, frame: Rect(x: 0, y: 0, width: 8, height: 8))]
        )
        let data = try JSONEncoder().encode(node)
        XCTAssertEqual(try JSONDecoder().decode(SemanticNode.self, from: data), node)
    }

    func testFlattenedIsPreorderInLayoutOrder() {
        let tree = SemanticNode(
            id: "root",
            role: .container,
            frame: Rect(x: 0, y: 0, width: 100, height: 100),
            children: [
                SemanticNode(
                    id: "a",
                    role: .container,
                    frame: Rect(x: 0, y: 0, width: 50, height: 50),
                    children: [SemanticNode(id: "a1", role: .text, frame: Rect(x: 0, y: 0, width: 10, height: 10))]
                ),
                SemanticNode(id: "b", role: .text, frame: Rect(x: 0, y: 60, width: 10, height: 10)),
            ]
        )
        XCTAssertEqual(tree.flattened().map(\.id), ["root", "a", "a1", "b"])
    }

    func testNodeWithIDFindsDescendantsAndRejectsEmptyQuery() {
        let tree = SemanticNode(
            id: "root",
            role: .container,
            frame: Rect(x: 0, y: 0, width: 10, height: 10),
            children: [
                SemanticNode(id: "", role: .spacer, frame: Rect(x: 0, y: 0, width: 0, height: 0)),
                SemanticNode(id: "deep", role: .button, frame: Rect(x: 0, y: 0, width: 5, height: 5)),
            ]
        )
        XCTAssertEqual(tree.node(withID: "deep")?.role, .button)
        XCTAssertNil(tree.node(withID: "missing"))
        XCTAssertNil(tree.node(withID: ""), "empty query must not match unprobed nodes")
    }

    func testWithAssignedStructuralPathsBuildsParentChainPaths() {
        let tree = SemanticNode(
            id: "",
            role: .container,
            frame: Rect(x: 0, y: 0, width: 10, height: 10),
            children: [
                SemanticNode(
                    id: "",
                    role: .container,
                    frame: Rect(x: 0, y: 0, width: 5, height: 5),
                    children: [SemanticNode(id: "", role: .text, frame: Rect(x: 0, y: 0, width: 2, height: 2))]
                ),
                SemanticNode(id: "", role: .text, frame: Rect(x: 0, y: 6, width: 2, height: 2)),
            ]
        )
        let paths = tree.withAssignedStructuralPaths().flattened().map(\.structuralPath)
        XCTAssertEqual(
            paths,
            ["root", "root/container[0]", "root/container[0]/text[0]", "root/text[1]"]
        )
    }

    // MARK: - Geometry

    func testRectEdgesSizeAndEmptiness() {
        let rect = Rect(x: 10, y: 20, width: 30, height: 40)
        XCTAssertEqual(rect.maxX, 40)
        XCTAssertEqual(rect.maxY, 60)
        XCTAssertEqual(rect.size, Size(width: 30, height: 40))
        XCTAssertFalse(rect.isEmpty)
        XCTAssertTrue(Rect(x: 0, y: 0, width: 0, height: 10).isEmpty)
        XCTAssertTrue(Rect(x: 0, y: 0, width: 10, height: -1).isEmpty)
    }

    func testRectIntersectionAndContainment() {
        let a = Rect(x: 0, y: 0, width: 100, height: 100)
        let b = Rect(x: 90, y: 90, width: 100, height: 100)
        XCTAssertTrue(a.intersects(b))
        XCTAssertEqual(a.intersection(b), Rect(x: 90, y: 90, width: 10, height: 10))

        let touching = Rect(x: 100, y: 0, width: 10, height: 10)
        XCTAssertFalse(a.intersects(touching), "shared edges are not overlap")
        XCTAssertNil(a.intersection(touching))

        XCTAssertTrue(a.contains(Rect(x: 0, y: 0, width: 100, height: 100)), "edges are inclusive")
        XCTAssertTrue(a.contains(Rect(x: 10, y: 10, width: 10, height: 10)))
        XCTAssertFalse(a.contains(b))
    }

    func testSizeAndRectSurviveCodableRoundTrip() throws {
        let size = Size(width: 28, height: 28)
        XCTAssertEqual(try JSONDecoder().decode(Size.self, from: try JSONEncoder().encode(size)), size)
        let rect = Rect(x: 1.5, y: 2.5, width: 3.5, height: 4.5)
        XCTAssertEqual(try JSONDecoder().decode(Rect.self, from: try JSONEncoder().encode(rect)), rect)
    }
}
