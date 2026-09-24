import Darwin
import XCTest
@testable import VerdictUIWeb

@MainActor
final class WebOpeningLifecycleTests: XCTestCase {
    private func fixture() throws -> (URL, URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("verdictui-opening-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("browser")
        try "#!/bin/sh\necho $$ > '\(root.path)/browser.pid'\nexec /bin/sleep 60\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let page = root.appendingPathComponent("page.html")
        try "<button>Ready</button>".write(to: page, atomically: true, encoding: .utf8)
        return (root, executable, page)
    }

    private func browserPID(root: URL) async throws -> pid_t {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if let raw = try? String(contentsOf: root.appendingPathComponent("browser.pid"), encoding: .utf8),
               let pid = pid_t(raw.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 { return pid }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw CocoaError(.fileReadNoSuchFile)
    }

    func testOpeningCancellationAndCloseAllAwaitTheUnpublishedBrowser() async throws {
        for cancel in [false, true] {
            let (root, executable, page) = try fixture()
            let profiles = root.appendingPathComponent("profiles")
            let manager = WebSessionManager(root: profiles, environment: ["VERDICTUI_WEB_BROWSER": executable.path])
            let opening = Task { try await manager.open(profile: "owned", url: page) }
            let child = try await browserPID(root: root)
            defer { if kill(child, 0) == 0 { kill(child, SIGKILL) } }
            XCTAssertEqual(kill(child, 0), 0, "positive control: child exists before cancellation")
            let start = ContinuousClock.now
            if cancel { opening.cancel() } else {
                let failures = await manager.closeAll()
                XCTAssertTrue(failures.isEmpty, "\(failures)")
                XCTAssertNotEqual(kill(child, 0), 0, "closeAll returned while its opening browser was alive")
            }
            do { _ = try await opening.value; XCTFail("cancelled open succeeded") }
            catch { XCTAssertTrue(error is WebBrowserError) }
            XCTAssertLessThan(start.duration(to: .now), .seconds(3), "cancellation must interrupt the discovery deadline")
            XCTAssertNotEqual(kill(child, 0), 0)
            let lock = try ProfileLock.acquire(profile: "owned", registry: ProfileRegistry(root: profiles))
            lock.release()
            await manager.closeAll()
        }
    }

    func testMCPSIGTERMAwaitsBrowserStillDiscoveringItsEndpoint() async throws {
        let (root, executable, page) = try fixture()
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let process = Process(), input = Pipe()
        process.executableURL = repository.appendingPathComponent(".build/debug/verdictui")
        process.arguments = ["mcp"]
        // This fixture owns the browser lifecycle, not a consumer build.
        process.currentDirectoryURL = root
        var environment = ProcessInfo.processInfo.environment
        environment["VERDICTUI_WEB_BROWSER"] = executable.path
        environment["VERDICTUI_WEB_PROFILE_ROOT"] = root.appendingPathComponent("profiles").path
        process.environment = environment
        process.standardInput = input; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { kill(process.processIdentifier, SIGKILL) }; try? input.fileHandleForWriting.close() }
        let request: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": ["name": "web_open", "arguments": ["profile": "owned", "url": page.absoluteString]]]
        var data = try JSONSerialization.data(withJSONObject: request)
        data.append(10)
        try input.fileHandleForWriting.write(contentsOf: data)
        let child = try await browserPID(root: root)
        defer { if kill(child, 0) == 0 { kill(child, SIGKILL) } }
        process.terminate()
        let deadline = ContinuousClock.now + .seconds(8)
        while process.isRunning, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(process.isRunning)
        if !process.isRunning { XCTAssertEqual(process.terminationStatus, 128 + SIGTERM) }
        XCTAssertNotEqual(kill(child, 0), 0, "MCP exited while its opening browser was alive")
    }
}
