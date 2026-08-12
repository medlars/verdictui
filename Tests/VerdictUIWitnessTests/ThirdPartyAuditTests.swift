import AppKit
import XCTest

@testable import VerdictUIKernel
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
        XCTAssertLessThan(
            elapsed, .seconds(30),
            "reading \(target.name) took \(elapsed) — the walk is not effectively bounded, and "
                + "each node costs ~5 cross-process AX calls, so this grows without limit")

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
