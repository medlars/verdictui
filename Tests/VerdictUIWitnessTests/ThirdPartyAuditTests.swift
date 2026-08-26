import AppKit
import XCTest

@testable import VerdictUIKernel
@testable import VerdictUIProbe
@testable import VerdictUIWitness

/// Wave 8 exit gate: are AX-gap findings USEFUL on software VerdictUI did not
/// write?
///
/// The reconciler's accessibility half is claimed as a marketing point — the
/// same machinery that keeps the probes honest also finds every control a
/// screen-reader user cannot reach. That claim is about OTHER PEOPLE'S apps,
/// and a suite that only ever reads VerdictUI's own demo scenarios cannot
/// support it: those trees are built by a harness that knows what the reader
/// expects, so agreement is close to guaranteed by construction.
///
/// This drives ``AXReader`` against a REAL third-party application chosen at
/// run time from whatever is running, and asserts the reader survives a tree it
/// did not design for. It is a robustness gate, not a correctness one: nothing
/// here knows what Finder's window SHOULD contain, so nothing asserts it.
@MainActor
final class ThirdPartyAuditTests: XCTestCase {

    private var isHeadless: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["CI"] != nil || environment["CODEX_CI"] != nil
            || environment["VERDICTUI_SKIP_WITNESS"] != nil
    }

    /// A running GUI application to read, or `nil`.
    ///
    /// Finder first because it is always running on a desktop session, then a
    /// short list of common apps. Deliberately not a single hard-coded target:
    /// a test that requires one specific app to be open fails for the machine
    /// rather than for the code — the failure mode `no.md` #15 names.
    private func targetApplication() -> (name: String, pid: pid_t)? {
        let candidates = [
            "com.apple.finder", "com.apple.systempreferences", "com.apple.Notes",
            "com.apple.Safari", "com.googlecode.iterm2",
        ]
        for identifier in candidates {
            let running = NSRunningApplication.runningApplications(
                withBundleIdentifier: identifier)
            if let app = running.first, !app.isTerminated {
                return (app.localizedName ?? identifier, app.processIdentifier)
            }
        }
        return nil
    }

    func testTheReaderSurvivesATreeItDidNotDesignFor() throws {
        try XCTSkipIf(isHeadless, "no window server on this host")
        try XCTSkipUnless(AXReader.isTrusted, "this process lacks Accessibility permission")
        guard let target = targetApplication() else {
            throw XCTSkip("no candidate third-party application is running")
        }

        let tree: SemanticNode
        do {
            tree = try AXReader.readTree(pid: target.pid)
        } catch AXReader.Failure.noWindow, AXReader.Failure.anchorUnreadable {
            // The app is running but publishes nothing readable right now — a
            // statement about that app's current state, not about the reader.
            throw XCTSkip("\(target.name) published no readable window at this moment")
        }

        let nodes = tree.flattened()
        XCTAssertGreaterThan(
            nodes.count, 1,
            "\(target.name) produced a \(nodes.count)-node tree; a real window publishes more")

        // Every node must survive normalization with a usable identity. A node
        // with neither an id nor a structural path cannot be cited in a finding,
        // which would make any gap reported about it unactionable — lesson 209's
        // shape: a finding nobody can act on destroys the report's signal.
        for node in nodes {
            XCTAssertFalse(
                node.id.isEmpty && node.structuralPath.isEmpty,
                "a node survived normalization with no way to cite it")
        }

        // Frames must be finite. A NaN or infinite frame from a foreign tree
        // would poison every geometric rule downstream — and every comparison
        // against NaN is false, so a tolerance check would silently report
        // agreement rather than failing.
        for node in nodes {
            XCTAssertTrue(
                node.frame.x.isFinite && node.frame.y.isFinite
                    && node.frame.width.isFinite && node.frame.height.isFinite,
                "\(node.evidenceLabel) has a non-finite frame: \(node.frame)")
        }
    }

    func testTheReaderIsBoundedAgainstAHostileTree() throws {
        try XCTSkipIf(isHeadless, "no window server on this host")
        try XCTSkipUnless(AXReader.isTrusted, "this process lacks Accessibility permission")
        guard let target = targetApplication() else {
            throw XCTSkip("no candidate third-party application is running")
        }

        // An `AXUIElement` tree is a GRAPH the window server hands you, not a
        // structure this process owns: an element may reference an ancestor,
        // and the children attribute then yields a cycle. An unbounded walk
        // segfaulted the whole runner at test 15 of 669 (`no.md` #44), and the
        // filtered runs could not see it because the process died AFTER
        // printing its per-test results.
        //
        // Reading a third-party tree is where that would bite in the wild, so
        // the bound is asserted HERE rather than only against a tree we built.
        // The read is TIMED, and the budget is asserted as elapsed wall clock
        // rather than only as a node count.
        //
        // Without this, removing the node budget makes the test HANG instead of
        // failing — and a hang is indistinguishable, at the harness's exit-code
        // boundary, from a hostile environment or a stuck machine. A guard whose
        // violation cannot be told apart from an infrastructure fault teaches
        // its reader to discount it, which is the failure `no.md` #15 names.
        // Measured 2026-08-12: with the budget the read is ~2 s; without it, it
        // did not finish in 120 s. 30 s is far above the former and far below
        // the latter, so the two are separated by an order of magnitude on both
        // sides rather than by a hair.
        let started = ContinuousClock.now
        let tree: SemanticNode
        do {
            tree = try AXReader.readTree(pid: target.pid)
        } catch AXReader.Failure.noWindow, AXReader.Failure.anchorUnreadable {
            throw XCTSkip("\(target.name) published no readable window at this moment")
        }
        let elapsed = ContinuousClock.now - started

        // THE BUDGET IS ASSERTED ONLY WHERE IT CAN MEAN SOMETHING.
        //
        // 30 s stands: it was measured, and a healthy read has been seen at
        // ~2 s (2026-08-12, Finder with windows open) and at 0.043–0.090 s
        // (2026-08-25, Finder idle) while an unbounded one did not finish in
        // 120 s — so the budget clears every observed healthy read by more than
        // two orders of magnitude and still sits far below the pathological
        // case. Raising it to stop a failure would be the silencer this project
        // forbids (SE Principle 11) — the number was never wrong, the LANE was
        // missing. Note the healthy figure SPANS 50x depending on the target
        // app's window state, which is exactly why no floor can be keyed on it.
        //
        // The cost of this read is set by ANOTHER process's view hierarchy and
        // by the window server, neither of which this project controls, so a
        // single absolute sample on any machine at any load cannot separate a
        // regression from a neighbour. Measured 2026-08-25: 47.66 s at load
        // 97+, and ~2 s quiet on the same code. That failure named a cause it
        // had not established ("the walk is not effectively bounded"), and a
        // gate that misdescribes its own failure teaches its reader to discount
        // it — which is fatal here, because this is the SAFETY bound whose
        // absence SIGSEGV'd the whole runner (`no.md` #44).
        //
        // Note the lane is `cannotHoldAbsoluteWallClockBudget`, not `isActive`:
        // the failing host exported ZERO markers, so the marker lane the sibling
        // gates use would not have caught this one.
        if ConstrainedTimingEnvironment.cannotHoldAbsoluteWallClockBudget {
            let ratio = ConstrainedTimingEnvironment.oversubscription
            let load = ratio.map { String(format: "%.2fx oversubscribed", $0) } ?? "load unreadable"
            print(
                "AXREAD-BOUND: recorded \(elapsed) reading \(target.name) "
                    + "(budget 30s NOT asserted — \(load))")
        } else {
            XCTAssertLessThan(
                elapsed, .seconds(30),
                "reading \(target.name) took \(elapsed) on an UNCONTENDED host — the walk is not "
                    + "effectively bounded, and each node costs ~5 cross-process AX calls, so this "
                    + "grows without limit")
        }

        // AND A FLOOR, SO A VACUOUS READ CANNOT RENDER AS A PASS.
        //
        // XCTest emits no skip marker (`no.md` #62): `passed (0.078 seconds)` is
        // byte-identical whether the body ran or an earlier XCTSkip fired, and
        // both bound assertions below are `<=`, so they hold for a ONE-NODE
        // tree. A read that returned almost nothing therefore posts the best
        // numbers the suite has ever seen while observing nothing.
        //
        // THE FLOOR IS A NODE COUNT, NOT A DURATION, and the first attempt at
        // this got it wrong in a way worth recording. A 0.1 s floor looked
        // right against the "~2 s healthy read" this file documents from
        // 2026-08-12 — and it FAILS A WORKING READER: measured 2026-08-25,
        // five consecutive genuine reads of Finder took 0.043–0.090 s, each
        // returning a real tree that satisfied every bound. The read cost is
        // set by the target app's CURRENT WINDOW STATE (a Finder with no open
        // windows publishes a small tree), so duration measures the subject's
        // circumstances, not whether the reader ran. Keying the floor on
        // elapsed time would blame the code for the app being idle — the same
        // environment-blaming shape this test was just fixed for, inverted.
        //
        // The node count answers the actual question. It matches the sibling
        // test's `nodes.count > 1` bar, and it is asserted in BOTH lanes:
        // contention changes how LONG a read takes, never how many nodes the
        // window publishes, so this figure is load-independent in a way no
        // duration is.
        XCTAssertGreaterThan(
            tree.flattened().count, 1,
            "reading \(target.name) produced a \(tree.flattened().count)-node tree in "
                + "\(elapsed) — a real window publishes more, so the walk observed nothing "
                + "and both bound assertions below are vacuous")

        // `maximumDepth` bounds the DEPTH INDEX, and the root sits at index 0,
        // so a fully-descended tree has `maximumDepth + 1` LEVELS. Measured
        // rather than reasoned: Finder's tree came back at exactly 65 levels,
        // which is the bound working, not leaking. Asserting `<= 64` here would
        // have failed a correct reader — the off-by-one was in the test.
        XCTAssertLessThanOrEqual(
            levels(of: tree), AXReader.maximumDepth + 1,
            "the normalized tree is deeper than the documented bound, so the walk is unbounded")

        // And the breadth bound, which is the one that actually hangs a read.
        // A depth bound cannot see it: measured 2026-08-12, reading Finder with
        // depth bounded and nodes unbounded did not finish in 60 s and was
        // SIGKILLed; with the node budget the same read takes ~2 s.
        XCTAssertLessThanOrEqual(
            tree.flattened().count, AXReader.maximumNodes,
            "the reader normalized more nodes than its budget allows")
    }

    /// Number of LEVELS, where a leaf-only tree is 1.
    private func levels(of node: SemanticNode) -> Int {
        1 + (node.children.map(levels(of:)).max() ?? 0)
    }
}
