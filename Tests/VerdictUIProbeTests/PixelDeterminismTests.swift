import AppKit
import SwiftUI
import VerdictUIKernel
import XCTest

@testable import VerdictUIProbe

// MARK: - Fixtures

/// Deterministic control: fixed content, no unpinned inputs.
///
/// Present so "refuses nondeterministic scenarios" cannot be satisfied by an
/// implementation that refuses everything — which would be the easiest way to
/// pass the refusal test and would disable the pixel channel entirely.
private struct StableScenario: VerdictScenario {
    var name: String { "stable-fixture" }

    func body(state: ScenarioState) -> some View {
        VStack(spacing: 6) {
            Rectangle().fill(Color.red).frame(width: 40, height: 20)
            Text("stable").font(.system(size: 12))
        }
        .padding(8)
        .background(Color.white)
        .verdictProbe("root", role: .container)
    }
}

/// Genuinely nondeterministic: the rendered TEXT changes between renders.
///
/// Getting this fixture right was the finding of the session, so the mechanism is
/// worth stating. Two earlier attempts produced a fixture that could not fail:
///
/// 1. `Text(Date().description)` inside a `View` struct held by one host. A
///    SwiftUI `View` is a value, so `Date()` is evaluated ONCE when the struct is
///    constructed; rendering that same host twice re-encodes one captured string.
/// 2. Constructing the view fresh per render in a bare `NSHostingView` spike. That
///    LOOKED right and still reported `identical=true` — because the spike was not
///    drawing text at all. The control that exposed it: rendering the knowingly
///    different strings "AAA" and "BBB" also produced identical bytes. The
///    instrument was reporting nothing, not stability. (`OracleHost` does draw
///    text: 724 vs 892 bytes for the same pair.)
///
/// So the source of variation is a counter incremented on every `body` evaluation
/// rather than a clock: it changes by construction, it does not depend on
/// wall-time resolution, and it cannot silently agree because two renders happened
/// inside the same second. `nonisolated(unsafe)` is sound here because every
/// `body` evaluation in this suite is on the main actor.
private nonisolated(unsafe) var bodyEvaluationCounter = 0

private struct DriftingScenario: VerdictScenario {
    var name: String { "drifting-fixture" }

    func body(state: ScenarioState) -> some View {
        bodyEvaluationCounter += 1
        return VStack(spacing: 6) {
            Rectangle().fill(Color.red).frame(width: 40, height: 20)
            Text("render \(bodyEvaluationCounter)").font(.system(size: 12))
        }
        .padding(8)
        .background(Color.white)
        .verdictProbe("root", role: .container)
    }
}

// MARK: - Tests

/// The double-render check, held to both directions: it must refuse a scenario
/// that disagrees with itself, and it must NOT refuse one that does not.
final class PixelDeterminismTests: XCTestCase {
    override func invokeTest() {
        autoreleasepool { super.invokeTest() }
    }

    private static let viewport = Size(width: 160, height: 80)

    // MARK: - The positive control

    /// A stable scenario passes and hands back the capture it verified.
    ///
    /// The control that makes the refusal test meaningful: without it, a check
    /// hard-coded to `.nondeterministic` would pass every refusal assertion while
    /// making pixel baselines impossible for anything.
    @MainActor
    func testAStableScenarioIsAcceptedAndCarriesItsCapture() async throws {
        let result = try await DeterminismCheck.verify(
            StableScenario(),
            viewport: Self.viewport
        )

        guard case let .deterministic(capture) = result else {
            return XCTFail("a stable scenario must not be refused: \(result)")
        }
        XCTAssertTrue(result.isDeterministic)
        XCTAssertEqual(capture.scenarioName, "stable-fixture")
        XCTAssertFalse(capture.png.isEmpty)
    }

    // MARK: - The refusal

    /// A scenario whose content changes between renders is REFUSED.
    ///
    /// The check's whole reason to exist. A baseline written here would fail at
    /// random on an unrelated commit, and the reader would look for a regression
    /// in code that never changed.
    @MainActor
    func testAScenarioThatChangesBetweenRendersIsRefused() async throws {
        bodyEvaluationCounter = 0

        let result = try await DeterminismCheck.verify(
            DriftingScenario(),
            viewport: Self.viewport
        )

        guard case let .nondeterministic(evidence) = result else {
            return XCTFail("a drifting scenario must be refused, got \(result)")
        }
        XCTAssertFalse(result.isDeterministic)
        XCTAssertEqual(evidence.scenarioName, "drifting-fixture")
        XCTAssertNotEqual(
            evidence.firstHash,
            evidence.secondHash,
            "the evidence must show the two renders actually differed"
        )
    }

    /// The fixture is genuinely re-evaluated — the check is not being handed two
    /// renders of one frozen view.
    ///
    /// Without this, `DriftingScenario` could stop varying (as it did in two
    /// earlier attempts, see its doc comment) and the refusal test above would go
    /// green for the wrong reason: a fixture that no longer drifts would simply be
    /// accepted, and only this assertion can tell that apart from a check that
    /// stopped refusing.
    @MainActor
    func testTheDriftingFixtureIsActuallyReEvaluatedBetweenRenders() async throws {
        bodyEvaluationCounter = 0
        _ = try await DeterminismCheck.verify(DriftingScenario(), viewport: Self.viewport)

        XCTAssertGreaterThanOrEqual(
            bodyEvaluationCounter,
            2,
            "body must be evaluated at least once per render, or the fixture proves nothing"
        )
    }

    // MARK: - Actionability

    /// The refusal names the scenario and what to do about it.
    ///
    /// "This scenario is nondeterministic" is true and useless; the answer is
    /// almost always one of a short list of unpinned inputs, so the error lists
    /// them. A refusal that a reader cannot act on gets suppressed, and a
    /// suppressed check is not a check.
    func testTheRefusalIsActionable() {
        let evidence = NondeterminismEvidence(
            scenarioName: "checkout",
            firstHash: "aaaa000000000000",
            secondHash: "bbbb000000000000",
            firstByteCount: 100,
            secondByteCount: 120,
            backend: .cacheDisplay
        )

        let message = PixelBaselineError.refused(evidence).description
        XCTAssertTrue(message.contains("'checkout'"), "must name the scenario")
        XCTAssertTrue(message.contains("aaaa000000000000"), "must cite the first hash")
        XCTAssertTrue(message.contains("bbbb000000000000"), "must cite the second hash")
        XCTAssertTrue(message.contains("Date()"), "must name the usual causes")
        XCTAssertTrue(
            message.contains("semantic rules"),
            "must offer the alternative that does not need byte stability"
        )
    }

    /// The evidence records which backend produced it.
    ///
    /// The two backends answer different questions, so a scenario shown unstable
    /// under one is not thereby shown unstable under the other; an evidence record
    /// that omitted the backend would overstate what was measured.
    func testTheEvidenceRecordsItsBackend() {
        let evidence = NondeterminismEvidence(
            scenarioName: "s",
            firstHash: "a",
            secondHash: "b",
            firstByteCount: 1,
            secondByteCount: 2,
            backend: .imageRenderer
        )

        XCTAssertEqual(evidence.backend, .imageRenderer)
        XCTAssertTrue(evidence.advice.contains("imageRenderer"))
    }
}
