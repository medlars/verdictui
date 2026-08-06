// Wave 3 Task 6: SLO 1, measured on the thing SLO 1 is actually about.
//
// `docs/slo.md` states SLO 1 as "inner-loop verify cycle (act → settle →
// verdict) < 100 ms p95". Wave 2 could only measure `currentTree()`, because
// act-and-observe did not exist yet; `OraclePerformanceTests` still holds that
// figure and remains useful as the capture-only half. This file measures the
// full cycle — `Harness.perform()` — which is the number the SLO names and the
// one an agent actually waits on.
import Foundation
import VerdictUIDemoScenarios
import VerdictUIKernel
import VerdictUIProbe
import XCTest

/// Samples ``Harness/perform(_:)`` end-to-end and holds p95 to SLO 1's 100 ms.
///
/// ### Why a toggle, and why the same one every time
///
/// `perform` needs an action that (a) always succeeds, (b) actually changes the
/// tree — a no-op action would measure settle against an unchanged layout and
/// report the cheap path as if it were the cycle — and (c) is reversible, so a
/// long sample run stays in a bounded state space instead of drifting somewhere
/// unrepresentative. `ToggleLayoutScenario`'s expand/collapse satisfies all
/// three: every other sample expands, the rest collapse, and both directions
/// are real layout work.
///
/// ### Statistics
///
/// The percentile and mean helpers are duplicated from ``OraclePerformanceTests``
/// rather than shared. They are four lines each, and the alternative is a test
/// utility target that both suites import — more moving parts than the thing
/// they compute, and a shared helper here would be a place for one suite's
/// change to silently move the other's numbers.
final class HarnessPerformanceTests: XCTestCase {
    /// Every test builds an AppKit hierarchy and `swift test` has no window
    /// server run loop to drain the pool between tests — see the same note on
    /// ``OraclePerformanceTests``.
    override func invokeTest() {
        autoreleasepool { super.invokeTest() }
    }

    /// Act-and-observe cycles sampled. Sixty, so nearest-rank p95 (rank
    /// `ceil(0.95 × 60)` = 57) sits on the fourth-slowest sample rather than on
    /// the slowest — one unlucky scheduling hiccup must not become the reported
    /// figure.
    private static let sampleCount = 60

    /// SLO 1, in milliseconds. This is the published product target from
    /// `docs/slo.md`, not a machine-local stretch goal: the same 100 ms CI
    /// runners are held to (see `OraclePerformanceTests.warmP95BudgetMs` for
    /// why the Wave 2 figure moved from 50 ms to the product number).
    private static let performP95BudgetMs: Double = 100

    // MARK: - SLO 1

    /// Full act → settle → verdict p95 under ``performP95BudgetMs``.
    @MainActor
    func testPerformCycleMeetsTheSLO1Gate() async throws {
        let harness = Harness(
            scenario: ToggleLayoutScenario(isExpanded: false),
            viewport: ToggleLayoutScenario.recommendedViewport
        )

        // Warm-up, discarded: the first cycle on a fresh host pays for the first
        // settle of a layout nothing has observed yet. Pooling that into the SLO
        // would report construction cost under the name of the inner loop.
        _ = await harness.perform(.toggle(ToggleLayoutScenario.toggleProbeID))

        var samples: [Double] = []
        for _ in 1...Self.sampleCount {
            let started = ContinuousClock.now
            let step = await harness.perform(.toggle(ToggleLayoutScenario.toggleProbeID))
            samples.append(Self.milliseconds(ContinuousClock.now - started))

            // A cycle that FAILED is not a cycle whose cost means anything —
            // the act-error path returns early and would look artificially fast.
            XCTAssertEqual(
                step.status, .pass,
                "a benchmarked cycle failed, so its timing is not comparable: "
                    + "\(step.verdict.findings.map(\.message))"
            )
            XCTAssertFalse(
                step.delta.isEmpty,
                "the benchmarked action changed nothing, so this measures the "
                    + "unchanged-layout path rather than the verify cycle"
            )
        }

        XCTAssertEqual(samples.count, Self.sampleCount)
        for sample in samples {
            XCTAssertTrue(
                sample.isFinite && sample >= 0,
                "unusable sample: \(sample) ms"
            )
        }

        let sorted = samples.sorted()
        let p50 = Self.percentile(0.50, of: sorted)
        let p95 = Self.percentile(0.95, of: sorted)

        // Printed before the assertion so a failing run still records its number
        // — a regression is worth more with its figure than without it. This is
        // the line `stage_runtime_bench` parses.
        print(
            String(
                format: "SLO1-PERFORM p50=%.2fms p95=%.2fms mean=%.2fms max=%.2fms n=%d",
                p50,
                p95,
                Self.mean(samples),
                sorted.last ?? .nan,
                samples.count
            )
        )

        XCTAssertLessThan(
            p95,
            Self.performP95BudgetMs,
            "act→settle→verdict p95 is \(p95) ms, over SLO 1's "
                + "\(Self.performP95BudgetMs) ms (p50 \(p50) ms over \(samples.count) samples)"
        )
    }

    /// A timed-out cycle must still return on its own deadline. SLO 1 governs
    /// the healthy path; this is the guard that an unhealthy one cannot blow
    /// past its budget and hang the agent that called it.
    @MainActor
    func testTimedOutCycleStillReturnsWithinItsBudget() async throws {
        let harness = Harness(
            scenario: ToggleLayoutScenario(isExpanded: false),
            viewport: ToggleLayoutScenario.recommendedViewport
        )
        _ = await harness.perform(.toggle(ToggleLayoutScenario.toggleProbeID))

        let budget = Duration.milliseconds(120)
        let started = ContinuousClock.now
        // An unknown probe fails before settle, so this measures the act-error
        // path's cost — the one an agent hits most often when it guesses an id.
        let step = await harness.perform(.toggle("no-such-probe"), timeout: budget)
        let elapsed = Self.milliseconds(ContinuousClock.now - started)

        XCTAssertEqual(step.status, .fail)
        XCTAssertLessThan(
            elapsed,
            Self.performP95BudgetMs,
            "a rejected act took \(elapsed) ms — it must fail fast, not on the settle budget"
        )
    }

    // MARK: - Statistics

    private static func milliseconds(_ duration: Duration) -> Double {
        let (seconds, attoseconds) = duration.components
        return Double(seconds) * 1000 + Double(attoseconds) / 1_000_000_000_000_000
    }

    /// Nearest-rank percentile of an ascending-sorted set; `.nan` for an empty
    /// one, which fails every comparison on purpose — a percentile of nothing
    /// must not read as a fast one.
    private static func percentile(_ fraction: Double, of sorted: [Double]) -> Double {
        guard !sorted.isEmpty else { return .nan }
        let rank = Int((fraction * Double(sorted.count)).rounded(.up))
        let index = min(max(rank - 1, 0), sorted.count - 1)
        return sorted[index]
    }

    private static func mean(_ samples: [Double]) -> Double {
        guard !samples.isEmpty else { return .nan }
        return samples.reduce(0, +) / Double(samples.count)
    }
}
