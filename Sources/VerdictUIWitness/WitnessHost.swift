import AppKit
import SwiftUI
import VerdictUIKernel

/// Renders a view in a **real window** so an external reader can see it through
/// the accessibility server.
///
/// ### Why this exists next to `OracleHost` rather than inside it
///
/// `OracleHost` never attaches its hosting view to an `NSWindow`, and that is
/// deliberate: it is the product's CI story, proven by a spike showing a
/// windowless `NSHostingView` runs real layout passes under a sandbox profile
/// that denies every `com.apple.windowserver*` mach-lookup. The witness needs
/// exactly the opposite — an on-screen window is what the accessibility server
/// publishes. Merging the two would trade the CI property for the AX one, so
/// they stay separate hosts with separate constraints.
///
/// ### The one line that makes this work
///
/// `NSApplication.run()` — not `RunLoop.run(until:)`. Measured 2026-08-12: a
/// trusted, bundled process with a visible ordered-front window is still
/// invisible to an external AX reader (`-25204 kAXErrorAPIDisabled`) until the
/// real AppKit event loop runs. Pumping the runloop by hand does not complete
/// the activation that registers the process with the accessibility server.
@MainActor
public final class WitnessHost {
    private let window: NSWindow

    /// Create a window hosting `content` at `size`.
    ///
    /// - Parameters:
    ///   - content: the view to render — normally a scenario body that has
    ///     already had probes applied, so both channels describe the same views.
    ///   - size: the content size in points.
    public init<Content: View>(content: Content, size: CGSize) {
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSHostingView(rootView: content)
        window.title = "VerdictUI Witness"
    }

    /// Show the window and hand control to AppKit.
    ///
    /// Does not return until ``NSApplication/terminate(_:)`` is called. The
    /// `lifetime` timer bounds the process so a witness host can never outlive
    /// the run that spawned it and leak a window onto the user's screen — a
    /// stuck host is a visible, confusing artifact, not merely a leaked process.
    public func run(lifetime: TimeInterval) -> Never {
        let app = NSApplication.shared
        // `.regular` rather than `.accessory`: an accessory app is not a
        // first-class AX citizen, and the witness has to be readable.
        // It does NOT activate itself: `open -n -a` already launches this as a
        // GUI app, and calling `activate(ignoringOtherApps:)` on top of that
        // terminated the xctest runner when the full suite ran. The witness
        // must be VISIBLE to the accessibility server, not frontmost.
        app.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)

        // The timer fires on a nonisolated context, so the terminate hops back
        // to the main actor explicitly rather than being assumed to be there.
        Timer.scheduledTimer(withTimeInterval: lifetime, repeats: false) { _ in
            Task { @MainActor in NSApplication.shared.terminate(nil) }
        }
        app.run()  // See the type doc: this, not RunLoop.run, is what registers AX.
        // `app.run()` only returns after terminate, which exits the process.
        exit(0)
    }
}
