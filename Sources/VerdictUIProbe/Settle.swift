// VerdictUIProbe — SwiftUI instrumentation runtime.
//
// Wave 3 Task 2: quiescence detection. Composes several quiet-signals on top of
// ``LayoutSettle``'s pump so `settle()` returns only when the hosted UI is
// honestly still — or times out with a delta that names what kept moving.
import AppKit
import Foundation
import VerdictUIKernel

// MARK: - Result

/// Outcome of ``OracleHost/settle(timeout:)``.
///
/// Never hangs: a timeout always produces ``timedOut(lastDelta:)``. Never lies:
/// ``settled(after:)`` requires the composed quiet token to agree across
/// ``LayoutSettle/requiredAgreeingChecks`` consecutive pump observations.
public enum SettleResult: Equatable, Sendable {
    /// The UI was quiet for the required confirming checks after `after`
    /// of wall-clock waiting (ContinuousClock, not the virtual clock).
    case settled(after: Duration)
    /// The timeout expired while something was still moving. `lastDelta` is the
    /// tree diff from the settle attempt's starting tree to the last observed
    /// tree — the still-changing evidence Task 5's hostile suite and agents cite.
    case timedOut(lastDelta: TreeDelta)
}

// MARK: - Quiescence

/// Composes the quiet-signals Wave 3 requires and drives them through
/// ``LayoutSettle/pump(_:deadline:progress:)``.
///
/// ### Signals (all must be stable across two consecutive checks)
///
/// | Signal | How it is observed |
/// |---|---|
/// | Main queue drained | Async double-barrier before the pump; each pump iteration runs the main `RunLoop` |
/// | No in-flight probe layout | `ProbeRecorder` measurement + placement counts part of the token |
/// | Tree unchanged | `VerdictTreeSink.updateCount` part of the token (`nil` until a tree exists) |
/// | No pending virtual-clock timers | ``VerdictClock/pendingWaiterCount`` must be 0 or the token is `nil` |
/// | `CATransaction` idle | `CATransaction.flush()` before sampling; see residual risk below |
///
/// ### Residual risk (documented, fail-closed)
///
/// - Work scheduled off the main queue is invisible here. Two consecutive quiet
///   checks + the virtual-clock census catch the instrumented cases; uninstrumented
///   async work is what the timeout verdict is for (plan SD1/SD2).
/// - Core Animation does not expose a true "commit cycle idle" probe. Flushing
///   before each sample forces pending commits through; a commit scheduled after
///   the sample can still race — the confirming second check is the mitigation.
@MainActor
public enum Quiescence {
    /// Plan default for ``OracleHost/settle(timeout:)``.
    public nonisolated static let defaultTimeout: Duration = .seconds(2)

    /// Rule name cited on a settle-timeout FAIL verdict.
    public nonisolated static let timeoutRule = "settle-timeout"

    /// Drain already-enqueued main-queue work before sampling quiescence.
    ///
    /// Two `DispatchQueue.main.async` hops: the first lets the current turn
    /// finish scheduling, the second runs after that work, so a barrier that
    /// only yielded once could still observe a non-empty queue.
    public static func drainMainQueue() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async {
                DispatchQueue.main.async {
                    continuation.resume()
                }
            }
        }
    }

    /// Wall-clock seconds for a Swift `Duration` — ``LayoutSettle``'s deadline.
    public nonisolated static func timeInterval(for duration: Duration) -> TimeInterval {
        let components = duration.components
        return Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }

    /// Composite progress token for ``LayoutSettle/pump(_:deadline:progress:)``.
    ///
    /// Returns `nil` when settling would be a lie (no tree yet, or virtual-clock
    /// waiters still pending), which resets the pump's agreement streak.
    /// Folds a node's identity, geometry and text into `hasher`, depth-first.
    ///
    /// Recursion is bounded by the tree the probe assembled, which is built
    /// from a finite view hierarchy — unlike the external AX tree, which is a
    /// GRAPH the window server owns and needs an explicit depth bound
    /// (`no.md` #44). Nothing here crosses a trust boundary.
    static func combine(_ node: SemanticNode, into hasher: inout Hasher) {
        hasher.combine(node.id)
        hasher.combine(node.role)
        hasher.combine(node.frame.x)
        hasher.combine(node.frame.y)
        hasher.combine(node.frame.width)
        hasher.combine(node.frame.height)
        hasher.combine(node.text)
        hasher.combine(node.isVisible)
        for child in node.children {
            combine(child, into: &hasher)
        }
    }

    public static func progressToken(
        sink: VerdictTreeSink,
        clock: VerdictClock
    ) -> Int? {
        // Sampled ONCE. Reading it again below the flush would let a waiter
        // registering in between produce a token that hashes a count the guard
        // never saw -- two reads of one moving quantity, reported as if they
        // were the same observation. Self-correcting on the next check, so this
        // was never a wrong verdict, only an incoherent one (CTS-8DDE6D09).
        let pendingWaiters = clock.pendingWaiterCount
        if pendingWaiters > 0 { return nil }
        guard sink.latestTree != nil else { return nil }
        // Force pending CA commits through before we sample. Not a true idle
        // probe — see the type's residual-risk note.
        CATransaction.flush()
        var hasher = Hasher()
        hasher.combine(sink.updateCount)
        hasher.combine(sink.recorder.measurements.count)
        hasher.combine(sink.recorder.placements.count)
        hasher.combine(pendingWaiters)
        // The tree's CONTENT, not merely how many times it was delivered.
        //
        // Every other term above is a COUNT, and a layout can change without
        // changing any of them: a box alternating between 10 pt and 40 pt wide
        // delivers the same number of measurements and placements each pass, so
        // the token went CONSTANT while the tree provably oscillated and
        // `settle()` reported quiet on a screen that never stopped moving.
        // Measured 2026-08-14: the tree's box read 40 → 10 → 40 → 10 on
        // consecutive reads while the token held one value for seven checks
        // (CI run 31776287835). A quiescence signal that cannot see the thing
        // it declares quiet is the false-green this engine exists to prevent.
        //
        // Folded explicitly rather than by making `SemanticNode: Hashable`:
        // the kernel type's conformances are its public contract, and widening
        // one for a probe-side concern would be a breaking-change surface added
        // for an internal caller. Geometry plus identity is what "the layout is
        // still moving" means; text and attributes ride along because a label
        // that keeps changing is movement too.
        if let tree = sink.latestTree {
            Quiescence.combine(tree, into: &hasher)
        }
        return hasher.finalize()
    }

    /// Drive `view` until the composed token is quiet, or `timeout` elapses.
    ///
    /// - Parameters:
    ///   - view: the windowless hosting view to pump (same as ``OracleHost``).
    ///   - sink: tree + recorder the token is built from.
    ///   - clock: virtual clock whose pending waiters block quiet.
    ///   - beforeTree: tree at the start of the attempt; used for the timeout delta.
    ///   - timeout: wall-clock budget (default 2 s).
    public static func settle(
        view: NSView,
        sink: VerdictTreeSink,
        clock: VerdictClock,
        beforeTree: SemanticNode?,
        timeout: Duration = defaultTimeout
    ) async -> SettleResult {
        await drainMainQueue()
        let started = ContinuousClock.now
        let outcome = LayoutSettle.pump(
            view,
            deadline: timeInterval(for: timeout),
            minimumQuiet: LayoutSettle.minimumQuietInterval
        ) {
            progressToken(sink: sink, clock: clock)
        }
        let elapsed = started.duration(to: .now)
        if outcome.isSettled {
            return .settled(after: elapsed)
        }
        let afterTree = sink.latestTree
        let delta = timeoutDelta(before: beforeTree, after: afterTree)
        return .timedOut(lastDelta: delta)
    }

    /// FAIL verdict naming the still-moving evidence. Task 4's harness surfaces
    /// this on timeout; Task 2 exposes it so the timeout path is never a bare
    /// boolean.
    public static func timeoutVerdict(
        scenario: String,
        result: SettleResult,
        tree: SemanticNode?,
        settleMs: Double
    ) -> Verdict? {
        guard case .timedOut(let delta) = result else { return nil }
        let nodeID = namedSubtree(in: delta) ?? tree?.id ?? ""
        let message: String
        if delta.isEmpty {
            message = """
                settle timed out with no tree delta — a pending virtual-clock \
                waiter or off-main work kept the UI from going quiet
                """
        } else {
            message = "settle timed out while the tree was still changing (\(delta.summary))"
        }
        return Verdict(
            scenario: scenario,
            findings: [
                Finding(
                    rule: timeoutRule,
                    severity: .error,
                    nodeID: nodeID,
                    message: message,
                    suggestion: """
                        Advance VerdictClock past pending sleeps, or raise the \
                        settle timeout if the scenario intentionally animates longer.
                        """
                )
            ],
            tree: tree,
            delta: delta,
            timing: Verdict.Timing(settleMs: settleMs)
        )
    }

    // MARK: - Internals

    private static func timeoutDelta(
        before: SemanticNode?,
        after: SemanticNode?
    ) -> TreeDelta {
        switch (before, after) {
        case let (before?, after?):
            return TreeDiff.compute(before: before, after: after)
        case (nil, _), (_, nil):
            // No honest before/after pair — empty delta; the FAIL finding explains.
            return TreeDelta()
        }
    }

    /// Prefer a concrete moved/changed/added/removed path so the finding cites
    /// a real node rather than the empty root id.
    private static func namedSubtree(in delta: TreeDelta) -> String? {
        if let moved = delta.moved.first {
            return moved.path.segments.last ?? moved.path.description
        }
        if let changed = delta.changed.first {
            return changed.path.segments.last ?? changed.path.description
        }
        if let added = delta.added.first {
            return added.node.id.isEmpty
                ? (added.path.segments.last ?? added.path.description)
                : added.node.id
        }
        if let removed = delta.removed.first {
            return removed.segments.last ?? removed.description
        }
        return nil
    }
}
