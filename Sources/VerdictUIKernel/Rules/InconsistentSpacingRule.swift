// VerdictUIKernel — platform-pure. No SwiftUI/AppKit imports allowed in this target.
import Foundation

/// One gap in a stack must not differ from the rhythm the others establish.
///
/// The defect is a list of eight rows spaced 12 pt apart with a single 20 pt gap
/// in the middle — a stray `.padding(.bottom, 8)`, a conditional insert that
/// brought its own spacing, one row using a different container. Every frame is
/// the size it asked for, nothing overlaps or clips, so no other rule can see
/// it; a human sees the broken rhythm immediately.
///
/// ## Why the modal gap and not the mean
///
/// The rule compares each gap against the MODE — the gap value that occurs most
/// often — never the mean or median. A mean is dragged by the very outlier being
/// hunted: with gaps `12, 12, 12, 12, 20` the mean is 13.6, so the true rhythm
/// (12) is no longer any gap's expected value and all five gaps read as slightly
/// wrong. The mode is the rhythm the author actually wrote, and the outlier is
/// then the one gap that disagrees with it.
///
/// ## Why a majority is required before reporting anything
///
/// A rhythm has to exist before a deviation from it means anything. Gaps of
/// `8, 20, 33` have a mode only by accident of counting, and reporting the odd
/// one out would be inventing an intent the layout never expressed. So the rule
/// stays silent unless the modal gap accounts for more than half the gaps
/// (``minimumRhythmShare``) and there are at least ``minimumGapCount`` of them —
/// deliberately varied layouts produce no findings at all rather than noise.
///
/// Severity is `warning`: uneven spacing is sometimes deliberate (a visual group
/// break before a footer), and the kernel cannot read intent. Suppress per node
/// with `attributes["verdict.suppress"] = .string("inconsistent-spacing")`.
public struct InconsistentSpacingRule: LintRule {
    public static let id = "inconsistent-spacing"

    /// Gaps differing by less than this are the same gap. Matches the float-noise
    /// band the other geometry rules use, for the reason ``SiblingOverlapRule``
    /// documents: three rules disagreeing about one hairline teaches an agent to
    /// discount all three.
    public static let quantum = 0.5

    /// Fewer gaps than this cannot establish a rhythm. Three gaps means four
    /// laid-out siblings — with two gaps, "the odd one out" is a coin toss
    /// between them, and calling either a defect states more than the tree
    /// supports.
    public static let minimumGapCount = 3

    /// The modal gap must account for more than this share of all gaps before
    /// any deviation is reported. A strict majority: below it there is no
    /// dominant rhythm, only a spread of values.
    public static let minimumRhythmShare = 0.5

    /// Axis a sibling group is stacked along.
    ///
    /// Deliberately inferred rather than assumed: a `VStack` and an `HStack`
    /// produce the same node shape, and measuring vertical gaps in a row yields
    /// nonsense (every gap is zero or negative). A group that is neither cleanly
    /// vertical nor cleanly horizontal — a grid, a `ZStack`, an absolute layout
    /// — has no single spacing rhythm to check, so the rule declines to judge it
    /// rather than picking an axis and reporting whatever falls out.
    enum Axis: Sendable {
        case vertical
        case horizontal

        /// The gap between `first` and `second` along this axis, where `second`
        /// is the later sibling in layout order.
        func gap(from first: Rect, to second: Rect) -> Double {
            switch self {
            case .vertical: second.y - first.maxY
            case .horizontal: second.x - first.maxX
            }
        }

        /// The name a finding reports for a gap on this axis.
        var gapName: String {
            switch self {
            case .vertical: "vertical"
            case .horizontal: "horizontal"
            }
        }

        /// How a finding describes one element's position relative to the
        /// element before it on this axis.
        var relation: String {
            switch self {
            case .vertical: "below"
            case .horizontal: "after"
            }
        }
    }

    public init() {}

    public func evaluate(_ root: SemanticNode, context: LintContext) -> [Finding] {
        var findings: [Finding] = []
        for parent in root.flattened() {
            let siblings = parent.children.filter(Self.isEligible)
            guard siblings.count > Self.minimumGapCount else { continue }
            guard let axis = Self.axis(of: siblings) else { continue }

            // Layout order is the tree's order, but a probe is free to emit
            // children in any order, so sort by position before measuring gaps:
            // an unsorted pass produces negative gaps that read as a broken
            // rhythm in a perfectly even stack.
            let ordered = siblings.sorted {
                axis == .vertical ? $0.frame.y < $1.frame.y : $0.frame.x < $1.frame.x
            }

            let gaps = zip(ordered, ordered.dropFirst()).map { first, second in
                axis.gap(from: first.frame, to: second.frame)
            }
            guard let rhythm = Self.rhythm(of: gaps) else { continue }

            for (index, gap) in gaps.enumerated() where abs(gap - rhythm) > Self.quantum {
                // The finding is attributed to the LATER of the two nodes: it is
                // the element that moved, and the one whose padding an author
                // reaches for first.
                let node = ordered[index + 1]
                let finding = context.makeFinding(
                    rule: Self.id,
                    node: node,
                    message: "'\(node.evidenceLabel)' sits \(gap.pointsDescription) pt "
                        + "\(axis.relation) "
                        + "'\(ordered[index].evidenceLabel)' but the other "
                        + "\(axis.gapName) gaps here are \(rhythm.pointsDescription) pt",
                    suggestion: "use the same \(rhythm.pointsDescription) pt spacing as the "
                        + "surrounding elements, or group this element separately so the "
                        + "different gap reads as deliberate",
                    defaultSeverity: .warning
                )
                if let finding { findings.append(finding) }
            }
        }
        return findings
    }

    /// The dominant gap value, or `nil` when the gaps establish no rhythm.
    ///
    /// Returns the mode, quantized to ``quantum`` so float noise does not split
    /// one rhythm across several buckets, and only when that mode holds a strict
    /// majority — see the type's discussion for why a majority is required.
    static func rhythm(of gaps: [Double]) -> Double? {
        guard gaps.count >= minimumGapCount else { return nil }

        var buckets: [Double: [Double]] = [:]
        for gap in gaps where gap.isFinite {
            buckets[(gap / quantum).rounded() * quantum, default: []].append(gap)
        }

        // Ties broken by the smaller gap, so the rhythm is deterministic. A
        // dictionary's iteration order is not stable across runs, and a rule
        // whose verdict depends on hash order cannot be baselined.
        guard
            let winner = buckets.max(by: { left, right in
                left.value.count != right.value.count
                    ? left.value.count < right.value.count
                    : left.key > right.key
            })
        else { return nil }

        guard Double(winner.value.count) > Double(gaps.count) * minimumRhythmShare else {
            return nil
        }
        // Report the mean of the bucket rather than the quantized key, so the
        // message quotes a gap that actually occurs in the layout.
        return winner.value.reduce(0, +) / Double(winner.value.count)
    }

    /// The axis `siblings` are stacked along, or `nil` if they are not a clean
    /// single-axis stack.
    ///
    /// A stack is recognised by NON-OVERLAPPING extents on one axis: every
    /// sibling starts after the previous one ends. That is what distinguishes a
    /// `VStack` from a grid or a `ZStack`, and it is checked on both axes so an
    /// ambiguous arrangement (which satisfies neither) is declined.
    static func axis(of siblings: [SemanticNode]) -> Axis? {
        let vertical = isStacked(siblings, along: .vertical)
        let horizontal = isStacked(siblings, along: .horizontal)
        // Exactly one axis must fit. Both fitting means a diagonal cascade,
        // which has no single rhythm; neither fitting means a grid or overlay.
        switch (vertical, horizontal) {
        case (true, false): return .vertical
        case (false, true): return .horizontal
        default: return nil
        }
    }

    private static func isStacked(_ siblings: [SemanticNode], along axis: Axis) -> Bool {
        let ordered = siblings.sorted {
            axis == .vertical ? $0.frame.y < $1.frame.y : $0.frame.x < $1.frame.x
        }
        return zip(ordered, ordered.dropFirst()).allSatisfy { first, second in
            axis.gap(from: first.frame, to: second.frame) >= -quantum
        }
    }

    /// Nodes whose geometry can carry a spacing rhythm.
    ///
    /// Spacers are excluded because a spacer IS the gap — including it would
    /// measure the distance to a gap rather than between the elements a user
    /// sees, and a `Spacer()` between two rows would read as a rhythm break in
    /// a layout that is behaving exactly as written.
    private static func isEligible(_ node: SemanticNode) -> Bool {
        node.isVisible && !node.frame.isEmpty && node.role != .spacer
    }
}
