import XCTest

@testable import VerdictUIKernel

/// Task 3 coverage: rule dispatch, ordering, suppression, and severity overrides,
/// exercised against stub rules so the engine is tested independently of the
/// six shipped rules.
final class RuleEngineTests: XCTestCase {

    /// Flags every node whose id starts with `bad`, so a test can plant findings
    /// at exact positions in the tree.
    private struct StubRule: LintRule {
        static let id = "stub"

        func evaluate(_ root: SemanticNode, context: LintContext) -> [Finding] {
            root.flattened().compactMap { node in
                guard node.id.hasPrefix("bad") else { return nil }
                return context.makeFinding(
                    rule: Self.id,
                    node: node,
                    message: "'\(node.id)' is bad",
                    suggestion: "stop being bad",
                    defaultSeverity: .error
                )
            }
        }
    }

    /// Always warns about the root — used to prove rule order is preserved.
    private struct SecondStubRule: LintRule {
        static let id = "second-stub"

        func evaluate(_ root: SemanticNode, context: LintContext) -> [Finding] {
            [
                context.makeFinding(
                    rule: Self.id,
                    node: root,
                    message: "root seen",
                    suggestion: nil,
                    defaultSeverity: .warning
                )
            ].compactMap { $0 }
        }
    }

    private let viewport = Rect(x: 0, y: 0, width: 400, height: 300)

    private func tree(rootAttributes: [String: AttributeValue] = [:]) -> SemanticNode {
        SemanticNode(
            id: "root",
            role: .container,
            frame: viewport,
            attributes: rootAttributes,
            children: [
                SemanticNode(id: "good", role: .text, frame: Rect(x: 0, y: 0, width: 10, height: 10)),
                SemanticNode(id: "bad1", role: .text, frame: Rect(x: 0, y: 20, width: 10, height: 10)),
                SemanticNode(id: "bad2", role: .text, frame: Rect(x: 0, y: 40, width: 10, height: 10)),
            ]
        )
    }

    // MARK: - LintContext configuration

    func testDefaultContextUsesMacOSPointerMinimum() {
        let context = LintContext(viewport: viewport)
        XCTAssertEqual(context.minimumTapTarget, Size(width: 28, height: 28))
        XCTAssertEqual(context.truncationTolerance, 0.5)
        XCTAssertEqual(context.scenario, "unnamed")
        XCTAssertTrue(context.disabledRules.isEmpty)
        XCTAssertTrue(context.severityOverrides.isEmpty)
    }

    func testPlatformPresetsCarryTheirMinimums() {
        XCTAssertEqual(
            LintContext.macOS(viewport: viewport, scenario: "s").minimumTapTarget,
            LintContext.macOSMinimumTapTarget
        )
        XCTAssertEqual(
            LintContext.touch(viewport: viewport, scenario: "s").minimumTapTarget,
            LintContext.touchMinimumTapTarget
        )
        XCTAssertEqual(LintContext.touch(viewport: viewport, scenario: "s").scenario, "s")
    }

    func testSuppressionAcceptsBoolWildcardAndRuleList() {
        let context = LintContext(viewport: viewport)
        func node(_ directive: AttributeValue?) -> SemanticNode {
            SemanticNode(
                id: "n",
                role: .text,
                frame: viewport,
                attributes: directive.map { [LintContext.suppressionKey: $0] } ?? [:]
            )
        }
        XCTAssertFalse(context.isSuppressed(rule: "stub", on: node(nil)))
        XCTAssertTrue(context.isSuppressed(rule: "stub", on: node(.bool(true))))
        XCTAssertFalse(context.isSuppressed(rule: "stub", on: node(.bool(false))))
        XCTAssertTrue(context.isSuppressed(rule: "stub", on: node(.string("*"))))
        XCTAssertTrue(context.isSuppressed(rule: "stub", on: node(.string("other, stub"))))
        XCTAssertFalse(context.isSuppressed(rule: "stub", on: node(.string("other"))))
        XCTAssertFalse(context.isSuppressed(rule: "stub", on: node(.number(1))))
    }

    func testSeverityOverrideReplacesTheRuleDefault() {
        let context = LintContext(viewport: viewport, severityOverrides: ["stub": .warning])
        XCTAssertEqual(context.severity(for: "stub", default: .error), .warning)
        XCTAssertEqual(context.severity(for: "other", default: .error), .error)
    }

    func testMakeFindingFallsBackToStructuralPathWhenUnprobed() throws {
        let context = LintContext(viewport: viewport)
        let node = SemanticNode(
            id: "",
            role: .text,
            frame: viewport,
            structuralPath: "root/text[0]"
        )
        let finding = try XCTUnwrap(
            context.makeFinding(
                rule: "stub",
                node: node,
                message: "m",
                suggestion: "s",
                defaultSeverity: .warning
            )
        )
        XCTAssertEqual(finding.nodeID, "root/text[0]", "evidence must still point somewhere")
        XCTAssertEqual(finding.suggestion, "s")
    }

    // MARK: - RuleEngine.run

    func testRunCollectsFindingsInRuleThenTraversalOrder() {
        let verdict = RuleEngine.run(
            rules: [StubRule(), SecondStubRule()],
            on: tree(),
            context: LintContext(scenario: "order", viewport: viewport)
        )
        XCTAssertEqual(verdict.scenario, "order")
        XCTAssertEqual(verdict.status, .fail)
        XCTAssertEqual(
            verdict.findings.map { "\($0.rule):\($0.nodeID)" },
            ["stub:bad1", "stub:bad2", "second-stub:root"]
        )
    }

    func testRunIsDeterministicAcrossRepeatedEvaluations() {
        let context = LintContext(viewport: viewport)
        let first = RuleEngine.run(rules: [StubRule(), SecondStubRule()], on: tree(), context: context)
        let second = RuleEngine.run(rules: [StubRule(), SecondStubRule()], on: tree(), context: context)
        XCTAssertEqual(first, second)
    }

    func testDisabledRuleIsNotEvaluated() {
        let verdict = RuleEngine.run(
            rules: [StubRule(), SecondStubRule()],
            on: tree(),
            context: LintContext(viewport: viewport, disabledRules: ["stub"])
        )
        XCTAssertEqual(verdict.findings.map(\.rule), ["second-stub"])
        XCTAssertEqual(verdict.status, .pass, "only a warning survived")
    }

    func testPerNodeSuppressionRemovesOnlyThatNodesFinding() {
        var root = tree()
        root.children[1].attributes[LintContext.suppressionKey] = .string("stub")
        let verdict = RuleEngine.run(
            rules: [StubRule()],
            on: root,
            context: LintContext(viewport: viewport)
        )
        XCTAssertEqual(verdict.findings.map(\.nodeID), ["bad2"])
    }

    func testSeverityOverrideCanTurnAFailIntoAPass() {
        let verdict = RuleEngine.run(
            rules: [StubRule()],
            on: tree(),
            context: LintContext(viewport: viewport, severityOverrides: ["stub": .warning])
        )
        XCTAssertEqual(verdict.findings.count, 2)
        XCTAssertTrue(verdict.findings.allSatisfy { $0.severity == .warning })
        XCTAssertEqual(verdict.status, .pass)
    }

    func testEmptyRuleSetProducesAPassingVerdict() {
        let verdict = RuleEngine.run(
            rules: [],
            on: tree(),
            context: LintContext(scenario: "empty", viewport: viewport)
        )
        XCTAssertEqual(verdict.status, .pass)
        XCTAssertTrue(verdict.findings.isEmpty)
        XCTAssertEqual(verdict.scenario, "empty")
    }

    func testRuleIdentifiersAreReachableThroughTheExistential() {
        let rules: [any LintRule] = [StubRule(), SecondStubRule()]
        XCTAssertEqual(rules.map { type(of: $0).id }, ["stub", "second-stub"])
    }
}
