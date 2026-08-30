import AppKit
import Foundation
import VerdictUIKernel

/// Spawns the windowed witness host and reads its accessibility tree.
///
/// The out-of-process design is forced, not chosen: a process cannot read its
/// own AX tree (measured -25208), so the window being verified and the reader
/// verifying it must live in different processes.
///
/// ### Why the host is launched through LaunchServices rather than fork/exec
///
/// A `Process`-spawned child does not join the GUI session the way a
/// shell-launched process does, so the window server never publishes it and
/// every read returns **-25204 (`kAXErrorAPIDisabled`)**. Measured 2026-08-12,
/// isolating one variable at a time: the SAME binary reads `err=0` launched
/// from a shell and `-25204` launched via `Process` from any parent — a plain
/// CLI parent and `xctest` behave identically, so this is not an XCTest quirk.
/// Session id and `sessionHasGraphicAccess` are identical in both cases, and
/// registration latency is not the cause either (a shell-launched host is
/// readable within 0.3 s and a spawned one never becomes readable).
///
/// Routing the launch through `open -a` on a minimal `.app` bundle fixes it:
/// LaunchServices registers the process as a GUI application, and the same
/// spawning parent then reads `err=0` with a full window tree. The bundle is
/// generated at run time rather than shipped, so there is nothing to keep in
/// sync with the executable.
public struct WitnessHostProcess {
    /// Path to the `verdictui-witness-host` executable.
    public let executable: URL
    /// How long the host may live before terminating itself.
    ///
    /// A bound rather than a convenience: a host that outlived its run would
    /// leave a window on the user's screen, which is a visible and confusing
    /// artifact rather than merely a leaked process.
    public let lifetime: TimeInterval

    public init(executable: URL, lifetime: TimeInterval = 30) {
        self.executable = executable
        self.lifetime = lifetime
    }

    /// Seconds the host is guaranteed to outlive the reader's wait by.
    ///
    /// Sized to complete a read, not as a token epsilon: the surplus over
    /// `readyTimeout` is the entire window in which `AXReader.readTree` runs.
    public static let readCompletionMargin: TimeInterval = 10

    /// The lifetime the host is actually launched with.
    ///
    /// `lifetime` and `readyTimeout` are two deadlines measured from DIFFERENT
    /// instants, and callers were setting both by hand to the same number
    /// (`LieCatchTests` used 20 and 20), which leaves zero margin by
    /// construction:
    ///
    ///   - the host's death clock starts when `run(lifetime:)` schedules its
    ///     timer, which is BEFORE `app.run()` — and `app.run()` is what
    ///     registers the process with the accessibility server;
    ///   - `awaitHost` then spends up to `readyTimeout` waiting for exactly
    ///     that registration, and the read happens only afterwards.
    ///
    /// So the later the window is published, the less host remains to read, and
    /// past a point the read lands on a host that is already terminating. That
    /// is a robustness defect independently of any one assertion: the failing
    /// run in CIS-2C757660 took 25.8s, longer than either deadline.
    ///
    /// The configured value is a FLOOR, never a ceiling — a caller asking for a
    /// long-lived host still gets one — and the result stays finite, because the
    /// bound also exists so a host can never leave a window on the user's
    /// screen.
    public static func effectiveLifetime(
        configured: TimeInterval, readyTimeout: TimeInterval
    ) -> TimeInterval {
        max(configured, readyTimeout + readCompletionMargin)
    }

    /// Render `scenario` in a real window and return its normalized AX tree.
    ///
    /// - Parameters:
    ///   - scenario: name of a scenario in the demo catalog.
    ///   - readyTimeout: how long to wait for the host to publish its window.
    /// - Returns: the tree as the accessibility server publishes it.
    /// - Throws: ``AXReader/Failure`` when the host or the read fails.
    public func readTree(
        scenario: String,
        readyTimeout: TimeInterval = 20
    ) throws -> SemanticNode {
        try withHost(scenario: scenario, readyTimeout: readyTimeout) { pid in
            try AXReader.readTree(pid: pid)
        }
    }

    /// The alpha of every window the WINDOW SERVER composites for `scenario`'s host.
    ///
    /// Readability and visibility are independent properties of the same window,
    /// and this reads the second one. It asks `CGWindowListCopyWindowInfo` — the
    /// window server's own account of what is on screen — rather than the host's
    /// own `alphaValue`, because the host is a separate process and a subject
    /// reporting on itself proves nothing.
    ///
    /// An empty result means the host published NO on-screen window, which a
    /// caller must treat as a failure rather than as "nothing is visible": an
    /// unreadable witness satisfies invisibility trivially.
    ///
    /// Read from INSIDE the host this returns nothing in either state, because a
    /// shell-launched binary is not LaunchServices-registered — the same mechanism
    /// `no.md` #43 records for AX. It only discriminates from OUTSIDE, about a pid.
    public func compositedAlphas(
        scenario: String,
        readyTimeout: TimeInterval = 20
    ) throws -> [Double] {
        try withHost(scenario: scenario, readyTimeout: readyTimeout) { pid in
            let info =
                CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
                as? [[String: Any]] ?? []
            return info
                .filter { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid }
                // `?? 1.0` is the FAIL-SAFE direction, not a neutral default: an
                // alpha that cannot be read means "assume it is drawing", so the
                // caller's assertion FAILS rather than reporting a window clean.
                // `?? 0.0` would claim invisibility from a missing measurement.
                // Deliberately unpinned by a test — `kCGWindowAlpha` is always
                // present on this path, so flipping the default is measurably
                // invisible today (verified 2026-08-14: the guard test still
                // passes at `?? 0.0`). Recorded rather than asserted, because a
                // test that cannot fail is not a test (`no.md` #12).
                .map { ($0[kCGWindowAlpha as String] as? Double) ?? 1.0 }
        }
    }

    /// Whether the host runs as a FOREGROUND application — a Dock tile, and a
    /// launch animation every time `open -n` starts one.
    ///
    /// This is the second half of "readable without being visible", and it is a
    /// genuinely different question from ``compositedAlphas``. Measured
    /// 2026-08-15: the window was `alpha=0.0` — properly transparent — while the
    /// owner still reported a flash at the bottom-left of the screen on every
    /// run. What he was seeing was the APPLICATION arriving, not its window
    /// drawing, and `open -n` starts one per scenario (~23 per suite).
    ///
    /// `NSRunningApplication.activationPolicy` is the window server's own answer
    /// about the process, asked from OUTSIDE about a pid — the host cannot be
    /// trusted to report on itself (`no.md` #50), and there is no `NSApplication`
    /// here to ask in any case.
    public func runsAsForegroundApp(
        scenario: String,
        readyTimeout: TimeInterval = 20
    ) throws -> Bool {
        try withHost(scenario: scenario, readyTimeout: readyTimeout) { pid in
            // `?? true` is the FAIL-SAFE direction, matching `compositedAlphas`:
            // a policy that cannot be read means "assume it is a foreground app",
            // so the caller's assertion FAILS rather than reporting it hidden.
            NSRunningApplication(processIdentifier: pid)
                .map { $0.activationPolicy == .regular } ?? true
        }
    }

    /// Launch a host for `scenario`, run `body` against its pid, then terminate it.
    ///
    /// Spelled once because two copies of the launch sequence are two places for
    /// the `-n` flag and the wait-for-WINDOW discipline to drift, and both are
    /// load-bearing (see `awaitHost`).
    private func withHost<T>(
        scenario: String,
        readyTimeout: TimeInterval,
        _ body: (pid_t) throws -> T
    ) throws -> T {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw AXReader.Failure.hostUnavailable("no host executable at \(executable.path)")
        }
        // ONE bundle per PROCESS, not per launch. `open -n -a <path>` asks
        // LaunchServices to REGISTER that path, and deleting the bundle
        // afterwards does not unregister it — removal and unregistration are
        // different operations. A per-launch UUID path therefore left one dead
        // registration behind every time: measured 2026-08-25, a 30-test
        // witness run left 14 registered `.app` paths of which 0 existed on
        // disk, and 240 had accumulated by 2026-08-28.
        //
        // A stable path collapses that to one registration for the whole
        // process, with no private-framework `lsregister -u` shell-out on the
        // core verification path. It is also SAFER than the per-launch bundle
        // it replaces: the bundle's contents do not depend on the scenario (the
        // scenario is an argv), so the only reason for uniqueness was a race
        // between one verification WRITING the bundle and another LAUNCHING it
        // — and writing exactly once, before any launch, removes that race
        // rather than working around it. Concurrent PROCESSES still get
        // separate paths because the path carries the pid.
        let bundle = try Self.processBundle(hostExecutable: executable)

        let launch = Process()
        launch.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        // `-n` forces a NEW instance: without it a still-terminating host from a
        // previous scenario is reused, and the reader then verifies the previous
        // scenario's window while reporting the current scenario's name.
        // NOT `lifetime`: the host must outlive the reader's wait for it, and
        // the two deadlines start from different instants. See
        // `effectiveLifetime`.
        let hostLifetime = Self.effectiveLifetime(
            configured: lifetime, readyTimeout: readyTimeout)
        launch.arguments = [
            "-n", "-a", bundle.path, "--args", scenario, String(hostLifetime),
        ]
        do {
            try launch.run()
        } catch {
            throw AXReader.Failure.hostUnavailable("could not launch host: \(error)")
        }
        launch.waitUntilExit()
        guard launch.terminationStatus == 0 else {
            throw AXReader.Failure.hostUnavailable(
                "open exited \(launch.terminationStatus) launching the host bundle")
        }

        let pid = try awaitHost(timeout: readyTimeout)
        defer { kill(pid, SIGTERM) }
        return try body(pid)
    }

    /// Wait for the launched host to appear and publish a readable window.
    ///
    /// Waits for the WINDOW rather than for the process, because the two are
    /// different events: the process exists well before the window server
    /// publishes it, and treating "process exists" as ready is the race that
    /// reports -25204 as a product defect.
    ///
    /// ### Why this is a run-loop wait and not a `Thread.sleep` poll
    ///
    /// The harness bans real sleeps (`Tests/test_verdictui_bench.py`), and
    /// rightly: the product's claim is that verification returns when the UI is
    /// quiet rather than when a guessed interval elapses. This wait is a
    /// different subject — it waits on LaunchServices registering a process with
    /// the window server, which is an OS event VerdictUI does not control — but
    /// the ban is worth honouring anyway rather than exempting, because a sleep
    /// here would be the same guess in a new place. Running the run loop yields
    /// to the OS and returns as soon as the deadline slice elapses, so the wait
    /// is bounded without a thread ever being parked on a guess.
    private func awaitHost(timeout: TimeInterval) throws -> pid_t {
        let deadline = Date().addingTimeInterval(timeout)
        var lastError: Int32 = 0
        var seenPID: pid_t?
        while Date() < deadline {
            if let pid = runningHostPID() {
                seenPID = pid
                do {
                    _ = try AXReader.readTree(pid: pid)
                    return pid
                } catch let AXReader.Failure.noWindow(code) {
                    lastError = code  // still registering; keep waiting
                }
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }
        guard seenPID != nil else {
            throw AXReader.Failure.hostUnavailable("the host process never appeared")
        }
        throw AXReader.Failure.noWindow(axError: lastError)
    }

    /// The pid of the most recently launched host, via its bundle identifier.
    ///
    /// LaunchServices detaches the process, so the `open` child's pid is not the
    /// host's and stdout is not connected — the identifier is what remains.
    private func runningHostPID() -> pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier)
            .last?
            .processIdentifier
    }

    static let bundleIdentifier = "com.vohux.verdictui.witnesshost"

    /// Guards the one-time bundle write. The runner is serial today; the lock
    /// is what keeps this correct if it ever is not.
    private static let bundleLock = NSLock()
    /// One bundle per DISTINCT host executable, keyed on its path.
    ///
    /// Keyed rather than a single slot because caching one bundle per process
    /// would hand back a wrapper around the FIRST executable to every later
    /// caller — measured while building this: three integration tests then
    /// launched an `.app` wrapping `/bin/echo` and failed with
    /// "Launchd job spawn failed", a failure that reads exactly like a broken
    /// window server.
    nonisolated(unsafe) private static var cachedBundles: [String: URL] = [:]
    /// Read by the `atexit` handler, which cannot capture context.
    nonisolated(unsafe) private static var rootToRemoveAtExit: String?

    /// The pid-scoped directory holding every bundle this process writes.
    private static var processRoot: URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(
                "verdictui-witness-\(ProcessInfo.processInfo.processIdentifier)")
    }

    /// The `.app` wrapper this process launches `executable` from, written once.
    ///
    /// Registered with LaunchServices exactly once per executable no matter how
    /// many scenarios run, and the whole tree is removed when the process exits.
    /// A crashed process leaves one directory behind rather than one per
    /// launch, which is bounded.
    static func processBundle(hostExecutable executable: URL) throws -> URL {
        bundleLock.lock()
        defer { bundleLock.unlock() }
        let key = executable.resolvingSymlinksInPath().path
        if let cached = cachedBundles[key], FileManager.default.fileExists(atPath: cached.path) {
            return cached
        }
        if rootToRemoveAtExit == nil {
            // A recycled pid could leave a stale tree from a dead process,
            // wrapping a possibly-different binary. Start clean rather than
            // trusting it — but only ONCE per process, or the second executable
            // would delete the first one's bundle out from under a live host.
            try? FileManager.default.removeItem(at: processRoot)
            rootToRemoveAtExit = processRoot.path
            atexit {
                if let root = WitnessHostProcess.rootToRemoveAtExit {
                    try? FileManager.default.removeItem(atPath: root)
                }
            }
        }
        let bundle = try makeBundle(hostExecutable: executable, slot: cachedBundles.count)
        cachedBundles[key] = bundle
        return bundle
    }

    /// Write a minimal `.app` wrapper around the host executable.
    ///
    /// Generated rather than shipped so it cannot drift from the binary, and
    /// placed under a pid-scoped directory so two concurrent verification
    /// PROCESSES do not overwrite each other's bundle mid-launch. Within a
    /// process each distinct executable is written once — see `processBundle`.
    private static func makeBundle(hostExecutable executable: URL, slot: Int) throws -> URL {
        let bundle = processRoot
            .appendingPathComponent("slot-\(slot)")
            .appendingPathComponent("VerdictUIWitnessHost.app")
        let macOS = bundle.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: executable, to: macOS.appendingPathComponent("VerdictUIWitnessHost"))
        let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
            "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>
            <key>CFBundleExecutable</key><string>VerdictUIWitnessHost</string>
            <key>CFBundleIdentifier</key><string>\(Self.bundleIdentifier)</string>
            <key>CFBundleName</key><string>VerdictUIWitnessHost</string>
            <key>CFBundlePackageType</key><string>APPL</string>
            <key>NSPrincipalClass</key><string>NSApplication</string>
            <key>LSUIElement</key><true/>
            </dict></plist>
            """
        try plist.write(
            to: bundle.appendingPathComponent("Contents/Info.plist"),
            atomically: true, encoding: .utf8)
        return bundle
    }
}
