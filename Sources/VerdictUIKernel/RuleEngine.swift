// VerdictUIKernel — platform-pure. No SwiftUI/AppKit imports allowed in this target.
import Foundation

/// A lint rule: pure function from a semantic tree to findings.
///
/// Rules are `Sendable` value types with no state, so the Wave 6 daemon can hold
/// one rule set and evaluate trees concurrently. A rule must never mutate the tree
/// and must derive every finding from the node data it was given — no ambient
/// state, no I/O, no clock.
public protocol LintRule: Sendable {
    /// Stable kebab-case identifier. It appears in ``Finding/rule``, in
    /// ``LintContext/disabledRules``, and in per-node suppression lists, so
    /// renaming one is a breaking change for consumers.
    static var id: String { get }

    /// Evaluate the whole tree rooted at `root`.
    func evaluate(_ root: SemanticNode, context: LintContext) -> [Finding]
}

/// Everything a rule needs to know beyond the tree itself: the viewport it was
/// laid out in, the platform's minimums, and the caller's rule configuration.
public struct LintContext: Sendable {
    /// Attribute key a view uses to opt a node out of rules:
    /// `.bool(true)` or `.string("*")` suppresses every rule, and a
    /// comma-separated list (`"tap-target,truncation"`) suppresses those rules.
    ///
    /// Every rule honours it. A rule with no suppression path is a rule people
    /// disable wholesale, which is how a lint library loses its users.
    public static let suppressionKey = "verdict.suppress"

    /// Wildcard value for ``suppressionKey``.
    public static let suppressAllRules = "*"

    /// macOS pointer-target minimum (Apple HIG). Smaller than the 44×44 pt touch
    /// minimum on purpose: measuring a mouse-driven UI against a finger target
    /// produces noise, and a rule that cries wolf gets switched off.
    public static let macOSMinimumTapTarget = Size(width: 28, height: 28)

    /// Touch-target minimum (Apple HIG), for scenarios rendered at iOS metrics.
    public static let touchMinimumTapTarget = Size(width: 44, height: 44)

    /// Scenario name recorded in the resulting ``Verdict``.
    public var scenario: String
    /// Bounds the tree was laid out in — the reference frame for ``OffscreenRule``.
    public var viewport: Rect
    /// Minimum hit size ``TapTargetRule`` enforces on interactive roles.
    public var minimumTapTarget: Size
    /// Slack, in points, before a width shortfall counts as truncation. Absorbs
    /// sub-pixel layout rounding so a 0.001 pt shortfall is not a defect.
    public var truncationTolerance: Double
    /// Lines a text may wrap onto before ``ExcessiveWrapRule`` reports it.
    ///
    /// Three, i.e. a fourth line is the finding. Chosen from measurement rather
    /// than taste — hosting one 13 pt string at seven widths gave two-line
    /// wraps at intrinsic/frame ratios 1.54, 1.88 and 2.00, all of them
    /// ordinary, and the defect that prompted the rule (a header subtitle at
    /// 82 pt) wrapped onto FIVE. Line count is the discriminating variable and
    /// the ratio is not: `Internationalization` at 58 pt has ratio 2.00 and
    /// wraps to two lines, which is fine, while the real defect sits at 3.88.
    /// A rule keyed on ratio alone would report the first and could not
    /// separate them.
    public var maximumWrappedLines: Int
    /// Per-rule severity replacement, e.g. demote `tap-target` to a warning.
    public var severityOverrides: [String: Finding.Severity]
    /// Rules skipped entirely by ``RuleEngine/run(rules:on:context:)``.
    public var disabledRules: Set<String>

    public init(
        scenario: String = "unnamed",
        viewport: Rect,
        minimumTapTarget: Size = LintContext.macOSMinimumTapTarget,
        truncationTolerance: Double = 0.5,
        maximumWrappedLines: Int = 3,
        severityOverrides: [String: Finding.Severity] = [:],
        disabledRules: Set<String> = []
    ) {
        self.scenario = scenario
        self.viewport = viewport
        self.minimumTapTarget = minimumTapTarget
        self.truncationTolerance = truncationTolerance
        self.maximumWrappedLines = maximumWrappedLines
        self.severityOverrides = severityOverrides
        self.disabledRules = disabledRules
    }

    /// Context with macOS platform minimums (the default for the desktop probe).
    public static func macOS(viewport: Rect, scenario: String = "unnamed") -> LintContext {
        LintContext(scenario: scenario, viewport: viewport, minimumTapTarget: macOSMinimumTapTarget)
    }

    /// Context with touch platform minimums.
    public static func touch(viewport: Rect, scenario: String = "unnamed") -> LintContext {
        LintContext(scenario: scenario, viewport: viewport, minimumTapTarget: touchMinimumTapTarget)
    }

    /// Whether `node` opted out of `ruleID` via ``suppressionKey``.
    public func isSuppressed(rule ruleID: String, on node: SemanticNode) -> Bool {
        guard let directive = node.attributes[LintContext.suppressionKey] else { return false }
        if let flag = directive.boolValue { return flag }
        guard let list = directive.stringValue else { return false }
        return list.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .contains { $0 == ruleID || $0 == LintContext.suppressAllRules }
    }

    /// The severity to report for `ruleID`, honouring ``severityOverrides``.
    public func severity(for ruleID: String, default fallback: Finding.Severity) -> Finding.Severity
    {
        severityOverrides[ruleID] ?? fallback
    }

    /// Build a finding for `node`, or `nil` if the node suppressed this rule.
    ///
    /// Rules call this instead of constructing ``Finding`` directly, so
    /// suppression and severity overrides cannot be forgotten by a new rule.
    public func makeFinding(
        rule ruleID: String,
        node: SemanticNode,
        message: String,
        suggestion: String?,
        defaultSeverity: Finding.Severity
    ) -> Finding? {
        guard !isSuppressed(rule: ruleID, on: node) else { return nil }
        return Finding(
            rule: ruleID,
            severity: severity(for: ruleID, default: defaultSeverity),
            nodeID: node.evidenceLabel,
            message: message,
            suggestion: suggestion
        )
    }
}

/// Runs a rule set over a tree and packages the findings as a ``Verdict``.
public enum RuleEngine {
    /// The Wave 1 rule library, in evaluation order.
    ///
    /// ``DuplicateProbeIDRule`` runs first because an id collision undermines the
    /// evidence every other rule produces about the same tree.
    public static let standardRules: [any LintRule] = [
        DuplicateProbeIDRule(),
        ZeroSizeRule(),
        SiblingOverlapRule(),
        ContentOverlapRule(),
        OffscreenRule(),
        TruncationRule(),
        ExcessiveWrapRule(),
        TapTargetRule(),
    ]

    /// Identifier of the structural vacuity guard. Not a ``LintRule`` id: no
    /// rule with this name exists, and naming it in ``LintContext/disabledRules``
    /// does nothing.
    public static let vacuousVerdictRule = "vacuous-verdict"

    /// Whether any node in the tree carries a probe id.
    ///
    /// Depth-first over the whole tree, not just the root's children: a probe
    /// nested under unprobed containers is still an observation. The root itself
    /// never counts — it is synthesized by `verdictRoot` and is always present,
    /// so counting it would make every tree look observed.
    private static func containsProbedNode(_ node: SemanticNode) -> Bool {
        for child in node.children {
            if !child.id.isEmpty || containsProbedNode(child) { return true }
        }
        return false
    }

    /// Evaluate `rules` against `root` and return the verdict.
    ///
    /// Findings are ordered by rule, then by the rule's own traversal order, so
    /// the evidence is byte-stable for a given tree — a prerequisite for baselines
    /// and for diffing verdicts between runs. `timestamp` and
    /// ``Verdict/Timing/evaluateMs`` are wall-clock facts and therefore the only
    /// parts of the result that vary between identical runs.
    ///
    /// Rules named in ``LintContext/disabledRules`` are not evaluated at all.
    ///
    /// - Parameter includeTree: whether to embed `root` in the verdict. Off by default:
    ///   the tree dwarfs the findings, and the MCP surface pays per token.
    public static func run(
        rules: [any LintRule],
        on root: SemanticNode,
        context: LintContext,
        includeTree: Bool = false
    ) -> Verdict {
        var findings: [Finding] = []
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            // STRUCTURAL, not a rule, and evaluated before them. Every rule
            // iterates children, so a tree with no probed node yields zero
            // findings, and zero findings derives to PASS -- the engine
            // announcing a screen is fine on the strength of having observed
            // nothing. Measured 2026-08-08 on a real app view hosted without
            // probes: squeezed to an eighth of its width, visibly broken, PASS
            // with an empty findings array.
            //
            // A LintRule would be the natural home and is the wrong one:
            // `disabledRules` could switch it off, and the one guard whose
            // absence is invisible must not be opt-out. Deliberately NOT routed
            // through `makeFinding`, because that consults per-node suppression
            // -- there is no node to suppress on here, and a tree-level
            // suppression key would reopen the hole from the other side.
            if !containsProbedNode(root) {
                findings.append(
                    Finding(
                        rule: vacuousVerdictRule,
                        severity: .error,
                        nodeID: root.evidenceLabel,
                        message:
                            "no probed nodes reached the kernel, so no rule could observe "
                            + "anything — this verdict is vacuous, not clean",
                        suggestion:
                            "attach .verdictProbe(_:role:text:) to the elements this "
                            + "scenario is meant to verify, or apply @Verifiable to the view"
                    )
                )
            }
            for rule in rules where !context.disabledRules.contains(type(of: rule).id) {
                findings.append(contentsOf: rule.evaluate(root, context: context))
            }
        }
        return Verdict(
            scenario: context.scenario,
            findings: findings,
            tree: includeTree ? root : nil,
            timing: Verdict.Timing(evaluateMs: elapsed.milliseconds)
        )
    }
}
