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
        // The hosting view is made to FILL the window, rather than being left at
        // its content's natural size.
        //
        // `NSHostingView` sizes itself to its content's ideal size and AppKit
        // then centres it, while `OracleHost` proposes the whole viewport and
        // lays out from there. A view smaller than its viewport therefore lands
        // in a different place in each channel, and the reconciler reports that
        // single uniform offset as a SEPARATE frame disagreement on every node —
        // blaming the UI for a difference between the two harnesses.
        //
        // Measured 2026-08-12 on a 260x120 viewport whose content is naturally
        // 73x50: the honest control (a scenario that lies about nothing) failed
        // with two invented disagreements — root width off by 187 pt, the label
        // off by 93.5 pt in x. The dense demo scenarios hid it because their
        // content nearly fills its viewport; the minimal lie fixtures exposed it.
        //
        // The frame goes on the SWIFTUI side, and that is not interchangeable
        // with sizing the NSView. Sizing the NSView (`autoresizingMask`, or
        // assigning `.frame`) was tried FIRST and did not work: measured
        // 2026-08-12 with a direct probe, both approaches give the hosting view
        // an NSView frame of 260x120, but `fittingSize` — which is what the
        // accessibility server publishes — reads 73x49.5 under autoresizing and
        // 260x120 under the SwiftUI frame. AX reports the CONTENT's size, not
        // the view's bounds, so only the SwiftUI-side frame changes what a
        // witness can see.
        //
        // The alignment is `.center` (the bare `.frame(width:height:)` default)
        // to MIRROR `OracleHost`, which applies exactly that modifier. Choosing
        // `.topLeading` here would be self-consistent and would disagree with
        // the channel this exists to check — measured at x=109.5 (probe) against
        // x=16 (witness) for the same label. The two harnesses must agree about
        // layout, and the probe channel is the one every baseline was recorded
        // against.
        window.contentView = NSHostingView(
            rootView: content.frame(width: size.width, height: size.height))
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
        // READABLE WITHOUT BEING VISIBLE. The window must exist and be ordered
        // front for the accessibility server to publish it (`no.md` #42/#43), so
        // it cannot simply be withheld — but nothing requires it to DRAW. At
        // alpha 0 the window server still assigns a windowNumber, still lists it
        // as on-screen, and still publishes its AX tree, while compositing
        // nothing a person can see.
        //
        // An offscreen origin was measured FIRST and REJECTED: `NSWindow`
        // constrains its frame to the visible screen, so `(-20000, -20000)` came
        // back as `(160, 800)` — fully on screen — and `setFrameOrigin` after
        // `orderFront` still leaves a 40x41 pt sliver, because AppKit clamps to
        // keep part of a titled window reachable. See `no.md` #50.
        window.alphaValue = 0
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
