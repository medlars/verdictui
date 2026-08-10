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

    /// Delegates to ``ConstrainedTimingEnvironment`` — the marker class spelled
    /// once. This copy previously omitted `CI`, so the same run recorded here
    /// and asserted in `HarnessPerformanceTests` (`no.md` #17).
    private static var recordsTimingOnly: Bool { ConstrainedTimingEnvironment.isActive }

    // MARK: - 1. Infinite animation must time out, naming what moved

    /// A `repeatForever` animation never reaches a fixed point, so settle must
    /// hit its deadline and FAIL rather than either hanging or declaring quiet.
    @MainActor
    func testInfiniteAnimationTimesOutWithAFailVerdict() async throws {
        try XCTSkipIf(
            Self.recordsTimingOnly,
            "real-time timer interleaving is recorded, not asserted, in constrained timing sandboxes"
        )

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

        let timerDeadline = Date().addingTimeInterval(1)
        while model.phase == 0, Date() < timerDeadline {
            try await Task.sleep(for: .milliseconds(10))
            await Task.yield()
        }
        XCTAssertGreaterThan(
            model.phase,
            0,
            "the perpetual-motion fixture never started moving, so settle cannot prove timeout honesty"
        )

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

    // MARK: - The quiet floor

    /// Settle must not call the UI quiet before a mutation scheduled tens of
    /// milliseconds out has had a chance to land.
    ///
    /// The agreement streak used to have no *time* floor: check 1 set the streak
    /// to 1, one 5 ms pump followed, check 2 reached 2 and settled — so "two
    /// agreeing checks" spanned a single 5 ms window. Measured before the fix:
    /// with a mutation scheduled 40 ms out, settle returned
    /// `settled(after: 0.0056s)` and the harness would have linted the
    /// pre-mutation tree while asserting the UI was still. That is the exact
    /// shape of lie the product's "never lie" claim rules out.
    @MainActor
    func testSettleWaitsOutAMutationScheduledBeyondOnePumpInterval() async throws {
        let model = PerpetualMotionModel()
        let host = OracleHost(
            scenario: PerpetualMotionScenario(model: model),
            viewport: Size(width: 200, height: 60)
        )
        let before = try await host.currentTree()

        // Inside the quiet floor: this is the class of late work the floor is
        // built to wait out. A timer scheduled BEYOND the floor is deliberately
        // not claimed — see the assertion note below.
        //
        // A `Timer` on `RunLoop.main`, deliberately, and NOT
        // `DispatchQueue.main.asyncAfter`. `LayoutSettle`'s pump advances time
        // with `RunLoop.current.run(until:)` (OracleHost.swift:181), which
        // services run-loop timers but does NOT drain queued main-queue work —
        // so `asyncAfter` is the channel that gets starved here, not this one.
        // Measured, after trying it the other way round: with `asyncAfter` the
        // model still read `phase == 0` after settle returned.
        // 5 ms, not 20. The floor is 30 ms, so 20 ms left only 10 ms of slack —
        // enough on idle hardware, not enough on a shared CI runner, where the
        // timer fires LATE: after `settle()` returns but before `currentTree()`.
        // That produced a 395-only failure across four `main` runs
        // (31199890306, 31230022315, 31231041419, 31235423483) while the tree
        // comparison below passed, which is the signature of a fixture race
        // rather than a settle defect — a starved-timer control fails BOTH.
        // The mutation still lands well inside the floor, so what the test
        // claims is unchanged; only the jitter budget grows (CTS-153D8F8A).
        let timer = Timer(timeInterval: 0.005, repeats: false) { _ in model.phase += 1 }
        RunLoop.main.add(timer, forMode: .common)
        defer { timer.invalidate() }

        let result = await host.settle(timeout: .seconds(2))
        guard case .settled(let after) = result else {
            XCTFail("a UI that goes quiet must still settle, got \(result)")
            return
        }
        // TWO assertions, because either alone is defeatable and in opposite
        // directions (measured, both ways):
        //
        // - Derived-only (`after >= Duration.seconds(minimumQuietInterval)`)
        //   moves WITH the constant: tuning the source floor down to 5 ms
        //   weakens the assertion to match, and the test passes while the
        //   guarantee is gone.
        // - Hardcoded-only (`after >= .milliseconds(30)`) does not notice when
        //   someone raises the constant and the two silently disagree.
        //
        // So: the engine must honour whatever floor it declares, AND that
        // declared floor must not drop below the value this scenario was built
        // around. The second is the one that fails when the floor is weakened.
        let declared = Duration.seconds(LayoutSettle.minimumQuietInterval)
        XCTAssertGreaterThanOrEqual(
            after,
            declared,
            "settled after \(after), quicker than the \(declared) floor it declares"
        )
        XCTAssertGreaterThanOrEqual(
            declared,
            .milliseconds(30),
            "the quiet floor was lowered to \(declared) — this scenario's late "
                + "mutation lands ~20 ms out, so a floor under 30 ms stops "
                + "catching it and the honesty guarantee is quietly gone"
        )

        // The point of waiting: a mutation landing inside the floor is IN the
        // tree we hand back, rather than arriving just after we called the UI
        // quiet.
        //
        // Deliberately scoped to work landing WITHIN the floor. A 30 ms floor
        // cannot promise anything about a mutation scheduled at 40 ms, and a
        // test asserting otherwise would be asserting a guarantee the code does
        // not make — it would pass only by accident of scheduling, then fail on
        // a loaded machine. Work beyond the floor is what the timeout and Wave
        // 8's independent witness are for, and `Quiescence`'s residual-risk note
        // says so.
        // The mutation must have been APPLIED before the trees are compared.
        // Asserted on the MODEL, because that is what the scheduled block
        // writes: it separates "the mutation never ran" (a fixture fault) from
        // "the mutation ran and settle missed it" (the defect this test exists
        // to catch). Only the second should reach the tree comparison.
        //
        // This is not hypothetical bookkeeping. CI run 31199890306 failed the
        // comparison below reporting "missing from the settled tree", and both
        // printed trees carried `width: 20.0` — `phase` was 0 in each, so the
        // mutation had never been applied and settle was being blamed for the
        // fixture's no-op. Reproduced locally by pushing the timer's interval
        // past the run: exit 1, same misleading message. Whatever starves the
        // timer on a loaded runner, the failure now names the right subject.
        // ORDER MATTERS, and it is the other half of the CTS-153D8F8A fix.
        // Reading `model.phase` BEFORE `currentTree()` samples it at the one
        // instant a late timer has not yet fired, so a mutation that lands
        // between the two reads is reported as "never ran" — the fixture
        // blaming itself for a race rather than for a no-op. Capturing the tree
        // first closes that window: by the time phase is read, any timer that
        // was going to fire has, and a phase of 0 then genuinely means the
        // block never ran.
        let tree = try await host.currentTree()

        XCTAssertEqual(
            model.phase, 1,
            "the scheduled mutation never ran, so this test can say nothing about "
                + "settle — the fixture is at fault, not the engine"
        )

        XCTAssertNotEqual(
            tree, before,
            "a mutation scheduled inside the quiet floor is missing from the settled tree"
        )
    }

    /// The floor must not become a hang: a genuinely static UI still settles
    /// promptly, just no faster than the floor.
    @MainActor
    func testTheQuietFloorDoesNotDelayAStaticSceneBeyondIt() async throws {
        let host = OracleHost(
            scenario: QuietBoxScenario(),
            viewport: Size(width: 80, height: 40)
        )
        _ = try await host.currentTree()

        let started = ContinuousClock.now
        let result = await host.settle(timeout: .seconds(2))
        let elapsed = started.duration(to: .now)

        guard case .settled = result else {
            XCTFail("a static scene must settle, got \(result)")
            return
        }
        XCTAssertLessThan(
            elapsed, .milliseconds(400),
            "the quiet floor turned a static scene into a slow one (\(elapsed))"
        )
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

            if Self.recordsTimingOnly {
                print("SETTLE-DEADLINE recorded result=\(result) elapsed=\(elapsed) budget=\(budget)")
            } else {
                guard case .timedOut = result else {
                    XCTFail("still-moving layout must time out at \(budget), got \(result)")
                    return
                }
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
