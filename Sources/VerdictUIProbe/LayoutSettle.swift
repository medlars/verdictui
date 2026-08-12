// VerdictUIProbe — the settle primitive.
//
// Extracted from `OracleHost.swift` (CTS-0F47964E) along a real seam rather
// than an arbitrary line count: `LayoutSettle` is a REUSABLE primitive that
// Wave 3's settle engine builds on, and it is the one thing a windowless AppKit
// host makes genuinely hard — knowing when layout has stopped changing. The
// host that USES it is a different subject, so the two live in different files.
//
// `no.md` #19/#22 govern the general case: a size limit is a proxy for
// readability, and where the mechanical fix makes the code worse (a re-labelled
// logger, a fixture-name collision, an arbitrary cut) the number stands and the
// reason is recorded. This split is the opposite case — the seam was already
// there, marked by its own `// MARK:` and its own doc comment.
import AppKit
import SwiftUI
import VerdictUIKernel


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

    /// Wall-clock span the token must hold before quiet is believed.
    ///
    /// ``requiredAgreeingChecks`` alone is a COUNT, and two checks are separated
    /// by exactly one ``pumpInterval`` — so "agreed twice" used to mean "nothing
    /// changed for 5 ms", which is not a claim worth making about a UI. Measured:
    /// with a mutation scheduled 40 ms out, settle returned
    /// `settled(after: 0.0056s)` and the caller would have linted the
    /// pre-mutation tree while being told the UI was still.
    ///
    /// 30 ms is chosen against SLO 1's budget rather than against a theory: the
    /// act→settle→verdict cycle measured p95 20.5 ms before this floor and the
    /// SLO is 100 ms. It is a floor, not a guarantee — work landing after it is
    /// still the timeout's job, and Wave 8's independent witness catches the rest.
    ///
    /// Applied by ``Quiescence/settle(view:sink:clock:beforeTree:timeout:)`` only,
    /// not by ``OracleHost/currentTree()``. `currentTree` is a CAPTURE — it waits
    /// for the layout it already has to stop moving — while `settle` is the call
    /// that claims the UI is quiet, so that is where the claim has to be paid for.
    /// Charging both would cost the floor three times per ``Harness/perform(_:)``
    /// (capture, settle, capture): measured p95 109.9 ms against a 100 ms SLO,
    /// i.e. a breach, versus 47 ms when only `settle` pays.
    public nonisolated static let minimumQuietInterval: TimeInterval = 0.030

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
        minimumQuiet: TimeInterval = 0,
        progress: () -> Int?
    ) -> Outcome {
        var previous: Int?
        var agreeingChecks = 0
        var iterations = 0
        // When the current run of identical tokens began. Reset with the streak,
        // so a token that changes restarts the clock as well as the count.
        var quietSince: Date?
        let limit = Date().addingTimeInterval(deadline)
        while true {
            let token = progress()
            if let token {
                if token == previous {
                    agreeingChecks += 1
                } else {
                    agreeingChecks = 1
                    quietSince = Date()
                }
            } else {
                agreeingChecks = 0
                quietSince = nil
            }
            previous = token
            // Both conditions: the count proves the token is stable across
            // observations, the span proves it stayed stable long enough for
            // work scheduled beyond one pump to have landed.
            if agreeingChecks >= requiredAgreeingChecks,
                let quietSince,
                Date().timeIntervalSince(quietSince) >= minimumQuiet
            {
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
