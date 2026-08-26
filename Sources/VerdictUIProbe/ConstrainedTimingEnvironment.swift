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
/// Keep in step with `CONSTRAINED_TIMING_ENV_MARKERS` and
/// `_timing_record_only_environment()` in `scripts/verdictui-pm.py`, which is
/// the same class read from Python; `test_the_swift_and_python_timing_lanes_agree`
/// pins the two together, because neither language can read the other's list.
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
        recordTimingOnlyOverride,
        "CODEX_CI",
        "CODEX_SANDBOX",
    ]

    /// The one marker that is an explicit instruction rather than a deduction
    /// about the machine.
    ///
    /// It is spelled here and referenced from ``markers`` so the two cannot
    /// drift: a second literal would be a second place to change, and changing
    /// one alone leaves the other's tests green — the copy problem ADR 2026-013
    /// rejected for this very type.
    public static let recordTimingOnlyOverride = "VERDICTUI_RECORD_TIMING_ONLY"

    /// SwiftPM cache locations whose presence without write access marks this
    /// process as timing-incomparable to developer hardware.
    ///
    /// This mirrors the PM's Python-side fallback. Some repair sandboxes do not
    /// export `CODEX_CI` / `CODEX_SANDBOX`, but they do expose the same
    /// condition through denied user-level SwiftPM caches. A direct `swift test`
    /// run then has no PM wrapper to inject `VERDICTUI_RECORD_TIMING_ONLY`, so
    /// the Swift lane must be able to recognize the host itself.
    public static var constrainedSwiftPMCachePaths: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent("Library/org.swift.swiftpm").path,
            home.appendingPathComponent("Library/Caches/org.swift.swiftpm").path,
        ]
    }

    /// True when a known SwiftPM user cache exists but this process cannot
    /// write to it.
    public static var hasUnwritableSwiftPMCache: Bool {
        hasUnwritableCache(among: constrainedSwiftPMCachePaths)
    }

    /// ``hasUnwritableSwiftPMCache`` over a caller-supplied path list.
    ///
    /// The seam exists so a test can supply a path where a mode-bit check and a
    /// real write DISAGREE. On healthy developer hardware the configured cache
    /// paths are writable by both methods, so an assertion over them holds under
    /// either implementation and cannot fail for the reason it exists
    /// (`no.md` #17).
    static func hasUnwritableCache(among paths: [String]) -> Bool {
        paths.contains { path in
            FileManager.default.fileExists(atPath: path)
                && !canWriteExistingDirectory(at: path)
        }
    }

    /// True when this process can create and remove a probe file in a directory.
    ///
    /// Sandbox denials can disagree with mode-bit checks. The timing lane cares
    /// about the operation SwiftPM will actually attempt, so it probes the write
    /// path directly instead of trusting static permissions.
    static func canWriteExistingDirectory(at path: String) -> Bool {
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        let probe = directory.appendingPathComponent(
            ".verdictui-write-probe-\(UUID().uuidString)"
        )
        do {
            try Data().write(to: probe, options: .withoutOverwriting)
            try? FileManager.default.removeItem(at: probe)
            return true
        } catch {
            try? FileManager.default.removeItem(at: probe)
            return false
        }
    }

    /// True when any marker is present in this process's environment.
    ///
    /// Presence, not truthiness: a runner that exports `CI=false` is still a
    /// runner, and reading the value would make the lane depend on a string
    /// nobody in this repo controls.
    public static var hasMarker: Bool {
        let environment = ProcessInfo.processInfo.environment
        return markers.contains { environment[$0] != nil }
    }

    /// True when this host cannot produce a WALL CLOCK comparable to developer
    /// hardware — the membership test for the record-only lane.
    ///
    /// Read this to decide whether to ASSERT or merely RECORD a latency budget
    /// (a p50, a p95, a cache speedup). Never read it to decide whether to
    /// check a correctness invariant: see ``canEvaluateElapsedInvariants``.
    public static var isActive: Bool {
        hasMarker || hasUnwritableSwiftPMCache
    }

    /// True when this host can still judge an ORDERING or OVERSHOOT relation
    /// between two durations it measured itself.
    ///
    /// ### Why this is a second question, and not the same one
    ///
    /// ``isActive`` answers "is my wall clock comparable to a developer's?".
    /// A shared runner's answer is no: its p50 for unchanged code spanned
    /// 74.2–119.9 ms against a 70 ms budget, so asserting an ABSOLUTE figure
    /// there fails for the neighbour rather than for the code (`no.md` #15).
    ///
    /// But a RELATIVE claim between two durations from the SAME clock survives a
    /// slow machine, because contention inflates both sides. `no.md` #18's
    /// discriminator is exactly that shape: a settle that gave up at its
    /// deadline has spent strictly MORE than the deadline, while an
    /// implementation echoing the budget back reports exactly `150.0` for a
    /// 150 ms budget and can never exceed it. Load makes the overshoot LARGER,
    /// never smaller — so a constrained host is, if anything, a *better* witness
    /// for it. That guard took four failed attempts to establish, and every
    /// assertion that looked like it worked (`> 0`, `<= elapsedMs`) was
    /// satisfied by both the correct and the broken implementation.
    ///
    /// Folding the two questions into one predicate is how the guard would be
    /// lost: widening ``isActive`` to cover an unwritable SwiftPM cache is
    /// correct for the six budget lanes and would silently switch the overshoot
    /// check off on any host with a read-only cache. Measured 2026-08-15 —
    /// forcing `VERDICTUI_RECORD_TIMING_ONLY=1` runs 784 tests to 0 failures
    /// with 3 skipped, i.e. the gates stop gating and every signal stays green.
    /// That is the `no.md` #17 shape: a predicate whose only exercised branch is
    /// the permissive one cannot distinguish a working rule from one that is
    /// always true.
    ///
    /// Only `VERDICTUI_RECORD_TIMING_ONLY` suppresses these, and it is the
    /// explicit human override rather than an inference about the host.
    public static var canEvaluateElapsedInvariants: Bool {
        ProcessInfo.processInfo.environment[recordTimingOnlyOverride] == nil
    }

    /// The run-queue depth per core at which this host stops being able to hold
    /// an absolute wall-clock budget.
    ///
    /// A load average is only meaningful against the core count that serves it:
    /// load 8 is idle on a 64-core host and a 2x queue on a 4-core one, so the
    /// comparable number is the RATIO. The figure mirrors
    /// `SEVERE_OVERSUBSCRIPTION` in `scripts/verdictui-pm.py`, which already
    /// reports this class on the Python side;
    /// `test_the_swift_and_python_oversubscription_thresholds_agree` pins the
    /// two together, because neither language can read the other's constant.
    public static let severeOversubscription = 2.0

    /// One-minute load average and active core count, each `nil` when the host
    /// will not report it.
    ///
    /// Returns a tuple rather than a ratio so a caller can tell "the host is
    /// quiet" from "the host would not say" — collapsing those to one number
    /// makes an unreadable load indistinguishable from an idle one, and they
    /// demand opposite responses (lesson 202).
    public static var currentLoad: (load1: Double, cores: Int)? {
        var samples = [Double](repeating: 0, count: 1)
        guard getloadavg(&samples, 1) == 1 else { return nil }
        let cores = ProcessInfo.processInfo.activeProcessorCount
        guard cores > 0, samples[0].isFinite, samples[0] >= 0 else { return nil }
        return (samples[0], cores)
    }

    /// Run-queue depth per core, or `nil` when the host will not report it.
    public static var oversubscription: Double? {
        guard let load = currentLoad else { return nil }
        return load.load1 / Double(load.cores)
    }

    /// True only for a MEASURED ratio at or past ``severeOversubscription``.
    ///
    /// An unreadable load answers `false` — the tree is presumed ours — so a
    /// host that cannot measure itself keeps ASSERTING its budgets rather than
    /// silently dropping to record-only. That direction is deliberate and is
    /// the opposite of the convenient one: a guard that suppressed its own
    /// assertion whenever it could not measure would be a check that cannot
    /// fail for the reason it exists (lesson 202), and the budget this serves
    /// is a SAFETY bound.
    public static var isSeverelyOversubscribed: Bool {
        guard let ratio = oversubscription else { return false }
        return ratio >= severeOversubscription
    }

    /// True when an ABSOLUTE wall-clock budget measured on this host would be a
    /// statement about the machine rather than about the code.
    ///
    /// ### Why this is a THIRD question rather than a wider ``isActive``
    ///
    /// ``isActive`` is a membership test for a class of HOSTS, decided by
    /// markers a runner exports. That is the right instrument for a shared CI
    /// runner, and it is blind to the case this predicate exists for: a
    /// developer machine under fleet contention exports no marker at all.
    /// Measured 2026-08-25 — `ThirdPartyAuditTests` read Notes in 47.66 s
    /// against a 30 s budget at load 97+ on a host with ZERO markers set, so
    /// `isActive` was `false` and the marker lane could not have caught it. The
    /// same read costs ~2 s on a quiet machine.
    ///
    /// Widening ``isActive`` to cover load would have been the tempting fix and
    /// is wrong for the same reason folding ``canEvaluateElapsedInvariants``
    /// into it would be: the six budget lanes that read ``isActive`` ask "is my
    /// clock comparable to a developer's?", a durable property of the host,
    /// while this asks "is my clock comparable RIGHT NOW?", a property of the
    /// moment. A momentary answer written into a host-class predicate makes six
    /// unrelated gates flip between runs.
    public static var cannotHoldAbsoluteWallClockBudget: Bool {
        isActive || isSeverelyOversubscribed
    }
}
