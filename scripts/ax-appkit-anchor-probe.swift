// What does a PURE-APPKIT window publish to the accessibility server?
//
// CIS-C5D9A5E8 says `inspect --pid` exits 2 on an AppKit app because
// `AXReader.hostingContent(of:)` wants an `AXHostingView` (a SwiftUI construct)
// and falls back to an `AXGroup` child that an AppKit window may not have. Any
// fix has to know what the failing window ACTUALLY publishes — and nothing in
// this repo had measured it.
//
//   swiftc -O scripts/ax-appkit-anchor-probe.swift -o /tmp/ax-anchor && /tmp/ax-anchor
//   /tmp/ax-anchor <pid>     # or point it at an already-running app
//
// Reading the output:
//   - a window with an AXGroup child whose frame EQUALS the window's -> the
//     anchor works and there is no offset to correct (measured on Finder)
//   - a window with NO AXGroup child -> the CIS-C5D9A5E8 case; note what it has
//     instead, because that is what a fallback must anchor on
//   - "no window" -> this login session does not publish new GUI apps, so
//     NOTHING here is measurable. Run scripts/ax-window-publication-probe.swift
//     first; it distinguishes that state in one command.
//
// The last case is not hypothetical: measured 2026-08-17, this probe could not
// observe its own fixture at all, which is why the anchor fix was NOT written.
// See `no.md`.
import AppKit
import ApplicationServices

func string(_ element: AXUIElement, _ attribute: String) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
    else { return nil }
    return value as? String
}

/// The element's frame, or nil when it publishes no readable geometry.
///
/// nil is a real answer here, not a failure to try: it is precisely the state
/// that makes `AXReader` throw `anchorUnreadable`.
func frame(of element: AXUIElement) -> CGRect? {
    var positionValue: CFTypeRef?
    var sizeValue: CFTypeRef?
    guard
        AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue)
            == .success,
        AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue)
            == .success,
        let rawPosition = positionValue, let rawSize = sizeValue,
        CFGetTypeID(rawPosition) == AXValueGetTypeID(),
        CFGetTypeID(rawSize) == AXValueGetTypeID()
    else { return nil }
    var point = CGPoint.zero
    var size = CGSize.zero
    // swift-format-ignore: NeverForceUnwrap
    AXValueGetValue(rawPosition as! AXValue, .cgPoint, &point)  // audit-allow: type-checked above
    // swift-format-ignore: NeverForceUnwrap
    AXValueGetValue(rawSize as! AXValue, .cgSize, &size)  // audit-allow: type-checked above
    return CGRect(origin: point, size: size)
}

func describe(pid: pid_t) {
    let application = AXUIElementCreateApplication(pid)
    var raw: CFTypeRef?
    let status = AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &raw)
    guard status == .success, let windows = raw as? [AXUIElement], let window = windows.first
    else {
        print("no window (status=\(status.rawValue)) — run ax-window-publication-probe.swift")
        return
    }

    let windowFrame = frame(of: window)
    print("WINDOW  frame=\(windowFrame.map { "\($0)" } ?? "UNREADABLE")")

    var children: CFTypeRef?
    AXUIElementCopyAttributeValue(window, kAXChildrenAttribute as CFString, &children)
    let elements = (children as? [AXUIElement]) ?? []
    guard !elements.isEmpty else {
        print("  (no children — this is the CIS-C5D9A5E8 shape: nothing to anchor on)")
        return
    }
    for (index, child) in elements.enumerated() {
        let role = string(child, kAXRoleAttribute as String) ?? "?"
        let subrole = string(child, kAXSubroleAttribute as String) ?? "-"
        let childFrame = frame(of: child)
        var offset = ""
        if let windowFrame, let childFrame {
            let dy = childFrame.origin.y - windowFrame.origin.y
            // The number a "subtract the titlebar" fix would depend on. Measured
            // as 0 on Finder, which is why that fix cannot use a constant.
            offset = "  offsetY=\(dy)"
        }
        print(
            "  [\(index)] role=\(role) subrole=\(subrole) "
                + "frame=\(childFrame.map { "\($0)" } ?? "UNREADABLE")\(offset)")
    }
}

if let argument = CommandLine.arguments.dropFirst().first, let pid = pid_t(argument) {
    describe(pid: pid)
    exit(0)
}

guard !CommandLine.arguments[0].hasSuffix(".swift") else {
    // Same re-exec constraint as the sibling probe: an interpreted script cannot
    // spawn itself as a child.
    print(
        """
        This probe launches a child GUI process, so it must be COMPILED:

          swiftc -O scripts/ax-appkit-anchor-probe.swift -o /tmp/ax-anchor && /tmp/ax-anchor
        """)
    exit(2)
}

if CommandLine.arguments.contains("--child") {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let window = NSWindow(
        contentRect: NSRect(x: 200, y: 200, width: 500, height: 400),
        styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.title = "appkit-anchor-probe"
    let content = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
    let label = NSTextField(labelWithString: "Startup Manager")
    label.frame = NSRect(x: 20, y: 340, width: 200, height: 24)
    content.addSubview(label)
    // Deliberately a plain NSView content view with plain AppKit controls: this
    // is the shape PanoMac presents, and the shape SwiftUI never produces.
    window.contentView = content
    window.orderFront(nil)
    RunLoop.current.run(until: Date().addingTimeInterval(15))
    exit(0)
}

let child = Process()
child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
child.arguments = ["--child"]
do {
    try child.run()
} catch {
    // Loudly: a swallowed launch failure surfaces later as an unrelated crash at
    // terminate(), pointing at the wrong line.
    print("could not launch the child fixture: \(error)")
    exit(2)
}
Thread.sleep(forTimeInterval: 2)

print("--- a pure-AppKit window (the CIS-C5D9A5E8 subject) ---")
describe(pid: child.processIdentifier)

print("\n--- control: Finder, an established app that reads successfully ---")
if let finder = NSWorkspace.shared.runningApplications
    .first(where: { $0.bundleIdentifier == "com.apple.finder" })
{
    describe(pid: finder.processIdentifier)
} else {
    print("Finder: not running — no control available")
}

if child.isRunning { child.terminate() }
