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

    /// Most recent tree delivered to the sink, if any.
    ///
    /// ``Harness`` reads this on the settle-timeout path so agents still get an
    /// after-tree without forcing another ``currentTree()`` against a dead budget.
    public var latestTree: SemanticNode? { sink.latestTree }

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
    ///   - variant: environment overrides applied AFTER the host's pins, for
    ///     variant sweeps. `nil` — the default — renders the pinned baseline, so
    ///     an ordinary verify is byte-identical to what it was before sweeps
    ///     existed.
    public init<Scenario: VerdictScenario>(
        scenario: Scenario,
        viewport: Size? = nil,
        deadline: TimeInterval = OracleHost.defaultDeadline,
        settlePolicy: SettlePolicy = .skipAnimations,
        clock: VerdictClock = VerdictClock(),
        variant: Variant? = nil
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
                    state: ScenarioState(),
                    // The MEASURING pass needs the variant too: a scenario sized
                    // at `.medium` and then rendered at `.accessibility5` would
                    // be hosted in a box too small for its own content, so every
                    // cell but the baseline would report truncation caused by
                    // the harness rather than by the UI.
                    variant: variant
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
                state: state,
                variant: variant
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

    /// Draw the live hosting view into `rep`.
    ///
    /// The one place ``PixelCapture`` reaches the hosted view. It stays here
    /// rather than in `PixelCapture.swift` because `hostingView` is private to
    /// this class BY DESIGN — the host owns the sink wiring, the pinned
    /// environment and the frame, and a caller holding the view could render it
    /// at a size or in an environment the host never sanctioned, which is the
    /// exact class of divergence the pixel channel exists to detect.
    func renderHostedView(into rep: NSBitmapImageRep) {
        // Layout before drawing: `cacheDisplay` draws whatever is currently laid
        // out, so a host whose state changed since the last pass would otherwise
        // encode the PREVIOUS appearance while reporting the current scenario.
        hostingView.layoutSubtreeIfNeeded()
        hostingView.cacheDisplay(in: hostingView.bounds, to: rep)
    }

    /// An `ImageRenderer` over the same pinned root view the host is showing.
    ///
    /// Uses `hostingView.rootView` rather than rebuilding from the scenario, so
    /// the alternate backend inherits every environment pin — locale, colour
    /// scheme, calendar, time zone — instead of rendering under whatever the
    /// process defaults happen to be. A backend that silently dropped the pins
    /// would diverge from the default backend for a reason that has nothing to
    /// do with the UI, and the diff would report it as a visual regression.
    func makeImageRenderer() -> ImageRenderer<AnyView> {
        ImageRenderer(
            content: AnyView(
                hostingView.rootView
                    .frame(width: hostSize.width, height: hostSize.height)
            )
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
        state: ScenarioState,
        variant: Variant? = nil
    ) -> AnyView {
        // `AnyView` so the class can stay non-generic while `NSHostingView` cannot.
        // It is layout-transparent — it forwards the proposal it receives and
        // reports the size its content returns — which the exact-frame tests in
        // `OracleHostTests` hold to.
        //
        // The variant is applied BEFORE `verdictPinnedEnvironment()` — i.e.
        // CLOSER TO THE CONTENT, which is the writer SwiftUI honours.
        //
        // This was measured rather than reasoned, and the first two attempts had
        // it backwards. A direct probe (two `.environment(\.dynamicTypeSize,)`
        // writes around one reader) shows `inner-medium-outer-ax5` reading
        // `medium`: for the environment, the modifier nearest the content wins,
        // NOT the outermost. Applied on the far side of the pin, a variant is
        // silently overwritten and every cell renders the baseline — measured as
        // two cells at `.medium` and `.accessibility5` both producing a label
        // 116.0 pt wide, a sweep that ran and reported while measuring one thing
        // twice.
        //
        // `verdictPinnedEnvironment()` therefore skips the axes a variant owns
        // when one is present: a pin that re-wrote them here would win, and the
        // sweep would be silently inert again.
        AnyView(
            view
                .verdictRoot(into: sink)
                .verdictPinnedEnvironment(overriding: variant)
                .environment(\.verdictClock, clock)
                .environment(\.verdictScenarioState, state)
        )
    }

    /// The pinned locale. `en_US` because it is the locale the kernel's fixtures,
    /// the demo scenarios and every documented expectation are written against.
    nonisolated static let pinnedLocale = Locale(identifier: "en_US")

    /// The pinned calendar — Gregorian, fixed to the pinned locale and time zone.
    ///
    /// Hoisted to a stored constant when `verdictPinnedEnvironment` became a
    /// `@ViewBuilder`: a builder body may not contain statements, and rebuilding
    /// the calendar on every evaluation was work repeated per layout pass for a
    /// value that never changes.
    nonisolated static let pinnedCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = pinnedLocale
        calendar.timeZone = pinnedTimeZone
        return calendar
    }()

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
    /// - Parameter overriding: when `true`, the four axes a ``Variant`` owns —
    ///   locale, colour scheme, dynamic type and layout direction — are left to
    ///   whatever was applied closer to the content, and only the axes no
    ///   variant can express (display scale, calendar, time zone) are pinned.
    ///
    ///   The two are mutually exclusive by construction rather than by
    ///   convention: SwiftUI honours the environment writer NEAREST the content
    ///   (measured — `inner-medium-outer-ax5` reads `medium`), so a pin that
    ///   re-wrote those axes would win over the variant applied beneath it and
    ///   every sweep cell would silently render the baseline. Keeping the two
    ///   spellings in ONE function means a caller cannot pin six axes and
    ///   override a seventh by accident.
    public func verdictPinnedEnvironment(overriding: Variant? = nil) -> some View {
        // Every axis is ALWAYS written — the modifier chain has one shape, so a
        // pinned host and a swept host differ only in the VALUES written, never
        // in the view type.
        //
        // A `@ViewBuilder` branching between two chains was tried and reverted:
        // it wraps the subtree in `_ConditionalContent`, which changes view
        // identity, and a `Button`'s label stopped reaching the tree entirely
        // ("'Pay' never reached the tree"). Verified against a pristine worktree
        // at HEAD — 10/10 there, 9/10 with the branch — so this is structural,
        // not a stale expansion.
        //
        // The variant's values win because they are written HERE, and the
        // caller applies nothing closer to the content. SwiftUI honours the
        // environment writer NEAREST the content (measured:
        // `inner-medium-outer-ax5` reads `medium`), so a variant applied by the
        // caller on the far side of this pin would be silently overwritten.
        environment(\.displayScale, 1)
            .environment(\.calendar, OracleHost.pinnedCalendar)
            .environment(\.timeZone, OracleHost.pinnedTimeZone)
            .environment(
                \.locale,
                overriding.map { Locale(identifier: $0.localeIdentifier) }
                    ?? OracleHost.pinnedLocale
            )
            .environment(\.colorScheme, overriding?.colorScheme ?? .light)
            .environment(\.dynamicTypeSize, overriding?.dynamicTypeSize ?? .medium)
            .environment(\.layoutDirection, overriding?.layoutDirection ?? .leftToRight)
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
