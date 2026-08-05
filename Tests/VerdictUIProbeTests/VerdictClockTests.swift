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
        // Let the sleep register its waiter before we advance.
        await Task.yield()
        await Task.yield()

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
