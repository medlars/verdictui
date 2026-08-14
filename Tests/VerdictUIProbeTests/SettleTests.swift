import AppKit
import Combine
import SwiftUI
import VerdictUIKernel
import XCTest

@testable import VerdictUIProbe

/// Wave 3 Task 2: quiescence detector. Hostile animation cases are Task 5;
/// these pin settle / timeout / virtual-clock blocking.
final class SettleTests: XCTestCase {
    override func invokeTest() {
        autoreleasepool { super.invokeTest() }
    }

    @MainActor
    func testQuietScenarioSettles() async throws {
        let host = OracleHost(
            scenario: QuietBoxScenario(),
            viewport: Size(width: 80, height: 40)
        )
        // Establish a tree first so settle's before-tree is non-nil.
        _ = try await host.currentTree()
        let result = await host.settle(timeout: .seconds(2))
        guard case .settled(let after) = result else {
            XCTFail("expected settled, got \(result)")
            return
        }
        XCTAssertGreaterThanOrEqual(after, .zero)
        XCTAssertLessThan(after, .seconds(2))
    }

    @MainActor
    func testPendingVirtualClockWaiterBlocksSettleUntilAdvanced() async throws {
        let clock = VerdictClock()
        let host = OracleHost(
            scenario: QuietBoxScenario(),
            viewport: Size(width: 80, height: 40),
            clock: clock
        )
        _ = try await host.currentTree()

        // Detached so registration is not stuck behind this MainActor test body.
        let sleeper = Task.detached {
            try await clock.sleep(for: .seconds(30))
        }
        let registerDeadline = Date().addingTimeInterval(1)
        while clock.pendingWaiterCount == 0, Date() < registerDeadline {
            await Task.yield()
        }
        XCTAssertEqual(clock.pendingWaiterCount, 1)

        let blocked = await host.settle(timeout: .milliseconds(150))
        guard case .timedOut = blocked else {
            sleeper.cancel()
            XCTFail("settle must time out while a virtual-clock waiter is pending, got \(blocked)")
            return
        }
        let fail = try XCTUnwrap(host.timeoutVerdict(from: blocked, settleMs: 150))
        XCTAssertEqual(fail.status, .fail)
        XCTAssertEqual(fail.findings.first?.rule, Quiescence.timeoutRule)

        clock.advance(by: .seconds(30))
        try await sleeper.value
        XCTAssertEqual(clock.pendingWaiterCount, 0)

        let cleared = await host.settle(timeout: .seconds(2))
        guard case .settled = cleared else {
            XCTFail("settle must succeed after the waiter is released, got \(cleared)")
            return
        }
    }

    @MainActor
    func testOscillatingLayoutTimesOutWithDeltaEvidence() async throws {
        let model = OscillatingBoxModel()
        let host = OracleHost(
            scenario: OscillatingBoxScenario(model: model),
            viewport: Size(width: 120, height: 40)
        )
        _ = try await host.currentTree()

        // Tick FASTER than LayoutSettle.pumpInterval so a change is available
        // on every check. The interval was tuned twice for this — 4 ms, then
        // pumpInterval/4 — and neither tuning was the real fix: see
        // `OscillatingBoxView.body` for why the fixture's PERIOD, not its rate,
        // is what let this test intermittently accuse the engine. A hostile
        // test that accuses its subject is worse than no hostile test.
        let interval = LayoutSettle.pumpInterval / 4
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            model.tick += 1
        }
        RunLoop.main.add(timer, forMode: .common)
        defer { timer.invalidate() }

        let result = await host.settle(timeout: .milliseconds(200))

        guard case .timedOut(let delta) = result else {
            XCTFail("oscillating layout must time out, got \(result)")
            return
        }
        let verdict = try XCTUnwrap(host.timeoutVerdict(from: result, settleMs: 200))
        XCTAssertEqual(verdict.status, .fail)
        XCTAssertEqual(verdict.findings.first?.rule, Quiescence.timeoutRule)
        if delta.isEmpty {
            XCTAssertTrue(
                verdict.findings.contains {
                    $0.message.contains("no tree delta")
                        || $0.message.contains("still changing")
                }
            )
        }
    }

    @MainActor
    func testProgressTokenIsNilWhileWaitersPending() {
        let sink = VerdictTreeSink()
        sink.accept(
            SemanticNode(
                id: "",
                role: .container,
                frame: Rect(x: 0, y: 0, width: 1, height: 1),
                structuralPath: "root"
            )
        )
        let clock = VerdictClock()
        let task = Task {
            try await clock.sleep(for: .seconds(5))
        }
        // Spin until the waiter registers (sync sleep registration happens in
        // the continuation body after the task starts).
        let deadline = Date().addingTimeInterval(1)
        while clock.pendingWaiterCount == 0, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.001))
        }
        XCTAssertEqual(clock.pendingWaiterCount, 1)
        XCTAssertNil(Quiescence.progressToken(sink: sink, clock: clock))
        clock.advance(by: .seconds(5))
        // Drain the resumed task.
        let expect = expectation(description: "sleeper finished")
        Task {
            _ = await task.result
            expect.fulfill()
        }
        wait(for: [expect], timeout: 1)
        XCTAssertNotNil(Quiescence.progressToken(sink: sink, clock: clock))
    }

    func testTimeIntervalConversionMatchesWholeSeconds() {
        XCTAssertEqual(Quiescence.timeInterval(for: .seconds(2)), 2, accuracy: 1e-9)
        XCTAssertEqual(
            Quiescence.timeInterval(for: .milliseconds(150)),
            0.15,
            accuracy: 1e-9
        )
    }
}

// MARK: - Fixtures

struct QuietBoxScenario: VerdictScenario {
    var name: String { "wave3-quiet-box" }

    @MainActor
    func body(state: ScenarioState) -> some View {
        Color.blue
            .frame(width: 20, height: 10)
            .verdictProbe("box", role: .image)
    }
}

final class OscillatingBoxModel: ObservableObject, @unchecked Sendable {
    @Published var tick = 0
}

struct OscillatingBoxScenario: VerdictScenario {
    let model: OscillatingBoxModel
    var name: String { "wave3-oscillating-box" }

    @MainActor
    func body(state: ScenarioState) -> some View {
        OscillatingBoxView(model: model)
    }
}

private struct OscillatingBoxView: View {
    @ObservedObject var model: OscillatingBoxModel

    var body: some View {
        // A NON-REPEATING width, not a two-state toggle.
        //
        // This alternated 10 ↔ 40 pt until 2026-08-14, and that period was the
        // whole defect: the tree repeated every TWO deliveries while
        // `LayoutSettle.requiredAgreeingChecks` is 2, so two identical samples
        // could land consecutively and — if they happened to span the 30 ms
        // quiet floor — settle declared the screen quiet. The engine was not
        // wrong; the fixture was ALIASING against the sampler, the way a wheel
        // appears stationary when filmed at its own rotation rate.
        //
        // Measured before this fix, by instrumenting `sink.accept` directly:
        // 67 deliveries, `updateCount` climbing 59 → 66, widths reading
        // 10, 40, 40, 10, 10, 40, 40, 10 — a two-delivery period, exactly the
        // check count. Everything was working; the sample rate and the signal
        // rate simply agreed.
        //
        // Period 97 (prime, and far larger than any plausible check count)
        // cannot alias: no two consecutive samples are ever equal, so the
        // token disagrees with itself on every check and settle can never
        // reach two agreeing ones. Verified 20/20 consecutive runs, and
        // negative-controlled by freezing the width — a static layout settles
        // and the test then FAILS, which is what makes this a test.
        Color.green
            .frame(width: 10 + Double(model.tick % 97), height: 10)
            .verdictProbe("box", role: .image)
    }
}
