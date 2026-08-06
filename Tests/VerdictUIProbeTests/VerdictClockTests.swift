import AppKit
import Combine
import SwiftUI
import VerdictUIKernel
import XCTest

@testable import VerdictUIProbe

/// Wave 3 Task 1: virtual clock, environment injection, and settle-policy
/// animation control. Hostile settle coverage is Task 5; this file only pins
/// the seams Task 1 owns.
final class VerdictClockTests: XCTestCase {
    override func invokeTest() {
        autoreleasepool { super.invokeTest() }
    }

    // MARK: - Clock

    func testAdvanceMovesNow() {
        let clock = VerdictClock()
        let start = clock.now
        clock.advance(by: .seconds(3))
        XCTAssertEqual(start.duration(to: clock.now), .seconds(3))
    }

    func testSleepReturnsImmediatelyWhenDeadlineIsAlreadyPast() async throws {
        let clock = VerdictClock()
        clock.advance(by: .seconds(5))
        let deadline = clock.now.advanced(by: .seconds(-1))
        try await clock.sleep(until: deadline)
    }

    func testSleepWakesWhenClockAdvancesPastDeadline() async throws {
        let clock = VerdictClock()
        let flag = WakeFlag()
        let task = Task {
            try await clock.sleep(for: .seconds(10))
            await flag.mark()
        }

        // Wait for the waiter to actually register — `Task.yield()` does not do
        // this, and using it here hung the whole suite. `sleep(for:)` computes
        // its deadline as `now + duration` *inside the task body*, so an
        // `advance` that lands first silently moves the target: at `now = 3` the
        // deadline becomes 13, the two advances below total 11, and the waiter
        // is never resumed. `task.value` then suspends forever and XCTest parks
        // the main thread in `invokeWithAsynchronousWait`, wedging the process.
        // Spinning on the observable count is the same synchronisation
        // `SettleTests` uses, and it is a fact rather than a hope.
        let registerDeadline = Date().addingTimeInterval(2)
        while clock.pendingWaiterCount == 0, Date() < registerDeadline {
            await Task.yield()
        }
        XCTAssertEqual(
            clock.pendingWaiterCount,
            1,
            "the sleeper must register before the clock moves, or its deadline shifts"
        )

        clock.advance(by: .seconds(3))
        try await Task.sleep(nanoseconds: 50_000_000)
        let early = await flag.value()
        XCTAssertFalse(early, "sleep must stay suspended before the deadline")

        clock.advance(by: .seconds(8))
        try await task.value
        let late = await flag.value()
        XCTAssertTrue(late)
    }

    func testCancelledSleepThrowsCancellationError() async {
        let clock = VerdictClock()
        let task = Task {
            try await clock.sleep(for: .seconds(60))
        }
        await Task.yield()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected CancellationError")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    /// Regression: a `cancel()` that lands *between* `sleep`'s cancellation
    /// check and its continuation registering used to be lost entirely.
    ///
    /// `withTaskCancellationHandler` runs `onCancel` immediately on the
    /// cancelling thread; it does not wait for the operation to suspend. So in
    /// that window `onCancel` found no waiter to resume, and the body then
    /// registered one that only a 60-second virtual advance could release —
    /// which never came. The sleep stayed suspended, `task.value` never
    /// returned, and XCTest's async wrapper parked the *main thread* in
    /// `invokeWithAsynchronousWait`, hanging the entire test process at 0% CPU
    /// about one run in three.
    ///
    /// Repeating the race is the point: a single attempt lands in the losing
    /// interleaving only sometimes, so one iteration would be a test that
    /// passes while the bug is present. Each iteration is independently bounded
    /// by `withTimeout`, so a regression fails with a named assertion instead
    /// of re-hanging the suite.
    func testCancellationRacingRegistrationIsNeverLost() async throws {
        for attempt in 0..<200 {
            let clock = VerdictClock()
            let task = Task {
                try await clock.sleep(for: .seconds(60))
            }
            // No yield: cancelling immediately is what maximises the chance of
            // landing inside the registration window.
            task.cancel()

            let outcome = try await Self.withTimeout(seconds: 5) {
                await task.result
            }
            switch outcome {
            case .success:
                XCTFail("attempt \(attempt): cancelled sleep must not succeed")
            case .failure(let error):
                XCTAssertTrue(
                    error is CancellationError,
                    "attempt \(attempt): expected CancellationError, got \(error)"
                )
            }
            XCTAssertEqual(
                clock.pendingWaiterCount,
                0,
                "attempt \(attempt): cancelled sleep leaked a waiter"
            )
        }
    }

    /// The deterministic companion to the 200-attempt race above.
    ///
    /// That test wins the losing interleaving by REPETITION, so its detection
    /// power depends on scheduling: measured 5/5 catches in isolation but
    /// UNNOTICED during a full `mutation-check.py` sweep, where every case runs
    /// straight after a cold rebuild under load. A guard whose ability to fail
    /// varies with machine load reports coverage it cannot always deliver — and
    /// the mutation harness scores that as an unverified guard, correctly.
    ///
    /// This drives the same window with no race at all: mark the id cancelled
    /// BEFORE the continuation body runs, which is exactly the state `onCancel`
    /// leaves behind when it wins, then assert the body consumes the mark and
    /// throws instead of registering a waiter nobody will resume.
    func testAPreMarkedCancellationIsConsumedByTheRegisteringBody() async throws {
        let clock = VerdictClock()
        let deadline = clock.now.advanced(by: .seconds(60))

        // Stand in for `onCancel` having already run: the mark is present, no
        // waiter is registered, and the body is about to run.
        let id = UUID()
        clock.markCancelledBeforeRegistration(id)

        // Bounded, because the defect under test is a PERMANENTLY suspended
        // continuation: with the mark never consumed, `registerSleep` suspends
        // on a 60-second virtual deadline nobody will advance to, and an
        // unbounded await would hang the whole xctest process rather than fail.
        // Measured: without this the mutated build times out at 450s instead of
        // failing in milliseconds, and a hang is a strictly worse signal than a
        // failure — the harness cannot tell it from a broken build.
        // `withTimeout` takes a non-throwing body, so the throw is captured as
        // a Result — the same shape the 200-attempt test above uses.
        let outcome = try await Self.withTimeout(seconds: 5) {
            await Task { try await clock.registerSleep(id: id, until: deadline) }.result
        }
        switch outcome {
        case .success:
            XCTFail("a pre-marked cancellation must not register a waiter")
        case .failure(let error):
            XCTAssertTrue(
                error is CancellationError,
                "expected CancellationError from the consumed mark, got \(error)"
            )
        }

        XCTAssertEqual(
            clock.pendingWaiterCount, 0,
            "the body registered a waiter despite a pending cancellation mark"
        )
        XCTAssertFalse(
            clock.hasCancellationMark(id),
            "the mark must be consumed, not left to accumulate"
        )
    }

    /// Awaits `work`, throwing ``TimeoutError`` rather than hanging if it does
    /// not finish in `seconds`.
    ///
    /// A task group is deliberately *not* used: the failure mode under test is
    /// a permanently suspended continuation, and a group waits for every child
    /// at scope exit. Cancelling the child that awaits the stuck task does not
    /// resume the leaked continuation, so the group itself would hang — the
    /// timeout helper would reproduce the very defect it exists to bound.
    ///
    /// An unstructured `Task` plus a continuation resumed by whichever side
    /// finishes first has no such join: when the timeout wins, the observer
    /// task is abandoned (it is cancelled, and the process exits at suite end)
    /// and the test reports a named failure instead of wedging XCTest.
    private static func withTimeout<T: Sendable>(
        seconds: Double,
        _ work: @escaping @Sendable () async -> T
    ) async throws -> T {
        let state = TimeoutState<T>()
        let observer = Task { @Sendable in
            let value = await work()
            state.finish(.success(value))
        }
        let timer = Task { @Sendable in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            state.finish(.failure(TimeoutError()))
        }
        defer {
            observer.cancel()
            timer.cancel()
        }
        return try await withCheckedThrowingContinuation { continuation in
            state.attach(continuation)
        }
    }

    /// Resolves a ``withTimeout(seconds:_:)`` continuation exactly once,
    /// whichever of the two racing tasks reports first.
    private final class TimeoutState<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, any Error>?
        private var result: Result<T, any Error>?
        private var isResolved = false

        func attach(_ continuation: CheckedContinuation<T, any Error>) {
            let pending: Result<T, any Error>? = lock.withLock {
                guard let result, !isResolved else {
                    self.continuation = continuation
                    return nil
                }
                isResolved = true
                return result
            }
            if let pending { continuation.resume(with: pending) }
        }

        func finish(_ value: Result<T, any Error>) {
            let waiting: CheckedContinuation<T, any Error>? = lock.withLock {
                guard !isResolved else { return nil }
                guard let continuation else {
                    // Raced ahead of `attach`; leave the result for it.
                    if result == nil { result = value }
                    return nil
                }
                isResolved = true
                self.continuation = nil
                return continuation
            }
            waiting?.resume(with: value)
        }
    }

    private struct TimeoutError: Error {}

    // MARK: - Environment + host seams

    @MainActor
    func testHostInstallsItsClockIntoTheEnvironment() async throws {
        let box = ClockBox()
        let host = OracleHost(
            scenario: ClockIdentityScenario(box: box),
            viewport: Size(width: 40, height: 20)
        )
        _ = try await host.currentTree()
        XCTAssertTrue(
            box.clock === host.clock,
            "hosted body must see the host-owned VerdictClock instance"
        )
    }

    @MainActor
    func testDefaultSettlePolicyIsSkipAnimations() {
        let host = OracleHost(
            scenario: ExpandBoxScenario(),
            viewport: Size(width: 120, height: 40)
        )
        XCTAssertEqual(host.settlePolicy, .skipAnimations)
    }

    @MainActor
    func testSkipAnimationsStateChangeLandsAtFinalGeometry() async throws {
        let model = ExpandBoxModel()
        let host = OracleHost(
            scenario: ExpandBoxScenario(model: model),
            viewport: Size(width: 120, height: 40),
            settlePolicy: .skipAnimations
        )
        let before = try await host.currentTree()
        XCTAssertEqual(Self.boxWidth(in: before), ExpandBoxScenario.collapsedWidth)

        host.applyStateChange { model.expanded = true }
        let after = try await host.currentTree()
        XCTAssertEqual(Self.boxWidth(in: after), ExpandBoxScenario.expandedWidth)
        XCTAssertEqual(
            host.caTransactionFlushCount,
            0,
            "skipAnimations must not flush CATransaction"
        )
    }

    @MainActor
    func testRunAnimationsPathFlushesCATransaction() async throws {
        let model = ExpandBoxModel()
        let host = OracleHost(
            scenario: ExpandBoxScenario(model: model),
            viewport: Size(width: 120, height: 40),
            settlePolicy: .runAnimations
        )
        _ = try await host.currentTree()
        XCTAssertEqual(host.caTransactionFlushCount, 0)

        host.applyStateChange { model.expanded = true }
        XCTAssertEqual(
            host.caTransactionFlushCount,
            1,
            "runAnimations must call CATransaction.flush exactly once per change"
        )
        let after = try await host.currentTree()
        XCTAssertEqual(Self.boxWidth(in: after), ExpandBoxScenario.expandedWidth)
    }

    @MainActor
    func testAnimationControlHelperMatchesHostCounters() {
        var flips = 0
        let skipped = AnimationControl.apply(.skipAnimations) { flips += 1 }
        XCTAssertEqual(skipped, 0)
        let flushed = AnimationControl.apply(.runAnimations) { flips += 1 }
        XCTAssertEqual(flushed, 1)
        XCTAssertEqual(flips, 2)
    }

    // MARK: - Helpers

    private static func boxWidth(in tree: SemanticNode) -> Double {
        guard let box = tree.children.first(where: { $0.id == "box" }) else {
            XCTFail("missing box probe")
            return .nan
        }
        return box.frame.width
    }
}

// MARK: - Fixtures

private actor WakeFlag {
    private var isSet = false
    func mark() { isSet = true }
    func value() -> Bool { isSet }
}

/// Shared box so a value-typed scenario can report the environment clock.
final class ClockBox: @unchecked Sendable {
    var clock: VerdictClock?
}

final class ExpandBoxModel: ObservableObject, @unchecked Sendable {
    @Published var expanded = false
}

struct ExpandBoxScenario: VerdictScenario {
    static let collapsedWidth = 10.0
    static let expandedWidth = 100.0

    let model: ExpandBoxModel

    init(model: ExpandBoxModel = ExpandBoxModel()) {
        self.model = model
    }

    var name: String { "wave3-expand-box" }

    @MainActor
    func body(state: ScenarioState) -> some View {
        // Nested view so `@ObservedObject` invalidates the hosted tree when the
        // model flips — a bare read of `model.expanded` in this method would not.
        ExpandBoxView(model: model)
    }
}

private struct ExpandBoxView: View {
    @ObservedObject var model: ExpandBoxModel

    var body: some View {
        // `animation` on the frame is what `.skipAnimations` must defeat: without
        // `Transaction(animation: nil)`, a one-second linear would leave
        // intermediate widths. The box itself is a fixed-size color so the
        // asserted widths are arithmetic, not font metrics.
        Color.red
            .frame(
                width: model.expanded
                    ? ExpandBoxScenario.expandedWidth
                    : ExpandBoxScenario.collapsedWidth,
                height: 10
            )
            .animation(.linear(duration: 1.0), value: model.expanded)
            .verdictProbe("box", role: .image)
    }
}

/// Captures the ``EnvironmentValues/verdictClock`` identity the hosted body sees.
struct ClockIdentityScenario: VerdictScenario {
    let box: ClockBox

    var name: String { "wave3-clock-identity" }

    @MainActor
    func body(state: ScenarioState) -> some View {
        ClockIdentityProbe { clock in
            box.clock = clock
        }
        .frame(width: 20, height: 10)
        .verdictProbe("probe", role: .image)
    }
}

private struct ClockIdentityProbe: View {
    @Environment(\.verdictClock) private var clock
    let onClock: (VerdictClock?) -> Void

    var body: some View {
        Color.clear
            .onAppear { onClock(clock) }
            .background(
                Color.clear.preference(key: EmptyPreferenceKey.self, value: clock != nil)
            )
            .onPreferenceChange(EmptyPreferenceKey.self) { _ in onClock(clock) }
    }
}

private struct EmptyPreferenceKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}
