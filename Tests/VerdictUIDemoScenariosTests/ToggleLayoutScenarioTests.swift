import VerdictUIDemoScenarios
import VerdictUIKernel
import VerdictUIProbe
import XCTest

/// Wave 3's act-and-observe fixture, held to the two things Wave 3 will assume
/// about it: both layouts render today, and neither has a defect of its own.
///
/// The second matters more than it looks. Wave 3's proof is "tap the toggle and
/// the verdict changes in exactly this way"; if the fixture carried a planted
/// defect, every verdict on either side of the action would be a FAIL and the
/// interesting difference would be buried in noise the action did not cause.
final class ToggleLayoutScenarioTests: XCTestCase {
    /// See ``DemoScenarioRenderingTests/invokeTest()``: without draining the
    /// pool the hosted AppKit hierarchies accumulate and wedge the suite.
    override func invokeTest() { autoreleasepool { super.invokeTest() } }

    /// The second layout is also reachable by construction (seeded
    /// `isExpanded: true`); Wave 3 action injection covers the live flip path.
    @MainActor
    func testTheExpandedBranchRendersUnderTheSameName() async throws {
        let expanded = ToggleLayoutScenario(isExpanded: true)
        XCTAssertEqual(
            expanded.name,
            ToggleLayoutScenario().name,
            "the state changed the scenario's identity, so Wave 3 could not diff the two trees"
        )

        let tree = try await Self.tree(isExpanded: true)

        XCTAssertNotNil(tree.node(withID: "advanced-toggle"), "the toggle left the expanded tree")
        XCTAssertNotNil(
            tree.node(withID: "advanced-detail"),
            "the expanded branch did not publish its detail text"
        )
        XCTAssertNotNil(
            tree.node(withID: "clear-cache-button"),
            "the expanded branch did not publish its action button"
        )
        XCTAssertNil(
            tree.node(withID: "collapsed-summary"),
            "the collapsed branch's text is still in the expanded tree, so the Bool changed nothing"
        )
    }

    @MainActor
    func testTheDefaultCollapsedStateIsClean() async throws {
        try await Self.assertNoFindings(isExpanded: false)
    }

    @MainActor
    func testTheExpandedStateIsClean() async throws {
        try await Self.assertNoFindings(isExpanded: true)
    }

    @MainActor
    private static func assertNoFindings(
        isExpanded: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let tree = try await tree(isExpanded: isExpanded)
        let verdict = RuleEngine.run(
            rules: RuleEngine.standardRules,
            on: tree,
            context: .macOS(viewport: tree.frame, scenario: ToggleLayoutScenario.scenarioName)
        )

        XCTAssertEqual(
            verdict.findings.map(\.rule),
            [],
            "the toggle fixture (isExpanded: \(isExpanded)) is not clean: "
                + verdict.findings.map { "\($0.rule) on \($0.nodeID): \($0.message)" }
                .joined(separator: "; "),
            file: file,
            line: line
        )
    }

    @MainActor
    private static func tree(isExpanded: Bool) async throws -> SemanticNode {
        let host = OracleHost(
            scenario: ToggleLayoutScenario(isExpanded: isExpanded),
            viewport: ToggleLayoutScenario.recommendedViewport
        )
        return try await host.currentTree()
    }
}
