// VerdictUIProbe — SwiftUI instrumentation runtime.
//
// Wave 2 Task 1: the transparent Layout probe. This is the only vantage point in
// VerdictUI that can observe layout *negotiation* — the proposal a parent makes
// and the size the child answers with — because SwiftUI hands that conversation
// to `Layout` conformances and to nothing else. `GeometryReader` reports the
// outcome (a resolved size) but never the argument (what was offered, and what
// the child would have taken if offered everything), and the argument is exactly
// what `TruncationRule` needs: `intrinsicWidth` is the width the child asks for
// under an unconstrained proposal.
import SwiftUI
import VerdictUIKernel

// MARK: - Recorded values

/// A size proposal as a platform-pure value: `nil` in a dimension means
/// "unspecified", i.e. the parent asked the child what it would like.
///
/// Mirrors `ProposedViewSize` deliberately rather than storing it: records are
/// handed to the kernel and to the Wave 6 daemon, and both are CoreGraphics-free
/// (`no.md` #5). Conversion happens once, here at the boundary.
public struct ProbeProposal: Equatable, Sendable {
    /// Proposed width in points, or `nil` when the parent left width open.
    public var width: Double?
    /// Proposed height in points, or `nil` when the parent left height open.
    public var height: Double?

    public init(width: Double?, height: Double?) {
        self.width = width
        self.height = height
    }

    /// The fully open proposal — both dimensions left to the child.
    /// Equivalent to `ProposedViewSize.unspecified`, and the proposal
    /// ``ProbeLayout`` uses for its intrinsic measurement.
    public static let unspecified = ProbeProposal(width: nil, height: nil)

    /// True when neither dimension was constrained, so the size a child returns
    /// under this proposal is its ideal size rather than a negotiated one.
    public var isUnspecified: Bool { width == nil && height == nil }
}

extension ProbeProposal {
    /// Bridge from SwiftUI's proposal type. Internal: the CoreGraphics ↔ kernel
    /// conversion is an implementation detail of this target, not API the kernel
    /// or a downstream consumer should depend on.
    init(_ proposal: ProposedViewSize) {
        self.init(
            width: proposal.width.map { Double($0) },
            height: proposal.height.map { Double($0) }
        )
    }
}

/// Where a probe placed its child, expressed in unit coordinates of the child's
/// own frame — `(0, 0)` is its top-leading corner, `(1, 1)` its bottom-trailing.
///
/// Exists so a placement record can name its anchor without embedding SwiftUI's
/// `UnitPoint` in data that crosses into the kernel. ``ProbeLayout`` always
/// places at ``topLeading``; the field is recorded rather than assumed so a
/// future probe that anchors differently cannot silently invalidate consumers
/// that computed frames from the position alone.
public struct ProbeAnchor: Equatable, Sendable {
    /// Horizontal unit coordinate, 0 = leading edge, 1 = trailing edge.
    public var x: Double
    /// Vertical unit coordinate, 0 = top edge, 1 = bottom edge.
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    /// The child's top-leading corner — what ``ProbeLayout`` anchors to, because
    /// it is the only anchor for which "place at `bounds.origin`" reproduces the
    /// frame the child would have had without the probe wrapping it.
    public static let topLeading = ProbeAnchor(x: 0, y: 0)
}

/// One completed size negotiation at a probe site: what was proposed, what the
/// child answered, and what the child would have taken if nothing constrained it.
///
/// A single layout pass can produce several of these for the same probe id —
/// SwiftUI measures speculatively before it commits — so consumers read the last
/// one for a given proposal rather than assuming one record per pass.
public struct ProbeMeasurement: Equatable, Sendable {
    /// Probe id supplied at the call site (`.probeLayout(id: "save-button")`).
    public var probeID: String
    /// The proposal this probe received from its parent and forwarded unchanged.
    public var proposal: ProbeProposal
    /// The size the child returned for ``proposal`` — the value the probe itself
    /// returned to its parent, unmodified.
    public var returnedSize: Size
    /// The size the child returned under ``ProbeProposal/unspecified``: its ideal
    /// size. `intrinsicSize.width` is `TextMetrics.intrinsicWidth` for text.
    public var intrinsicSize: Size
    /// The size the child returned when offered ``proposal``'s width with the
    /// height left open: the space the content needs to render *fully* at the
    /// width it was actually given.
    ///
    /// This is the measurement that separates truncation from wrapping. Under the
    /// real proposal a `Text` clipped by its frame height reports the height it
    /// was allowed, which says nothing about how much it wanted; the
    /// unconstrained measurement reports one line, because an unconstrained width
    /// never wraps. Only a width-constrained, height-unconstrained query says how
    /// many lines the text would take at this width — which is
    /// `TextMetrics.idealLineCount`, and therefore whether lines were lost.
    ///
    /// When ``proposal`` left width open too, this equals ``intrinsicSize``.
    public var idealSizeAtProposedWidth: Size

    public init(
        probeID: String,
        proposal: ProbeProposal,
        returnedSize: Size,
        intrinsicSize: Size,
        idealSizeAtProposedWidth: Size
    ) {
        self.probeID = probeID
        self.proposal = proposal
        self.returnedSize = returnedSize
        self.intrinsicSize = intrinsicSize
        self.idealSizeAtProposedWidth = idealSizeAtProposedWidth
    }
}

/// Where a probe's child ended up, in the probe's own coordinate space.
///
/// Coordinates are local to the layout — `bounds` is the region the probe's
/// parent handed it, so `frame` is comparable to `bounds` but not to a frame from
/// another probe. Root-space frames come from the preference stream in Task 2;
/// this record exists to prove the probe placed the child where the child would
/// have been anyway.
public struct ProbePlacement: Equatable, Sendable {
    /// Probe id supplied at the call site.
    public var probeID: String
    /// The proposal that accompanied this placement, forwarded to the child as-is.
    public var proposal: ProbeProposal
    /// The region the probe's parent gave it to place children in.
    public var bounds: Rect
    /// The anchor the child was placed against — always
    /// ``ProbeAnchor/topLeading`` for ``ProbeLayout``.
    public var anchor: ProbeAnchor
    /// The child's resolved frame: ``bounds`` origin plus the size the child
    /// returned for ``proposal``.
    public var frame: Rect

    public init(
        probeID: String,
        proposal: ProbeProposal,
        bounds: Rect,
        anchor: ProbeAnchor,
        frame: Rect
    ) {
        self.probeID = probeID
        self.proposal = proposal
        self.bounds = bounds
        self.anchor = anchor
        self.frame = frame
    }
}

// MARK: - Recorder

/// The sink every ``ProbeLayout`` writes into: an append-only log of layout
/// observations, keyed by probe id.
///
/// Reference type on purpose — the same instance is injected once at the root
/// (Task 2's `.verdictRoot()`) and reached by every probe below it through the
/// environment, so observations from one layout pass land in one place without
/// the probes knowing about each other.
///
/// `@MainActor` because SwiftUI runs layout on the main thread and the harness
/// reads the log from the main thread; isolating the mutable state to that actor
/// makes the "no locks, no races" claim checkable by the compiler instead of by
/// inspection. ``ProbeLayout`` bridges into it with `MainActor.assumeIsolated`
/// (see the note on ``ProbeLayout``).
///
/// The log grows without bound while a host is alive because SwiftUI re-measures
/// freely and discarding entries would hide exactly the re-measurement pattern
/// the probe exists to expose. Callers own the lifetime: ``reset()`` before a
/// pass whose records they intend to read.
@MainActor
public final class ProbeRecorder {
    /// Every size negotiation recorded so far, oldest first.
    public private(set) var measurements: [ProbeMeasurement] = []
    /// Every placement recorded so far, oldest first.
    public private(set) var placements: [ProbePlacement] = []

    public init() {}

    /// True when nothing has been recorded — no measurements and no placements.
    public var isEmpty: Bool { measurements.isEmpty && placements.isEmpty }

    /// Probe ids seen in either log. Task 2 uses this to detect probes that were
    /// declared but never laid out (a view that never made it into the tree).
    public var recordedProbeIDs: Set<String> {
        Set(measurements.map(\.probeID)).union(placements.map(\.probeID))
    }

    /// Append a size negotiation.
    public func record(_ measurement: ProbeMeasurement) {
        measurements.append(measurement)
    }

    /// Append a placement.
    public func record(_ placement: ProbePlacement) {
        placements.append(placement)
    }

    /// Every measurement recorded for `probeID`, oldest first.
    public func measurements(for probeID: String) -> [ProbeMeasurement] {
        measurements.filter { $0.probeID == probeID }
    }

    /// Every placement recorded for `probeID`, oldest first.
    public func placements(for probeID: String) -> [ProbePlacement] {
        placements.filter { $0.probeID == probeID }
    }

    /// The most recent measurement for `probeID`, or `nil` if that probe never
    /// measured. "Most recent" is the committed one: SwiftUI's speculative
    /// measurements precede the proposal it settles on.
    public func latestMeasurement(for probeID: String) -> ProbeMeasurement? {
        measurements.last { $0.probeID == probeID }
    }

    /// The most recent placement for `probeID`, or `nil` if that probe never
    /// placed its child.
    public func latestPlacement(for probeID: String) -> ProbePlacement? {
        placements.last { $0.probeID == probeID }
    }

    /// Drop every recorded observation. The harness calls this immediately before
    /// the pass it intends to read, so stale records from an earlier pass cannot
    /// be mistaken for current ones.
    public func reset() {
        measurements.removeAll()
        placements.removeAll()
    }
}

// MARK: - Environment

/// Default `nil`: a probe with no recorder is inert rather than fatal, so a
/// probed view stays usable in a real app or preview where no harness is hosting
/// it. Nothing is silently dropped — an absent recorder is an absent *sink*, and
/// the harness that wanted the data is the one that installs it.
private struct ProbeRecorderKey: EnvironmentKey {
    static let defaultValue: ProbeRecorder? = nil
}

extension EnvironmentValues {
    /// The recorder layout probes below this point write into, or `nil` when no
    /// harness is observing. Task 2's `.verdictRoot()` installs it; every
    /// `.probeLayout(id:)` in the subtree reads it.
    public var probeRecorder: ProbeRecorder? {
        get { self[ProbeRecorderKey.self] }
        set { self[ProbeRecorderKey.self] = newValue }
    }
}

// MARK: - Boundary conversions

extension Size {
    /// CoreGraphics → kernel at the one boundary that owns the conversion.
    init(_ size: CGSize) {
        self.init(width: Double(size.width), height: Double(size.height))
    }
}

extension Rect {
    /// CoreGraphics → kernel. SwiftUI and ``Rect`` share the y-down convention,
    /// so origin and size transfer component-wise with no flip.
    init(_ rect: CGRect) {
        self.init(
            x: Double(rect.origin.x),
            y: Double(rect.origin.y),
            width: Double(rect.size.width),
            height: Double(rect.size.height)
        )
    }
}

// MARK: - The probe

/// A `Layout` that wraps one view, reports it to a ``ProbeRecorder``, and changes
/// nothing about how it lays out.
///
/// Transparency is the entire contract: the same proposal goes in, the child's
/// own answer comes out, the child is placed at the probe's `bounds.origin`
/// anchored top-leading — which is where it would have been without the probe —
/// and any alignment guide the child declared is forwarded, so a parent that
/// aligns rather than centres still positions the child the way it would have.
/// `ProbeLayoutTests.testProbeLayoutDoesNotChangeTheRenderedFrame` holds the
/// line: it compares a hosted view's resolved frame with and without the wrapper,
/// and `testProbeLayoutForwardsAnExplicitAlignmentGuideOverride` (with its
/// vertical twin) holds the alignment half of it.
///
/// Beyond forwarding, the probe performs two extra queries per size negotiation:
/// it measures the child again under `ProposedViewSize.unspecified`
/// (``ProbeMeasurement/intrinsicSize``) and once more at the proposed width with
/// the height left open (``ProbeMeasurement/idealSizeAtProposedWidth``). Neither
/// can influence layout — `LayoutSubview.sizeThatFits` is a question, not a
/// command, and the answers are discarded after being recorded — and together
/// they are the only way to learn the width a `Text` wanted before its frame
/// clipped it and how many lines it would have taken at the width it got.
///
/// ### Why `MainActor.assumeIsolated` is sound here
///
/// `Layout`'s requirements are `nonisolated` and the protocol refines `Sendable`,
/// so a conformance cannot be `@MainActor`. That is a statement about SwiftUI's
/// pre-concurrency vintage (`Layout` is a `@preconcurrency` protocol), not about
/// its threading: layout is a phase of the SwiftUI update pass, and the update
/// pass runs on the main thread — a view hierarchy is only ever mutated,
/// measured, and placed from there. So the isolation the compiler cannot see is
/// nonetheless real, which is precisely the situation `assumeIsolated` exists
/// for. It is also the *checked* option: if the assumption is ever false, it
/// traps immediately with the file and line of the violation, instead of racing
/// on the recorder's arrays and corrupting a verdict. The alternatives were both
/// worse — `Task { @MainActor in … }` would record asynchronously, after the
/// layout pass whose data the harness is about to read, and `@unchecked
/// Sendable` mutable state would trade a checked assumption for an unchecked one.
/// Only `Sendable` value records cross into the closure; the non-`Sendable`
/// `LayoutSubview` values stay on this side of it.
public struct ProbeLayout: Layout {
    /// No cross-pass state is worth caching: every value the probe reports is
    /// derived from the proposal it was just handed.
    public typealias Cache = Void

    /// Identity this probe records under. Callers keep it stable across passes;
    /// ``DuplicateProbeIDRule`` catches the case where two live probes share one.
    public let probeID: String

    /// Where observations go, or `nil` to run inert (no recorder in scope).
    public let recorder: ProbeRecorder?

    /// - Parameters:
    ///   - probeID: identity to record under.
    ///   - recorder: sink for observations; `nil` makes the probe inert while
    ///     leaving its layout behaviour identical.
    public init(probeID: String, recorder: ProbeRecorder?) {
        self.probeID = probeID
        self.recorder = recorder
    }

    /// Returns exactly what the child returns for `proposal`, and records the
    /// negotiation plus one unconstrained measurement of the same child.
    public func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) -> CGSize {
        let resolved = Self.measure(subviews, proposal: proposal)
        if let recorder {
            let intrinsic = Self.measure(subviews, proposal: .unspecified)
            // With no proposed width the ideal-at-width query *is* the
            // unconstrained one — `ProposedViewSize(width: nil, height: nil)`
            // is `.unspecified` — so reuse the answer rather than reading as
            // though a third distinct measurement always happens.
            let idealAtWidth =
                proposal.width == nil
                ? intrinsic
                : Self.measure(
                    subviews,
                    proposal: ProposedViewSize(width: proposal.width, height: nil)
                )
            let measurement = ProbeMeasurement(
                probeID: probeID,
                proposal: ProbeProposal(proposal),
                returnedSize: Size(resolved),
                intrinsicSize: Size(intrinsic),
                idealSizeAtProposedWidth: Size(idealAtWidth)
            )
            MainActor.assumeIsolated { recorder.record(measurement) }
        }
        return resolved
    }

    /// Places the child at `bounds.origin` with the proposal that was handed
    /// down, and records the resulting frame.
    public func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) {
        for subview in subviews {
            subview.place(at: bounds.origin, anchor: .topLeading, proposal: proposal)
        }
        guard let recorder else { return }
        // Re-querying the child costs nothing measurable (SwiftUI caches the
        // answer it just computed for this proposal) and is the only way to
        // record the frame the child actually occupies: `bounds` is the region
        // the probe was given, which is not always the size the child took.
        let placed = Self.measure(subviews, proposal: proposal)
        let placement = ProbePlacement(
            probeID: probeID,
            proposal: ProbeProposal(proposal),
            bounds: Rect(bounds),
            anchor: .topLeading,
            frame: Rect(CGRect(origin: bounds.origin, size: placed))
        )
        MainActor.assumeIsolated { recorder.record(placement) }
    }

    /// Forwards a horizontal alignment guide declared inside the wrapped view,
    /// and reports no guide when the wrapped view declared none.
    ///
    /// A `Layout` view's alignment guides come from this method and its
    /// `VerticalAlignment` twin, and from nothing else. The protocol's default
    /// implementations return `nil` for every guide — "this view declares no
    /// explicit guide" — and SwiftUI then derives the guide from the *wrapper's*
    /// own `ViewDimensions` via `AlignmentID.defaultValue`: `.leading` → 0,
    /// `.bottom` → height, and so on.
    ///
    /// For a **default** guide that fallback is already exactly right, and is
    /// deliberately left in place: the probe reports the child's size as its own
    /// and places the child at `bounds.origin`, so the wrapper's box and the
    /// child's box are the same box, and a guide derived from one is the guide
    /// derived from the other. That is why `.topLeading`, `.bottomTrailing` and
    /// `.center` reproduce the unwrapped layout with no forwarding at all, and
    /// why the fix here is not "compute a position" but "stop dropping one".
    ///
    /// For an **explicit** guide — one the wrapped subtree declared with
    /// `.alignmentGuide(_:computeValue:)` — the fallback is wrong, and silently
    /// so. The child's dimensions carry a value its author chose (a caption whose
    /// `.leading` is its own centre, a row whose `.firstTextBaseline` sits inside
    /// it). A parent aligning the unwrapped child uses that value; a parent above
    /// the probe was told there was no explicit guide and aligned against the
    /// wrapper's edge instead, so the child lands somewhere it never would have —
    /// the one thing this type promises cannot happen.
    ///
    /// So the rule is to forward the child's answer *and its explicitness*:
    /// report the guide when the child declared one, and report `nil` when it did
    /// not. Synthesising the computed default instead of `nil` would yield the
    /// same number and still be wrong: explicitness is itself observable, and
    /// containers that derive their own guides from their children's explicit ones
    /// would start seeing a guide the wrapped view never declared — the same class
    /// of distortion, introduced by the code meant to remove it.
    ///
    /// The value is forwarded **untranslated**, which is not an oversight. A guide
    /// is expressed in its own view's dimensions, and the probe places the child
    /// flush at `bounds.origin`, so the child's space and the wrapper's space are
    /// the same space and the number needs no adjustment. A `bounds.origin` term
    /// was written here first, on the theory that the guide is owed in whatever
    /// space `bounds` is stated in — and it was removed as unverifiable: SwiftUI
    /// evaluates a layout's guides in that layout's own unoffset space, so the
    /// term was always adding zero and no test could tell a correct one from a
    /// wrong one. `ProbeLayoutTests`
    /// `.testAlignmentGuidesAreEvaluatedInTheLayoutsOwnUnoffsetSpace` measures
    /// that assumption directly — every guide evaluation across a stack
    /// alignment, an offsetting custom parent, padding, a five-deep layout nest, a
    /// baseline stack and a custom `AlignmentID` receives a zero origin, while
    /// placements in those same shapes do not — and fails if a future SwiftUI ever
    /// hands this method an offset region, which is the signal to translate.
    ///
    /// Guides are forwarded only for the single-subview case the probe is designed
    /// for. Content that resolves to several subviews is stacked at a common
    /// origin (see `measure(_:proposal:)`), and no one subview's guide speaks for
    /// that union, so the wrapper declares nothing explicit and its own geometry
    /// answers — the same honest degenerate behaviour the sizing path takes.
    public func explicitAlignment(
        of guide: HorizontalAlignment,
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) -> CGFloat? {
        guard let explicit = Self.soleSubviewDimensions(subviews, proposal: proposal)?[
            explicit: guide
        ] else { return nil }
        return explicit
    }

    /// Forwards a vertical alignment guide declared inside the wrapped view, and
    /// reports no guide when the wrapped view declared none.
    ///
    /// The vertical half of the same rule; the reasoning is on the
    /// `HorizontalAlignment` overload above. `Layout` declares the two guide
    /// families as separate requirements, so an implementation that covers only
    /// one axis is transparent only along that axis — `.firstTextBaseline` and a
    /// `.bottom` override live here.
    public func explicitAlignment(
        of guide: VerticalAlignment,
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) -> CGFloat? {
        guard let explicit = Self.soleSubviewDimensions(subviews, proposal: proposal)?[
            explicit: guide
        ] else { return nil }
        return explicit
    }

    /// The wrapped view's dimensions under `proposal`, or `nil` unless the probe
    /// wraps exactly one subview.
    private static func soleSubviewDimensions(
        _ subviews: Subviews,
        proposal: ProposedViewSize
    ) -> ViewDimensions? {
        guard subviews.count == 1, let subview = subviews.first else { return nil }
        return subview.dimensions(in: proposal)
    }

    /// The size the probe reports for `proposal`.
    ///
    /// `.probeLayout(id:)` always wraps a single view, and for one subview this
    /// returns that subview's answer byte-for-byte — it never touches the value.
    /// The union fallback covers content that resolves to several subviews (a
    /// `Group`, a `ForEach`): those are stacked at a common origin and reported
    /// together rather than dropped on the floor, which is the honest degenerate
    /// behaviour for a probe asked to wrap more than it was designed for.
    /// Zero subviews report zero, which is the seed rather than a special case:
    /// SwiftUI elides empty content (`EmptyView`, an empty `ForEach`) before a
    /// custom `Layout` is instantiated, so an empty `subviews` is not reachable
    /// through `.probeLayout(id:)`. Written as a reduction over the zero size so
    /// that the unreachable state needs no branch — an `if` no test can enter
    /// reads like a handled case and is not one.
    private static func measure(_ subviews: Subviews, proposal: ProposedViewSize) -> CGSize {
        subviews.reduce(into: CGSize.zero) { union, subview in
            let size = subview.sizeThatFits(proposal)
            union.width = max(union.width, size.width)
            union.height = max(union.height, size.height)
        }
    }
}

// MARK: - View integration

/// Reads the recorder out of the environment so ``ProbeLayout`` — a `Layout`, not
/// a `View`, and therefore unable to hold `@Environment` — can be handed one.
private struct ProbeLayoutHost<Content: View>: View {
    let probeID: String
    let content: Content

    @Environment(\.probeRecorder) private var recorder

    var body: some View {
        ProbeLayout(probeID: probeID, recorder: recorder) { content }
    }
}

extension View {
    /// Observe this view's layout negotiation under `id` without changing it.
    ///
    /// The wrapped view keeps its size and its position: what its parent proposes
    /// reaches it unaltered, what it answers reaches its parent unaltered. What
    /// the wrapper adds is a record — the proposal, the answer, the placement,
    /// and the size the view would have taken with nothing constraining it —
    /// written to the ``ProbeRecorder`` in the environment, if one is installed.
    ///
    /// Composes with `.verdictProbe(_:)`: that modifier reports the resolved
    /// frame in root coordinates, this one reports how that frame was arrived at.
    ///
    /// - Parameter id: identity the observations are recorded under. Stable
    ///   across passes, and unique among live probes.
    public func probeLayout(id: String) -> some View {
        ProbeLayoutHost(probeID: id, content: self)
    }
}
