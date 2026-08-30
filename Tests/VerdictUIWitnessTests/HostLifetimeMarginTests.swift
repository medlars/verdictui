import XCTest

@testable import VerdictUIWitness

/// The host must outlive the reader's wait for it.
///
/// `LieCatchTests` built its witness with `lifetime: 20` and read it with the
/// default `readyTimeout: 20`. Those are two deadlines of the SAME duration
/// measured from different instants, which leaves zero margin by construction:
///
///   - The host's death clock starts when `run(lifetime:)` schedules its timer,
///     which happens BEFORE `app.run()` — and `app.run()` is what gets the
///     process registered with the accessibility server.
///   - The reader then spends up to `readyTimeout` waiting for exactly that
///     registration, and only afterwards performs the read.
///
/// So the later the window is published, the less host remains to read, and past
/// a point the read lands on a host that is already terminating. Nothing
/// enforced an ordering between the two values; callers set both by hand.
///
/// Filed from CIS-2C757660, whose failing run took 25.8 seconds — longer than
/// either deadline.
final class HostLifetimeMarginTests: XCTestCase {
    /// The defect, stated as the invariant it violates.
    func testEqualDeadlinesGetAMarginRatherThanRacing() {
        let effective = WitnessHostProcess.effectiveLifetime(configured: 20, readyTimeout: 20)
        XCTAssertGreaterThan(
            effective, 20,
            "a host configured to live exactly as long as the reader waits can die inside the "
                + "read; the launched lifetime must exceed readyTimeout")
    }

    /// The margin must be enough to finish a read, not merely a token epsilon.
    func testTheMarginLeavesRoomToActuallyRead() {
        let effective = WitnessHostProcess.effectiveLifetime(configured: 20, readyTimeout: 20)
        XCTAssertGreaterThanOrEqual(
            effective, 20 + WitnessHostProcess.readCompletionMargin,
            "the surplus over readyTimeout is what the read runs in")
    }

    /// Negative control: a caller who already asked for a generous lifetime
    /// keeps it. Without this, `effectiveLifetime` could satisfy the two tests
    /// above by ignoring `configured` entirely — a rule that is always true is
    /// indistinguishable from a working one (lesson 328).
    func testAnAlreadySufficientLifetimeIsNotShortened() {
        let effective = WitnessHostProcess.effectiveLifetime(configured: 600, readyTimeout: 20)
        XCTAssertEqual(effective, 600, accuracy: 0.0001)
    }

    /// The bound is a SAFETY bound too: a host must never be launched
    /// unbounded, whatever the reader asks for.
    func testTheLifetimeStaysFinite() {
        let effective = WitnessHostProcess.effectiveLifetime(configured: 1, readyTimeout: 1)
        XCTAssertTrue(effective.isFinite)
        XCTAssertGreaterThan(effective, 1)
    }
}
