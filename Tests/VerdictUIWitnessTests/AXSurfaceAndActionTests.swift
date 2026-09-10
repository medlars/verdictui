import AppKit
import XCTest

@testable import VerdictUIKernel
@testable import VerdictUIWitness

/// Reading every surface of a running app (CIS-DD4A93B7), interaction state
/// (CIS-E9FC906F), non-press actions (CIS-07CB1181) and window-only capture
/// with colour (CIS-009B4F22 / CIS-29DC2767).
///
/// Live assertions read Finder and ACT on nothing that exists: every act test
/// targets a path or an action the element does not have, so a failing test
/// cannot change the owner's desktop.
@MainActor
final class AXSurfaceAndActionTests: XCTestCase {

    private var isHeadless: Bool {
        let e = ProcessInfo.processInfo.environment
        return e["CI"] != nil || e["CODEX_CI"] != nil || e["VERDICTUI_SKIP_WITNESS"] != nil
    }

    private func finder() throws -> pid_t {
        try XCTSkipIf(isHeadless, "no window server on this host")
        try XCTSkipUnless(AXReader.isTrusted, "this process lacks Accessibility permission")
        guard
            let pid = NSRunningApplication.runningApplications(
                withBundleIdentifier: "com.apple.finder"
            ).first?.processIdentifier
        else { throw XCTSkip("Finder is not running") }
        return pid
    }

    // MARK: - surface vocabulary

    func testSurfaceArgumentsParseAndRoundTrip() {
        XCTAssertEqual(AXReader.Surface(argument: "window:2"), .window(2))
        XCTAssertEqual(AXReader.Surface(argument: "3"), .window(3))
        XCTAssertEqual(AXReader.Surface(argument: "menubar"), .menuBar)
        XCTAssertEqual(AXReader.Surface(argument: "extras"), .extrasMenuBar)
        for surface in [AXReader.Surface.window(0), .window(7), .menuBar, .extrasMenuBar] {
            XCTAssertEqual(AXReader.Surface(argument: surface.description), surface)
        }
    }

    func testMalformedSurfacesAreRefusedNotDefaulted() {
        XCTAssertNil(AXReader.Surface(argument: "window:-1"))
        XCTAssertNil(AXReader.Surface(argument: "window:x"))
        XCTAssertNil(AXReader.Surface(argument: "sidebar"))
    }

    // MARK: - action vocabulary

    func testActionVerbsMapOntoAccessibilityActions() {
        XCTAssertEqual(AXReader.Action(verb: "press", value: nil), .perform(kAXPressAction))
        XCTAssertEqual(AXReader.Action(verb: "increment", value: nil), .perform(kAXIncrementAction))
        XCTAssertEqual(AXReader.Action(verb: "show-menu", value: nil), .perform(kAXShowMenuAction))
        XCTAssertEqual(AXReader.Action(verb: "ax:AXCustom", value: nil), .perform("AXCustom"))
        XCTAssertEqual(AXReader.Action(verb: "focus", value: nil), .focus)
        XCTAssertEqual(AXReader.Action(verb: "set-value", value: "hi"), .setValue("hi"))
        XCTAssertEqual(AXReader.Action(verb: "scroll-to", value: "0.5"), .scrollTo(0.5))
        XCTAssertEqual(AXReader.Action(verb: "type", value: "abc"), .type("abc"))
    }

    /// A verb missing its value, or a scroll fraction outside 0...1, is refused
    /// rather than clamped: a clamped scroll reads as having done what was asked.
    func testIncompleteOrOutOfRangeActionsAreRefused() {
        XCTAssertNil(AXReader.Action(verb: "set-value", value: nil))
        XCTAssertNil(AXReader.Action(verb: "type", value: ""))
        XCTAssertNil(AXReader.Action(verb: "scroll-to", value: "1.5"))
        XCTAssertNil(AXReader.Action(verb: "scroll-to", value: "down"))
        XCTAssertNil(AXReader.Action(verb: "ax:", value: nil))
        XCTAssertNil(AXReader.Action(verb: "drag", value: nil), "drag would move the real pointer")
        XCTAssertNil(AXReader.Action(verb: "hover", value: nil))
    }

    func testNewFailuresDescribeThemselves() {
        XCTAssertTrue(
            AXReader.Failure.actionUnsupported(action: "AXIncrement", available: ["AXPress"])
                .description.contains("AXPress"))
        XCTAssertTrue(
            AXReader.Failure.actionUnsupported(action: "AXIncrement", available: [])
                .description.contains("no actions"))
        XCTAssertTrue(AXReader.Failure.surfaceNotFound("window:9").description.contains("window:9"))
        XCTAssertTrue(
            AXReader.Failure.attributeNotSettable("AXValue").description.contains("AXValue"))
    }

    // MARK: - live reads (Finder)

    /// The defect: only the first window was ever read, so a menu bar was
    /// unreachable and its absence silent. An all-surfaces read must include
    /// the menu bar Finder always publishes, alongside at least one window.
    func testAllSurfacesIncludeTheMenuBarNotJustTheFrontWindow() throws {
        let pid = try finder()
        let surfaces = try AXReader.readAllSurfaces(pid: pid)
        let names = surfaces.map(\.surface)
        XCTAssertTrue(names.contains("window:0"), "surfaces: \(names)")
        let menuBar = try XCTUnwrap(surfaces.first { $0.surface == "menubar" }, "\(names)")
        let tree = try XCTUnwrap(menuBar.tree, menuBar.error ?? "menubar unreadable")
        XCTAssertFalse(tree.children.isEmpty, "Finder's menu bar has items")
        XCTAssertTrue(
            tree.flattened().contains { $0.text == "Finder" || $0.text == "File" },
            "the menu bar's items are readable by name")
    }

    func testAnOutOfRangeWindowIsNamedAsMissingRatherThanReadingAnotherOne() throws {
        let pid = try finder()
        XCTAssertThrowsError(try AXReader.readTree(pid: pid, surface: .window(10_000))) { error in
            guard case .surfaceNotFound = error as? AXReader.Failure else {
                return XCTFail("expected surfaceNotFound, got \(error)")
            }
        }
    }

    /// State keys are written only in their NON-default spelling, so a present
    /// key always means something. A reader writing `enabled: true` everywhere
    /// would bloat every tree and make the key carry no information.
    func testStateKeysAppearOnlyInTheirNonDefaultSpelling() throws {
        let pid = try finder()
        let nodes = try AXReader.readTree(pid: pid, surface: .menuBar).flattened()
        for node in nodes {
            if let enabled = node.attributes[AXReader.enabledKey] {
                XCTAssertEqual(enabled, .bool(false), node.structuralPath)
            }
            if let focused = node.attributes[AXReader.focusedKey] {
                XCTAssertEqual(focused, .bool(true), node.structuralPath)
            }
            if let selected = node.attributes[AXReader.selectedKey] {
                XCTAssertEqual(selected, .bool(true), node.structuralPath)
            }
        }
    }

    func testActingOnAPathThatDoesNotResolveIsNotFound() throws {
        let pid = try finder()
        XCTAssertThrowsError(
            try AXReader.act(
                pid: pid, atPath: "root/button[9999]", surface: .menuBar, action: .focus)
        ) { error in
            XCTAssertEqual(error as? AXReader.Failure, .elementNotFound)
        }
    }

    /// An action the element does not advertise is refused BEFORE anything is
    /// sent, and the refusal names what the element does support.
    func testAnUnadvertisedActionIsRefusedWithTheAvailableVocabulary() throws {
        let pid = try finder()
        XCTAssertThrowsError(
            try AXReader.act(
                pid: pid, atPath: "root", surface: .menuBar,
                action: .perform("AXNoSuchActionForVerdictUI"))
        ) { error in
            guard case .actionUnsupported(let name, _) = error as? AXReader.Failure else {
                return XCTFail("expected actionUnsupported, got \(error)")
            }
            XCTAssertEqual(name, "AXNoSuchActionForVerdictUI")
        }
    }

    // MARK: - capture

    /// Window-only is a property of the argv: `-l <id>` must always be there.
    func testTheCaptureArgvIsAlwaysWindowOnly() {
        let argv = WindowCapture.arguments(windowID: 42, path: "/tmp/x.png")
        let flag = argv.firstIndex(of: "-l")
        XCTAssertNotNil(flag)
        XCTAssertEqual(flag.map { argv[$0 + 1] }, "42")
        XCTAssertTrue(argv.contains("-x"), "no shutter sound")
    }

    /// No window is an ERROR — never a fall back to capturing the screen.
    func testAPidWithNoWindowIsRefusedNotCapturedFullScreen() throws {
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("verdictui-nowindow-\(UUID().uuidString).png")
        XCTAssertThrowsError(try WindowCapture.capture(pid: 1, to: out)) { error in
            XCTAssertEqual(error as? WindowCapture.Failure, .noWindow(pid: 1))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
        XCTAssertThrowsError(try WindowCapture.capture(pid: getpid(), index: -1, to: out))
    }

    func testALiveWindowCaptureDecodesAtItsBackingScale() throws {
        let pid = try finder()
        guard let window = WindowCapture.windows(pid: pid).first else {
            throw XCTSkip("Finder has no on-screen window")
        }
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("verdictui-capture-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: out) }
        let shot = try WindowCapture.capture(window: window, to: out)
        XCTAssertGreaterThan(shot.scale, 0.9)
        XCTAssertEqual(Double(shot.raster.width), window.width * shot.scale, accuracy: 1)
        XCTAssertEqual(Double(shot.raster.height), window.height * shot.scale, accuracy: 1)
    }
}
