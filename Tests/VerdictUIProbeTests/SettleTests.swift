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

        // Oscillate on a timer FASTER than LayoutSettle.pumpInterval, not near
        // it. At the original 4 ms against a 5 ms pump the two periods were
        // close enough that a loaded run loop could let two consecutive quiet
        // checks land between ticks, and the test then reported the ENGINE
        // broken for a race in its own fixture — it passed alone and failed in
        // the full suite (measured: 308 tests, one failure, then 308 tests,
        // zero, on the same commit). A hostile test that intermittently accuses
        // the subject is worse than no hostile test.
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
        Color.green
            .frame(width: model.tick.isMultiple(of: 2) ? 10 : 40, height: 10)
            .verdictProbe("box", role: .image)
    }
}
