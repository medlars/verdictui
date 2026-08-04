// VerdictUIProbe — SwiftUI instrumentation runtime.
//
// Wave 2 Task 2, the pure half: turning a flat list of probe reports into the
// `SemanticNode` tree the kernel verifies. Deliberately free of SwiftUI, AppKit
// and rendering — the whole file is a function of its arguments — because the
// tree-shaping rules (containment, sibling order, what counts as an honest
// measurement) are where the interesting mistakes live, and a rule you can only
// exercise by hosting a view is a rule you will test once and then never again.
import Foundation
import VerdictUIKernel

/// Builds a ``SemanticNode`` tree from the flat probe reports one layout pass
/// produced.
///
/// The probe stream is intentionally flat: SwiftUI gives no parent/child
/// relationship through a preference key, only a sequence of reports in
/// view-tree order. Structure is therefore recovered from geometry — a probe
/// whose frame sits strictly inside another probe's frame is that probe's child
/// — with layout order as the sibling order and as the tiebreak wherever
/// geometry is ambiguous.
///
/// Everything here is a pure function of `records`, `measurements` and
/// `viewport`, so the same three inputs always produce the same tree. That is a
/// requirement, not an accident: `Verdict` baselines and `TreeDiff` deltas are
/// only meaningful if an unchanged view re-encodes byte-identically.
public enum TreeAssembly {
    /// Slack, in points, applied to every containment comparison.
    ///
    /// Frames arrive from AppKit as `CGFloat` values that have been resolved
    /// against the backing-store pixel grid, so a child that a developer wrote
    /// as exactly coincident with its parent can come back a fraction of a point
    /// outside it. Half a point is the smallest value that absorbs that
    /// rounding, and it is far below any nesting inset a real layout uses (the
    /// tightest common case, a 1 pt border, still reads as nesting). Frames
    /// themselves are stored exactly as measured — the epsilon lives only in the
    /// comparisons, never in the data.
    public static let containmentEpsilon: Double = 0.5

    /// Slack, in points, when matching a recorded measurement to a reported
    /// frame. Same rounding argument as ``containmentEpsilon``; kept separate
    /// because the two answer different questions and could justifiably diverge.
    public static let sizeMatchEpsilon: Double = 0.5

    /// Structural path assigned to the root node, and the prefix every
    /// descendant path is built from. Matches the kernel's `TreeDiff.rootSegment`
    /// default so probe-built and kernel-canonicalized trees agree.
    public static let rootPath = "root"

    /// Assemble the tree.
    ///
    /// - Parameters:
    ///   - records: one report per probe, **in layout order**. The array order
    ///     *is* the ordering token: see ``ProbeRecord`` for why no counter is
    ///     stored in the record itself.
    ///   - measurements: every layout measurement recorded for a probe id,
    ///     oldest first — `ProbeRecorder.measurements` grouped by
    ///     `ProbeMeasurement/probeID`. Ids absent from this dictionary simply get
    ///     no ``TextMetrics``.
    ///   - viewport: the root's bounds in root coordinates, i.e.
    ///     `(0, 0, width, height)` of the view `verdictRoot(into:)` was applied
    ///     to. Becomes the root node's frame and the reference frame the kernel's
    ///     `OffscreenRule` measures against.
    /// - Returns: the root node, with ``SemanticNode/structuralPath`` filled in
    ///   for every node in the tree.
    public static func assemble(
        records: [ProbeRecord],
        measurements: [String: [ProbeMeasurement]],
        viewport: Rect
    ) -> SemanticNode {
        let entries = records.enumerated().map { Entry(order: $0.offset, record: $0.element) }

        // Root synthesis, branch B: exactly one probe covers the whole viewport,
        // so that probe *is* the root and keeps its id, role and text. Wrapping
        // it in a synthesized parent with an identical frame would invent a
        // node, hand `SiblingOverlapRule` a spurious full-bleed sibling, and put
        // an unnamed node where the developer clearly named one.
        //
        // Branch A (zero spanning probes, or several) synthesizes an anonymous
        // `.container` at the viewport. With several spanning probes there is no
        // non-arbitrary way to pick which one is "the" root, and nesting them by
        // registration order would encode a parent/child claim the geometry does
        // not support — so they stay siblings under a synthesized root, and
        // `DuplicateProbeIDRule`/`SiblingOverlapRule` get to say their piece.
        let spanning = entries.filter { spansViewport($0.record.frame, viewport) }
        let rootEntry = spanning.count == 1 ? spanning[0] : nil
        let descendants = entries.filter { $0.order != rootEntry?.order }

        let linkage = link(descendants)
        // `uniqueKeysWithValues` on purpose: orders come from `enumerated()`
        // eleven lines up, so they are unique by construction, and a future
        // refactor that breaks that should trap here rather than have
        // `uniquingKeysWith` silently drop an entry from the tree.
        let byOrder = Dictionary(uniqueKeysWithValues: descendants.map { ($0.order, $0) })
        let topLevel = linkage.roots.compactMap { byOrder[$0] }.map {
            subtree(of: $0, linkage: linkage, byOrder: byOrder, measurements: measurements)
        }

        let root: SemanticNode
        if let rootEntry {
            root = node(for: rootEntry.record, measurements: measurements, children: topLevel)
        } else {
            root = SemanticNode(
                id: "",
                role: .container,
                frame: viewport,
                children: topLevel
            )
        }
        // Probe ids win over structural paths (kernel identity rule), but every
        // node still carries a path so unprobed and synthesized nodes have an
        // identity to be diffed and reported by.
        return root.withAssignedStructuralPaths(rootPath: rootPath)
    }

    /// The ``TextMetrics`` a record honestly supports, or `nil`.
    ///
    /// Exposed because the honesty boundary is part of this type's contract, not
    /// an implementation detail: `TruncationRule` skips nodes without metrics on
    /// purpose ("a rule that speculates is a rule people stop believing"), so
    /// what the probe declines to fill in matters as much as what it fills.
    ///
    /// ### What is measured, and what is derived
    ///
    /// | Field | Provenance |
    /// |---|---|
    /// | `intrinsicWidth` | **measured** — the width the content returned under `ProposedViewSize.unspecified` (``ProbeMeasurement/intrinsicSize``). |
    /// | `renderedLineCount` | **derived** — `returnedSize.height / intrinsicSize.height`, rounded. |
    /// | `idealLineCount` | **derived** — `idealSizeAtProposedWidth.height / intrinsicSize.height`, rounded. |
    ///
    /// The two derived counts share one denominator: the height the content
    /// returned with *nothing* constraining it. For text with no hard line
    /// break that height is exactly one line — an unconstrained width never
    /// wraps — which is what makes the division a line count rather than a
    /// guess. Everything the derivation needs is therefore itself a measurement;
    /// only the division and the rounding are ours.
    ///
    /// ### When `nil` is returned
    ///
    /// - the role does not render text (`Role.isTextBearing` is false), so there
    ///   are no lines to count;
    /// - the record carries no text, or empty text — without the string there is
    ///   no way to know whether the unconstrained height is one line;
    /// - the text contains a hard line break — any `Character.isNewline`
    ///   scalar: `\n`, `\r`, CRLF, NEL, or a Unicode line/paragraph separator.
    ///   The unconstrained height is then several lines, the per-line
    ///   denominator is unknown, and dividing by the whole block would
    ///   fabricate both counts. This is a real gap, not a rounding detail —
    ///   hard-broken text gets no metrics until the probe can measure a single
    ///   line directly;
    /// - no recorded measurement matches the reported frame, or the
    ///   unconstrained height is zero. A measurement from a speculative pass at
    ///   a different size does not describe the frame being reported, and
    ///   attaching it would put a number in the verdict that nothing measured.
    public static func textMetrics(
        for record: ProbeRecord,
        measurements: [ProbeMeasurement]
    ) -> TextMetrics? {
        guard record.role.isTextBearing else { return nil }
        // `isNewline` rather than a literal "\n": SwiftUI renders a bare CR,
        // NEL, and the Unicode line/paragraph separators as line breaks too,
        // and any of them makes the unconstrained height a multi-line block —
        // the same unknown-denominator problem, differing only in spelling.
        guard let text = record.text, !text.isEmpty, !text.contains(where: \.isNewline) else {
            return nil
        }
        guard let measurement = measurement(matching: record.frame, in: measurements) else {
            return nil
        }
        let unitLineHeight = measurement.intrinsicSize.height
        guard unitLineHeight > 0 else { return nil }
        return TextMetrics(
            intrinsicWidth: measurement.intrinsicSize.width,
            renderedLineCount: lineCount(of: measurement.returnedSize.height, unit: unitLineHeight),
            idealLineCount: lineCount(
                of: measurement.idealSizeAtProposedWidth.height,
                unit: unitLineHeight
            )
        )
    }

    // MARK: - Linkage

    /// One record plus its position in the layout-ordered input.
    private struct Entry {
        let order: Int
        let record: ProbeRecord

        /// Frame area, used to order candidate parents innermost-first. Negative
        /// dimensions (which a broken layout can produce) clamp to zero rather
        /// than flipping the sign and inverting the ordering.
        var area: Double {
            max(0, record.frame.width) * max(0, record.frame.height)
        }
    }

    /// Which records are top-level and which records own which children, keyed
    /// by ``Entry/order``.
    private struct Linkage {
        var roots: [Int]
        var children: [Int: [Int]]
    }

    /// Recover parent/child structure from frames.
    ///
    /// Candidate parents are considered largest-area first, and a record may only
    /// attach to a record that came earlier in that ordering. That is what makes
    /// the result a forest by construction: a parent always has an area greater
    /// than or equal to its child's, so no chain of parents can close into a
    /// cycle no matter how the epsilon falls.
    ///
    /// Among the records that strictly contain a given record, the smallest wins
    /// — the innermost enclosing box is the parent, which is what makes deep
    /// nesting come out as a chain instead of a fan. Equal-area containers are
    /// separated by layout order, earliest first.
    private static func link(_ entries: [Entry]) -> Linkage {
        let byArea = entries.sorted { lhs, rhs in
            lhs.area == rhs.area ? lhs.order < rhs.order : lhs.area > rhs.area
        }
        var linkage = Linkage(roots: [], children: [:])
        for (index, entry) in byArea.enumerated() {
            let parent = byArea[..<index]
                .filter { strictlyContains($0.record.frame, entry.record.frame) }
                .min { lhs, rhs in
                    lhs.area == rhs.area ? lhs.order < rhs.order : lhs.area < rhs.area
                }
            if let parent {
                linkage.children[parent.order, default: []].append(entry.order)
            } else {
                linkage.roots.append(entry.order)
            }
        }
        // Sibling order is layout order: `order` is the index in the
        // layout-ordered input, so sorting these integers restores it after the
        // area-ordered walk above.
        linkage.roots.sort()
        for key in linkage.children.keys {
            linkage.children[key]?.sort()
        }
        return linkage
    }

    /// The node for `entry` with its whole subtree beneath it.
    private static func subtree(
        of entry: Entry,
        linkage: Linkage,
        byOrder: [Int: Entry],
        measurements: [String: [ProbeMeasurement]]
    ) -> SemanticNode {
        node(
            for: entry.record,
            measurements: measurements,
            children: (linkage.children[entry.order] ?? []).compactMap { byOrder[$0] }.map {
                subtree(of: $0, linkage: linkage, byOrder: byOrder, measurements: measurements)
            }
        )
    }

    /// One node built from one record. `structuralPath` is left empty here and
    /// assigned in a single pass at the end of ``assemble(records:measurements:viewport:)``.
    private static func node(
        for record: ProbeRecord,
        measurements: [String: [ProbeMeasurement]],
        children: [SemanticNode]
    ) -> SemanticNode {
        SemanticNode(
            id: record.id,
            role: record.role,
            frame: record.frame,
            text: record.text,
            attributes: record.attributes,
            // Reported `true` for every probe: a probe only reports once the
            // layout engine has placed it, so the node describes something that
            // was laid out. Opacity and clip-based invisibility are not
            // observable from the layout pass and are Wave 4's business; until
            // then `true` is the conservative choice, because rules skip
            // invisible nodes and a wrongly-false flag would hide real defects.
            isVisible: true,
            textMetrics: textMetrics(for: record, measurements: measurements[record.id] ?? []),
            children: children
        )
    }

    // MARK: - Geometry

    /// True when `outer` encloses `inner` and `inner` does not enclose `outer`.
    ///
    /// The second half is what keeps ambiguity out of the tree: two records with
    /// the same frame (a `.background`, an overlay, a wrapper that added no
    /// insets) each "contain" the other within the epsilon, so neither strictly
    /// contains the other and they stay siblings in layout order rather than one
    /// being arbitrarily buried inside the other.
    static func strictlyContains(_ outer: Rect, _ inner: Rect) -> Bool {
        expanded(outer).contains(inner) && !expanded(inner).contains(outer)
    }

    /// True when `frame` covers the viewport, within ``containmentEpsilon`` on
    /// every edge.
    static func spansViewport(_ frame: Rect, _ viewport: Rect) -> Bool {
        abs(frame.x - viewport.x) <= containmentEpsilon
            && abs(frame.y - viewport.y) <= containmentEpsilon
            && abs(frame.width - viewport.width) <= containmentEpsilon
            && abs(frame.height - viewport.height) <= containmentEpsilon
    }

    /// `rect` grown by ``containmentEpsilon`` on all four sides.
    private static func expanded(_ rect: Rect) -> Rect {
        Rect(
            x: rect.x - containmentEpsilon,
            y: rect.y - containmentEpsilon,
            width: rect.width + 2 * containmentEpsilon,
            height: rect.height + 2 * containmentEpsilon
        )
    }

    /// The most recent measurement whose returned size matches `frame`.
    ///
    /// Most recent, because SwiftUI measures speculatively and commits last;
    /// matched on size, because a measurement taken at a size other than the one
    /// being reported describes a layout that was considered and rejected.
    static func measurement(matching frame: Rect, in measurements: [ProbeMeasurement])
        -> ProbeMeasurement?
    {
        measurements.last {
            abs($0.returnedSize.width - frame.width) <= sizeMatchEpsilon
                && abs($0.returnedSize.height - frame.height) <= sizeMatchEpsilon
        }
    }

    /// `height` expressed in whole lines of `unit`, never less than one: content
    /// that was measured at all occupies at least one line.
    private static func lineCount(of height: Double, unit: Double) -> Int {
        max(1, Int((height / unit).rounded()))
    }
}
