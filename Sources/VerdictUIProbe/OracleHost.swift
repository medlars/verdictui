// VerdictUIProbe — SwiftUI instrumentation runtime.
//
// Wave 2 Task 3: the oracle harness. Everything before this file produces data
// during a layout pass; this file is what *causes* a layout pass to happen, and
// causes it to happen the same way every time. It owns the three things a
// scenario author must not be trusted to remember — the sink wiring, the pinned
// environment, and the host size — and the one thing a windowless AppKit host
// makes genuinely hard: knowing when the layout has stopped changing.
//
// It never attaches its hosting view to an `NSWindow`. That is the product's CI
// story (runbook: "Probe tests fail on CI but pass locally → NSHostingView
// window-server dependency; the oracle harness must stay windowless"), and the
// pre-wave spike proved it holds — a windowless `NSHostingView` runs real layout
// passes under a sandbox profile that denies every `com.apple.windowserver*`
// mach-lookup, while a control program that orders a real window on screen fails
// under the same profile.
import AppKit
import SwiftUI
import VerdictUIKernel

// MARK: - Settle primitive

/// Drives layout and the main run loop until an observed progress token stops
/// changing, or a deadline expires.
///
/// Factored out of ``OracleHost`` because Wave 3's settle engine needs exactly
/// this loop with more signals hung off it (main-queue drain, virtual-clock
/// timers, `CATransaction` idle) and a `SettleResult` that names the still-moving
/// subtree. The loop shape — observe, pump, observe again, never trust a single
/// observation — is the part worth having in one place.
///
/// ### Why a token instead of a boolean
///
/// "Are we there yet?" cannot be answered by a windowless host: SwiftUI delivers
/// a changed preference *after* the layout pass that produced it, so the first
/// tree to arrive is only the first tree, not the last one. What can be answered
/// is "has anything changed since I last looked?", and that needs a value to
/// compare rather than a predicate to poll. Callers hand over a monotonically
/// increasing token — for ``OracleHost`` it is `VerdictTreeSink.updateCount` —
/// and `nil` for "nothing observable has arrived yet", which resets the streak so
/// an absent value can never be mistaken for a stable one.
@MainActor
public enum LayoutSettle {
    /// How long one iteration lets the main run loop run, in seconds.
    ///
    /// Preference delivery and any `Task { @MainActor … }` a scenario schedules
    /// need a run-loop turn, not just a layout pass, so each iteration gives the
    /// loop a real slice. 5 ms is short enough that settling costs single-digit
    /// milliseconds in the common case (one confirming iteration) and long enough
    /// that a turn's worth of enqueued main-actor work actually runs.
    ///
    /// `nonisolated` because it is a compile-time constant, not main-actor state:
    /// a caller reasoning about the settle budget (or a test pinning this number
    /// against the prose that quotes it) should not have to hop to the main actor
    /// to read a `Double`.
    public nonisolated static let pumpInterval: TimeInterval = 0.005

    /// How many consecutive checks must report the same token before the layout
    /// counts as settled.
    ///
    /// Two, and the second one is not ceremony. A layout that resolves in stages
    /// — a child publishes its measured width upward, the parent stores it, the
    /// next pass places the real thing — delivers a *complete, self-consistent,
    /// wrong* tree first and the settled one a run-loop turn later. Returning the
    /// first delivery would hand callers the placeholder geometry, and it would do
    /// so intermittently, because whether the second delivery has landed depends
    /// on timing. One confirming check is the cheapest observation that
    /// distinguishes "delivered" from "finished".
    ///
    /// `nonisolated` for the same reason as ``pumpInterval``.
    public nonisolated static let requiredAgreeingChecks = 2

    /// How a pump ended.
    public enum Outcome: Equatable, Sendable {
        /// The token agreed across ``requiredAgreeingChecks`` consecutive checks
        /// after `iterations` pumped layout passes.
        case settled(iterations: Int)
        /// The deadline expired while the token was still moving, or while it was
        /// still `nil`, after `iterations` pumped layout passes.
        case expired(iterations: Int)

        /// True only for ``settled(iterations:)``.
        public var isSettled: Bool {
            if case .settled = self { return true }
            return false
        }

        /// Pumped layout passes, either way — the cost of the settle, and the
        /// evidence that a confirming pass actually happened.
        public var iterations: Int {
            switch self {
            case .settled(let iterations), .expired(let iterations): iterations
            }
        }
    }

    /// Pump `view` until `progress` reports the same non-`nil` token on
    /// ``requiredAgreeingChecks`` consecutive checks, or until `deadline` elapses.
    ///
    /// Synchronous on purpose, and not merely as a convenience: `RunLoop.current`
    /// and `run(until:)` are both unavailable from asynchronous contexts (an error
    /// in the Swift 6 language mode), so the run-loop pump has to live in a
    /// synchronous function. An `async` caller — ``OracleHost/currentTree()`` —
    /// calls into it, which is allowed and is the shape the compiler wants.
    ///
    /// - Parameters:
    ///   - view: the hosting view to lay out. `needsLayout` is set before each
    ///     pass, because a layout that AppKit already considers clean would
    ///     otherwise return without giving SwiftUI a chance to publish anything.
    ///   - deadline: wall-clock budget in seconds. Checked between iterations, so
    ///     a deadline of `0` performs one observation and no pumping — it cannot
    ///     loop forever and it cannot pump forever.
    ///   - progress: the token to watch. `nil` means "nothing observable yet" and
    ///     resets the agreement streak.
    /// - Returns: how the pump ended, with the iteration count either way.
    public static func pump(
        _ view: NSView,
        deadline: TimeInterval,
        progress: () -> Int?
    ) -> Outcome {
        var previous: Int?
        var agreeingChecks = 0
        var iterations = 0
        let limit = Date().addingTimeInterval(deadline)
        while true {
            let token = progress()
            if let token {
                agreeingChecks = token == previous ? agreeingChecks + 1 : 1
            } else {
                agreeingChecks = 0
            }
            previous = token
            if agreeingChecks >= requiredAgreeingChecks {
                return .settled(iterations: iterations)
            }
            if Date() >= limit {
                return .expired(iterations: iterations)
            }
            iterations += 1
            view.needsLayout = true
            view.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(pumpInterval))
        }
    }
}

// MARK: - Failure surface

/// What ``OracleHost/currentTree()`` throws when it cannot honestly answer.
///
/// ### Why throwing, and not a `SemanticNode` come what may
///
/// The plan sketched `func currentTree() async -> SemanticNode`, and a
/// non-throwing signature has exactly three possible implementations at the
/// deadline: hang, fabricate, or trap. Hanging is the failure mode CI cannot
/// diagnose. Fabricating — returning the synthesized empty root, or the last tree
/// from a layout that is still moving — is worse than hanging, because it reports
/// PASS for a screen nobody ever measured, and a verification engine that
/// occasionally invents a verdict is not one anyone will keep using. Trapping via
/// `preconditionFailure` at least does not lie, but it takes the whole test
/// process with it, so the one test that proves the harness fails cleanly could
/// not be written, and Wave 6's daemon would die on a bad scenario instead of
/// returning a structured error verdict.
///
/// Throwing leaves the caller holding the evidence and the choice. Wave 3 turns
/// these into `.timedOut` settle results and FAIL verdicts; Wave 6 turns them
/// into JSON.
public enum OracleHostError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The settle budget expired before the harness could confirm that the layout
    /// had stopped changing.
    ///
    /// One case rather than two, because "no tree arrived" and "trees kept
    /// arriving" are the same event — the deadline — seen with different evidence,
    /// and ``deliveries`` is that evidence:
    ///
    /// - `deliveries == 0`: nothing was ever delivered. A body with no geometry
    ///   below the root gets no `GeometryReader` evaluated, so no viewport is
    ///   reported, and `verdictRoot(into:)` correctly refuses to assemble a tree
    ///   whose reference frame it would have to invent.
    /// - `deliveries > 0`: a tree exists but the count was still moving, or the
    ///   budget was too short to see it stop. Either way the last tree describes a
    ///   layout that had not been confirmed finished.
    ///
    /// No tree is attached in either case, and that is the point. A tree from a
    /// layout still in motion is a snapshot of a moment, not a description of a
    /// screen, and returning it would let a verdict be drawn from geometry nobody
    /// confirmed — which is worse than returning nothing, because it is
    /// indistinguishable from a real answer.
    case settleTimedOut(
        scenario: String,
        hostSize: Size,
        deadline: TimeInterval,
        iterations: Int,
        deliveries: Int
    )

    public var description: String {
        switch self {
        case .settleTimedOut(
            let scenario, let hostSize, let deadline, let iterations, let deliveries):
            let size = "\(Self.points(hostSize.width)) x \(Self.points(hostSize.height)) pt"
            let context =
                "scenario '\(scenario)' at \(size) after \(deadline) s "
                + "and \(iterations) pumped layout passes"
            if deliveries == 0 {
                return "\(context): no semantic tree was ever delivered. A body with no geometry "
                    + "reports no viewport, and a tree with no viewport would have to invent the "
                    + "frame every other frame is measured against."
            }
            return "\(context): \(deliveries) trees delivered but the layout was never confirmed "
                + "settled, so the last one is not returned."
        }
    }

    /// A point measurement without a trailing `.0`, matching how the kernel
    /// renders measurements inside finding messages.
    private static func points(_ value: Double) -> String {
        guard value.isFinite, value == value.rounded(), value.magnitude < 1e15 else {
            return "\(value)"
        }
        return "\(Int64(value))"
    }
}

// MARK: - Host

/// Renders one ``VerdictScenario`` in a windowless `NSHostingView` and hands back
/// the semantic tree its layout produced.
///
/// ```swift
/// let host = OracleHost(scenario: CheckoutScreen(), viewport: Size(width: 375, height: 600))
/// let tree = try await host.currentTree()
/// let verdict = RuleEngine.run(
///     rules: RuleEngine.standardRules,
///     on: tree,
///     context: .macOS(viewport: tree.frame, scenario: host.scenarioName)
/// )
/// ```
///
/// ### What the host owns, so the scenario does not
///
/// - `.verdictRoot(into:)` and the ``VerdictTreeSink`` behind it. A scenario that
///   wires its own sink can wire it wrong — outside the coordinate space, around
///   only half the content — and the symptom is an empty or truncated tree, which
///   looks exactly like a screen with no defects.
/// - The pinned environment. See ``pinned(_:sink:)``.
/// - The host size, rounded to whole points and capped. See ``resolveHostSize(_:)``.
/// - Knowing when the layout has stopped moving. See ``currentTree()``.
///
/// ### Lifetime
///
/// One host renders one scenario for as long as it lives; it is not reusable for
/// a different scenario, because the pinned environment and the resolved viewport
/// are both properties of the pair. Constructing a host runs a full layout pass —
/// and a second, throwaway one when no explicit viewport is given, to measure
/// `fittingSize` — so it is not free, while ``currentTree()`` on an already-settled
/// host costs one confirming pass. Wave 6's daemon pools hosts per scenario for
/// exactly that reason.
@MainActor
public final class OracleHost {
    /// Largest host size the harness will infer, in points, per dimension.
    ///
    /// Unbounded content makes `fittingSize` answer honestly and uselessly: a
    /// `ScrollView` over 300 twenty-point rows measures 6000 pt tall, and content
    /// with an infinite ideal size can measure larger still. Hosting at that size
    /// would lay out every row of a list nobody can see, and the plan's Wave 2
    /// risk list names it ("`fittingSize` loops on unbounded content — cap by
    /// explicit viewport").
    ///
    /// 4096 pt is chosen to sit above every real macOS viewport and below any
    /// runaway one. The widest display Apple ships, the Pro Display XDR, is 6016
    /// physical pixels — 3008 pt at its native 2× scale — so a full-screen window
    /// on the largest hardware in existence still fits with room to spare, while
    /// the 300-row `ScrollView` measured at 6000 pt below — and the 40000 pt the
    /// same arithmetic gives a 2000-row list — is cut to a fraction of the layout
    /// work.
    ///
    /// Clamping is never silent: see ``wasClamped``.
    public nonisolated static let sizeCap = Size(width: 4096, height: 4096)

    /// Default settle budget for ``currentTree()``, in seconds.
    ///
    /// Three seconds is the same figure the Wave 2 probe tests converged on:
    /// generous enough to absorb a cold first pass on a loaded CI machine, short
    /// enough that a scenario which never settles fails the suite in seconds
    /// rather than wedging it. Wave 3's `settle(timeout:)` defaults tighter (2 s)
    /// because by then the harness has more signals and fewer excuses.
    public nonisolated static let defaultDeadline: TimeInterval = 3

    /// The scenario's own ``VerdictScenario/name``, kept so a verdict, a baseline
    /// key, and an error message can all cite the same string the author chose.
    public let scenarioName: String

    /// The size the hosting view was given, in whole points — and therefore the
    /// viewport the assembled tree's root frame reports and every root-space
    /// frame is measured from.
    public let hostSize: Size

    /// True when ``hostSize`` is ``sizeCap`` in a dimension the scenario asked for
    /// more of, or asked for nonsense in (a non-finite or negative measurement).
    ///
    /// Exposed as a fact rather than emitted as a finding because findings are the
    /// kernel's business, and the kernel is deliberately blind to how a tree was
    /// produced. A clamped host is a real caveat about the tree — content below
    /// the cap was laid out under a constraint the scenario did not choose — so a
    /// caller that turns trees into verdicts (Wave 2 Task 6, Wave 6's CLI) reads
    /// this and attaches the `warning` finding the plan asks for. Silently
    /// clamping and hoping nobody notices is the failure mode this property
    /// exists to prevent.
    public let wasClamped: Bool

    /// Settle budget ``currentTree()`` works within, in seconds.
    public let deadline: TimeInterval

    /// Controllable clock installed into the hosted environment as
    /// ``EnvironmentValues/verdictClock``. Scenario code that sleeps against it
    /// advances only when a test (or later the settle engine) calls
    /// ``VerdictClock/advance(by:)``.
    public let clock: VerdictClock

    /// Harness-owned scenario state — the same instance passed to every
    /// `body(state:)` evaluation and the target of ``apply(_:)``.
    public let state: ScenarioState

    /// How ``applyStateChange(_:)`` wraps injected mutations. Defaults to
    /// ``SettlePolicy/skipAnimations`` — Wave 3's animation control, not the
    /// unwritable `accessibilityReduceMotion` pin.
    public var settlePolicy: SettlePolicy

    /// Count of `CATransaction.flush` calls performed by ``applyStateChange(_:)``
    /// on this host. Tests pin the ``SettlePolicy/runAnimations`` path with it.
    public private(set) var caTransactionFlushCount = 0

    /// The raw layout negotiations recorded below the root: proposals, answers,
    /// placements, per probe id.
    ///
    /// Exposed because a caller looking at a surprising frame wants the
    /// conversation that produced it, not just its outcome. The log accumulates
    /// across ``currentTree()`` calls by design (``ProbeRecorder`` documents its
    /// own unbounded growth); a caller that wants only the next pass's
    /// negotiations calls `recorder.reset()` first, which is safe — unlike
    /// resetting the whole sink, see ``currentTree()``.
    public var recorder: ProbeRecorder { sink.recorder }

    /// Never added to a window, never ordered on screen. See the file header.
    private let hostingView: NSHostingView<AnyView>

    /// Owned by the host so the scenario cannot install its own.
    private let sink: VerdictTreeSink

    /// Create a host for `scenario`.
    ///
    /// - Parameters:
    ///   - scenario: what to render. Generic rather than existential so the
    ///     scenario's `Body` type survives into the hosted view tree; the class
    ///     itself stays non-generic so a pool can hold hosts for different
    ///     scenarios.
    ///   - viewport: the size to render at, in points. `nil` measures the
    ///     scenario's own ideal size with `fittingSize` instead. An explicit
    ///     viewport wins over the measurement, because the point of a viewport is
    ///     to ask "does this screen work at *this* size" — but it is still put
    ///     through ``resolveHostSize(_:)``, so an explicit `Size(width: .infinity,
    ///     height: 100)` is capped and reported rather than obeyed. A viewport
    ///     that large is not a viewport, it is a mistake, and obeying it would
    ///     hang the caller.
    ///   - deadline: settle budget for ``currentTree()``, in seconds.
    ///   - settlePolicy: animation control for ``applyStateChange(_:)``.
    ///   - clock: virtual clock installed into the hosted environment. The host
    ///     owns the default instance; tests that need a pre-advanced frontier
    ///     can pass one in.
    public init<Scenario: VerdictScenario>(
        scenario: Scenario,
        viewport: Size? = nil,
        deadline: TimeInterval = OracleHost.defaultDeadline,
        settlePolicy: SettlePolicy = .skipAnimations,
        clock: VerdictClock = VerdictClock()
    ) {
        scenarioName = scenario.name
        self.deadline = deadline
        self.settlePolicy = settlePolicy
        self.clock = clock
        let state = ScenarioState()
        self.state = state

        let requested: Size
        if let viewport {
            requested = viewport
        } else {
            // Measured in a throwaway host with a throwaway state, so the
            // measurement pass cannot leave anything behind — no `@State` settled
            // at an unbounded proposal, no probe registrations from a pass that
            // is about to be discarded — in the tree the caller will read.
            let measuring = NSHostingView(
                rootView: Self.pinned(
                    ScenarioRoot(scenario: scenario, state: ScenarioState()),
                    sink: VerdictTreeSink(),
                    clock: clock,
                    state: ScenarioState()
                )
            )
            requested = Size(measuring.fittingSize)
        }
        let resolved = Self.resolveHostSize(requested)
        hostSize = resolved.size
        wasClamped = resolved.wasClamped

        let sink = VerdictTreeSink()
        self.sink = sink
        hostingView = NSHostingView(
            rootView: Self.pinned(
                ScenarioRoot(scenario: scenario, state: state)
                    // Applied by the host, always, in both sizing paths, so
                    // `hostSize` *is* the viewport rather than an upper bound on
                    // it. Without it the root would be content-sized, the root
                    // frame and `hostSize` would disagree for any content that
                    // does not fill, and a clamped host would not actually
                    // constrain the content it was clamped to protect.
                    .frame(width: resolved.size.width, height: resolved.size.height),
                sink: sink,
                clock: clock,
                state: state
            )
        )
        hostingView.frame = CGRect(
            x: 0,
            y: 0,
            width: resolved.size.width,
            height: resolved.size.height
        )
        hostingView.layoutSubtreeIfNeeded()
    }

    /// The settled semantic tree for the scenario as it currently stands.
    ///
    /// Pumps layout and the main run loop until ``VerdictTreeSink/updateCount``
    /// agrees across ``LayoutSettle/requiredAgreeingChecks`` consecutive checks
    /// with a tree in hand, then returns that tree.
    ///
    /// ### Why the sink is not reset first
    ///
    /// `VerdictTreeSink` documents `reset()` as the thing to call "before a pass
    /// whose tree the caller intends to read", and doing that here was the first
    /// implementation. It does not work, and the way it fails is instructive:
    /// SwiftUI delivers a preference only when the value *changes*, so resetting
    /// the sink before an unchanged layout discards the only copy of the tree and
    /// nothing will ever re-deliver it. Measured, not assumed — a reset followed
    /// by 342 pumped layout passes produced no tree at all.
    ///
    /// So the reset contract belongs to a caller who is about to *change*
    /// something (Wave 3, around an injected action), not to a caller who wants to
    /// read what is already true. Not resetting is also the more honest reading of
    /// this method's name: the tree the last delivery produced *is* the current
    /// tree, because a delivery is exactly what a change causes.
    ///
    /// ### Why `async`
    ///
    /// The suspension at the top is not decoration: it lets already-enqueued
    /// main-actor work — a `Task { @MainActor … }` a scenario scheduled during a
    /// previous pass — run before the first observation, so the settle loop starts
    /// from a state the caller could not have raced with.
    ///
    /// - Returns: the assembled tree. Its root frame is ``hostSize``.
    /// - Throws: ``OracleHostError/settleTimedOut(scenario:hostSize:deadline:iterations:deliveries:)``
    ///   when ``deadline`` expires before stability is confirmed. It never hangs
    ///   and never returns a tree it cannot stand behind.
    public func currentTree() async throws -> SemanticNode {
        await Task.yield()
        let outcome = LayoutSettle.pump(hostingView, deadline: deadline) { [sink] in
            // `nil` until something is delivered: a count of zero is stable
            // forever, and reporting it as a token would settle instantly on a
            // scenario that never produced a tree.
            sink.latestTree == nil ? nil : sink.updateCount
        }
        // The second clause cannot fail once the first holds: `isSettled` means
        // the closure above returned the same non-nil token twice, which means
        // `latestTree` was set, and nothing on this synchronous stretch calls
        // `reset()`. It exists to bind `tree` without a force-unwrap, not to
        // cover a reachable state — the `else` branch is entered only on expiry.
        guard outcome.isSettled, let tree = sink.latestTree else {
            throw OracleHostError.settleTimedOut(
                scenario: scenarioName,
                hostSize: hostSize,
                deadline: deadline,
                iterations: outcome.iterations,
                deliveries: sink.updateCount
            )
        }
        return tree
    }

    // MARK: - Sizing

    /// The host size to use for `requested`: whole points, within ``sizeCap``.
    ///
    /// Rounding is upward. A fractional request rounded *down* would host content
    /// in less space than it asked for, and the visible consequence would be a
    /// truncation or clipping finding manufactured by the harness — the one kind
    /// of false positive that destroys trust in every other finding. Rounding at
    /// all is required by the coordinate space: a host placed on a half-pixel
    /// boundary makes root-space frames wobble by 0.5 pt, so a tree that should
    /// re-encode byte-identically does not.
    ///
    /// A dimension is clamped when it exceeds the cap, and also when it is not a
    /// usable measurement at all — infinite, NaN, or negative — because
    /// `fittingSize` on content with an infinite ideal size can report any of
    /// those, and `CGRect` arithmetic on a NaN width produces a tree of NaN
    /// frames that compares equal to nothing and encodes as invalid JSON.
    ///
    /// - Returns: the size to host at, and whether either dimension was clamped.
    nonisolated static func resolveHostSize(_ requested: Size) -> (size: Size, wasClamped: Bool) {
        let width = clamp(requested.width, cap: sizeCap.width)
        let height = clamp(requested.height, cap: sizeCap.height)
        return (
            Size(width: width.value, height: height.value),
            width.wasClamped || height.wasClamped
        )
    }

    /// One dimension of ``resolveHostSize(_:)``.
    private nonisolated static func clamp(_ value: Double, cap: Double)
        -> (value: Double, wasClamped: Bool)
    {
        guard value.isFinite, value >= 0 else { return (cap, true) }
        let rounded = value.rounded(.up)
        return rounded > cap ? (cap, true) : (rounded, false)
    }

    // MARK: - The hosted root

    /// Apply an injected state mutation under the host's ``settlePolicy``.
    ///
    /// This is the Wave 3 Task 1 seam Task 4's `perform` will call before
    /// settle: one place that owns `Transaction(animation: nil)` vs the
    /// `CATransaction.flush` + run-loop pump path. It does not settle and does
    /// not capture trees — that is later work.
    public func applyStateChange(_ body: () -> Void) {
        caTransactionFlushCount += AnimationControl.apply(settlePolicy, body)
    }

    /// Apply a ``ProbeAction`` to ``state`` under ``settlePolicy``.
    ///
    /// Forces one layout pass first so `.verdictProbe(..., action:)` sites and
    /// ``ScenarioState`` binding factories have registered — otherwise a call
    /// before any render fails with a false ``ProbeActionError/unknownProbe``.
    /// Does not settle and does not capture trees — Task 4's `perform` wraps
    /// this with settle + diff. Throws ``ProbeActionError`` when the probe has
    /// no compatible binding.
    public func apply(_ action: ProbeAction) throws {
        hostingView.layoutSubtreeIfNeeded()
        var thrown: (any Error)?
        applyStateChange {
            do {
                try action.apply(to: state)
            } catch {
                thrown = error
            }
        }
        if let thrown { throw thrown }
    }

    /// Wait until the hosted UI is quiescent, or until `timeout`.
    ///
    /// Composes main-queue drain, probe-recorder activity, tree stability,
    /// virtual-clock waiter census, and a `CATransaction.flush` sample on top
    /// of ``LayoutSettle`` — see ``Quiescence``. Default timeout is 2 seconds
    /// (tighter than ``defaultDeadline`` because settle has more signals).
    ///
    /// - Returns: ``SettleResult/settled(after:)`` or
    ///   ``SettleResult/timedOut(lastDelta:)``. Never hangs. On timeout, call
    ///   ``timeoutVerdict(from:settleMs:)`` for the FAIL ``Verdict`` agents cite.
    public func settle(
        timeout: Duration = Quiescence.defaultTimeout
    ) async -> SettleResult {
        await Quiescence.settle(
            view: hostingView,
            sink: sink,
            clock: clock,
            beforeTree: sink.latestTree,
            timeout: timeout
        )
    }

    /// FAIL verdict for a ``SettleResult/timedOut(lastDelta:)``, or `nil` when
    /// `result` was a settle. Uses the sink's latest tree as evidence.
    public func timeoutVerdict(
        from result: SettleResult,
        settleMs: Double
    ) -> Verdict? {
        Quiescence.timeoutVerdict(
            scenario: scenarioName,
            result: result,
            tree: sink.latestTree,
            settleMs: settleMs
        )
    }

    /// Wrap `view` in the verdict root, the pinned environment, and the
    /// harness-owned virtual clock.
    ///
    /// The pins themselves live on ``SwiftUI/View/verdictPinnedEnvironment()``,
    /// which is where they are documented and where anything else that hosts a
    /// probed view — including this package's own test hosts — gets them from.
    /// One definition, so a host that pins six of the seven values cannot exist.
    private static func pinned<Content: View>(
        _ view: Content,
        sink: VerdictTreeSink,
        clock: VerdictClock,
        state: ScenarioState
    ) -> AnyView {
        // `AnyView` so the class can stay non-generic while `NSHostingView` cannot.
        // It is layout-transparent — it forwards the proposal it receives and
        // reports the size its content returns — which the exact-frame tests in
        // `OracleHostTests` hold to.
        AnyView(
            view
                .verdictRoot(into: sink)
                .verdictPinnedEnvironment()
                .environment(\.verdictClock, clock)
                .environment(\.verdictScenarioState, state)
        )
    }

    /// The pinned locale. `en_US` because it is the locale the kernel's fixtures,
    /// the demo scenarios and every documented expectation are written against.
    nonisolated static let pinnedLocale = Locale(identifier: "en_US")

    /// The pinned time zone. UTC because it is the only zone with no daylight
    /// saving transition, so a scenario rendering a date cannot produce a
    /// different tree in March than it did in February.
    nonisolated static let pinnedTimeZone = TimeZone(identifier: "UTC") ?? .gmt
}

// MARK: - The deterministic environment

extension View {
    /// Pin every environment value a VerdictUI render must not read from the
    /// machine it runs on.
    ///
    /// Applied by ``OracleHost`` to every scenario it hosts, and separated out so
    /// it is applied *identically* everywhere: a second host — this package's own
    /// test hosts, Wave 5's sweeps, a caller embedding the probe in their own
    /// harness — that pinned six of these seven values would produce trees that
    /// agree with the harness on most machines and disagree on someone's.
    ///
    /// Every pin below exists because the value it fixes would otherwise be read
    /// from the machine running the test, and a verdict that depends on the
    /// machine is not a verdict — it is a local opinion that will disagree with
    /// CI. `en_CA` and `America/Toronto` are what this developer's Mac reports
    /// today; a colleague's Mac reports something else, and the frames come out
    /// different because a date string is a different number of glyphs wide.
    ///
    /// | Pin | Fixes | Why layout depends on it |
    /// |---|---|---|
    /// | `displayScale` = 1 | backing-store scale | point-to-pixel rounding: at 2× a frame can land on a half point, at 1× it cannot. Also makes points and pixels the same number, so the cap in ``OracleHost/sizeCap`` means one thing. |
    /// | `locale` = `en_US` | number, date, currency and plural formatting | `Text(date, format:)` and `Text(value, format:)` render a locale-specific string, and a longer string is a wider frame. Measured: the same instant renders 142 pt wide under `en_US` and 115 pt under `de_DE`. |
    /// | `calendar` = Gregorian in UTC | era, month names, week rules | pinned separately from `timeZone` because it carries its own: an unpinned `calendar` keeps the machine's zone even when `\.timeZone` is pinned, which was measured (`America/Toronto` surviving a `UTC` pin) and is exactly the kind of half-fix that makes a determinism bug intermittent. |
    /// | `timeZone` = UTC | wall-clock rendering of an instant | the same `Date` is a different day, and a different number of characters, in a different zone. |
    /// | `colorScheme` = `.light` | resolved colors, and control metrics that differ by scheme | pinned so a machine in dark mode does not produce a different tree, and so Wave 5's scheme sweep starts from a known cell rather than from "whatever this Mac was set to". |
    /// | `dynamicTypeSize` = `.medium` | every text metric in the tree | the single biggest lever on layout there is; unpinned, a tester with larger type sees truncation findings nobody else can reproduce. Wave 5 sweeps this deliberately, which only means anything if the default is fixed. |
    /// | `layoutDirection` = `.leftToRight` | mirroring of every frame | not in the plan's list, and added after noticing that pinning `locale` does not pin direction: SwiftUI takes direction from the system, so a Mac configured in Arabic would mirror every `x` coordinate in the tree while every other pin held. |
    ///
    /// ### The one pin that could not be made
    ///
    /// `accessibilityReduceMotion` is read-only in `EnvironmentValues` — there is
    /// no `WritableKeyPath` to write through, which the compiler says plainly —
    /// so the value in the hosted tree is the machine's system setting. Wave 2
    /// renders no animations, so nothing in a tree depends on it unless a scenario
    /// branches on it explicitly, and a scenario that does is non-deterministic
    /// across machines in a way this harness cannot fix. Wave 3, which drives
    /// animations on purpose, applies `Transaction(animation: nil)` instead —
    /// controlling the animation rather than asking the system to.
    public func verdictPinnedEnvironment() -> some View {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = OracleHost.pinnedLocale
        calendar.timeZone = OracleHost.pinnedTimeZone

        return environment(\.displayScale, 1)
            .environment(\.locale, OracleHost.pinnedLocale)
            .environment(\.calendar, calendar)
            .environment(\.timeZone, OracleHost.pinnedTimeZone)
            .environment(\.colorScheme, .light)
            .environment(\.dynamicTypeSize, .medium)
            .environment(\.layoutDirection, .leftToRight)
    }
}

// MARK: - Scenario hosting

/// Calls `scenario.body(state:)` from inside a `View`'s own body.
///
/// The indirection is what makes the ``ScenarioState`` lifetime guarantee real.
/// Handing `scenario.body(state: state)` straight to `NSHostingView` would
/// evaluate the scenario's body exactly once, at construction, and every
/// subsequent SwiftUI update would re-evaluate only whatever that one call
/// returned — so a Wave 3 action that mutates the state would never reach the
/// author's own `body`. Evaluating it here instead means SwiftUI re-runs
/// `body(state:)` on every invalidation, with the same state instance each time.
private struct ScenarioRoot<Scenario: VerdictScenario>: View {
    let scenario: Scenario
    @ObservedObject var state: ScenarioState

    var body: some View {
        scenario.body(state: state)
    }
}
