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


    /// The window server in this login session is not publishing windows for
    /// newly-launched GUI apps, in EITHER of the two spellings that state takes.
    ///
    /// Keyed on the STATE, not on one error case, because the same environment
    /// reaches the reader two ways and this suite recognised only the first:
    ///   * `.anchorUnreadable` — a window came back and its hosting group had
    ///     no geometry;
    ///   * `.noWindow` — measured 2026-08-31, the more common shape here: the
    ///     accessibility server answers `kAXWindowsAttribute` with `.success`
    ///     and a list whose only member is the APPLICATION element, so there is
    ///     no window at all. `AXPosition`, `AXSize` and `AXFrame` are each
    ///     `kAXErrorAttributeUnsupported` on it. Positive control taken in the
    ///     same minute: Finder's app element answers all three with err=0 and
    ///     its first window is an `AXScrollArea` at (0,0,1728,1117), so the
    ///     reader works where a window exists.
    ///
    /// `.noWindow` is only reached here after `waitForReady` has exhausted its
    /// whole deadline retrying, so it means "the host ran and never published a
    /// window" — the environment state — rather than a transient first read.
    static func isUnpublishedWindowEnvironment(_ error: Error) -> Bool {
        switch error {
        case AXReader.Failure.anchorUnreadable, AXReader.Failure.noWindow:
            true
        default:
            false
        }
    }

    static let environmentSkipReason =
        "the window server is not publishing windows for new GUI apps in this login "
        + "session, so the witness cannot observe anything. This is an ENVIRONMENT "
        + "state, not a product defect — re-run in a fresh login session."

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
        } catch where Self.isUnpublishedWindowEnvironment(error) {
            // A THIRD environment state, beyond "headless" and "no grant": a login
            // session where the window server has stopped publishing windows for
            // newly-launched GUI apps.
            //
            // Measured 2026-08-12: this test passed at 17:22:55 and failed at
            // 18:04 with `Sources/VerdictUIWitness/` byte-identical at HEAD, after
            // a session's worth of launching and killing an unsigned `.app`.
            // Nothing about the product changed between the two runs.
            //
            // A red here means "this machine cannot host a window", which reads as
            // a product defect and teaches its reader to discount the suite
            // (`no.md` #15). `AXIsProcessTrusted()` cannot separate the two — it
            // stays `true` throughout (`no.md` #42) — so the discrimination has to
            // come from the read itself, which is what this catch does.
            throw XCTSkip(Self.environmentSkipReason)
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
        } catch where Self.isUnpublishedWindowEnvironment(error) {
            throw XCTSkip(Self.environmentSkipReason)
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

    /// The witness must not run as a FOREGROUND app — no Dock tile, no launch
    /// animation.
    ///
    /// This is the half `testTheWitnessWindowIsReadableWithoutBeingVisible` does
    /// not cover, and the gap was not academic: after `alphaValue = 0` shipped,
    /// the window measured `alpha=0.0` — genuinely transparent — and the owner
    /// STILL reported a flash at the bottom-left on every run, twice, across two
    /// sessions. What he saw was the APPLICATION arriving, not its window
    /// drawing, and `open -n` starts one per scenario (~23 per suite).
    ///
    /// The cause was a comment asserting that `.accessory` is "not a first-class
    /// AX citizen". Measured 2026-08-15 with two bundles differing only in the
    /// policy, each read from an external process:
    ///
    ///   `.accessory` + `LSUIElement` -> AXerr=0 windows=1, foreground procs 0
    ///   `.regular`,  no `LSUIElement` -> AXerr=0 windows=1, foreground procs 1
    ///
    /// Identical AX visibility. The claim was false, and it is what kept the
    /// flashing in place — which is why this test asserts the CONSEQUENCE rather
    /// than trusting the comment.
    ///
    /// Paired with the alpha test on purpose: an implementation that hid the app
    /// but drew the window, or drew the app but hid the window, fails exactly one
    /// of the two. Neither alone is sufficient.
    func testTheWitnessDoesNotRunAsAForegroundApp() throws {
        try XCTSkipIf(isHeadless, "no window server on this host")
        let executable = try XCTUnwrap(
            hostExecutable, "verdictui-witness-host was not built alongside the tests")
        try XCTSkipUnless(AXReader.isTrusted, "this process lacks Accessibility permission")

        let host = WitnessHostProcess(executable: executable, lifetime: 20)
        let isForeground: Bool
        do {
            isForeground = try host.runsAsForegroundApp(scenario: "demo-clean-settings")
        } catch where Self.isUnpublishedWindowEnvironment(error) {
            throw XCTSkip(Self.environmentSkipReason)
        }

        XCTAssertFalse(
            isForeground,
            "the witness host runs as a foreground app — it takes a Dock tile and animates on "
                + "launch, which is the flash the owner sees once per scenario")
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

    /// A host launch must leave NOTHING behind in the temporary directory.
    ///
    /// `makeBundle` creates a UUID-named ROOT directory and puts the `.app`
    /// inside it; the cleanup removed only the `.app`, so the root survived
    /// every launch. That is one leaked directory per scenario — about 23 per
    /// suite run — and it is not merely untidy: every one of them is an app
    /// bundle path `launchservicesd` has seen, and it was measured at 208 % CPU
    /// with 88 of these present, on a machine whose load average had climbed to
    /// 113 with no heavy job running at all.
    ///
    /// The test drives the REAL launch path rather than asserting on
    /// `makeBundle` directly: the leak is in the relationship between what
    /// `makeBundle` creates and what the cleanup removes, and a test that called
    /// `makeBundle` alone could not see the cleanup at all. `/bin/echo` is a
    /// deliberate choice — it is a genuine executable, so it passes the
    /// `isExecutableFile` guard and a bundle IS created, and it is not an app,
    /// so `open` fails afterwards. That reaches the cleanup on the error path,
    /// which is the path a crashed or rejected launch takes in production.
    func testRepeatedLaunchesReuseOneTemporaryDirectory() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
        // Count the BUNDLE directories, not the top-level witness roots. The
        // bundles now live in per-executable slots under one pid-scoped root,
        // so counting roots would read 1 whether the bundle is reused or
        // rewritten per launch — a check that cannot fail for the reason it
        // exists. Verified by mutation: restoring the per-launch path makes
        // THIS assertion red, which the root count did not.
        func witnessBundleDirectories() throws -> Set<String> {
            var found: Set<String> = []
            let roots = try FileManager.default
                .contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("verdictui-witness-") }
            for witnessRoot in roots {
                let slots =
                    (try? FileManager.default
                        .contentsOfDirectory(at: witnessRoot, includingPropertiesForKeys: nil))
                    ?? []
                for slot in slots {
                    found.insert("\(witnessRoot.lastPathComponent)/\(slot.lastPathComponent)")
                }
            }
            return found
        }
        let witnessDirectories = witnessBundleDirectories

        // SET DIFFERENCE, not a count. The temp directory is shared, so a count
        // makes this test's verdict depend on what every OTHER test is doing at
        // the same instant — it would fail for a sibling's bundle and accuse
        // this launch.
        //
        // The invariant CHANGED on 2026-08-28 and this test changed with it.
        // It used to demand ZERO new directories, which was right while each
        // launch made and destroyed its own. The bundle is now written ONCE per
        // process at a pid-scoped path, because `open -a` REGISTERS the path
        // with LaunchServices and deleting the bundle does not unregister it —
        // so a per-launch path leaked one dead registration per scenario. What
        // must hold now is that the directory count is bounded by the PROCESS,
        // not by the number of launches: the second launch must add nothing.
        let before = try witnessDirectories()
        let host = WitnessHostProcess(
            executable: URL(fileURLWithPath: "/bin/echo"), lifetime: 1)
        // The reads are EXPECTED to fail; the subject under test is what
        // survives them, not whether they succeeded.
        _ = try? host.readTree(scenario: "demo-clean-settings", readyTimeout: 1)
        let afterFirst = try witnessDirectories().subtracting(before)

        _ = try? host.readTree(scenario: "demo-clean-settings", readyTimeout: 1)
        _ = try? host.readTree(scenario: "demo-clean-settings", readyTimeout: 1)
        let afterFourth = try witnessDirectories().subtracting(before)

        XCTAssertLessThanOrEqual(
            afterFirst.count, 1,
            "one launch created \(afterFirst.count) bundle directories under \(root.path): "
                + "\(afterFirst.sorted()). The bundle must be written once per process.")
        XCTAssertEqual(
            afterFourth, afterFirst,
            "launches 2 and 3 added \(afterFourth.subtracting(afterFirst).sorted()) — the "
                + "per-process bundle is not being reused, so every launch registers a new "
                + "app-bundle path with LaunchServices and leaks it")
    }

    /// The registration leak itself, counted as REGISTRATIONS rather than
    /// directories — the mistake the previous version of this suite made.
    ///
    /// Deleting a generated bundle does NOT unregister it: measured 2026-08-25,
    /// a 30-test witness run left 14 registered witness `.app` paths of which 0
    /// existed on disk, while the directory count was correctly zero. A check
    /// that reads the wrong subject cannot fail for the reason it exists.
    func testRepeatedLaunchesDoNotRegisterANewBundlePathEachTime() throws {
        try XCTSkipIf(isHeadless, "no window server on this host")
        let lsregister =
            "/System/Library/Frameworks/CoreServices.framework/Frameworks/"
            + "LaunchServices.framework/Support/lsregister"
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: lsregister),
            "lsregister is not available at \(lsregister); registrations cannot be observed")

        func registeredWitnessPaths() throws -> Set<String> {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [
                "-c",
                "\(lsregister) -dump | grep -oE '/[^ ]*verdictui-witness-[^ ]*\\.app' | sort -u",
            ]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let text = String(decoding: data, as: UTF8.self)
            return Set(text.split(separator: "\n").map(String.init))
        }

        let host = WitnessHostProcess(
            executable: URL(fileURLWithPath: "/bin/echo"), lifetime: 1)
        _ = try? host.readTree(scenario: "demo-clean-settings", readyTimeout: 1)
        let afterFirst = try registeredWitnessPaths()

        _ = try? host.readTree(scenario: "demo-clean-settings", readyTimeout: 1)
        _ = try? host.readTree(scenario: "demo-clean-settings", readyTimeout: 1)
        _ = try? host.readTree(scenario: "demo-clean-settings", readyTimeout: 1)
        let afterFourth = try registeredWitnessPaths()

        XCTAssertTrue(
            afterFourth.subtracting(afterFirst).isEmpty,
            "three further launches registered \(afterFourth.subtracting(afterFirst).count) new "
                + "bundle path(s): \(afterFourth.subtracting(afterFirst).sorted()). Every one is "
                + "an entry LaunchServices re-validates forever, because removing a bundle does "
                + "not unregister it")
    }
}
