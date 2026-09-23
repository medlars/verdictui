import AppKit
import XCTest

@testable import VerdictUIWitness

/// Explicit live lane: creates only its own transparent fixture app. An opted-in
/// run fails if permission or AX is unavailable; it never changes an owner's app.
@MainActor
final class NativeInputIntegrationTests: XCTestCase {
    private struct State: Decodable {
        let pid: pid_t
        let clicks: Int
        let text: String
        let dragEvents: Int
        let keyChords: Int
        let mouseMoves: Int
        let x: Double
        let y: Double
        let windowID: Int
        let alpha: Double
        let lastMouse: String
    }

    func testAppKitReceivesInputWithoutMovingTheCursorOrTakingFocus() async throws {
        try await exercise(mode: "appkit")
    }

    func testSwiftUIReceivesTheSameNativeDriverWithoutVisibleWindows() async throws {
        try await exercise(mode: "swiftui")
    }

    private func exercise(mode: String) async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["VERDICTUI_NATIVE_INTEGRATION"] == "1",
            "native fixture requires explicit VERDICTUI_NATIVE_INTEGRATION=1")
        guard CGPreflightPostEventAccess() else { throw NativeInput.Failure.permissionDenied }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("verdictui-native-\(UUID().uuidString)")
        let bundle = directory.appendingPathComponent("LiveAppFixture.app")
        let contents = bundle.appendingPathComponent("Contents")
        let binary = contents.appendingPathComponent("MacOS/LiveAppFixture")
        let output = directory.appendingPathComponent("state.json")
        try FileManager.default.createDirectory(
            at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let plist: [String: Any] = [
            "CFBundleExecutable": "LiveAppFixture", "CFBundlePackageType": "APPL",
            "CFBundleIdentifier": "com.vohux.verdictui.native-fixture.\(UUID().uuidString)",
            "LSUIElement": true,
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        compiler.arguments = [
            "swiftc", "-parse-as-library", "-warnings-as-errors", "-strict-concurrency=complete",
            root.appendingPathComponent("examples/LiveAppFixture/Fixture.swift").path,
            "-o", binary.path,
        ]
        try compiler.run()
        compiler.waitUntilExit()
        XCTAssertEqual(compiler.terminationStatus, 0, "native fixture must compile")
        guard compiler.terminationStatus == 0 else { return }
        let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let launcher = Process()
        launcher.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        launcher.arguments = ["-gj", "-n", "-a", bundle.path, "--args", output.path, mode]
        try launcher.run()
        launcher.waitUntilExit()
        XCTAssertEqual(launcher.terminationStatus, 0)
        let initial = try await awaitState(output) { _ in true }
        defer { kill(initial.pid, SIGTERM) }
        XCTAssertEqual(initial.alpha, 0)
        try await Task.sleep(for: .milliseconds(300))
        let rows = (CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]]) ?? []
        let ownRows = rows.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == initial.pid }
        XCTAssertFalse(ownRows.isEmpty, "positive control: the fixture really has a window")
        let invisible = ownRows.allSatisfy {
            ($0[kCGWindowAlpha as String] as? Double) == 0
                || ($0[kCGWindowIsOnscreen as String] as? Bool) == false
        }
        guard invisible else {
            XCTFail("fixture windows must be transparent or offscreen: \(ownRows)")
            return
        }
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, foreground)

        let input = NativeInput()
        let point = try NativeInput.Point(x: initial.x, y: initial.y)
        try assertCursorUnchanged { try input.type("Hello🦉", to: initial.pid) }
        _ = try await awaitState(output) { $0.text == "Hello🦉" }
        try assertCursorUnchanged { try input.key(.init("control+z"), to: initial.pid) }
        _ = try await awaitState(output) { $0.keyChords == 1 }
        try assertCursorUnchanged { try input.click(at: point, to: initial.pid) }
        _ = try await awaitState(output) { $0.clicks == 1 }
        let destination = try NativeInput.Point(x: point.x + 30, y: point.y + 10)
        try assertCursorUnchanged { try input.drag(from: point, to: destination, pid: initial.pid) }
        _ = try await awaitState(output) { $0.dragEvents > 0 && $0.clicks == 2 }

        // The AX-selected path reaches the SAME driver. A successful post alone
        // would not satisfy these assertions; the app must change its state.
        let tree = try AXReader.readTree(pid: initial.pid)
        let canvas = try XCTUnwrap(tree.flattened().first { $0.text == "Native input canvas" })
        try assertCursorUnchanged {
            try AXReader.act(pid: initial.pid, atPath: canvas.structuralPath, action: .click)
        }
        _ = try await awaitState(output) { $0.clicks == 3 }
        try assertCursorUnchanged {
            try AXReader.act(pid: initial.pid, atPath: canvas.structuralPath, action: .type("!"))
        }
        _ = try await awaitState(output) { $0.text == "Hello🦉!" }
        try assertCursorUnchanged {
            try AXReader.act(pid: initial.pid, atPath: canvas.structuralPath, action: .key(.init("control+z")))
        }
        _ = try await awaitState(output) { $0.keyChords == 2 }
        try assertCursorUnchanged {
            try AXReader.act(pid: initial.pid, atPath: canvas.structuralPath, action: .perform(kAXPressAction))
        }
        _ = try await awaitState(output) { $0.clicks == 4 }
        try assertCursorUnchanged {
            try AXReader.act(pid: initial.pid, atPath: canvas.structuralPath, action: .hover)
        }
        _ = try await awaitState(output) { $0.mouseMoves > 0 }
        if mode == "swiftui" {
            let button = try XCTUnwrap(tree.flattened().first { $0.text == "SwiftUI increment" })
            try AXReader.act(
                pid: initial.pid, atPath: button.structuralPath,
                action: .perform(kAXPressAction))
            _ = try await awaitState(output) { $0.clicks == 5 }
        }
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, foreground)
    }

    private func assertCursorUnchanged(_ action: () throws -> Void) throws {
        let before = try XCTUnwrap(CGEvent(source: nil)?.location)
        try action()
        let after = try XCTUnwrap(CGEvent(source: nil)?.location)
        XCTAssertEqual(after, before, "targeted input must never move the owner's pointer")
    }

    private func awaitState(_ output: URL, until predicate: (State) -> Bool) async throws -> State {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        var latest: State?
        while ContinuousClock.now < deadline {
            if let data = try? Data(contentsOf: output),
                let state = try? JSONDecoder().decode(State.self, from: data)
            {
                latest = state
                if predicate(state) { return state }
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NSError(
            domain: "VerdictUINativeFixture", code: 1,
            userInfo: [NSLocalizedDescriptionKey:
                "fixture did not reach the requested state (latest: \(String(describing: latest)))"])
    }
}
