// VerdictUIProbe — SwiftUI instrumentation runtime.
//
// Wave 2 Task 2: the preference spine. Task 1's `ProbeLayout` can see how a size
// was negotiated but not *where* the result landed; a `GeometryReader` can see
// where it landed but not how it was negotiated. This file joins the two — one
// modifier per probed view emitting a `ProbeRecord` upward, one modifier at the
// root collecting them, merging in the recorder's measurements, and handing the
// assembled `SemanticNode` tree to a sink the harness owns.
//
// It replaces the Wave 0 seed wholesale. The seed's `VerdictFramesKey` carried a
// `[String: Rect]` in `.global` space; both halves of that were wrong for a
// verification engine. A dictionary throws away layout order, which is the only
// tiebreak available when frames are ambiguous, and `.global` is measured from
// the host window's placement, so the same view in a window moved 20 pt to the
// right produces a different tree. Nothing outside this package consumed the
// seed, so it is gone rather than deprecated.
import SwiftUI
import VerdictUIKernel

// MARK: - Coordinate space

/// The named coordinate space every probe frame is measured in.
///
/// `.global` was the seed's choice and is the tempting one, because it needs no
/// setup. It is also non-deterministic: it resolves against the window, so a
/// tree assembled from global frames encodes where the host window happened to
/// be. Root-relative frames make "same view + same viewport ⇒ byte-identical
/// tree" achievable, which is the property `TreeDiff` and verdict baselines rest
/// on. `verdictRoot(into:)` declares the space; every probe below it reads it.
public enum VerdictRootCoordinateSpace {
    /// Name passed to `coordinateSpace(.named(_:))` and `GeometryProxy.frame(in:)`.
    public static let name = "verdict-root"
}

// MARK: - Records

/// What one probe reports about itself during a layout pass.
///
/// ### Why there is no ordering field
///
/// Sibling order and the containment tiebreak both need layout order, and the
/// obvious way to get it — a monotonically increasing registration counter
/// stamped into each record — is wrong here. SwiftUI re-collects preferences
/// from scratch on every pass that changes them, so a global counter would keep
/// climbing across passes: pass two's records would carry different tokens than
/// pass one's for the same views, and two renders of the same view would not
/// encode identically. A per-pass counter would need mutable state shared by
/// probes that deliberately know nothing about each other.
///
/// The stream already carries the information. Preference reduction walks the
/// view tree depth-first, so appending each record to an array yields the
/// records in declaration order — which is the order SwiftUI's own containers
/// lay their children out in. So **the array order is the ordering token**:
/// ``TreeAssembly/assemble(records:measurements:viewport:)`` takes its `records`
/// argument in layout order and uses the index. Nothing to keep in sync, and
/// re-collection is harmless because a fresh collection reproduces the same
/// order.
///
/// One consequence worth stating: a probe attached via `.background` reports
/// after its own children in some arrangements, so a parent may appear later in
/// the array than its descendants. That is fine — parentage comes from
/// containment, and order is only consulted *within* a sibling group.
public struct ProbeRecord: Equatable, Sendable {
    /// Role reported when a call site does not classify its view.
    ///
    /// `Role.custom("unclassified")` rather than `.container`, because a silent
    /// `.container` is indistinguishable from a deliberate one and makes an
    /// unclassified element disappear into the scaffolding. Deliberately *not*
    /// prefixed `verdict.` either: that prefix exempts a node from `ZeroSizeRule`
    /// (see `ZeroSizeRule.probeRolePrefix`), and a real view that collapsed to
    /// zero size should still be reported, whether or not its role was named.
    public static let unclassifiedRole = Role.custom("unclassified")

    /// Probe id from the call site — `.verdictProbe("save-button")`. Wins over
    /// ``SemanticNode/structuralPath`` as identity; must be unique among live
    /// probes, which `DuplicateProbeIDRule` enforces after the fact.
    public var id: String
    /// Semantic role the call site declared, or ``unclassifiedRole``.
    public var role: Role
    /// Resolved frame in the ``VerdictRootCoordinateSpace`` — never `.global`.
    /// Stored exactly as AppKit measured it; no rounding is applied anywhere in
    /// the pipeline.
    public var frame: Rect
    /// The text the view renders, when the call site supplied it. Required for
    /// ``TextMetrics``: without the string there is no way to know whether an
    /// unconstrained measurement is one line or several.
    public var text: String?
    /// Role-specific data, forwarded to ``SemanticNode/attributes`` unchanged —
    /// including `verdict.suppress`, which is how a call site opts a node out of
    /// a rule.
    public var attributes: [String: AttributeValue]

    public init(
        id: String,
        role: Role,
        frame: Rect,
        text: String? = nil,
        attributes: [String: AttributeValue] = [:]
    ) {
        self.id = id
        self.role = role
        self.frame = frame
        self.text = text
        self.attributes = attributes
    }

    /// Why `candidate` is not a legal probe id, or `nil` if it is.
    ///
    /// The rules `verdictProbe(_:role:text:attributes:)` preconditions on,
    /// separated out so they are testable — a trap message cannot be asserted
    /// on, but the judgement behind it can be. Kept here rather than on the
    /// modifier because the namespace being protected is this record's `id`.
    public static func idViolation(_ candidate: String) -> String? {
        if candidate.isEmpty {
            return "a probe id must be non-empty — an empty id is an unprobed node"
        }
        if candidate.hasPrefix("@") {
            return "probe id '\(candidate)' starts with '@', which is reserved for "
                + "structural-path identity"
        }
        return nil
    }
}

/// Everything one layout pass reported through the preference stream: the root's
/// bounds and the probe records, in layout order.
///
/// The viewport travels in the same payload as the records so the root needs a
/// single `onPreferenceChange` and cannot deliver a tree assembled from records
/// of one pass and a viewport of another.
public struct ProbeSnapshot: Equatable, Sendable {
    /// The root's own bounds in root coordinates — `(0, 0, width, height)`.
    /// `nil` until the root's reporter has been laid out, which is the signal
    /// that no tree can be assembled yet.
    public var viewport: Rect?
    /// One record per probe, in layout order. See ``ProbeRecord`` on why the
    /// order is the ordering token.
    public var records: [ProbeRecord]

    public init(viewport: Rect? = nil, records: [ProbeRecord] = []) {
        self.viewport = viewport
        self.records = records
    }
}

/// Preference key carrying probe records and the root's bounds up the view tree.
///
/// Reduction concatenates records, preserving the depth-first order SwiftUI
/// visits the tree in. The viewport is coalesced first-writer-wins, which is
/// correct for the supported arrangement — exactly one `verdictRoot`, whose
/// single reporter is the only viewport writer in the stream.
///
/// **Nesting `verdictRoot` inside another `verdictRoot` is not supported.**
/// Reduction is depth-first, so the *inner* root's viewport wins the
/// first-writer race, and the outer collector would assemble every frame —
/// including the kernel's `OffscreenRule` reference — against the inner root's
/// smaller rectangle. The inner collector works; the outer one lies. Nothing
/// in this package nests roots, and a preference key has no way to strip its
/// own value at a boundary, so the limitation is documented rather than
/// papered over.
public struct VerdictProbeKey: PreferenceKey {
    public static let defaultValue = ProbeSnapshot()

    public static func reduce(value: inout ProbeSnapshot, nextValue: () -> ProbeSnapshot) {
        let next = nextValue()
        value.records.append(contentsOf: next.records)
        if value.viewport == nil {
            value.viewport = next.viewport
        }
    }
}

// MARK: - Delivery

/// Where an assembled tree is delivered: a `@MainActor` object the harness owns
/// and reads.
///
/// A sink rather than a callback as the primary flavour because the consumer is
/// Task 3's `OracleHost`, which needs to *ask* "is there a tree yet, and is it
/// still changing?" while pumping the run loop — a question a fire-and-forget
/// closure cannot answer. ``updateCount`` is that question's other half.
///
/// The sink also owns the ``ProbeRecorder``, so one object carries both halves of
/// a pass: the frames from the preference stream and the size negotiations from
/// the layout probes. `verdictRoot(into:)` injects ``recorder`` into the
/// environment for every `probeLayout` below it.
@MainActor
public final class VerdictTreeSink {
    /// The recorder the probes below the root write their measurements into.
    /// Exposed because a caller investigating a surprising verdict wants the raw
    /// negotiations, not just the tree derived from them.
    public let recorder: ProbeRecorder

    /// The most recently delivered tree, or `nil` before the first delivery.
    public private(set) var latestTree: SemanticNode?

    /// How many trees have been delivered since the last ``reset()``.
    ///
    /// The contract Task 3 depends on: this increments once per *delivered*
    /// tree, and a tree is delivered only when the preference payload changed.
    /// So a counter that stops moving across several pumped run-loop iterations
    /// means the layout has stopped changing — settled, not stalled. A counter
    /// still climbing means SwiftUI is still re-laying out and any tree read now
    /// may be superseded.
    public private(set) var updateCount = 0

    /// - Parameter recorder: the layout recorder to install below the root.
    ///   Defaults to a fresh one; pass an existing recorder to share it.
    public init(recorder: ProbeRecorder = ProbeRecorder()) {
        self.recorder = recorder
    }

    /// True before the first tree arrives.
    public var isEmpty: Bool { latestTree == nil }

    /// Forget the delivered tree, zero the counter, and clear the recorder.
    ///
    /// Called before the pass whose tree the caller intends to read, so a tree
    /// from an earlier state cannot be mistaken for the current one.
    public func reset() {
        latestTree = nil
        updateCount = 0
        recorder.reset()
    }

    /// Accept a freshly assembled tree. Internal: only the root modifier is in a
    /// position to know that a tree describes the pass that just happened.
    func accept(_ tree: SemanticNode) {
        latestTree = tree
        updateCount += 1
    }
}

// MARK: - Probe modifier

/// Emits one ``ProbeRecord`` for the view it backs, measured in the
/// ``VerdictRootCoordinateSpace``.
///
/// A `GeometryReader` inside a `.background` rather than a wrapper around the
/// content: the background is sized to the view it backs and adds nothing to the
/// layout, so the frame it reads is the frame the view actually got. Recording
/// happens while the geometry closure is evaluated — during layout — because
/// `onAppear` never fires for a view hosted without a window.
private struct ProbeRecordReporter: View {
    let id: String
    let role: Role
    let text: String?
    let attributes: [String: AttributeValue]

    var body: some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: VerdictProbeKey.self,
                value: ProbeSnapshot(
                    records: [
                        ProbeRecord(
                            id: id,
                            role: role,
                            frame: Rect(proxy.frame(in: .named(VerdictRootCoordinateSpace.name))),
                            text: text,
                            attributes: attributes
                        )
                    ]
                )
            )
        }
    }
}

/// Emits the root's own bounds as the viewport of the pass.
///
/// Origin is `(0, 0)` by definition, not by measurement: the root *is* the origin
/// of the ``VerdictRootCoordinateSpace``, so its bounds in that space are its
/// size at zero. Asking `GeometryProxy.frame(in:)` for it instead was measurably
/// worse — a host that places the root on a half-pixel boundary makes the
/// round-trip through the coordinate transform come back at `(-0.5, -0.5)`, which
/// would put a rounding artifact into the one rectangle every other frame and
/// every `OffscreenRule` finding is measured against.
private struct VerdictViewportReporter: View {
    var body: some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: VerdictProbeKey.self,
                value: ProbeSnapshot(
                    viewport: Rect(
                        x: 0,
                        y: 0,
                        width: Double(proxy.size.width),
                        height: Double(proxy.size.height)
                    )
                )
            )
        }
    }
}

extension View {
    /// Report this view to VerdictUI: its frame in root coordinates, its role,
    /// its text, and how its size was negotiated.
    ///
    /// Two observations are made, and they are complementary. The record emitted
    /// through ``VerdictProbeKey`` says *where the view ended up*; the
    /// `probeLayout(id:)` wrapper this modifier applies under the same id says
    /// *what was proposed and what the view asked for*, which is where
    /// ``TextMetrics`` comes from. Both are inert without a
    /// ``VerdictTreeSink`` — a probed view stays a normal view in a real app or
    /// a preview.
    ///
    /// Neither observation changes layout: `probeLayout` forwards proposals and
    /// placements unchanged (`ProbeLayoutTests.testProbeLayoutDoesNotChangeTheRenderedFrame`),
    /// and the reporter lives in a background that is sized by the view it backs.
    ///
    /// Apply it as close to the view being described as possible. Modifiers
    /// applied *outside* the probe (a `.frame`, a `.padding`) are what the probe
    /// measures the view against, which is exactly what makes a truncation
    /// finding possible: `Text(…).lineLimit(1).verdictProbe("label", role: .text,
    /// text: …).frame(width: 120)` reports a 120 pt frame and an intrinsic width
    /// wider than it.
    ///
    /// - Parameters:
    ///   - id: stable identity, unique among live probes. It becomes
    ///     ``SemanticNode/id`` and wins over the structural path as identity.
    ///   - role: what the view is, for role-aware rules. Defaults to
    ///     ``ProbeRecord/unclassifiedRole`` — unclassified stays visible rather
    ///     than being silently filed as a container.
    ///   - text: the text the view renders, if any. Required for ``TextMetrics``;
    ///     see ``TreeAssembly/textMetrics(for:measurements:)`` for why the string
    ///     itself is needed and not just the measurements.
    ///   - attributes: role-specific data, forwarded to the node unchanged.
    ///
    /// The id must be non-empty and must not start with `@`. Both are programmer
    /// errors a rule cannot catch after the fact: an empty id makes the node
    /// indistinguishable from an unprobed one, so `DuplicateProbeIDRule` skips it
    /// and the author's chosen identity silently never existed; a leading `@`
    /// collides with the namespace ``SemanticNode/identity`` reserves for
    /// unprobed nodes (`@` + structural-path component), and a collision there
    /// makes `TreeDiff` silently fall back to positional matching for the whole
    /// sibling group. Neither failure produces a finding, which is why this is a
    /// precondition rather than a rule.
    public func verdictProbe(
        _ id: String,
        role: Role = ProbeRecord.unclassifiedRole,
        text: String? = nil,
        attributes: [String: AttributeValue] = [:]
    ) -> some View {
        if let violation = ProbeRecord.idViolation(id) { preconditionFailure(violation) }
        return probeLayout(id: id)
            .background {
                ProbeRecordReporter(id: id, role: role, text: text, attributes: attributes)
            }
    }

    /// Like ``verdictProbe(_:role:text:attributes:)``, and registers an
    /// in-process ``ProbeSiteAction`` on the harness-owned ``ScenarioState``
    /// (installed as ``EnvironmentValues/verdictScenarioState``).
    ///
    /// Prefer constructing the binding from ``ScenarioState/boolBinding(_:default:)``
    /// (or string/double/tap) with the same `id`, then passing it here so the
    /// probe site and the action target cannot drift.
    public func verdictProbe(
        _ id: String,
        role: Role = ProbeRecord.unclassifiedRole,
        text: String? = nil,
        attributes: [String: AttributeValue] = [:],
        action: ProbeSiteAction
    ) -> some View {
        if let violation = ProbeRecord.idViolation(id) { preconditionFailure(violation) }
        return probeLayout(id: id)
            .background {
                ProbeRecordReporter(id: id, role: role, text: text, attributes: attributes)
            }
            .background {
                ProbeActionRegistrar(id: id, action: action)
            }
    }
}

/// Registers a ``ProbeSiteAction`` onto ``EnvironmentValues/verdictScenarioState``
/// during view evaluation (not `onAppear`).
///
/// `onAppear` was too late: ``OracleHost/apply(_:)`` after `init`'s
/// `layoutSubtreeIfNeeded()` still raced when registration waited for appear,
/// and Task 4's `perform` must not depend on that ordering. Evaluating
/// `register` in `body` runs whenever SwiftUI builds the probe — including the
/// host's first layout pass. Inert when no host installed the state.
private struct ProbeActionRegistrar: View {
    let id: String
    let action: ProbeSiteAction
    @Environment(\.verdictScenarioState) private var state

    var body: some View {
        let _ = state?.register(probeID: id, action: action)
        return Color.clear
    }
}

// MARK: - Root modifier

/// The root half of the spine: declares the coordinate space, installs the
/// recorder, collects the records, assembles the tree, delivers it.
///
/// Internal rather than private so `assembledTree(from:measurements:)` — the
/// judgement half of delivery — is reachable from the test target.
struct VerdictRootModifier: ViewModifier {
    let explicitSink: VerdictTreeSink?
    let onTree: ((SemanticNode) -> Void)?

    /// Used only by the `onTree:` flavour, which has no sink of its own. `@State`
    /// so the recorder survives across passes — a recorder recreated on every
    /// body evaluation would lose the measurements of the pass being reported.
    @State private var implicitSink = VerdictTreeSink()

    func body(content: Content) -> some View {
        let sink = explicitSink ?? implicitSink
        return content
            .environment(\.probeRecorder, sink.recorder)
            // Inside the coordinate space, deliberately: a reporter attached
            // outside the `.coordinateSpace` view is not a descendant of it and
            // could not resolve the name.
            .background { VerdictViewportReporter() }
            .coordinateSpace(.named(VerdictRootCoordinateSpace.name))
            .onPreferenceChange(VerdictProbeKey.self) { snapshot in
                deliver(snapshot, to: sink)
            }
    }

    /// Assemble and deliver, or do nothing if the pass reported no viewport.
    ///
    /// Runs while SwiftUI propagates preferences, i.e. after layout — so the
    /// recorder already holds this pass's measurements.
    private func deliver(_ snapshot: ProbeSnapshot, to sink: VerdictTreeSink) {
        guard
            let tree = Self.assembledTree(from: snapshot, measurements: sink.recorder.measurements)
        else { return }
        sink.accept(tree)
        onTree?(tree)
    }

    /// The tree `snapshot` honestly supports, or `nil` when it reported no
    /// viewport.
    ///
    /// Delivering a tree without a viewport would mean guessing the reference
    /// frame every coordinate is relative to, so an absent viewport is a
    /// non-delivery — `nil` here, a skipped `accept` above. A pure function of
    /// its arguments so that judgement is directly assertable, not only
    /// observable as a pump timeout.
    ///
    /// `nonisolated` because it touches no main-actor state: SwiftUI's
    /// `ViewModifier` conformance is main-actor isolated, which would otherwise
    /// make this pure function inherit an isolation it has no use for.
    ///
    /// The recorder is append-only, so it also holds measurements for probes that
    /// have since left the view tree. Those are handed over as they are and not
    /// filtered out: `TreeAssembly` reads `measurements[record.id]` and nothing
    /// else, so a group no record names is never consulted. A filter here read
    /// like a guard against stale data leaking into a node and was removed once
    /// mutation testing showed no test could tell whether it was present — it
    /// could not, because removing it changes no output.
    nonisolated static func assembledTree(
        from snapshot: ProbeSnapshot,
        measurements recorded: [ProbeMeasurement]
    ) -> SemanticNode? {
        guard let viewport = snapshot.viewport else { return nil }
        return TreeAssembly.assemble(
            records: snapshot.records,
            measurements: Dictionary(grouping: recorded, by: \.probeID),
            viewport: viewport
        )
    }
}

extension View {
    /// Make this view a VerdictUI root and deliver its semantic tree into `sink`.
    ///
    /// Four things happen here, and all four are needed for the tree to mean
    /// anything:
    ///
    /// 1. `coordinateSpace(.named("verdict-root"))` — every probe frame below
    ///    becomes relative to *this* view, so the tree does not depend on where
    ///    the host window sits.
    /// 2. `sink.recorder` is injected into the environment, so
    ///    `probeLayout(id:)` probes below have somewhere to record size
    ///    negotiations.
    /// 3. The ``VerdictProbeKey`` stream is collected, together with this view's
    ///    own bounds as the viewport.
    /// 4. ``TreeAssembly`` turns the flat records plus the recorded
    ///    measurements into a ``SemanticNode`` tree, which is handed to `sink`.
    ///
    /// Delivery timing is the part a harness must respect: SwiftUI hands over a
    /// changed preference value after the layout pass that produced it, and only
    /// when it changed. So the tree appears one update cycle after hosting, and
    /// ``VerdictTreeSink/updateCount`` stops moving once the layout is stable.
    /// A caller that reads `latestTree` without pumping the run loop will find
    /// `nil`.
    ///
    /// - Parameter sink: the harness-owned destination. Call
    ///   ``VerdictTreeSink/reset()`` before the pass you intend to read.
    public func verdictRoot(into sink: VerdictTreeSink) -> some View {
        modifier(VerdictRootModifier(explicitSink: sink, onTree: nil))
    }

    /// Callback flavour of ``verdictRoot(into:)``, for a caller that wants to be
    /// pushed each tree rather than poll for the latest one.
    ///
    /// Same pipeline; the closure runs on the main actor during preference
    /// propagation, once per changed tree. It cannot answer "has it settled?" —
    /// use ``verdictRoot(into:)`` and ``VerdictTreeSink/updateCount`` for that.
    /// The recorder installed for the subtree is private to this modifier, so
    /// the raw measurements are not reachable through this flavour.
    ///
    /// - Parameter onTree: receives each assembled tree.
    public func verdictRoot(onTree: @escaping (SemanticNode) -> Void) -> some View {
        modifier(VerdictRootModifier(explicitSink: nil, onTree: onTree))
    }
}
