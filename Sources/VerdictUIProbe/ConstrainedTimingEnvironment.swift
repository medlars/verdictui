import Foundation

/// Whether this process can run the suite but cannot produce a wall clock
/// comparable to developer hardware.
///
/// The lane decision itself is `no.md` #13/#15: a latency budget is asserted on
/// developer hardware and RECORDED on a host whose timings measure the machine
/// rather than the code. This type is only the *membership test* for that
/// second class — spelled ONCE, because it had already drifted.
///
/// It is a type rather than three private computed properties because the three
/// timing suites each grew their own copy, and by 2026-08-09 they disagreed:
/// `HarnessPerformanceTests` honoured `CI` while `HostileSettleTests` and
/// `OraclePerformanceTests` did not, so the same run asserted in one file and
/// recorded in another. Adding a marker then meant remembering three sites, and
/// forgetting one is invisible — the forgetful copy simply keeps asserting a
/// figure it cannot hold, which is the failure `no.md` #17 records: a Codex
/// repair sandbox measured p50 167.50 ms and 394.97 ms against a 70 ms budget
/// on source that measures ~49 ms locally, producing three P1 tickets for a
/// regression that did not exist.
///
/// Keep in step with `CONSTRAINED_TIMING_ENV_MARKERS` in
/// `scripts/verdictui-pm.py`, which is the same class read from Python;
/// `test_the_swift_and_python_timing_lanes_agree` pins the two together,
/// because neither language can read the other's list.
///
/// ### Why it lives in the library rather than a test target
///
/// It began in `VerdictUIProbeTests`, which put it out of reach of every other
/// test target — so `MCPLatencyTests` (SLO 3, in `VerdictUICLICoreTests`) could
/// only have had a COPY, which is precisely the drift this type was extracted to
/// end. Test targets cannot share a file without a shared target, so the type
/// moved down into the library both already depend on. It reads `ProcessInfo`
/// and nothing else: no test-only API, no XCTest, and it stays inside the
/// probe's platform surface.
public enum ConstrainedTimingEnvironment {
    /// Environment variables that each mark a host in this class.
    ///
    /// - `CI`: any shared runner. Five consecutive GitHub macOS medians on
    ///   UNCHANGED code spanned 74.2–119.9 ms against a 70 ms budget.
    /// - `VERDICTUI_RECORD_TIMING_ONLY`: the explicit override, set by the PM
    ///   when it detects a constrained host by other means (an unwritable
    ///   SwiftPM cache), so the Swift side inherits one decision.
    /// - `CODEX_CI` / `CODEX_SANDBOX`: a Codex repair sandbox. It runs the real
    ///   suite under seatbelt with denied caches, so it is measurement-capable
    ///   and timing-incomparable at once — the exact combination that reads as
    ///   developer hardware unless named.
    public static let markers = [
        "CI",
        "VERDICTUI_RECORD_TIMING_ONLY",
        "CODEX_CI",
        "CODEX_SANDBOX",
    ]

    /// True when any marker is present in this process's environment.
    ///
    /// Presence, not truthiness: a runner that exports `CI=false` is still a
    /// runner, and reading the value would make the lane depend on a string
    /// nobody in this repo controls.
    public static var isActive: Bool {
        let environment = ProcessInfo.processInfo.environment
        return markers.contains { environment[$0] != nil }
    }
}
