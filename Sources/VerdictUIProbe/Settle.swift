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
    public static func progressToken(
        sink: VerdictTreeSink,
        clock: VerdictClock
    ) -> Int? {
        if clock.pendingWaiterCount > 0 { return nil }
        guard sink.latestTree != nil else { return nil }
        // Force pending CA commits through before we sample. Not a true idle
        // probe — see the type's residual-risk note.
        CATransaction.flush()
        var hasher = Hasher()
        hasher.combine(sink.updateCount)
        hasher.combine(sink.recorder.measurements.count)
        hasher.combine(sink.recorder.placements.count)
        hasher.combine(clock.pendingWaiterCount)
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
            deadline: timeInterval(for: timeout)
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
