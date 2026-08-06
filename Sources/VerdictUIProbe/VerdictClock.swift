// VerdictUIProbe — SwiftUI instrumentation runtime.
//
// Wave 3 Task 1: a controllable clock and the animation-control policy the
// settle engine wraps around injected state changes. Scenarios that schedule
// work with `Task.sleep(for:clock:)` or `clock.sleep(until:)` become
// deterministic under the harness; animations are controlled by
// ``SettlePolicy`` + `Transaction`, not by the unwritable
// `accessibilityReduceMotion` environment key (see
// ``SwiftUI/View/verdictPinnedEnvironment()``).
import AppKit
import Foundation
import SwiftUI

// MARK: - Settle policy

/// How the harness treats animations when it injects a state change.
///
/// Wave 3's default is ``skipAnimations``: injected mutations land as final
/// geometry in one transaction, so settle does not wait on a display-link
/// curve. ``runAnimations`` is the opt-in for scenarios that exist to prove
/// animation-correctness — those still flush Core Animation and pump the run
/// loop so in-flight presentations can tick.
public enum SettlePolicy: Equatable, Sendable {
    /// Wrap the mutation in `Transaction(animation: nil)` so SwiftUI applies
    /// the end state without an interpolating animation.
    case skipAnimations
    /// Allow the mutation's animations to run; flush `CATransaction` and pump
    /// the main run loop so presentation can advance.
    case runAnimations
}

// MARK: - Virtual clock

/// A manually advanced ``Clock`` for instrumented scenario code.
///
/// Wall time never moves this clock — only ``advance(by:)`` does. Suspensions
/// created by ``sleep(until:tolerance:)`` resume when `now` reaches their
/// deadline, so a debounce or delayed `Task` under test can be driven without
/// real sleeps (and without the hang that a forgotten wall-clock wait would
/// cause in CI).
///
/// ### Concurrency
///
/// `Clock` requires `Sendable`. Sleep waiters may resume on whatever executor
/// the suspension used, while ``OracleHost`` advances from the main actor, so
/// the mutable frontier is guarded by a lock rather than by actor isolation.
public final class VerdictClock: Clock, @unchecked Sendable {
    public struct Instant: InstantProtocol {
        fileprivate let offset: Duration

        public func advanced(by duration: Duration) -> Instant {
            Instant(offset: offset + duration)
        }

        public func duration(to other: Instant) -> Duration {
            other.offset - offset
        }

        public static func < (lhs: Instant, rhs: Instant) -> Bool {
            lhs.offset < rhs.offset
        }
    }

    public typealias Duration = Swift.Duration

    private struct Waiter {
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    /// Locking lives only in synchronous helpers — `NSLock` is unavailable
    /// from `async` under complete strict concurrency (Swift 6 mode error).
    private let lock = NSLock()
    private var _now = Instant(offset: .zero)
    private var waiters: [UUID: Waiter] = [:]

    /// Sleeps whose cancellation arrived before their continuation registered.
    ///
    /// `withTaskCancellationHandler` runs `onCancel` immediately on the
    /// cancelling thread when the task is already cancelled — it does *not*
    /// wait for the operation body to suspend. So a `cancel()` landing in the
    /// window between ``sleep(until:tolerance:)``'s `Task.checkCancellation()`
    /// and the continuation body's insert would find `waiters[id]` empty,
    /// resume nothing, and never fire again — leaving the sleep suspended for
    /// a virtual deadline no one will advance to. Recording the id here under
    /// the same lock that guards `waiters` closes that window: whichever side
    /// runs second sees the other's mark and resumes the continuation exactly
    /// once. Measured, not theorised — the losing interleaving hung the whole
    /// XCTest process (main thread parked in `invokeWithAsynchronousWait`,
    /// every concurrency worker idle) in roughly one run in three.
    private var cancelledBeforeRegistration: Set<UUID> = []

    public init() {}

    public var now: Instant {
        withLock { $0 }
    }

    /// How many `sleep(until:)` waiters are still suspended.
    ///
    /// The quiescence detector (Wave 3 Task 2) refuses to report settled while
    /// this is non-zero: a pending virtual-clock timer means work the scenario
    /// has already scheduled has not run yet, and calling that quiet would lie.
    public var pendingWaiterCount: Int {
        withLock { _ in waiters.count }
    }

    public var minimumResolution: Duration { .nanoseconds(1) }

    /// Move the virtual frontier forward and resume every waiter whose
    /// deadline is now in the past (or exactly `now`).
    public func advance(by duration: Duration) {
        let toResume: [CheckedContinuation<Void, any Error>] = withLock { now in
            now = now.advanced(by: duration)
            let frontier = now
            var remaining: [UUID: Waiter] = [:]
            var ready: [CheckedContinuation<Void, any Error>] = []
            for (id, waiter) in waiters {
                if waiter.deadline <= frontier {
                    ready.append(waiter.continuation)
                } else {
                    remaining[id] = waiter
                }
            }
            waiters = remaining
            return ready
        }
        for continuation in toResume {
            continuation.resume()
        }
    }

    public func sleep(
        until deadline: Instant,
        tolerance: Duration? = nil
    ) async throws {
        // Tolerance is accepted for Clock conformance; a virtual clock has no
        // scheduler slack to exploit, so it is ignored on purpose.
        _ = tolerance
        try Task.checkCancellation()
        if deadline <= now { return }

        let id = UUID()
        // What the continuation body decided to do, resolved under the lock so
        // it can never disagree with a concurrent `onCancel`.
        enum Registration {
            case resumeNow
            case throwCancelled
            case suspended
        }
        // A cancellation arriving after this sleep finished (resumed by
        // `advance`, or already-past) leaves a mark no continuation body will
        // ever consume. Harmless per-sleep, unbounded across a long session, so
        // every exit from this scope clears its own id.
        defer { withLock { _ in _ = cancelledBeforeRegistration.remove(id) } }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                // Continuation bodies are synchronous — safe to lock here.
                let registration = withLock { now -> Registration in
                    // Cancellation that beat us to the lock: consume the mark
                    // and fail here, rather than registering a waiter nothing
                    // will ever resume.
                    if cancelledBeforeRegistration.remove(id) != nil {
                        return .throwCancelled
                    }
                    if deadline <= now { return .resumeNow }
                    waiters[id] = Waiter(deadline: deadline, continuation: continuation)
                    return .suspended
                }
                switch registration {
                case .resumeNow:
                    continuation.resume()
                case .throwCancelled:
                    continuation.resume(throwing: CancellationError())
                case .suspended:
                    break
                }
            }
        } onCancel: {
            let cancelled = withLock { _ -> CheckedContinuation<Void, any Error>? in
                guard let waiter = waiters.removeValue(forKey: id) else {
                    // The continuation has not registered yet. Leave a mark the
                    // body will find; it resumes itself with the error.
                    cancelledBeforeRegistration.insert(id)
                    return nil
                }
                return waiter.continuation
            }
            cancelled?.resume(throwing: CancellationError())
        }
    }

    private func withLock<T>(_ body: (inout Instant) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&_now)
    }
}

// MARK: - Environment

private struct VerdictClockKey: EnvironmentKey {
    static let defaultValue: VerdictClock? = nil
}

extension EnvironmentValues {
    /// The harness-owned virtual clock, or `nil` when no ``OracleHost`` (or
    /// equivalent) has installed one. Scenario code that needs controllable
    /// time should take a `Clock` parameter or read this key; uninstrumented
    /// wall-clock sleeps remain what the settle timeout is for.
    public var verdictClock: VerdictClock? {
        get { self[VerdictClockKey.self] }
        set { self[VerdictClockKey.self] = newValue }
    }
}

// MARK: - Animation control

/// Applies a state mutation under the active ``SettlePolicy``.
///
/// Factored out of ``OracleHost`` so Task 4's harness and tests can share one
/// transaction/flush path without inventing `Harness.swift` yet.
@MainActor
public enum AnimationControl {
    /// How many run-loop slices ``runAnimations`` pumps after
    /// `CATransaction.flush`, using ``LayoutSettle/pumpInterval``.
    public nonisolated static let displayLinkPumpIterations = 2

    /// Run `body` under `policy`. Returns the number of `CATransaction.flush`
    /// calls performed (0 for ``SettlePolicy/skipAnimations``, 1 for
    /// ``SettlePolicy/runAnimations``) so tests can pin the flush path without
    /// swizzling Core Animation.
    @discardableResult
    public static func apply(
        _ policy: SettlePolicy,
        _ body: () -> Void
    ) -> Int {
        switch policy {
        case .skipAnimations:
            withTransaction(Transaction(animation: nil), body)
            return 0
        case .runAnimations:
            withTransaction(Transaction(), body)
            CATransaction.flush()
            for _ in 0..<displayLinkPumpIterations {
                RunLoop.current.run(
                    until: Date().addingTimeInterval(LayoutSettle.pumpInterval)
                )
            }
            return 1
        }
    }
}
