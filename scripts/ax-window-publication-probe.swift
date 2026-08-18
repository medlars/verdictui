// Does this login session publish NEW GUI windows to the accessibility server?
//
// The witness channel needs one precondition that nothing else in this repo
// checks: a freshly-launched GUI process must be readable cross-process by the
// AX server. When it is not, VerdictUIWitnessTests skips 6 tests and the reason
// LOOKS like an anchor defect (both surface as `Failure.anchorUnreadable`).
// This probe settles which it is, with NO VerdictUI code in the path — so it
// cannot be confounded by the thing it is diagnosing.
//
//   swiftc -o /tmp/axprobe scripts/ax-window-publication-probe.swift
//   /tmp/axprobe            # opens a window, then reads ITSELF and a control
//
// Measured 2026-08-17 on a degraded session: fresh process -25204 / 0 windows,
// Finder 0 / 1 window with readable geometry. See `no.md`.
import AppKit
import ApplicationServices

/// Cross-process read of what `pid` publishes. This is the read the witness
/// performs, reduced to its essentials.
func read(pid: pid_t, label: String) {
    let element = AXUIElementCreateApplication(pid)
    var raw: CFTypeRef?
    let status = AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &raw)
    let windows = raw as? [AXUIElement] ?? []
    var detail = ""
    if let first = windows.first {
        var position: CFTypeRef?
        var size: CFTypeRef?
        let positionStatus = AXUIElementCopyAttributeValue(
            first, kAXPositionAttribute as CFString, &position)
        let sizeStatus = AXUIElementCopyAttributeValue(first, kAXSizeAttribute as CFString, &size)
        detail = "  geometry: position=\(positionStatus.rawValue) size=\(sizeStatus.rawValue)"
    }
    print("\(label): status=\(status.rawValue) windows=\(windows.count)\(detail)")
}

// A child process is required, not a nicety: a process cannot read its OWN
// accessibility tree — it returns -25208 regardless of session health — so a
// self-read would report "broken" on a perfectly healthy host.
if CommandLine.arguments.contains("--child") {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let window = NSWindow(
        contentRect: NSRect(x: 100, y: 100, width: 300, height: 200),
        styleMask: [.titled], backing: .buffered, defer: false)
    window.title = "ax-publication-probe"
    window.orderFront(nil)
    print("child: pid=\(ProcessInfo.processInfo.processIdentifier) NSApp.windows=\(app.windows.count)")
    // Long enough for the parent to read it several times over.
    RunLoop.current.run(until: Date().addingTimeInterval(10))
    exit(0)
}

// A probe that cannot be run the obvious way is a probe nobody re-runs, which
// defeats the point of shipping it as a script. Measured: `swift <file>` crashed
// with "-[NSConcreteTask terminate]: task not launched" — the `try?` on the
// re-exec swallowed the launch failure, and the crash surfaced 20 lines later at
// `terminate()`, pointing at the wrong line entirely.
//
// Detect by EXTENSION, not by the interpreter's name. Measured: under
// `swift <file>` argv[0] is the .swift SOURCE PATH (not the compiler, as a
// first guess assumed), so a `hasPrefix("swift")` check never fires and the
// failure surfaces later as an unhelpful "file doesn't exist" from the re-exec.
// The source path is the tell: a compiled binary never ends in `.swift`.
let selfPath = CommandLine.arguments[0]
guard !selfPath.hasSuffix(".swift") else {
    FileHandle.standardError.write(
        Data(
            """
            This probe re-execs itself to create a child GUI process, so it must be \
            COMPILED rather than interpreted:

              swiftc -O scripts/ax-window-publication-probe.swift -o /tmp/ax-probe && /tmp/ax-probe

            Run under `swift <file>`, argv[0] is this SOURCE PATH rather than an \
            executable, so the re-exec fails and nothing is measured.

            """.utf8))
    exit(2)
}

let child = Process()
child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
child.arguments = ["--child"]
do {
    try child.run()
} catch {
    // Loudly, not `try?`: a probe whose subject never started must say so rather
    // than measure nothing and report a confident reading (lesson 399).
    FileHandle.standardError.write(
        Data("could not launch the child probe process: \(error)\n".utf8))
    exit(2)
}
Thread.sleep(forTimeInterval: 2)

print("--- a freshly-launched GUI process (the witness's own case) ---")
read(pid: child.processIdentifier, label: "fresh")

print("--- control: an established app. If THIS fails, the grant is missing ---")
if let finder = NSWorkspace.shared.runningApplications
    .first(where: { $0.bundleIdentifier == "com.apple.finder" })
{
    read(pid: finder.processIdentifier, label: "Finder")
} else {
    print("Finder: not running — no control available")
}

// `isRunning` first: `terminate()` on a task that never launched raises
// NSInvalidArgumentException, which would crash the probe AFTER it printed a
// correct reading — turning a successful measurement into an apparent failure.
if child.isRunning {
    child.terminate()
}
print("""

    Reading: fresh=0-windows-with-error AND control=readable means the SESSION \
    is not publishing new windows. That is an environment state, not a defect \
    in AXReader — re-run in a fresh login session before filing anything.
    """)
