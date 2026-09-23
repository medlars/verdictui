import Darwin
import Foundation
import XCTest
import VerdictUIKernel
@testable import VerdictUIWeb

final class WebFrameIntegrationTests: XCTestCase {
    /// The callback is installed before launch so even an immediate exit is
    /// observed. Async tests must never enter Process.waitUntilExit's run loop.
    private final class FixtureProcess: @unchecked Sendable {
        private final class ExitObservation: @unchecked Sendable {
            private let lock = NSLock()
            private var value: Int32?
            func record(_ status: Int32) {
                lock.lock(); defer { lock.unlock() }
                value = status
            }
            func status() -> Int32? {
                lock.lock(); defer { lock.unlock() }
                return value
            }
        }
        let process: Process
        private let observation = ExitObservation()
        var exitStatus: Int32? { observation.status() }
        init(_ process: Process) {
            self.process = process
            let observation = observation
            process.terminationHandler = { child in observation.record(child.terminationStatus) }
        }
        func waitForExit(timeout: Duration = .seconds(5)) async -> Int32? {
            let observation = observation
            // Cleanup must still finish when the test task has been cancelled.
            // This detached observer is bounded and always awaited by its owner.
            return await Task.detached {
                let deadline = ContinuousClock.now + timeout
                while ContinuousClock.now < deadline {
                    if let status = observation.status() { return status }
                    try? await Task.sleep(for: .milliseconds(10))
                }
                return observation.status()
            }.value
        }
        @discardableResult
        func stop() async throws -> Int32 {
            if let status = exitStatus { return status }
            if process.isRunning, kill(process.processIdentifier, SIGKILL) != 0, errno != ESRCH {
                throw WebBrowserError.invalidWebOperation(reason: "fixture termination failed: errno \(errno)")
            }
            guard let status = await waitForExit() else {
                throw WebBrowserError.invalidWebOperation(reason: "fixture termination was not observed within 5 seconds")
            }
            return status
        }
    }
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

    private func server(root: URL, environment: [String: String] = ProcessInfo.processInfo.environment) async throws -> (FixtureProcess, Int) {
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
        let fixtureProcess = FixtureProcess(process)
        do { try process.run() }
        catch {
            throw WebBrowserError.invalidWebOperation(reason: "fixture interpreter=\(python.path) could not launch: \(error)")
        }
        do {
            let deadline = ContinuousClock.now + .seconds(5)
            while ContinuousClock.now < deadline {
                if let text = try? String(contentsOf: portFile, encoding: .utf8),
                   let port = Int(text) {
                    return (fixtureProcess, port)
                }
                if fixtureProcess.exitStatus != nil { break }
                try await Task.sleep(for: .milliseconds(25))
            }
            let timedOut = fixtureProcess.exitStatus == nil
            let status = try await fixtureProcess.stop()
            let reader = try FileHandle(forReadingFrom: outputFile)
            defer { try? reader.close() }
            let excerpt = String(decoding: try reader.read(upToCount: 4096) ?? Data(), as: UTF8.self)
            let outcome = timedOut ? "timed out after 5 seconds" : "exited with status \(status)"
            throw WebBrowserError.invalidWebOperation(reason:
                "loopback fixture server failed to start; interpreter=\(python.path); \(outcome); output (first 4096 bytes): \(excerpt)")
        } catch {
            try await fixtureProcess.stop()
            throw error
        }
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
            try await process.stop()
            XCTFail("the configured interpreter failure must not fall back to another Python")
        } catch {
            let message = String(describing: error)
            XCTAssertTrue(message.contains(interpreter.path), message)
            XCTAssertTrue(message.contains("exited with status 73"), message)
            XCTAssertTrue(message.contains("fixture-startup-diagnostic"), message)
            XCTAssertLessThan(message.utf8.count, 5000, "startup diagnostics must remain bounded")
        }
    }

    func testFixtureExitObservationHandlesFastExitLateWaitAndCancelledCleanup() async throws {
        for _ in 0..<20 {
            let child = Process()
            child.executableURL = URL(fileURLWithPath: "/bin/sh")
            child.arguments = ["-c", "exit 73"]
            let fixture = FixtureProcess(child)
            try child.run()
            let firstExit = await fixture.waitForExit()
            XCTAssertEqual(firstExit, 73)
            // A second waiter begins after Foundation has already reaped it.
            let lateExit = await fixture.waitForExit()
            XCTAssertEqual(lateExit, 73)
            let stoppedExit = try await fixture.stop()
            XCTAssertEqual(stoppedExit, 73)
            XCTAssertEqual(kill(child.processIdentifier, 0), -1)
            XCTAssertEqual(errno, ESRCH)
        }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sh")
        child.arguments = ["-c", "exec /bin/sleep 30"]
        let fixture = FixtureProcess(child)
        try child.run()
        let cleanup = Task { try await fixture.stop() }
        cleanup.cancel()
        let killedExit = try await cleanup.value
        XCTAssertEqual(killedExit, SIGKILL)
        XCTAssertEqual(kill(child.processIdentifier, 0), -1)
        XCTAssertEqual(errno, ESRCH)
        let unlaunched = FixtureProcess(Process())
        let missingExit = await unlaunched.waitForExit(timeout: .milliseconds(20))
        XCTAssertNil(missingExit)
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
        } catch {
            await manager.closeAll()
            try await server.stop()
            throw error
        }
        await manager.closeAll()
        try await server.stop()
    }

    func testSameAndCrossOriginFramesRenderAndActWithCorrectRootCoordinates() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vui-frame-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (server, port) = try await server(root: root)
        XCTAssertNil(server.exitStatus, "fixture must remain alive when startup hands ownership to its caller")
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
        } catch {
            await manager.closeAll()
            try await server.stop()
            throw error
        }
        await manager.closeAll()
        try await server.stop()
    }
    func testLongDocumentsNestedPanelsAndFramesRemainScrollableAndActionable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vui-scroll-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (server, port) = try await server(root: root)
        let manager = WebSessionManager(root: root.appendingPathComponent("profiles"), environment: [:])
        var phase = "starting"
        do {
            for route in ["long", "nested", "transformed", "long-same", "long-cross"] {
                phase = route + " open"
                _ = try await manager.open(profile: "scroll", url: XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/\(route)")))
                phase = route + " verify"
                let report = try await manager.verify(profile: "scroll", expectText: "Run task")
                XCTAssertEqual(report.status, .pass, "\(route) before: \(report.findings)")
                let tree = try XCTUnwrap(report.tree)
                let bottom = try XCTUnwrap(tree.flattened().first { $0.attributes["web.id"] == .string("bottom") })
                XCTAssertTrue(bottom.isVisible)
                XCTAssertGreaterThan(bottom.frame.y, tree.frame.height)
                phase = route + " click"
                let complete = try await manager.act(profile: "scroll", action: .click(nodeID: bottom.id), expectText: "Completed")
                XCTAssertEqual(complete.status, .pass, "\(route) after: \(complete.findings)")
                let updated = try XCTUnwrap(complete.tree?.flattened().first { $0.id == bottom.id })
                XCTAssertLessThan(updated.frame.y, tree.frame.height, "trusted click must actually scroll before dispatch")
                XCTAssertEqual(complete.tree?.frame, tree.frame)
                let again = try await manager.verify(profile: "scroll", expectText: "Completed")
                XCTAssertEqual(again.status, .pass, "\(route) after nonzero scroll: \(again.findings)")
            }
            for (route, rule, domIDs) in [("displaced", "offscreen", ["negative", "fixed"]), ("clipped", "clipped-content", ["clipped"])] {
                phase = route + " open"
                _ = try await manager.open(profile: "scroll", url: XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/\(route)")))
                phase = route + " verify"
                let report = try await manager.verify(profile: "scroll")
                XCTAssertEqual(report.status, .fail)
                for domID in domIDs {
                    let node = try XCTUnwrap(report.tree?.flattened().first { $0.attributes["web.id"] == .string(domID) })
                    XCTAssertTrue(report.findings.contains { $0.rule == rule && $0.nodeID == node.id }, "\(route)/\(domID): \(report.findings)")
                }
            }
            _ = try await manager.open(profile: "scroll", url: XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/skip")))
            let hidden = try await manager.verify(profile: "scroll")
            XCTAssertEqual(hidden.status, .pass, "\(hidden.findings)")
            let skip = try XCTUnwrap(hidden.tree?.flattened().first { $0.attributes["web.id"] == .string("skip") })
            XCTAssertTrue(skip.flattened().allSatisfy { !$0.isVisible })
            let revealed = try await manager.act(profile: "scroll", action: .key(nodeID: nil, key: "Tab", modifiers: []), expectText: "Skip to content")
            XCTAssertEqual(revealed.status, .pass, "\(revealed.findings)")
            XCTAssertTrue(try XCTUnwrap(revealed.tree?.flattened().first { $0.id == skip.id }).isVisible)
            let clicked = try await manager.act(profile: "scroll", action: .click(nodeID: skip.id), expectText: "Visible content")
            XCTAssertEqual(clicked.status, .pass, "\(clicked.findings)")
            for route in ["typography", "typography-overlap"] {
                phase = route + " verify"
                _ = try await manager.open(profile: "scroll", url: XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/\(route)")))
                let report = try await manager.verify(profile: "scroll")
                if route == "typography" {
                    XCTAssertEqual(report.status, .pass, "\(report.findings)")
                } else {
                    XCTAssertEqual(report.status, .fail)
                    XCTAssertTrue(report.findings.contains { $0.rule == "sibling-overlap" || $0.rule == "content-overlap" })
                    let evidence = Set(try XCTUnwrap(report.tree).flattened().map { $0.id.isEmpty ? $0.structuralPath : $0.id })
                    XCTAssertTrue(report.findings.allSatisfy { evidence.contains($0.nodeID) })
                    XCTAssertFalse(report.findings.contains { $0.message.contains("paint-fragment") })
                }
            }
            phase = "long text verify"
            _ = try await manager.open(profile: "scroll", url: XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/long-text")))
            let longText = try await manager.verify(profile: "scroll", expectText: "Measured line 9999")
            XCTAssertEqual(longText.status, .pass, "\(longText.findings)")
            phase = "overlap budget refusal"
            _ = try await manager.open(profile: "scroll", url: XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/overlap-budget")))
            do {
                _ = try await manager.verify(profile: "scroll")
                XCTFail("exhausted overlap inspection must not return a partial verdict")
            } catch {
                XCTAssertTrue(String(describing: error).contains("bounded work budget"), "\(error)")
            }
        } catch { XCTFail("\(phase): \(error)") }
        await manager.closeAll()
        try await server.stop()
    }

}
