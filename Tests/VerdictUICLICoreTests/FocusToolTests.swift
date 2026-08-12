import XCTest

@testable import VerdictUICLICore
@testable import VerdictUIDemoScenarios
@testable import VerdictUIKernel

/// `focus(nodePath)` — the follow-up verb for a tree that came back
/// `truncated: true`.
///
/// The property under test is the ROUND TRIP, not the tool's presence: a
/// truncated tree must name nodes that `focus` can actually resolve. A test
/// that only asserted the tool exists would pass against a `focus` that
/// resolves nothing, and the defect this closes is precisely an agent being
/// told its picture is incomplete with no verb to complete it.
@MainActor
final class FocusToolTests: XCTestCase {

    private func engine() -> VerdictEngine {
        VerdictEngine(
            registry: DemoScenarios.registry,
            baselines: BaselineStore.standard(
                root: URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("verdictui-focus-\(UUID().uuidString)")
            )
        )
    }

    private let scenario = "demo-clean-settings"

    private func tree(_ result: DaemonResult?) throws -> SemanticNode {
        guard case .tree(let tree)? = result else {
            throw XCTSkip("the daemon did not return a tree")
        }
        return tree
    }

    // MARK: - The round trip

    func testATruncatedTreeNamesNodesFocusCanResolve() async throws {
        // The whole point, end to end: render small enough to truncate, then
        // resolve what the truncation left addressable. If these two vocabularies
        // ever diverge, an agent reading `truncated: true` has a path it cannot
        // use, which is the same dead end as having no `focus` at all.
        let whole = try tree(
            await VerdictDaemon.handle(
                DaemonRequest(method: "render", scenario: scenario), engine: engine()
            ).result)

        let compact = CompactTree(whole, maxNodes: 3)
        XCTAssertTrue(
            compact.truncated,
            "the fixture did not truncate, so this test is not exercising the case focus exists for")

        // Every path a truncated tree publishes must resolve. Not "at least
        // one" — a partial vocabulary is the defect, since an agent cannot know
        // which of the names it was given are the usable ones.
        for path in compact.structuralPaths where !path.isEmpty {
            let response = await VerdictDaemon.handle(
                DaemonRequest(method: "focus", scenario: scenario, nodePath: path),
                engine: engine()
            )
            XCTAssertTrue(
                response.ok,
                "focus could not resolve '\(path)', a path the compact tree published")
        }
    }

    func testFocusReturnsTheSubtreeRatherThanTheWholeScreen() async throws {
        let whole = try tree(
            await VerdictDaemon.handle(
                DaemonRequest(method: "render", scenario: scenario), engine: engine()
            ).result)

        let target = try XCTUnwrap(
            whole.flattened().first { $0.id == "button-row" },
            "the fixture no longer contains the node this test focuses on")

        let focused = try tree(
            await VerdictDaemon.handle(
                DaemonRequest(method: "focus", scenario: scenario, nodePath: "button-row"),
                engine: engine()
            ).result)

        XCTAssertEqual(focused.id, "button-row", "focus returned the wrong node")
        XCTAssertEqual(
            focused.flattened().count, target.flattened().count,
            "focus returned a different number of nodes than the subtree holds")

        // The control that makes the assertion mean something: a `focus` that
        // ignored its argument and returned the whole tree would satisfy every
        // assertion above about content, since the subtree is contained in it.
        XCTAssertLessThan(
            focused.flattened().count, whole.flattened().count,
            "focus returned the whole screen — the node path is being ignored")
    }

    func testFocusResolvesAStructuralPathAsWellAsAProbeID() async throws {
        // Both vocabularies must work. A verdict cites whichever the node has,
        // so supporting only one leaves half the nodes an agent can SEE
        // unreachable by the verb that exists to reach them.
        let whole = try tree(
            await VerdictDaemon.handle(
                DaemonRequest(method: "render", scenario: scenario), engine: engine()
            ).result)

        let node = try XCTUnwrap(
            whole.flattened().first { !$0.structuralPath.isEmpty && !$0.id.isEmpty },
            "no node carries both a structural path and a probe id")

        for path in [node.structuralPath, node.id] {
            let response = await VerdictDaemon.handle(
                DaemonRequest(method: "focus", scenario: scenario, nodePath: path),
                engine: engine()
            )
            XCTAssertTrue(response.ok, "focus could not resolve '\(path)'")
        }
    }

    // MARK: - Refusals are about the REQUEST, never the UI

    func testFocusOnAnUnknownPathIsRefusedRatherThanAnsweredWithAnEmptyTree() async {
        let response = await VerdictDaemon.handle(
            DaemonRequest(method: "focus", scenario: scenario, nodePath: "root/nothing[99]"),
            engine: engine()
        )

        // An empty tree would be a plausible-looking lie: the agent would read
        // it as "that node has no children" rather than "that node does not
        // exist", and act on a screen it never saw.
        XCTAssertFalse(response.ok, "an unknown path must be refused, not answered")
        let message = response.error ?? ""
        XCTAssertTrue(
            message.contains("root/nothing[99]"),
            "the refusal must quote the path that failed, got: \(message)")
    }

    func testFocusWithoutAPathIsRefused() async {
        let response = await VerdictDaemon.handle(
            DaemonRequest(method: "focus", scenario: scenario), engine: engine())
        XCTAssertFalse(response.ok, "focus without a nodePath must be refused")
    }

    // MARK: - The tool is reachable

    func testFocusEncodesAsACompactTreeOnTheWire() throws {
        // Read the BYTES a foreign client sees, with a different parser, against
        // the documented keys — not through the type that produced them.
        //
        // This is `no.md` #35's rule, and it earned its place here: driving the
        // shipped binary during this task, a hand-written reader looked for
        // `id` and `children` and reported an EMPTY node, which read as a broken
        // `focus`. The tool was correct; the reader was checking the wrong
        // shape. The MCP surface publishes trees as a CompactTree — parallel
        // arrays plus a parent index — and a test that decodes with `SemanticNode`
        // would agree with itself no matter which shape actually travelled.
        let subtree = SemanticNode(
            id: "button-row",
            role: .container,
            frame: Rect(x: 60, y: 175, width: 204, height: 32),
            children: [
                SemanticNode(
                    id: "cancel-button", role: .button,
                    frame: Rect(x: 60, y: 175, width: 96, height: 32), text: "Cancel"),
                SemanticNode(
                    id: "save-button", role: .button,
                    frame: Rect(x: 168, y: 175, width: 96, height: 32), text: "Save"),
            ]
        )

        let data = try JSONEncoder().encode(CompactTree(subtree))
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(
            raw["ids"] as? [String], ["button-row", "cancel-button", "save-button"],
            "the published key is 'ids', a parallel array — not a nested 'children' tree")
        XCTAssertEqual(
            raw["parents"] as? [Int], [-1, 0, 0],
            "the focused node must be the ROOT of what it returns (parent -1)")
    }

    func testTheCatalogPublishesFocusWithTheParameterItReads() throws {
        // A tool the dispatch handles but the catalog never advertises is
        // unreachable: a client discovers tools by their schema and cannot
        // guess an undocumented verb.
        let focus = try XCTUnwrap(
            MCPServer.tools.first { $0.name == "focus" },
            "focus is dispatched but absent from the tool catalog")

        XCTAssertNotNil(
            focus.inputSchema.properties["node_path"],
            "focus reads node_path but does not declare it")
        XCTAssertTrue(
            focus.inputSchema.required.contains("node_path"),
            "node_path is required by the dispatch, so the schema must say so")
    }
}
