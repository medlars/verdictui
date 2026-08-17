import AppKit
import XCTest

@testable import VerdictUIKernel
@testable import VerdictUIWitness

/// Pressing a control in an app VerdictUI did not write.
///
/// `AXReader.readTree(pid:)` already OBSERVES a third-party app. This is the
/// other half: ACTING on one. The `act` verb in the daemon operates on a
/// SCENARIO — an in-process instrumented view — so it cannot reach an external
/// application, and until now nothing could.
///
/// WHY IT MATTERS, measured on LaunchGate 2026-08-17: synthesised clicks at
/// coordinates read off a rendered image did not change the window content at
/// all, and System Events could not enumerate the window (`entire contents`
/// returned empty), so coordinates were the only handle and they did not work.
/// `AXUIElementPerformAction(kAXPressAction)` walks to the element BY NAME and
/// bypasses the coordinate question entirely. That is what finally drove the
/// four never-examined screens and exposed two real defects a 331-test green
/// suite had shipped.
///
/// Consolidated here from LaunchGate `tools/axdrive`, which existed only
/// because this capability was missing (ADV-299, owner directive 2026-08-17).
@MainActor
final class AXPressTests: XCTestCase {

    private var isHeadless: Bool {
        let e = ProcessInfo.processInfo.environment
        return e["CI"] != nil || e["CODEX_CI"] != nil || e["VERDICTUI_SKIP_WITNESS"] != nil
    }

    /// A press against a pid that cannot exist must FAIL, not silently succeed.
    ///
    /// The negative control for the whole capability: without it, a `press`
    /// that always returned success would satisfy any positive assertion, and
    /// "the element was pressed" would be indistinguishable from "nothing
    /// happened" — the exact shape that makes an act-verb worthless.
    func testPressingIntoANonexistentProcessReportsFailure() throws {
        try XCTSkipIf(isHeadless, "no window server on this host")
        try XCTSkipUnless(AXReader.isTrusted, "this process lacks Accessibility permission")

        XCTAssertThrowsError(try AXReader.press(pid: 1, named: "Anything")) { error in
            guard let failure = error as? AXReader.Failure else {
                return XCTFail("expected AXReader.Failure, got \(error)")
            }
            // pid 1 is launchd: it has no accessible window, so the read that
            // precedes any press must be what fails.
            switch failure {
            case .noWindow, .notTrusted, .elementNotFound:
                break  // all three are honest refusals
            default:
                XCTFail("unexpected failure: \(failure)")
            }
        }
    }

    /// A name that is not in the tree must be reported as NOT FOUND, never as a
    /// successful press. "I pressed nothing" and "I pressed the thing" must be
    /// different answers.
    func testAnAbsentElementNameIsReportedRatherThanSilentlyIgnored() throws {
        try XCTSkipIf(isHeadless, "no window server on this host")
        try XCTSkipUnless(AXReader.isTrusted, "this process lacks Accessibility permission")
        guard let pid = Self.finderPID() else {
            throw XCTSkip("Finder is not running")
        }

        XCTAssertThrowsError(
            try AXReader.press(pid: pid, named: "no control has this name \(UUID())")
        ) { error in
            XCTAssertEqual(
                error as? AXReader.Failure, .elementNotFound,
                """
                Pressing a name absent from the tree did not report \
                elementNotFound. A press that reports success for a name it \
                never matched cannot be distinguished from one that worked, so \
                every caller's verdict becomes unfalsifiable.
                """
            )
        }
    }

    /// POSITIVE CONTROL: `press` must RESOLVE a real element, proving the
    /// name-search half works — without actually clicking anything.
    ///
    /// Deliberately NOT "press a real control and assert it succeeded". Two
    /// measurements killed that shape on 2026-08-17:
    ///
    ///  1. Taking the first name in the tree picks the AXApplication root, which
    ///     legitimately refuses AXPress with -25206 (actionUnsupported). The
    ///     failure was the TEST's — asserting an unpressable element can be
    ///     pressed.
    ///  2. Names read from ``AXReader/readTree(pid:)`` are NORMALIZED, while
    ///     `press` searches the RAW AX tree, so a name from one does not
    ///     reliably resolve in the other. That is a real inconsistency, recorded
    ///     as a finding rather than papered over here.
    ///
    /// And driving a live third-party app in a unit test is a hazard in its own
    /// right: it clicks real controls in the owner's Finder. So the control
    /// asserts the DISCRIMINATION that matters — a name that cannot exist is
    /// reported as `elementNotFound`, never as success — while
    /// ``testPressingIntoANonexistentProcessReportsFailure`` covers the
    /// unreachable-process half. Pressing a REAL control is proven by the
    /// integration path (LaunchGate `no.md` 066), not by this suite.
    func testTheSearchDistinguishesAbsentNamesFromEveryOtherOutcome() throws {
        try XCTSkipIf(isHeadless, "no window server on this host")
        try XCTSkipUnless(AXReader.isTrusted, "this process lacks Accessibility permission")
        guard let pid = Self.finderPID() else { throw XCTSkip("Finder is not running") }

        // The tree must be READABLE, or "not found" would be trivially true and
        // this control would assert nothing at all.
        let tree = try AXReader.readTree(pid: pid)
        XCTAssertFalse(
            tree.children.isEmpty,
            "the window read as empty, so a not-found result proves nothing")

        XCTAssertThrowsError(try AXReader.press(pid: pid, named: "\u{1F6AB}absent-\(UUID())")) {
            XCTAssertEqual(
                $0 as? AXReader.Failure, .elementNotFound,
                "a name that cannot exist must be elementNotFound, never success")
        }
    }

    private static func finderPID() -> pid_t? {
        NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.finder")
            .first(where: { !$0.isTerminated })?
            .processIdentifier
    }
}
