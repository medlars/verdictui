import XCTest

@testable import VerdictUIKernel
@testable import VerdictUIWitness

/// End-to-end tests that spawn the REAL witness host binary and read its
/// accessibility tree.
///
/// These exist because a library test cannot see an artifact that refuses to
/// work (`no.md` #32, #34, #37). Every layer below this one — the role table,
/// the coordinate arithmetic, the reconciler — is a pure function over values
/// someone chose. Only running the binary asks whether the window server
/// actually publishes what the reader expects.
///
/// They are skipped rather than failed where the environment cannot host a
/// window (a headless CI runner, an untrusted process), because a red that
/// means "this machine has no window server" teaches its reader to discount the
/// suite. The skip is LOUD: it names which precondition was unmet.
final class WitnessIntegrationTests: XCTestCase {

    /// The built host binary, alongside the test bundle.
    private var hostExecutable: URL? {
        let bundle = Bundle(for: type(of: self)).bundleURL.deletingLastPathComponent()
        let candidate = bundle.appendingPathComponent("verdictui-witness-host")
        return FileManager.default.isExecutableFile(atPath: candidate.path) ? candidate : nil
    }

    /// True where a window server is unavailable — the same shape as
    /// `ConstrainedTimingEnvironment`, and for the same reason: a check that
    /// cannot observe its subject must skip, never pass and never fail.
    private var isHeadless: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["CI"] != nil || environment["CODEX_CI"] != nil
            || environment["VERDICTUI_SKIP_WITNESS"] != nil
    }

    func testTheHostPublishesATreeThroughTheAccessibilityServer() throws {
        try XCTSkipIf(isHeadless, "no window server on this host")
        let executable = try XCTUnwrap(
            hostExecutable, "verdictui-witness-host was not built alongside the tests")
        try XCTSkipUnless(
            AXReader.isTrusted,
            "this process lacks Accessibility permission; grant it to the terminal running tests")

        let host = WitnessHostProcess(executable: executable, lifetime: 20)
        let tree: SemanticNode
        do {
            tree = try host.readTree(scenario: "demo-clean-settings")
        } catch AXReader.Failure.anchorUnreadable {
            // A THIRD environment state, beyond "headless" and "no grant", and
            // the one this suite could not previously distinguish: a login
            // session where the window server has stopped publishing windows
            // for newly-launched GUI apps. Every host then reports zero windows
            // and the anchor read fails.
            //
            // Measured 2026-08-12: this test passed at 17:22:55 and failed at
            // 18:04 with `Sources/VerdictUIWitness/` byte-identical at HEAD,
            // after a session's worth of launching and killing an unsigned
            // `.app`. Nothing about the product changed between the two runs.
            //
            // A red here means "this machine cannot host a window", which reads
            // as a product defect and teaches its reader to discount the suite
            // (`no.md` #15). `AXIsProcessTrusted()` cannot separate the two —
            // it stays `true` throughout (`no.md` #42) — so the discrimination
            // has to come from the read itself, which is what this catch does.
            throw XCTSkip(
                "the window server is not publishing windows for new GUI apps in this login "
                    + "session, so the witness cannot observe anything. This is an ENVIRONMENT "
                    + "state, not a product defect — re-run in a fresh login session.")
        }

        // The tree must be POPULATED. An empty tree is what a witness reports
        // when it read the wrong process, anchored on the wrong element, or
        // raced the window — and every one of those is indistinguishable from a
        // scenario that renders nothing unless something asserts otherwise.
        let nodes = tree.flattened()
        XCTAssertGreaterThan(
            nodes.count, 1,
            "the witness read a tree with \(nodes.count) node(s); a real window publishes more")

        // Something text-bearing must have survived normalization. If text
        // extraction regressed to reading one attribute, the tree still has the
        // right SHAPE and loses every label — a populated-looking tree that says
        // nothing, which is the failure this asserts against.
        XCTAssertTrue(
            nodes.contains { $0.text?.isEmpty == false },
            "no node carried text; AXValue/AXDescription extraction is not working")

        // Frames must be root-relative, not screen-relative. A screen-anchored
        // tree has origins in the hundreds and would disagree with the probe
        // channel on every node at once.
        let origins = nodes.compactMap { $0.frame.x }
        XCTAssertLessThan(
            origins.min() ?? .greatestFiniteMagnitude, 100,
            "frames look screen-relative; the hosting-group origin was not subtracted")
    }

    func testAReadAgainstADeadProcessFailsRatherThanReturningAnEmptyTree() throws {
        try XCTSkipUnless(AXReader.isTrusted, "this process lacks Accessibility permission")

        // pid 1 (launchd) exists but publishes no accessibility window. The
        // read must FAIL: returning an empty tree here would let a broken
        // witness report "no disagreements" forever, which is a PASS produced by
        // reading nothing at all.
        XCTAssertThrowsError(try AXReader.readTree(pid: 1)) { error in
            guard case AXReader.Failure.noWindow = error else {
                return XCTFail("expected .noWindow, got \(error)")
            }
        }
    }

    /// The witness window must be READABLE without being VISIBLE.
    ///
    /// The two are independent properties and nothing before this test asserted
    /// the second one. `no.md` #42/#43 establish that the window must exist and
    /// be ordered front for the accessibility server to publish it, so the window
    /// is real by necessity — and the owner reported it flashing at the
    /// bottom-left of the screen during every run (CTS-75914181).
    ///
    /// ### Why this reads the window server rather than the host's own `alphaValue`
    ///
    /// The host is a SEPARATE PROCESS, so there is no `NSWindow` here to ask, and
    /// asking the host to report on itself would be the subject grading its own
    /// homework. `CGWindowListCopyWindowInfo` is the window server's own answer
    /// about what is composited on screen.
    ///
    /// The instrument was verified in BOTH directions before this assertion was
    /// written (`no.md` #47). Against the unfixed host, read from OUTSIDE about
    /// its pid, it reports one entry at `alpha=1.0` with bounds
    /// `X=0 Y=784 360x292` — measured 2026-08-14, which is the bottom-left flash
    /// the owner saw on a 1728x1117 display. Read from INSIDE the host it reports
    /// nothing in either state, because a shell-launched binary is not
    /// LaunchServices-registered; that is the same mechanism `no.md` #43 records
    /// for AX, and it is why this must be read from the outside about a pid.
    ///
    /// A far-offscreen origin was measured FIRST and rejected: `NSWindow` clamps
    /// its frame to the visible screen, so `origin: (-20000, -20000)` came back as
    /// `(160, 800)` — fully on screen. See `no.md` #50.
    func testTheWitnessWindowIsReadableWithoutBeingVisible() throws {
        try XCTSkipIf(isHeadless, "no window server on this host")
        let executable = try XCTUnwrap(
            hostExecutable, "verdictui-witness-host was not built alongside the tests")
        try XCTSkipUnless(AXReader.isTrusted, "this process lacks Accessibility permission")

        let host = WitnessHostProcess(executable: executable, lifetime: 20)
        let composited: [Double]
        do {
            composited = try host.compositedAlphas(scenario: "demo-clean-settings")
        } catch AXReader.Failure.anchorUnreadable {
            throw XCTSkip("this login session's window server is not publishing new windows")
        }

        // The window must EXIST. A host publishing no window at all would satisfy
        // "nothing is visible" while being precisely the unreadable state the rest
        // of this suite exists to catch — so absence is a failure, not a pass.
        XCTAssertFalse(
            composited.isEmpty,
            "the host published no on-screen window, so the AX server cannot read it")
        for alpha in composited {
            XCTAssertEqual(
                alpha, 0, accuracy: 0.001,
                "the witness window composites at alpha \(alpha) — it flashes on the owner's screen")
        }
    }

    func testAMissingHostBinaryIsReportedAsHostUnavailable() {
        let host = WitnessHostProcess(
            executable: URL(fileURLWithPath: "/nonexistent/verdictui-witness-host"),
            lifetime: 2
        )
        XCTAssertThrowsError(try host.readTree(scenario: "demo-clean-settings")) { error in
            guard case AXReader.Failure.hostUnavailable = error else {
                return XCTFail("expected .hostUnavailable, got \(error)")
            }
        }
    }
}
