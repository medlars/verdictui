// The runner `docs/appkit.md` tells an AppKit developer to write, shipped as a
// real executable so the documented snippet is COMPILE-CHECKED by `swift build`
// rather than only asserted in prose. A doc snippet nothing builds is an
// untested claim, and it rots silently as the API moves (CTS-491C01E5).
//
// It is also the falsifiability control that page asks every adopter to build
// for themselves: a tree that always passes may mean the UI is clean or may
// mean the producer emits nothing useful, and only a DELIBERATE failure
// separates those two. `defective-screen` must FAIL and `clean-screen` must
// PASS — the PM asserts both directions, so a producer that silently stopped
// emitting findings breaks the build instead of reporting a clean product.

import AppKit
import VerdictUIAppKit

/// A title label given far less width than its string needs, which
/// `TruncationRule` must catch.
private final class DefectiveController: NSViewController {
    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 480))
        let title = NSTextField(labelWithString: "Startup Manager")
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        title.identifier = NSUserInterfaceItemIdentifier("title-label")
        title.maximumNumberOfLines = 1
        title.frame = NSRect(x: 16, y: 440, width: 60, height: 24)
        container.addSubview(title)
        view = container
    }
}

/// The same screen with a frame wide enough for the string — the positive
/// control. Without it a runner that reported FAIL unconditionally would
/// satisfy any check that looked solely at the failure path.
private final class CleanController: NSViewController {
    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 480))
        let title = NSTextField(labelWithString: "Startup Manager")
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        title.identifier = NSUserInterfaceItemIdentifier("title-label")
        title.maximumNumberOfLines = 1
        title.frame = NSRect(x: 16, y: 430, width: 400, height: 30)
        container.addSubview(title)
        view = container
    }
}

AppKitTreeRunner.launch(subjects: [
    .controller("defective-screen") { DefectiveController() },
    .controller("clean-screen") { CleanController() },
])
