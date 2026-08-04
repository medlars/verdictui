import XCTest

@testable import VerdictUIKernel

/// Keeps `docs/kernel.md` true.
///
/// The rule catalog quotes a concrete failure message per rule and the role table
/// lists the wire identifiers. Both are copied from the code, and a copy rots: a
/// reworded message or a renamed role leaves the doc confidently wrong, which is
/// worse than a doc that is merely thin. So every quoted string here is produced
/// by running the rule and then looked up in the file.
final class KernelDocumentationTests: XCTestCase {

    private var documentation: String {
        get throws {
            let url = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("docs/kernel.md")
            return try String(contentsOf: url, encoding: .utf8)
        }
    }

    private let viewport = Rect(x: 0, y: 0, width: 320, height: 240)

    private func context() -> LintContext {
        LintContext.macOS(viewport: viewport, scenario: "docs")
    }

    // MARK: - Scenarios, one per rule, matching what docs/kernel.md describes

    private func duplicateProbeIDScenario() -> SemanticNode {
        SemanticNode(
            id: "root",
            role: .container,
            frame: viewport,
            structuralPath: "root",
            children: [
                SemanticNode(
                    id: "save",
                    role: .button,
                    frame: Rect(x: 0, y: 0, width: 80, height: 32),
                    structuralPath: "root/button[0]"
                ),
                SemanticNode(
                    id: "save",
                    role: .button,
                    frame: Rect(x: 0, y: 40, width: 80, height: 32),
                    structuralPath: "root/button[1]"
                ),
            ]
        )
    }

    private func zeroSizeScenario() -> SemanticNode {
        SemanticNode(
            id: "root",
            role: .container,
            frame: viewport,
            structuralPath: "root",
            children: [
                SemanticNode(
                    id: "title",
                    role: .text,
                    frame: Rect(x: 0, y: 0, width: 0, height: 0),
                    text: "Monthly summary",
                    structuralPath: "root/text[0]"
                )
            ]
        )
    }

    private func siblingOverlapScenario() -> SemanticNode {
        SemanticNode(
            id: "root",
            role: .container,
            frame: viewport,
            structuralPath: "root",
            children: [
                SemanticNode(
                    id: "avatar",
                    role: .image,
                    frame: Rect(x: 0, y: 0, width: 48, height: 48),
                    structuralPath: "root/image[0]"
                ),
                SemanticNode(
                    id: "badge",
                    role: .text,
                    frame: Rect(x: 32, y: 32, width: 24, height: 16),
                    text: "9",
                    structuralPath: "root/text[1]"
                ),
            ]
        )
    }

    private func offscreenScenario() -> SemanticNode {
        SemanticNode(
            id: "root",
            role: .container,
            frame: viewport,
            structuralPath: "root",
            children: [
                SemanticNode(
                    id: "sidebar",
                    role: .container,
                    frame: Rect(x: 360, y: 0, width: 200, height: 240),
                    structuralPath: "root/container[0]"
                )
            ]
        )
    }

    private func truncationScenario() -> SemanticNode {
        SemanticNode(
            id: "root",
            role: .container,
            frame: viewport,
            structuralPath: "root",
            children: [
                SemanticNode(
                    id: "title",
                    role: .text,
                    frame: Rect(x: 0, y: 0, width: 120, height: 20),
                    text: "Monthly summary",
                    textMetrics: TextMetrics(
                        intrinsicWidth: 212,
                        renderedLineCount: 1,
                        idealLineCount: 1
                    ),
                    structuralPath: "root/text[0]"
                )
            ]
        )
    }

    private func tapTargetScenario() -> SemanticNode {
        SemanticNode(
            id: "root",
            role: .container,
            frame: viewport,
            structuralPath: "root",
            children: [
                SemanticNode(
                    id: "close",
                    role: .button,
                    frame: Rect(x: 280, y: 16, width: 24, height: 18),
                    structuralPath: "root/button[0]"
                )
            ]
        )
    }

    private func documentedScenarios() -> [(rule: any LintRule, tree: SemanticNode)] {
        [
            (DuplicateProbeIDRule(), duplicateProbeIDScenario()),
            (ZeroSizeRule(), zeroSizeScenario()),
            (SiblingOverlapRule(), siblingOverlapScenario()),
            (OffscreenRule(), offscreenScenario()),
            (TruncationRule(), truncationScenario()),
            (TapTargetRule(), tapTargetScenario()),
        ]
    }

    // MARK: - Tests

    func testEveryDocumentedScenarioActuallyFiresItsRule() throws {
        for (rule, tree) in documentedScenarios() {
            let findings = rule.evaluate(tree, context: context())
            XCTAssertEqual(
                findings.count,
                1,
                "\(type(of: rule).id): docs/kernel.md describes a single-finding scenario"
            )
            XCTAssertEqual(findings.first?.rule, type(of: rule).id)
        }
    }

    func testDocsQuoteTheRealFindingMessageAndSuggestion() throws {
        let text = try documentation
        for (rule, tree) in documentedScenarios() {
            let finding = try XCTUnwrap(rule.evaluate(tree, context: context()).first)
            XCTAssertTrue(
                text.contains(finding.message),
                "docs/kernel.md does not quote \(finding.rule)'s real message:\n\(finding.message)"
            )
            let suggestion = try XCTUnwrap(finding.suggestion)
            XCTAssertTrue(
                text.contains(suggestion),
                "docs/kernel.md does not quote \(finding.rule)'s real suggestion:\n\(suggestion)"
            )
        }
    }

    func testDocsQuoteTheSeverityEachRuleActuallyProduces() throws {
        let text = try documentation
        for (rule, tree) in documentedScenarios() {
            let finding = try XCTUnwrap(rule.evaluate(tree, context: context()).first)
            let row = "`\(finding.rule)` | \(finding.severity.rawValue)"
            XCTAssertTrue(text.contains(row), "docs/kernel.md is missing the row: \(row)")
        }
    }

    func testEverySuppressionPathTheDocsPromiseWorks() throws {
        for (rule, tree) in documentedScenarios() {
            let ruleID = type(of: rule).id
            var suppressed = tree
            // The doc says the attribute goes on the node the finding is attached to.
            let target = try XCTUnwrap(rule.evaluate(tree, context: context()).first).nodeID
            suppressed = Self.annotate(
                suppressed,
                nodeID: target,
                value: .string(ruleID)
            )
            XCTAssertTrue(
                rule.evaluate(suppressed, context: context()).isEmpty,
                "\(ruleID) ignored a per-node suppression naming it"
            )
            let wildcard = Self.annotate(tree, nodeID: target, value: .bool(true))
            XCTAssertTrue(
                rule.evaluate(wildcard, context: context()).isEmpty,
                "\(ruleID) ignored a .bool(true) blanket suppression"
            )
            var disabled = context()
            disabled.disabledRules = [ruleID]
            XCTAssertTrue(
                RuleEngine.run(rules: [rule], on: tree, context: disabled).findings.isEmpty,
                "\(ruleID) ran despite being in disabledRules"
            )
            var demoted = context()
            demoted.severityOverrides = [ruleID: .warning]
            XCTAssertEqual(
                rule.evaluate(tree, context: demoted).first?.severity,
                .warning,
                "\(ruleID) ignored a severity override"
            )
        }
    }

    /// Every case of ``Role`` except `custom`, which has no fixed identifier.
    private static let namedRoles: [Role] = [
        .container, .text, .button, .toggle, .slider, .textField, .image, .list, .listRow,
        .navigation, .tabBar, .menu, .spacer,
    ]

    func testEveryRoleIdentifierAppearsInTheRoleTable() throws {
        let text = try documentation
        for role in Self.namedRoles {
            XCTAssertTrue(
                text.contains("`\(role.identifier)`"),
                "docs/kernel.md's role table is missing \(role.identifier)"
            )
        }
        XCTAssertTrue(
            text.contains("custom(String)"),
            "docs/kernel.md must document the custom escape hatch"
        )
        // A silent gap here would be the whole vocabulary going undocumented, so
        // check the count too: a new case must land in the table.
        XCTAssertEqual(Self.namedRoles.count, 13, "Role gained a case — update the role table")
    }

    /// The interactive and text-bearing columns decide `tap-target` eligibility and
    /// `zero-size` severity, so a wrong cell is a wrong doc, not a cosmetic slip.
    func testTheRoleTableMarksTheRightRolesInteractiveAndTextBearing() throws {
        let rows = try Self.tableRows(
            after: "| Wire identifier | SwiftUI source | Interactive | Text-bearing |",
            in: try documentation
        )
        for role in Self.namedRoles {
            let row = try XCTUnwrap(
                rows.first { $0.hasPrefix("| `\(role.identifier)` |") },
                "no role-table row for \(role.identifier)"
            )
            let cells = row.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            XCTAssertEqual(cells.count, 4, "unexpected role-table shape: \(row)")
            XCTAssertEqual(
                cells[2] == "**yes**",
                role.isInteractive,
                "\(role.identifier): interactive column disagrees with Role.isInteractive"
            )
            XCTAssertEqual(
                cells[3] == "**yes**",
                role.isTextBearing,
                "\(role.identifier): text-bearing column disagrees with Role.isTextBearing"
            )
        }
    }

    func testDocsNameEveryRuleInTheStandardSet() throws {
        let text = try documentation
        for rule in RuleEngine.standardRules {
            XCTAssertTrue(
                text.contains("`\(type(of: rule).id)`"),
                "docs/kernel.md does not document \(type(of: rule).id)"
            )
        }
        XCTAssertEqual(
            RuleEngine.standardRules.count,
            6,
            "the rule catalog in docs/kernel.md is written for six rules"
        )
    }

    func testDocsQuoteTheContractsCurrentSchemaVersionAndKeys() throws {
        let text = try documentation
        XCTAssertTrue(text.contains(SchemaVersion.current), "docs must state the schema version")
        for key in [
            "schemaVersion", "scenario", "timestamp", "status", "findings", "tree", "delta",
            "timing", "settleMs", "evaluateMs", "suggestion", "structuralPath", "textMetrics",
            "isVisible", "zIndex", "attributes",
        ] {
            XCTAssertTrue(text.contains(key), "schema reference is missing \(key)")
        }
        XCTAssertTrue(
            text.contains(LintContext.suppressionKey),
            "docs must name the suppression attribute key"
        )
        XCTAssertTrue(text.contains(TreeDiff.rootSegment), "docs must name the root path segment")
    }

    func testDocsStateTheRealDefaultThresholds() throws {
        let text = try documentation
        let defaults = LintContext(viewport: viewport)
        XCTAssertTrue(
            text.contains("\(defaults.minimumTapTarget.width.pointsDescription)"),
            "docs must state the default tap-target minimum"
        )
        XCTAssertTrue(
            text.contains("\(LintContext.touchMinimumTapTarget.width.pointsDescription)"),
            "docs must state the touch minimum"
        )
        XCTAssertTrue(
            text.contains("\(defaults.truncationTolerance)"),
            "docs must state the truncation tolerance"
        )
        XCTAssertTrue(
            text.contains(ZeroSizeRule.probeRolePrefix),
            "docs must state the probe role prefix zero-size exempts"
        )
    }

    /// Body rows of the markdown table whose header line is `header`.
    ///
    /// Scoped to one table on purpose: matching `| \`text\` |` anywhere in the file
    /// also hits the `SemanticNode` field table, and a test that reads the wrong
    /// table proves nothing about the right one.
    private static func tableRows(after header: String, in text: String) throws -> [String] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let headerIndex = try XCTUnwrap(
            lines.firstIndex(of: header),
            "docs/kernel.md has no table with header: \(header)"
        )
        let body = lines[(headerIndex + 1)...].prefix { $0.hasPrefix("|") }
        return body.filter { !$0.contains("---") }
    }

    /// Copy of `tree` with a suppression attribute on the node whose evidence
    /// label matches `nodeID`.
    private static func annotate(
        _ tree: SemanticNode,
        nodeID: String,
        value: AttributeValue
    ) -> SemanticNode {
        var copy = tree
        if copy.evidenceLabel == nodeID {
            copy.attributes[LintContext.suppressionKey] = value
        }
        copy.children = copy.children.map { annotate($0, nodeID: nodeID, value: value) }
        return copy
    }
}
