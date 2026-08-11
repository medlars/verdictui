// VerdictUIKernel — platform-pure. No SwiftUI/AppKit imports allowed in this target.
import Foundation

/// A recorded semantic tree a later run is compared against.
///
/// Rules catch defects the kernel can name; expectations catch the ones an
/// author can name. A baseline catches the third class — *unintended change* —
/// where nothing is detectably wrong and nothing was asserted, but the screen is
/// no longer the screen that was reviewed. It is the regression channel, and it
/// is the one that needs the most careful destructive-update handling, because
/// the cheapest way to make a failing baseline pass is to overwrite it.
///
/// ## Canonical form
///
/// A baseline is only useful if two runs of unchanged code produce byte-identical
/// files, so the tree is canonicalized before it is written: object keys sorted,
/// and every coordinate quantized to ``quantum``. Quantization is not cosmetic —
/// SwiftUI's layout arithmetic produces sub-pixel jitter that is invisible on
/// screen and would otherwise make every baseline fail on the next machine.
public struct Baseline: Equatable, Sendable {
    /// Scenario this baseline records.
    public let scenario: String
    /// Schema version the tree was recorded under, so a later kernel can refuse
    /// (or migrate) a file it does not understand rather than misreading it.
    public let schemaVersion: String
    /// The canonicalized tree.
    public let tree: SemanticNode

    /// Grid every coordinate is snapped to, in points.
    ///
    /// Half a point: the same band every geometry rule treats as noise, chosen
    /// for the reason ``SiblingOverlapRule/tolerance`` documents. A finer grid
    /// re-admits the jitter this exists to remove; a coarser one would hide real
    /// single-point moves that `misalignment` reports as defects.
    public static let quantum = 0.5

    public init(scenario: String, schemaVersion: String = SchemaVersion.current, tree: SemanticNode)
    {
        self.scenario = scenario
        self.schemaVersion = schemaVersion
        self.tree = Baseline.canonicalize(tree)
    }

    /// The tree with every coordinate snapped to ``quantum``.
    ///
    /// Applied on the way in rather than at compare time, so what is stored is
    /// what is compared and a reader of the file sees the values the engine
    /// actually uses. Non-finite coordinates are left untouched: they are a
    /// defect `zero-size` owns, and rounding them would launder a broken frame
    /// into a plausible-looking one.
    static func canonicalize(_ node: SemanticNode) -> SemanticNode {
        var copy = node
        copy.frame = Rect(
            x: quantize(node.frame.x),
            y: quantize(node.frame.y),
            width: quantize(node.frame.width),
            height: quantize(node.frame.height)
        )
        copy.children = node.children.map(canonicalize)
        return copy
    }

    static func quantize(_ value: Double) -> Double {
        guard value.isFinite else { return value }
        return (value / quantum).rounded() * quantum
    }
}

extension Baseline: Codable {
    private enum CodingKeys: String, CodingKey {
        case scenario, schemaVersion, tree
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            scenario: try container.decode(String.self, forKey: .scenario),
            schemaVersion: try container.decode(String.self, forKey: .schemaVersion),
            tree: try container.decode(SemanticNode.self, forKey: .tree)
        )
    }
}

/// The outcome of comparing a live tree against a recorded one.
public struct BaselineComparison: Sendable {
    /// Scenario compared.
    public let scenario: String
    /// The structural difference, empty when the trees agree.
    public let delta: TreeDelta
    /// Findings a verdict should carry — one per significant change.
    public let findings: [Finding]

    /// True when nothing significant changed.
    public var matches: Bool { findings.isEmpty }
}

/// Compares live trees against recorded baselines.
public enum BaselineCheck {
    /// Rule id every baseline finding carries.
    public static let id = "baseline-drift"

    /// Compare `tree` against `baseline`.
    ///
    /// Sub-``Baseline/quantum`` moves are filtered out by canonicalizing the
    /// live tree the same way the baseline was canonicalized — so the
    /// significance filter is the SAME operation that produced the stored file,
    /// rather than a second threshold that could drift away from it.
    public static func compare(
        _ tree: SemanticNode,
        to baseline: Baseline,
        context: LintContext
    ) -> BaselineComparison {
        // A baseline recorded under an incompatible schema cannot be compared:
        // the field set differs, so every difference would be reported as drift
        // and the real answer ("this file predates a schema change") would be
        // buried under noise.
        guard SchemaVersion.isCompatible(baseline.schemaVersion) else {
            return BaselineComparison(
                scenario: baseline.scenario,
                delta: TreeDelta(),
                findings: [
                    Finding(
                        rule: id,
                        severity: .error,
                        nodeID: tree.id,
                        message: "baseline for '\(baseline.scenario)' was recorded under schema "
                            + "\(baseline.schemaVersion), which this kernel "
                            + "(\(SchemaVersion.current)) cannot compare against",
                        suggestion: "re-record the baseline with "
                            + "`verdictui baseline update \(baseline.scenario) --accept`"
                    )
                ]
            )
        }

        let canonical = Baseline.canonicalize(tree)
        let delta = TreeDiff.compute(before: baseline.tree, after: canonical)

        // Built as (path, message) pairs first so every category goes through
        // ONE call to `drift` — suppression and severity handling cannot then
        // drift between the four kinds of change, which is exactly the shape
        // that let the first draft re-emit a suppressed finding.
        var reports: [(path: NodePath, message: String)] = []
        reports += delta.added.map {
            ($0.path, "'\($0.path.description)' is new since the baseline")
        }
        reports += delta.removed.map {
            ($0, "'\($0.description)' was in the baseline and is now gone")
        }
        reports += delta.moved.map {
            (
                $0.path,
                "'\($0.path.description)' moved from "
                    + "\(describe($0.from)) to \(describe($0.to))"
            )
        }
        reports += delta.changed.map {
            (
                $0.path,
                "'\($0.path.description)' changed: "
                    + $0.changes.map(describe).sorted().joined(separator: ", ")
            )
        }

        return BaselineComparison(
            scenario: baseline.scenario,
            delta: delta,
            findings: reports.compactMap {
                drift(tree: canonical, path: $0.path, message: $0.message, context: context)
            }
        )
    }

    /// One drift finding, honouring per-node suppression when the node still
    /// exists in the live tree.
    ///
    /// Returns a non-optional finding for a REMOVED node: there is no live node
    /// to carry a suppression attribute, and a removal that could be silenced by
    /// the markup of the thing that was removed is not silenceable in practice.
    private static func drift(
        tree: SemanticNode,
        path: NodePath,
        message: String,
        context: LintContext
    ) -> Finding? {
        let suggestion =
            "review the change; if intended, re-record with "
            + "`verdictui baseline update \(context.scenario) --accept`"
        // Resolved by the path's LEAF segment rather than by walking the path:
        // `NodePath` segments are sibling-local identities, and an unprobed
        // node's segment is `@`-prefixed and not a probe id. `node(withID:)`
        // declines an empty query, so an unresolvable path takes the
        // unsuppressable branch rather than matching an arbitrary node.
        //
        // The two branches must NOT be collapsed into one `if let` chain with a
        // shared fallback: "no such node" and "the node suppressed this rule"
        // would then produce the same answer, and since `makeFinding` returns
        // nil for a SUPPRESSED node, the fallback would re-emit the very
        // finding the directive silenced. Measured on the first draft: a node
        // carrying `verdict.suppress` still reported its move.
        guard let node = tree.node(withID: path.leaf) else {
            return Finding(
                rule: id,
                severity: context.severity(for: id, default: .error),
                nodeID: path.description,
                message: message,
                suggestion: suggestion
            )
        }
        return context.makeFinding(
            rule: id,
            node: node,
            message: message,
            suggestion: suggestion,
            defaultSeverity: .error
        )
    }

    /// One field change, rendered for a finding message.
    ///
    /// `AttributeChange` carries optional before/after values because a field
    /// can be gained or lost, not only altered — a node that acquires text and
    /// one that loses it are different events, and collapsing both to "text
    /// changed" would leave a reader unable to tell which.
    private static func describe(_ change: AttributeChange) -> String {
        let before = change.before.map(\.description) ?? "nothing"
        let after = change.after.map(\.description) ?? "nothing"
        return "\(change.key) \(before) → \(after)"
    }

    private static func describe(_ rect: Rect) -> String {
        "(\(rect.x.pointsDescription), \(rect.y.pointsDescription)) "
            + "\(rect.width.pointsDescription)x\(rect.height.pointsDescription)"
    }
}
