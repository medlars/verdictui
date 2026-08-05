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

    public init() {}

    public var now: Instant {
        withLock { $0 }
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
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                // Continuation bodies are synchronous — safe to lock here.
                let alreadyPast = withLock { now -> Bool in
                    if deadline <= now { return true }
                    waiters[id] = Waiter(deadline: deadline, continuation: continuation)
                    return false
                }
                if alreadyPast {
                    continuation.resume()
                }
            }
        } onCancel: {
            let cancelled = withLock { _ -> CheckedContinuation<Void, any Error>? in
                waiters.removeValue(forKey: id)?.continuation
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
