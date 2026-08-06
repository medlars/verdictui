import Combine
import SwiftUI
import VerdictUIKernel
import XCTest

@testable import VerdictUIProbe

/// Wave 3 Task 5: the settle engine's own verification.
///
/// Every test here is written to make settle LIE if it can — report quiet while
/// something is still moving, or report motion where there is none. A settle
/// engine that only ever sees cooperative scenarios has not been tested; the
/// plan's SD2 requirement is "never hang, never lie", and both halves need a
/// hostile witness.
///
/// The four scenarios are the plan's, in order: infinite animation, delayed
/// async mutation, debounced input, and rapid successive actions.
final class HostileSettleTests: XCTestCase {
    override func invokeTest() {
        autoreleasepool { super.invokeTest() }
    }

    // MARK: - 1. Infinite animation must time out, naming what moved

    /// A `repeatForever` animation never reaches a fixed point, so settle must
    /// hit its deadline and FAIL rather than either hanging or declaring quiet.
    @MainActor
    func testInfiniteAnimationTimesOutWithAFailVerdict() async throws {
        let model = PerpetualMotionModel()
        let host = OracleHost(
            scenario: PerpetualMotionScenario(model: model),
            viewport: Size(width: 200, height: 60)
        )
        _ = try await host.currentTree()

        // Drive the mutation from the main RunLoop: LayoutSettle pumps
        // synchronously, so a concurrent Task frequently never interleaves and
        // the settle would report a false quiet (SettleTests learned this the
        // same way).
        let timer = Timer(timeInterval: 0.004, repeats: true) { _ in
            model.phase += 1
        }
        RunLoop.main.add(timer, forMode: .common)
        defer { timer.invalidate() }

        let started = ContinuousClock.now
        let result = await host.settle(timeout: .milliseconds(200))
        let elapsed = started.duration(to: .now)

        guard case .timedOut = result else {
            XCTFail("a perpetual animation must time out, got \(result)")
            return
        }

        // "Never hang" is a real requirement, not a figure of speech: the call
        // must return on roughly its own deadline, not whenever motion stops.
        XCTAssertLessThan(
            elapsed, .seconds(2),
            "settle overran its 200 ms budget by more than 10x — that is a hang"
        )

        let verdict = try XCTUnwrap(host.timeoutVerdict(from: result, settleMs: 200))
        XCTAssertEqual(verdict.status, .fail)
        XCTAssertEqual(verdict.findings.first?.rule, Quiescence.timeoutRule)
    }

    /// The control for the test above. Same host shape, same probe, no motion —
    /// it must settle. Without this, "times out" could equally mean the settle
    /// engine times out on everything.
    @MainActor
    func testTheSameShapeSettlesWhenNothingIsAnimating() async throws {
        let model = PerpetualMotionModel()
        let host = OracleHost(
            scenario: PerpetualMotionScenario(model: model),
            viewport: Size(width: 200, height: 60)
        )
        _ = try await host.currentTree()

        let result = await host.settle(timeout: .seconds(2))

        guard case .settled = result else {
            XCTFail("an idle scenario must settle, got \(result)")
            return
        }
        XCTAssertNil(
            host.timeoutVerdict(from: result, settleMs: 0),
            "a settled result must not produce a timeout verdict"
        )
    }

    // MARK: - 2. Delayed async mutation must not be mistaken for quiet

    /// A `Task` that sleeps on the virtual clock and then mutates state is the
    /// classic false-quiescence trap: the main queue is empty and the tree is
    /// stable, so every naive signal says "quiet" while a mutation is pending.
    ///
    /// The virtual-clock waiter census is what closes it — settle must refuse
    /// to call this quiet until the clock is advanced and the mutation lands.
    @MainActor
    func testDelayedMutationBlocksQuietUntilTheClockAdvances() async throws {
        let clock = VerdictClock()
        let model = DeferredLabelModel()
        let host = OracleHost(
            scenario: DeferredLabelScenario(model: model),
            viewport: Size(width: 200, height: 60),
            clock: clock
        )
        let before = try await host.currentTree()
        XCTAssertNotNil(before.node(withID: "label"))

        // Detached: registration must not queue behind this MainActor body.
        let pending = Task.detached {
            try await clock.sleep(for: .seconds(5))
            await MainActor.run { model.caption = "arrived" }
        }
        let deadline = Date().addingTimeInterval(1)
        while clock.pendingWaiterCount == 0, Date() < deadline {
            await Task.yield()
        }
        XCTAssertEqual(
            clock.pendingWaiterCount, 1,
            "the sleeper must be registered before we assert on quiet"
        )

        // The trap: nothing is moving, but a mutation is scheduled.
        let premature = await host.settle(timeout: .milliseconds(150))
        guard case .timedOut = premature else {
            pending.cancel()
            XCTFail(
                "settle must not report quiet while a virtual-clock timer is pending — "
                    + "got \(premature)"
            )
            return
        }

        // Release it: the mutation lands, and only now may settle report quiet.
        clock.advance(by: .seconds(5))
        try await pending.value
        XCTAssertEqual(clock.pendingWaiterCount, 0)

        let settled = await host.settle(timeout: .seconds(2))
        guard case .settled = settled else {
            XCTFail("settle must succeed once the timer has fired, got \(settled)")
            return
        }

        let after = try await host.currentTree()
        XCTAssertNotEqual(
            after, before,
            "the deferred mutation must be visible in the post-settle tree"
        )
    }

    // MARK: - 3. Debounced input must be observed settled, not mid-flight

    /// A debounced field publishes its committed value only after a quiet
    /// interval. `setText` + settle must surface the POST-debounce tree — if it
    /// returned the intermediate, an agent would assert against a value the app
    /// was about to discard.
    @MainActor
    func testDebouncedFieldSettlesOnTheCommittedValueNotTheIntermediate() async throws {
        let clock = VerdictClock()
        let model = DebouncedFieldModel(clock: clock)
        let harness = Harness(
            scenario: DebouncedFieldScenario(model: model),
            viewport: Size(width: 240, height: 80),
            clock: clock
        )
        _ = try await harness.host.currentTree()

        // `.custom` rather than `.setText`: the typed case writes ScenarioState's
        // storage directly, so an app-side debounce could only start on the next
        // render — and no render has happened yet at the point this test needs
        // the timer to exist. `.custom` is the documented escape hatch for a
        // scenario-specific mutation, and it runs synchronously.
        try harness.host.apply(
            .custom("query-field") { state in
                state.stringBinding("query-field", default: "").wrappedValue = "hello"
                model.type("hello")
            }
        )
        XCTAssertEqual(model.raw, "hello")
        XCTAssertEqual(
            model.committed, "",
            "the debounce has not elapsed — committed must still be empty"
        )

        // The debounce Task registers its clock waiter asynchronously, so wait
        // for the registration before asserting on quiet — otherwise this test
        // races the scheduler and a pass would mean "we sampled too early",
        // not "settle handled a pending timer".
        let registered = Date().addingTimeInterval(1)
        while clock.pendingWaiterCount == 0, Date() < registered {
            await Task.yield()
        }
        XCTAssertEqual(
            clock.pendingWaiterCount, 1,
            "the debounce timer must be registered before we assert on quiet"
        )

        // Settle must refuse to call this quiet: a debounce timer is pending.
        let midFlight = await harness.host.settle(timeout: .milliseconds(150))
        guard case .timedOut = midFlight else {
            XCTFail(
                "settle must not report quiet mid-debounce — an agent would read "
                    + "a value the app is about to replace; got \(midFlight)"
            )
            return
        }

        // Advance past the debounce window; now the commit lands.
        clock.advance(by: .milliseconds(300))
        let deadline = Date().addingTimeInterval(1)
        while model.committed.isEmpty, Date() < deadline {
            await Task.yield()
        }
        XCTAssertEqual(model.committed, "hello")

        let settled = await harness.host.settle(timeout: .seconds(2))
        guard case .settled = settled else {
            XCTFail("settle must succeed after the debounce fires, got \(settled)")
            return
        }

        let tree = try await harness.host.currentTree()
        let label = try XCTUnwrap(tree.node(withID: "committed-label"))
        XCTAssertEqual(
            label.text, "hello",
            "the settled tree must show the committed value, not the intermediate"
        )
    }

    // MARK: - 4. Rapid successive actions must produce clean, ordered deltas

    /// Two taps in immediate succession must come back as two atomic steps with
    /// two independent deltas. Interleaving would show up as a step whose before
    /// is not the previous step's after — the seam an agent uses to reason about
    /// causality.
    @MainActor
    func testRapidDoubleTapProducesTwoCleanNonInterleavedSteps() async throws {
        let model = CounterModel()
        let harness = Harness(
            scenario: CounterScenario(model: model),
            viewport: Size(width: 200, height: 60)
        )

        let result = await harness.run([.tap("increment"), .tap("increment")])

        XCTAssertEqual(result.steps.count, 2)
        XCTAssertEqual(result.status, .pass)
        XCTAssertEqual(model.count, 2, "both taps must have landed exactly once")

        // Causality: step 2 starts exactly where step 1 finished.
        XCTAssertEqual(
            result.steps[1].before, result.steps[0].after,
            "steps interleaved — step 2's before is not step 1's after"
        )

        // Each step reports its own change, not the sum of both.
        for (index, step) in result.steps.enumerated() {
            guard case .settled = step.settle else {
                XCTFail("step \(index) failed to settle: \(step.settle)")
                continue
            }
            XCTAssertFalse(
                step.delta.isEmpty,
                "step \(index) incremented the counter but reported no delta"
            )
        }

        let final = try XCTUnwrap(result.steps[1].after)
        let label = try XCTUnwrap(final.node(withID: "count-label"))
        XCTAssertEqual(label.text, "2")
    }

    /// The counter must move exactly once per step — a settle that returned
    /// before the state change was applied would let two taps land as one, and
    /// the count is the only thing that can prove otherwise.
    @MainActor
    func testEachStepAdvancesTheCounterExactlyOnce() async throws {
        let model = CounterModel()
        let harness = Harness(
            scenario: CounterScenario(model: model),
            viewport: Size(width: 200, height: 60)
        )

        for expected in 1...3 {
            let step = await harness.perform(.tap("increment"))
            XCTAssertEqual(step.status, .pass)
            XCTAssertEqual(
                model.count, expected,
                "after \(expected) step(s) the counter must read \(expected)"
            )
            let tree = try XCTUnwrap(step.after)
            let label = try XCTUnwrap(tree.node(withID: "count-label"))
            XCTAssertEqual(
                label.text, "\(expected)",
                "the settled tree must agree with the model"
            )
        }
    }

    // MARK: - Never hang: deadline coverage

    /// Every hostile path above must return within a bounded multiple of its own
    /// timeout. This is the plan's "settle never hangs" gate stated as an
    /// assertion rather than as a property of the suite's wall-clock.
    @MainActor
    func testTimedOutSettleRespectsItsDeadlineBudget() async throws {
        let model = PerpetualMotionModel()
        let host = OracleHost(
            scenario: PerpetualMotionScenario(model: model),
            viewport: Size(width: 200, height: 60)
        )
        _ = try await host.currentTree()

        let timer = Timer(timeInterval: 0.002, repeats: true) { _ in
            model.phase += 1
        }
        RunLoop.main.add(timer, forMode: .common)
        defer { timer.invalidate() }

        for budget in [Duration.milliseconds(80), .milliseconds(160)] {
            let started = ContinuousClock.now
            let result = await host.settle(timeout: budget)
            let elapsed = started.duration(to: .now)

            guard case .timedOut = result else {
                XCTFail("still-moving layout must time out at \(budget), got \(result)")
                return
            }
            XCTAssertLessThan(
                elapsed, budget * 10,
                "settle(\(budget)) took \(elapsed) — deadline is not being honoured"
            )
        }
    }
}

// MARK: - Fixtures

/// Drives a frame change on every tick — the animation stand-in. A real
/// `repeatForever` animation is not used because the oracle host pins
/// `Transaction(animation: nil)` by policy; what matters to settle is that the
/// geometry never reaches a fixed point, which this reproduces deterministically.
final class PerpetualMotionModel: ObservableObject, @unchecked Sendable {
    @Published var phase = 0
}

struct PerpetualMotionScenario: VerdictScenario {
    let model: PerpetualMotionModel
    var name: String { "wave3-perpetual-motion" }

    @MainActor
    func body(state: ScenarioState) -> some View {
        PerpetualMotionView(model: model)
    }
}

private struct PerpetualMotionView: View {
    @ObservedObject var model: PerpetualMotionModel

    var body: some View {
        Color.orange
            .frame(width: 20 + Double(model.phase % 7) * 6, height: 12)
            .verdictProbe("mover", role: .image)
    }
}

/// State a deferred `Task` mutates after sleeping on the virtual clock.
final class DeferredLabelModel: ObservableObject, @unchecked Sendable {
    @Published var caption = "initial"
}

struct DeferredLabelScenario: VerdictScenario {
    let model: DeferredLabelModel
    var name: String { "wave3-deferred-label" }

    @MainActor
    func body(state: ScenarioState) -> some View {
        DeferredLabelView(model: model)
    }
}

private struct DeferredLabelView: View {
    @ObservedObject var model: DeferredLabelModel

    var body: some View {
        Text(model.caption)
            .verdictProbe("label", role: .text)
    }
}

/// A field whose committed value trails its raw value by a debounce interval,
/// measured on the injected ``VerdictClock`` so the test controls time.
@MainActor
final class DebouncedFieldModel: ObservableObject {
    @Published private(set) var raw = ""
    @Published var committed = ""

    /// Called by the view when the stored field value changes.
    func type(_ value: String) {
        raw = value
        scheduleCommit()
    }

    /// Debounce window — matches the plan's 0.3 s example.
    static let window: Duration = .milliseconds(300)

    private let clock: VerdictClock
    private var pending: Task<Void, Never>?

    init(clock: VerdictClock) {
        self.clock = clock
    }

    private func scheduleCommit() {
        pending?.cancel()
        let value = raw
        pending = Task { [clock] in
            try? await clock.sleep(for: Self.window)
            guard !Task.isCancelled else { return }
            self.committed = value
        }
    }
}

struct DebouncedFieldScenario: VerdictScenario {
    let model: DebouncedFieldModel
    var name: String { "wave3-debounced-field" }

    @MainActor
    func body(state: ScenarioState) -> some View {
        DebouncedFieldView(model: model, state: state)
    }
}

private struct DebouncedFieldView: View {
    @ObservedObject var model: DebouncedFieldModel
    let state: ScenarioState

    var body: some View {
        // `performSetText` writes ScenarioState's own storage directly, so a
        // wrapper Binding's `set:` never runs for an injected action. The
        // debounce therefore has to key off the STORED value as the view sees
        // it, which is what `onChange` observes.
        let stored = state.stringBinding("query-field", default: "")
        VStack {
            TextField("Query", text: stored)
                .verdictProbe("query-field", role: .textField, action: .text(stored))
            Text(model.committed)
                .verdictProbe("committed-label", role: .text, text: model.committed)
        }
    }
}

/// Counter for the rapid-action scenario — the only thing that can prove two
/// taps landed as two rather than as one.
@MainActor
final class CounterModel: ObservableObject {
    @Published var count = 0
}

struct CounterScenario: VerdictScenario {
    let model: CounterModel
    var name: String { "wave3-counter" }

    @MainActor
    func body(state: ScenarioState) -> some View {
        CounterView(model: model, state: state)
    }
}

private struct CounterView: View {
    @ObservedObject var model: CounterModel
    let state: ScenarioState

    var body: some View {
        VStack {
            Text("\(model.count)")
                .verdictProbe("count-label", role: .text, text: "\(model.count)")
            // Sized past the 28x28 tap-target minimum on purpose: a default
            // AppKit button renders 85x24 and TapTargetRule would (correctly)
            // FAIL it, early-exiting the flow before the second tap ever ran.
            // The subject here is settle, not tap-target.
            Button("Increment") { model.count += 1 }
                .frame(width: 120, height: 32)
                .verdictProbe(
                    "increment",
                    role: .button,
                    action: .tap { model.count += 1 }
                )
        }
    }
}
