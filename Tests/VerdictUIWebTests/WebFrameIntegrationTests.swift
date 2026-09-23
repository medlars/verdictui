import Darwin
import Foundation
import XCTest
import VerdictUIKernel
@testable import VerdictUIWeb

final class WebFrameIntegrationTests: XCTestCase {
    private func fixturePython(environment: [String: String]) throws -> URL {
        if let configured = environment["VERDICTUI_TEST_PYTHON"] {
            guard configured.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: configured) else {
                throw WebBrowserError.invalidWebOperation(reason: "configured fixture Python is not executable: \(configured)")
            }
            return URL(fileURLWithPath: configured)
        }
        for entry in (environment["PATH"] ?? "").split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(entry)).appendingPathComponent("python3.14")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        throw WebBrowserError.invalidWebOperation(reason: "fixture requires VERDICTUI_TEST_PYTHON or python3.14 on PATH")
    }

    private func server(root: URL, environment: [String: String] = ProcessInfo.processInfo.environment) async throws -> (Process, Int) {
        let python = try fixturePython(environment: environment)
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "server", withExtension: "py", subdirectory: "Fixtures"))
        let portFile = root.appendingPathComponent("server.port")
        let outputFile = root.appendingPathComponent("server-output.log")
        try Data().write(to: outputFile)
        let output = try FileHandle(forWritingTo: outputFile)
        defer { try? output.close() }
        let process = Process()
        process.executableURL = python
        process.currentDirectoryURL = root
        process.environment = environment
        process.arguments = [fixture.path, fixture.deletingLastPathComponent().path, portFile.path]
        process.standardOutput = output; process.standardError = output
        do { try process.run() }
        catch {
            throw WebBrowserError.invalidWebOperation(reason: "fixture interpreter=\(python.path) could not launch: \(error)")
        }
        var handedOff = false
        defer {
            if !handedOff {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
            }
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if let text = try? String(contentsOf: portFile, encoding: .utf8),
               let port = Int(text) {
                handedOff = true
                return (process, port)
            }
            if !process.isRunning { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let timedOut = process.isRunning
        if process.isRunning { kill(process.processIdentifier, SIGKILL); process.waitUntilExit() }
        let reader = try FileHandle(forReadingFrom: outputFile)
        defer { try? reader.close() }
        let excerpt = String(decoding: try reader.read(upToCount: 4096) ?? Data(), as: UTF8.self)
        let outcome = timedOut ? "timed out after 5 seconds" : "exited with status \(process.terminationStatus)"
        throw WebBrowserError.invalidWebOperation(reason:
            "loopback fixture server failed to start; interpreter=\(python.path); \(outcome); output (first 4096 bytes): \(excerpt)")
    }

    func testConfiguredFixtureInterpreterReportsExitAndBoundedOutput() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let interpreter = root.appendingPathComponent("configured-python")
        try ("#!/bin/sh\nprintf 'fixture-startup-diagnostic\\n' >&2\nprintf '" + String(repeating: "x", count: 8192)
            + "' >&2\nexit 73\n").write(to: interpreter, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: interpreter.path)
        var environment = ProcessInfo.processInfo.environment
        environment["VERDICTUI_TEST_PYTHON"] = interpreter.path
        do {
            let (process, _) = try await server(root: root, environment: environment)
            if process.isRunning { kill(process.processIdentifier, SIGKILL); process.waitUntilExit() }
            XCTFail("the configured interpreter failure must not fall back to another Python")
        } catch {
            let message = String(describing: error)
            XCTAssertTrue(message.contains(interpreter.path), message)
            XCTAssertTrue(message.contains("exited with status 73"), message)
            XCTAssertTrue(message.contains("fixture-startup-diagnostic"), message)
            XCTAssertLessThan(message.utf8.count, 5000, "startup diagnostics must remain bounded")
        }
    }

    func testFixtureInterpreterUsesPATHAndRefusesInvalidConfiguration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let interpreter = root.appendingPathComponent("python3.14")
        try "#!/bin/sh\nexit 0\n".write(to: interpreter, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: interpreter.path)
        XCTAssertEqual(try fixturePython(environment: ["PATH": "/missing:\(root.path)"]), interpreter)
        XCTAssertThrowsError(try fixturePython(environment: ["PATH": root.path, "VERDICTUI_TEST_PYTHON": "/missing/python"]))
        XCTAssertThrowsError(try fixturePython(environment: ["PATH": ""]))
    }

    func testHiddenSameAndCrossOriginFramesPreserveMainPageAndBecomeActionableWhenShown() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vui-hidden-frame-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (server, port) = try await server(root: root)
        defer { if server.isRunning { kill(server.processIdentifier, SIGKILL); server.waitUntilExit() } }
        let manager = WebSessionManager(root: root.appendingPathComponent("profiles"), environment: [:])
        do {
            for route in ["hidden-same", "hidden-cross"] {
                _ = try await manager.open(profile: "frames", url: XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/\(route)")))
                let tree = try await manager.render(profile: "frames")
                let owner = try XCTUnwrap(tree.flattened().first { $0.attributes["web.id"] == .string("child") })
                XCTAssertFalse(owner.isVisible)
                XCTAssertTrue(owner.frame.isEmpty)
                XCTAssertTrue(owner.flattened().allSatisfy { !$0.isVisible })
                let main = try await manager.verify(profile: "frames", expectText: "Main frame")
                XCTAssertEqual(main.status, .pass, "\(route): \(main.findings)")
                let hidden = try await manager.verify(profile: "frames", expectText: "Save task")
                XCTAssertEqual(hidden.status, .fail, "hidden child text must not satisfy the task outcome")
                XCTAssertTrue(hidden.findings.contains { $0.rule == "web-expectation" })
                let show = try XCTUnwrap(tree.flattened().first { $0.attributes["web.id"] == .string("show") })
                let shown = try await manager.act(profile: "frames", action: .click(nodeID: show.id), expectText: "Save task")
                XCTAssertEqual(shown.status, .pass, "\(route): \(shown.findings)")
                let updated = try await manager.render(profile: "frames")
                let visibleOwner = try XCTUnwrap(updated.flattened().first { $0.attributes["web.id"] == .string("child") })
                XCTAssertTrue(visibleOwner.isVisible)
                let button = try XCTUnwrap(updated.flattened().first { $0.attributes["web.id"] == .string("save") })
                XCTAssertTrue(button.isVisible)
                XCTAssertEqual(button.frame.x, visibleOwner.frame.x + 3 + 24, accuracy: 0.5)
                let complete = try await manager.act(profile: "frames", action: .click(nodeID: button.id), expectText: "Task complete")
                XCTAssertEqual(complete.status, .pass, "\(route): \(complete.findings)")
            }
            await manager.closeAll()
        } catch { await manager.closeAll(); throw error }
    }

    func testSameAndCrossOriginFramesRenderAndActWithCorrectRootCoordinates() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vui-frame-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (server, port) = try await server(root: root)
        defer { if server.isRunning { kill(server.processIdentifier, SIGKILL); server.waitUntilExit() } }
        let manager = WebSessionManager(root: root.appendingPathComponent("profiles"), environment: [:])
        do {
            for route in ["same", "cross"] {
                let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/\(route)"))
                _ = try await manager.open(profile: "frames", url: url)
                let tree = try await manager.render(profile: "frames")
                let owner = try XCTUnwrap(tree.flattened().first { $0.attributes["web.id"] == .string("child") })
                let button = try XCTUnwrap(tree.flattened().first { $0.attributes["web.id"] == .string("save") })
                XCTAssertEqual(button.frame.x, owner.frame.x + 3 + 24, accuracy: 0.5)
                XCTAssertEqual(button.frame.y, owner.frame.y + 3 + 66, accuracy: 0.5)
                XCTAssertNotEqual(button.attributes["web.frame"], owner.attributes["web.frame"])
                let textField = try XCTUnwrap(tree.flattened().first { $0.attributes["web.id"] == .string("name") })
                let typed = try await manager.act(profile: "frames", action: .type(nodeID: textField.id, text: "frame text"))
                XCTAssertFalse(String(decoding: try JSONEncoder().encode(typed), as: UTF8.self).contains("frame text"))
                let report = try await manager.act(profile: "frames", action: .click(nodeID: button.id), expectText: "Task complete")
                XCTAssertEqual(report.status, .pass, "\(route): \(report.findings)")
            }
            _ = try await manager.open(profile: "frames", url: XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/network")))
            let completed = try await manager.verify(profile: "frames", expectText: "Network task complete")
            XCTAssertEqual(completed.status, .pass)
            await manager.closeAll()
        } catch { await manager.closeAll(); throw error }
    }
}
