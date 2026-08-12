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
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw AXReader.Failure.hostUnavailable("no host executable at \(executable.path)")
        }
        let bundle = try makeBundle()
        defer { try? FileManager.default.removeItem(at: bundle) }

        let launch = Process()
        launch.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        // `-n` forces a NEW instance: without it a still-terminating host from a
        // previous scenario is reused, and the reader then verifies the previous
        // scenario's window while reporting the current scenario's name.
        launch.arguments = [
            "-n", "-a", bundle.path, "--args", scenario, String(lifetime),
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
        return try AXReader.readTree(pid: pid)
    }

    /// Wait for the launched host to appear and publish a readable window.
    ///
    /// Polls for the window rather than for the process, because the two are
    /// different events: the process exists well before the window server
    /// publishes it, and treating "process exists" as ready is the race that
    /// reports -25204 as a product defect.
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
            Thread.sleep(forTimeInterval: 0.1)
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

    /// Write a minimal `.app` wrapper around the host executable.
    ///
    /// Generated rather than shipped so it cannot drift from the binary, and
    /// placed in a unique directory so two concurrent verifications do not
    /// overwrite each other's bundle mid-launch.
    private func makeBundle() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("verdictui-witness-\(UUID().uuidString)")
        let bundle = root.appendingPathComponent("VerdictUIWitnessHost.app")
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
            </dict></plist>
            """
        try plist.write(
            to: bundle.appendingPathComponent("Contents/Info.plist"),
            atomically: true, encoding: .utf8)
        return bundle
    }
}
