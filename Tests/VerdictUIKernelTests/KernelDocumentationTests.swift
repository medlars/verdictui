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

    /// A two-row list where the first row's text outgrows its row and runs into
    /// the second row's text. The two texts have different parents, which is why
    /// `sibling-overlap` cannot see this and `content-overlap` exists.
    private func contentOverlapScenario() -> SemanticNode {
        func row(_ id: String, y: Double, textHeight: Double) -> SemanticNode {
            SemanticNode(
                id: id,
                role: .container,
                frame: Rect(x: 0, y: y, width: 200, height: 24),
                structuralPath: "root/container[\(Int(y / 24))]",
                children: [
                    SemanticNode(
                        id: "\(id)-title",
                        role: .text,
                        frame: Rect(x: 0, y: y, width: 200, height: textHeight),
                        text: id,
                        structuralPath: "root/container[\(Int(y / 24))]/text[0]"
                    )
                ]
            )
        }
        return SemanticNode(
            id: "root",
            role: .container,
            frame: viewport,
            structuralPath: "root",
            children: [row("first", y: 0, textHeight: 40), row("second", y: 24, textHeight: 24)]
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
                // 8 x 6 pt, not the 24 x 18 it was until 2026-08-14: the macOS
                // floor moved from 28 pt (a touch metric, which no native macOS
                // control can satisfy) to 12 pt, so 24 x 18 stopped producing a
                // finding at all and this helper stopped exercising the rule.
                SemanticNode(
                    id: "close",
                    role: .button,
                    frame: Rect(x: 280, y: 16, width: 8, height: 6),
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
            (ContentOverlapRule(), contentOverlapScenario()),
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
        // Counted from the document's own catalog headings rather than pinned to
        // a literal. A hand-maintained number here describes the moment someone
        // last typed it, not the catalog: it goes stale the instant a rule is
        // added, and the failure it produces points at the count instead of at
        // the missing section. Counting the headings also catches the reverse
        // drift a `contains` loop cannot see — a section documenting a rule that
        // no longer exists in the standard set.
        let catalogRuleIDs = text
            .split(separator: "\n")
            .compactMap { line -> String? in
                guard line.hasPrefix("### `"), line.hasSuffix("`") else { return nil }
                return String(line.dropFirst("### `".count).dropLast())
            }
            .filter { id in RuleEngine.standardRules.contains { rule in type(of: rule).id == id } }
        XCTAssertEqual(
            Set(catalogRuleIDs),
            Set(RuleEngine.standardRules.map { type(of: $0).id }),
            "docs/kernel.md's rule catalog and RuleEngine.standardRules disagree"
        )
        XCTAssertEqual(
            catalogRuleIDs.count,
            RuleEngine.standardRules.count,
            "the rule catalog in docs/kernel.md documents a different number of rules"
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

    /// Read row-scoped, not with a whole-document `contains`: the numbers here also
    /// appear in the prose and in the quoted `tap-target` message, so a
    /// document-wide search for "28" stays satisfied while the authoritative table
    /// says something else entirely.
    func testDocsStateTheRealDefaultThresholds() throws {
        let text = try documentation
        let defaults = LintContext(viewport: viewport)
        let rows = try Self.tableRows(after: "| Field | Default | Used by |", in: text)

        func defaultCell(for field: String) throws -> String {
            let row = try XCTUnwrap(
                rows.first { $0.hasPrefix("| `\(field)` |") },
                "no LintContext defaults row for \(field)"
            )
            let cells = row.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            XCTAssertEqual(cells.count, 3, "unexpected defaults-table shape: \(row)")
            return cells[1]
        }

        let tapCell = try defaultCell(for: "minimumTapTarget")
        XCTAssertTrue(
            tapCell.contains(Self.dimensionPhrase(defaults.minimumTapTarget)),
            "defaults table says \(tapCell) for the tap-target minimum"
        )
        let toleranceCell = try defaultCell(for: "truncationTolerance")
        XCTAssertTrue(
            toleranceCell.contains("`\(defaults.truncationTolerance)`"),
            "defaults table says \(toleranceCell) for the truncation tolerance"
        )

        XCTAssertTrue(
            text.contains(ZeroSizeRule.probeRolePrefix),
            "docs must state the probe role prefix zero-size exempts"
        )
    }

    /// Every tap-target dimension the page states, table or prose, must be one a
    /// `LintContext` constructor actually installs — and both must be stated.
    ///
    /// Scoped to the backticked `` `N` × `N` pt `` form the threshold text uses;
    /// example frames and viewports are written plainly (`24 × 18 pt`), so they do
    /// not collide with this.
    func testDocsStateNoTapTargetDimensionTheKernelDoesNotUse() throws {
        let defaults = LintContext(viewport: viewport)
        let allowed: Set<String> = [
            Self.dimensionPhrase(defaults.minimumTapTarget),
            Self.dimensionPhrase(LintContext.touchMinimumTapTarget),
        ]
        let text = try documentation
        let dimension = try Regex("`[0-9.]+` × `[0-9.]+` pt")
        let stated = text.matches(of: dimension).map { String(text[$0.range]) }

        XCTAssertFalse(stated.isEmpty, "docs state no tap-target dimensions at all")
        for phrase in stated {
            XCTAssertTrue(
                allowed.contains(phrase),
                "docs state \(phrase), which no LintContext constructor uses"
            )
        }
        XCTAssertEqual(
            Set(stated),
            allowed,
            "docs must state both the macOS pointer minimum and the touch minimum"
        )
    }

    /// The page's rendering of a tap-target size: `` `28` × `28` pt ``.
    private static func dimensionPhrase(_ size: Size) -> String {
        "`\(size.width.pointsDescription)` × `\(size.height.pointsDescription)` pt"
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
