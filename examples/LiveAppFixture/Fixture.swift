import AppKit
import SwiftUI

/// A disposable, transparent app used only by the native-input integration test.
/// Its state file records changes made by actual AppKit/SwiftUI event handlers.
@MainActor
final class FixtureState: ObservableObject {
    @Published var clicks = 0
    @Published var summary = ""
    var text = ""
    var dragEvents = 0
    var keyChords = 0
    var mouseMoves = 0
    var lastMouse = ""
    let output: URL
    let mode: String
    weak var window: NSWindow?
    weak var canvas: InputCanvas?
    weak var statusLabel: NSTextField?

    init(output: URL, mode: String) {
        self.output = output
        self.mode = mode
    }

    func persist() {
        guard let window, let canvas, let screen = window.screen ?? NSScreen.screens.first else {
            return
        }
        summary = "text=\(text);clicks=\(clicks);dragEvents=\(dragEvents);keyChords=\(keyChords)"
        statusLabel?.stringValue = summary
        let local = canvas.convert(NSPoint(x: canvas.bounds.midX, y: canvas.bounds.midY), to: nil)
        let point = window.convertPoint(toScreen: local)
        let value: [String: Any] = [
            "pid": getpid(), "mode": mode, "clicks": clicks, "text": text,
            "dragEvents": dragEvents, "keyChords": keyChords, "mouseMoves": mouseMoves,
            "x": point.x, "y": screen.frame.maxY - point.y,
            "windowID": window.windowNumber, "alpha": window.alphaValue,
            "lastMouse": lastMouse,
        ]
        do {
            try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
                .write(to: output, options: .atomic)
        } catch {
            FileHandle.standardError.write(Data("fixture state write failed\n".utf8))
            exit(2)
        }
    }
}

@MainActor
final class FixtureApplication: NSApplication {
    var fixtureState: FixtureState?
    override func sendEvent(_ event: NSEvent) {
        if [.leftMouseDown, .leftMouseUp, .leftMouseDragged, .mouseMoved].contains(event.type) {
            fixtureState?.lastMouse = "\(event.type) window:\(event.windowNumber) location:\(event.locationInWindow) cg:\(String(describing: event.cgEvent?.location)) frame:\(String(describing: event.window?.frame)) screen:\(String(describing: NSScreen.screens.first?.frame))"
            fixtureState?.persist()
        }
        super.sendEvent(event)
    }
}

@MainActor
final class InputCanvas: NSView {
    let state: FixtureState
    init(state: FixtureState) {
        self.state = state
        super.init(frame: NSRect(x: 20, y: 20, width: 200, height: 100))
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Native input canvas")
        setAccessibilityIdentifier("native-canvas")
    }
    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    // No AXPress override: `press` exercises the real event fallback.
    override func mouseDown(with event: NSEvent) {
        state.clicks += 1
        state.persist()
    }
    override func mouseDragged(with event: NSEvent) {
        state.dragEvents += 1
        state.persist()
    }
    override func mouseMoved(with event: NSEvent) {
        state.mouseMoves += 1
        state.persist()
    }
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control), event.keyCode == 6 {
            state.keyChords += 1
        } else {
            state.text += event.characters ?? ""
        }
        state.persist()
    }
}

struct FixtureView: View {
    @ObservedObject var state: FixtureState
    var body: some View {
        VStack {
            CanvasView(state: state).frame(width: 200, height: 100)
            Button("SwiftUI increment") {
                state.clicks += 1
                state.persist()
            }.accessibilityIdentifier("swiftui-increment")
            Text(state.summary).accessibilityIdentifier("native-status")
        }.frame(width: 280, height: 230)
    }
}

struct CanvasView: NSViewRepresentable {
    let state: FixtureState
    func makeNSView(context: Context) -> InputCanvas {
        let canvas = InputCanvas(state: state)
        state.canvas = canvas
        return canvas
    }
    func updateNSView(_ nsView: InputCanvas, context: Context) {}
}

@main
struct LiveAppFixture {
    @MainActor static func main() {
        guard CommandLine.arguments.count == 3 else { exit(2) }
        let state = FixtureState(
            output: URL(fileURLWithPath: CommandLine.arguments[1]),
            mode: CommandLine.arguments[2])
        let app = FixtureApplication.shared
        (app as? FixtureApplication)?.fixtureState = state
        app.setActivationPolicy(.accessory)
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 280, height: 230),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "VerdictUI Native Fixture"
        window.animationBehavior = .none
        window.hasShadow = false
        window.alphaValue = 0
        window.acceptsMouseMovedEvents = true
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 230))
        if state.mode == "swiftui" {
            let hosting = NSHostingView(rootView: FixtureView(state: state))
            hosting.frame = root.frame
            window.contentView = hosting
        } else {
            let canvas = InputCanvas(state: state)
            state.canvas = canvas
            root.addSubview(canvas)
            let status = NSTextField(labelWithString: "")
            status.frame = NSRect(x: 10, y: 125, width: 260, height: 20)
            status.setAccessibilityIdentifier("native-status")
            root.addSubview(status)
            state.statusLabel = status
            let label = NSTextField(labelWithString: "AppKit native input fixture")
            label.frame = NSRect(x: 20, y: 170, width: 240, height: 30)
            root.addSubview(label)
            window.contentView = root
        }
        state.window = window
        window.makeKeyAndOrderFront(nil)
        window.alphaValue = 0
        window.contentView?.layoutSubtreeIfNeeded()
        DispatchQueue.main.async {
            window.makeFirstResponder(state.canvas)
            state.persist()
        }
        Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { _ in
            Task { @MainActor in NSApplication.shared.terminate(nil) }
        }
        app.run()
    }
}
