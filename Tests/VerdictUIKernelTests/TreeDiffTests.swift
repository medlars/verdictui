import XCTest

@testable import VerdictUIKernel

/// Task 2 coverage: id-first matching, every delta category, the documented
/// degradations (reparent as remove+add, duplicate ids as positional matching),
/// and the failure modes of ``TreeDiff/apply(_:to:)``.
final class TreeDiffTests: XCTestCase {

    private func container(_ id: String, _ children: [SemanticNode] = []) -> SemanticNode {
        SemanticNode(
            id: id,
            role: .container,
            frame: Rect(x: 0, y: 0, width: 200, height: 200),
            children: children
        )
    }

    private func leaf(_ id: String, x: Double = 0, role: Role = .text) -> SemanticNode {
        SemanticNode(id: id, role: role, frame: Rect(x: x, y: 0, width: 20, height: 20))
    }

    // MARK: - NodePath

    func testNodePathNavigationAndDescription() {
        let path = NodePath.root.appending("toolbar").appending("save")
        XCTAssertEqual(path.segments, ["$root", "toolbar", "save"])
        XCTAssertEqual(path.description, "$root/toolbar/save")
        XCTAssertEqual(path.leaf, "save")
        XCTAssertEqual(path.parent, NodePath.root.appending("toolbar"))
        XCTAssertNil(NodePath.root.parent)
    }

    /// Segments may contain `/` (structural components), so the wire form is an
    /// array — a joined string would be ambiguous.
    func testNodePathEncodesAsSegmentArray() throws {
        let path = NodePath(["$root", "@container[0]"])
        let data = try JSONEncoder().encode(path)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"["$root","@container[0]"]"#)
        XCTAssertEqual(try JSONDecoder().decode(NodePath.self, from: data), path)
    }

    // MARK: - childSegments

    func testChildSegmentsPreferIDThenStructuralPathThenPosition() {
        let node = container(
            "root",
            [
                leaf("probed"),
                SemanticNode(
                    id: "",
                    role: .text,
                    frame: Rect(x: 0, y: 0, width: 1, height: 1),
                    structuralPath: "root/text[1]"
                ),
                SemanticNode(id: "", role: .spacer, frame: Rect(x: 0, y: 0, width: 0, height: 0)),
            ]
        )
        XCTAssertEqual(TreeDiff.childSegments(of: node), ["probed", "@text[1]", "#2"])
    }

    func testDuplicateIdentitiesFallBackToPositionalSegments() {
        let node = container("root", [leaf("dupe"), leaf("dupe", x: 40)])
        XCTAssertEqual(TreeDiff.childSegments(of: node), ["#0", "#1"])
    }

    // MARK: - compute

    func testIdenticalTreesProduceEmptyDelta() {
        let tree = container("root", [leaf("a"), leaf("b", x: 40)])
        let delta = TreeDiff.compute(before: tree, after: tree)
        XCTAssertTrue(delta.isEmpty)
        XCTAssertEqual(delta.summary, "added 0, removed 0, moved 0, changed 0")
    }

    func testFrameChangeIsReportedAsMoveNotChange() {
        let before = container("root", [leaf("a")])
        var after = before
        after.children[0].frame = Rect(x: 5, y: 5, width: 20, height: 20)

        let delta = TreeDiff.compute(before: before, after: after)
        XCTAssertEqual(delta.moved.count, 1)
        XCTAssertEqual(delta.moved[0].path, NodePath.root.appending("a"))
        XCTAssertEqual(delta.moved[0].from, Rect(x: 0, y: 0, width: 20, height: 20))
        XCTAssertEqual(delta.moved[0].to, Rect(x: 5, y: 5, width: 20, height: 20))
        XCTAssertTrue(delta.changed.isEmpty, "frames live in `moved` only")
    }

    func testInsertionCarriesSubtreeAndAfterTreeIndex() {
        let before = container("root", [leaf("a")])
        var after = before
        after.children.insert(leaf("new", x: 60, role: .button), at: 0)

        let delta = TreeDiff.compute(before: before, after: after)
        XCTAssertEqual(delta.added.count, 1)
        XCTAssertEqual(delta.added[0].index, 0)
        XCTAssertEqual(delta.added[0].path, NodePath.root.appending("new"))
        XCTAssertEqual(delta.added[0].node.role, .button)
        XCTAssertTrue(delta.changed.isEmpty, "shifting later siblings is not a reorder")
    }

    func testRemovalReportsTheSubtreeRootOnly() {
        let before = container("root", [container("group", [leaf("inner")]), leaf("b", x: 60)])
        var after = before
        after.children.removeFirst()

        let delta = TreeDiff.compute(before: before, after: after)
        XCTAssertEqual(delta.removed, [NodePath.root.appending("group")])
    }

    func testFieldChangesCoverEveryNonGeometricField() throws {
        let before = SemanticNode(
            id: "t",
            role: .text,
            frame: Rect(x: 0, y: 0, width: 10, height: 10),
            text: "old",
            attributes: ["kept": .bool(true), "dropped": .number(1)],
            isVisible: true,
            zIndex: nil,
            textMetrics: nil,
            structuralPath: "root/text[0]"
        )
        var after = before
        after.role = .button
        after.text = nil
        after.attributes = ["kept": .bool(false), "gained": .string("x")]
        after.isVisible = false
        after.zIndex = 3
        after.textMetrics = TextMetrics(intrinsicWidth: 100, renderedLineCount: 1, idealLineCount: 2)
        after.structuralPath = "root/button[0]"

        let delta = TreeDiff.compute(
            before: container("root", [before]),
            after: container("root", [after])
        )
        let changes = try XCTUnwrap(delta.changed.first).changes
        XCTAssertEqual(
            changes.map(\.key),
            [
                "attributes.dropped", "attributes.gained", "attributes.kept", "isVisible", "role",
                "structuralPath", "text", "textMetrics.idealLineCount",
                "textMetrics.intrinsicWidth", "textMetrics.renderedLineCount", "zIndex",
            ],
            "keys must be sorted for a deterministic wire format"
        )
        let dropped = try XCTUnwrap(changes.first { $0.key == "attributes.dropped" })
        XCTAssertEqual(dropped.before, .number(1))
        XCTAssertNil(dropped.after, "an absent field is nil, not a sentinel")
    }

    func testReorderingSurvivorsEmitsChildIndexChanges() throws {
        let before = container("root", [leaf("a"), leaf("b", x: 40), leaf("c", x: 80)])
        var after = before
        after.children = [before.children[2], before.children[0], before.children[1]]

        let delta = TreeDiff.compute(before: before, after: after)
        XCTAssertTrue(delta.moved.isEmpty, "frames unchanged — only paint/layout order moved")
        let targets = delta.changed.reduce(into: [String: Double]()) { result, change in
            for entry in change.changes where entry.key == AttributeChange.childIndexKey {
                result[change.path.leaf] = entry.after?.numberValue
            }
        }
        XCTAssertEqual(targets, ["a": 1, "b": 2, "c": 0])
    }

    /// Reparenting is deliberately a removal plus an addition (see `no.md` #6):
    /// structure then always replays exactly.
    func testReparentIsReportedAsRemovalPlusAddition() {
        let before = container("root", [container("left", [leaf("moving")]), container("right")])
        var after = before
        after.children[0].children = []
        after.children[1].children = [leaf("moving")]

        let delta = TreeDiff.compute(before: before, after: after)
        XCTAssertEqual(delta.removed, [NodePath.root.appending("left").appending("moving")])
        XCTAssertEqual(delta.added.map(\.path), [NodePath.root.appending("right").appending("moving")])
    }

    func testUnprobedNodesMatchByStructuralPath() {
        let before = container(
            "root",
            [
                SemanticNode(
                    id: "",
                    role: .text,
                    frame: Rect(x: 0, y: 0, width: 10, height: 10),
                    structuralPath: "root/text[0]"
                )
            ]
        )
        var after = before
        after.children[0].text = "appeared"

        let delta = TreeDiff.compute(before: before, after: after)
        XCTAssertEqual(delta.changed.map(\.path), [NodePath.root.appending("@text[0]")])
        XCTAssertTrue(delta.added.isEmpty)
        XCTAssertTrue(delta.removed.isEmpty)
    }

    func testRootIDChangeIsReportedRatherThanRekeyingTheTree() throws {
        let before = container("root", [leaf("a")])
        var after = before
        after.id = "renamed-root"

        let delta = TreeDiff.compute(before: before, after: after)
        let change = try XCTUnwrap(delta.changed.first)
        XCTAssertEqual(change.path, .root)
        XCTAssertEqual(change.changes.map(\.key), [AttributeChange.idKey])
        XCTAssertEqual(try TreeDiff.apply(delta, to: before), after)
    }

    func testDeltaSurvivesCodableRoundTrip() throws {
        let before = container("root", [leaf("a"), leaf("b", x: 40)])
        var after = before
        after.children[0].frame = Rect(x: 3, y: 0, width: 20, height: 20)
        after.children[1].text = "hi"
        after.children.append(leaf("c", x: 90))
        after.children.remove(at: 0)

        let delta = TreeDiff.compute(before: before, after: after)
        let data = try JSONEncoder().encode(delta)
        XCTAssertEqual(try JSONDecoder().decode(TreeDelta.self, from: data), delta)
    }

    // MARK: - apply

    func testApplyReplaysEveryDeltaCategoryAtOnce() throws {
        let before = container(
            "root",
            [container("group", [leaf("inner")]), leaf("stay", x: 40), leaf("gone", x: 80)]
        )
        var after = before
        after.children[0].children[0].text = "changed"
        after.children[1].frame = Rect(x: 41, y: 1, width: 20, height: 20)
        after.children.remove(at: 2)
        after.children.insert(leaf("fresh", x: 120, role: .button), at: 1)

        let delta = TreeDiff.compute(before: before, after: after)
        XCTAssertEqual(try TreeDiff.apply(delta, to: before), after)
    }

    func testApplyRestoresTextMetricsAcrossNilTransitions() throws {
        let before = container("root", [leaf("t")])
        var withMetrics = before
        withMetrics.children[0].textMetrics = TextMetrics(
            intrinsicWidth: 212,
            renderedLineCount: 1,
            idealLineCount: 3
        )
        let gained = TreeDiff.compute(before: before, after: withMetrics)
        XCTAssertEqual(try TreeDiff.apply(gained, to: before), withMetrics)

        let lost = TreeDiff.compute(before: withMetrics, after: before)
        XCTAssertEqual(try TreeDiff.apply(lost, to: withMetrics), before)

        var partial = withMetrics
        partial.children[0].textMetrics?.renderedLineCount = 3
        let single = TreeDiff.compute(before: withMetrics, after: partial)
        XCTAssertEqual(single.changed.first?.changes.count, 1, "only the differing component")
        XCTAssertEqual(try TreeDiff.apply(single, to: withMetrics), partial)
    }

    func testApplyRejectsAPathThatDoesNotExist() {
        let tree = container("root", [leaf("a")])
        let delta = TreeDelta(removed: [NodePath.root.appending("ghost")])
        XCTAssertThrowsError(try TreeDiff.apply(delta, to: tree)) { error in
            XCTAssertEqual(error as? TreeDiffError, .pathNotFound(NodePath.root.appending("ghost")))
        }
    }

    func testApplyRejectsRemovingTheRoot() {
        let tree = container("root")
        XCTAssertThrowsError(try TreeDiff.apply(TreeDelta(removed: [.root]), to: tree)) { error in
            XCTAssertEqual(error as? TreeDiffError, .rootRemoved)
        }
    }

    func testApplyRejectsAnOutOfRangeInsertionIndex() {
        let tree = container("root", [leaf("a")])
        let delta = TreeDelta(
            added: [NodeAddition(path: NodePath.root.appending("x"), index: 9, node: leaf("x"))]
        )
        XCTAssertThrowsError(try TreeDiff.apply(delta, to: tree)) { error in
            XCTAssertEqual(error as? TreeDiffError, .indexOutOfRange(.root, 9))
        }
    }

    func testApplyRejectsTwoInstructionsClaimingOneSlot() {
        let tree = container("root", [leaf("a")])
        let delta = TreeDelta(
            added: [
                NodeAddition(path: NodePath.root.appending("x"), index: 1, node: leaf("x")),
                NodeAddition(path: NodePath.root.appending("y"), index: 1, node: leaf("y")),
            ]
        )
        XCTAssertThrowsError(try TreeDiff.apply(delta, to: tree)) { error in
            XCTAssertEqual(error as? TreeDiffError, .conflictingIndex(.root, 1))
        }
    }

    func testApplyRejectsUnknownAndMistypedChangeKeys() {
        let tree = container("root", [leaf("a")])
        let unknown = TreeDelta(
            changed: [
                NodeChange(
                    path: NodePath.root.appending("a"),
                    changes: [AttributeChange(key: "nonsense", before: nil, after: .bool(true))]
                )
            ]
        )
        XCTAssertThrowsError(try TreeDiff.apply(unknown, to: tree)) { error in
            XCTAssertEqual(error as? TreeDiffError, .malformedChange("nonsense"))
        }

        let mistyped = TreeDelta(
            changed: [
                NodeChange(
                    path: NodePath.root.appending("a"),
                    changes: [
                        AttributeChange(
                            key: AttributeChange.isVisibleKey,
                            before: nil,
                            after: .string("yes")
                        )
                    ]
                )
            ]
        )
        XCTAssertThrowsError(try TreeDiff.apply(mistyped, to: tree)) { error in
            XCTAssertEqual(error as? TreeDiffError, .malformedChange(AttributeChange.isVisibleKey))
        }
    }

    func testTreeDiffErrorDescriptionsNameTheOffendingLocation() {
        XCTAssertEqual(TreeDiffError.pathNotFound(.root).description, "no node at path '$root'")
        XCTAssertEqual(
            TreeDiffError.indexOutOfRange(.root, 3).description,
            "index 3 out of range under '$root'"
        )
        XCTAssertEqual(
            TreeDiffError.conflictingIndex(.root, 1).description,
            "index 1 claimed twice under '$root'"
        )
        XCTAssertEqual(
            TreeDiffError.malformedChange("k").description,
            "change key 'k' is unknown or carried a wrong value"
        )
        XCTAssertEqual(TreeDiffError.rootRemoved.description, "delta removed the tree root")
    }

    // MARK: - wire vocabulary

    /// The change keys and the root segment are wire strings an agent reads, so
    /// they are pinned against literals rather than against each other. The keys
    /// are asserted here; `testFieldChangesCoverEveryNonGeometricField` asserts
    /// (also with literals) that the differ actually emits them.
    func testChangeKeyVocabularyMatchesTheDocumentedWireStrings() {
        XCTAssertEqual(AttributeChange.idKey, "id")
        XCTAssertEqual(AttributeChange.roleKey, "role")
        XCTAssertEqual(AttributeChange.textKey, "text")
        XCTAssertEqual(AttributeChange.isVisibleKey, "isVisible")
        XCTAssertEqual(AttributeChange.zIndexKey, "zIndex")
        XCTAssertEqual(AttributeChange.structuralPathKey, "structuralPath")
        XCTAssertEqual(AttributeChange.childIndexKey, "childIndex")
        XCTAssertEqual(AttributeChange.intrinsicWidthKey, "textMetrics.intrinsicWidth")
        XCTAssertEqual(AttributeChange.renderedLineCountKey, "textMetrics.renderedLineCount")
        XCTAssertEqual(AttributeChange.idealLineCountKey, "textMetrics.idealLineCount")
        XCTAssertEqual(AttributeChange.attributePrefix, "attributes.")
        XCTAssertEqual(AttributeChange.attributeKey("verdict.suppress"), "attributes.verdict.suppress")
    }

    func testRootSegmentIsTheFixedPathPrefix() {
        XCTAssertEqual(TreeDiff.rootSegment, "$root")
        XCTAssertEqual(NodePath.root.segments, [TreeDiff.rootSegment])
        // Fixed rather than identity-derived: probing the root must not re-key
        // every path in the tree.
        var root = container("root", [leaf("a")])
        let anonymous = TreeDiff.compute(before: root, after: root)
        XCTAssertTrue(anonymous.isEmpty)
        root.id = "renamed-root"
        XCTAssertEqual(
            TreeDiff.compute(before: container("root", [leaf("a")]), after: root).changed.map(\.path),
            [.root]
        )
    }

    /// A hand-built move applies on its own, which is what a Wave 7 client does
    /// when it replays a delta it received without the tree.
    func testAppliedNodeMoveRelocatesOnlyThatFrame() throws {
        let tree = container("root", [leaf("a"), leaf("b", x: 40)])
        let destination = Rect(x: 90, y: 5, width: 20, height: 20)
        let delta = TreeDelta(
            moved: [NodeMove(path: NodePath.root.appending("b"), from: leaf("b", x: 40).frame, to: destination)]
        )
        let rebuilt = try TreeDiff.apply(delta, to: tree)
        XCTAssertEqual(rebuilt.children.map(\.frame), [leaf("a").frame, destination])
    }

    /// The schema requires `minItems: 1` on a node path. An empty path names
    /// nothing, so it must not cross the JSON boundary in either direction.
    func testEmptyNodePathIsRejectedByBothEncodeAndDecode() {
        XCTAssertThrowsError(try JSONEncoder().encode(NodePath([]))) { error in
            guard case EncodingError.invalidValue(_, let context) = error else {
                return XCTFail("expected invalidValue, got \(error)")
            }
            XCTAssertEqual(context.debugDescription, "node path has no segments")
        }
        XCTAssertThrowsError(try JSONDecoder().decode(NodePath.self, from: Data("[]".utf8))) {
            error in
            guard case DecodingError.dataCorrupted(let context) = error else {
                return XCTFail("expected dataCorrupted, got \(error)")
            }
            XCTAssertEqual(context.debugDescription, "node path has no segments")
        }
    }
}
