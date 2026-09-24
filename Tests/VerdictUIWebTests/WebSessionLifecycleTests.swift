import Foundation
import XCTest
import VerdictUIKernel
@testable import VerdictUIWeb

final class WebSessionLifecycleTests: XCTestCase {
    private func fixturePython() throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        if let configured = environment["VERDICTUI_TEST_PYTHON"] {
            guard configured.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: configured) else {
                throw WebBrowserError.invalidWebOperation(reason: "configured fixture Python is not executable")
            }
            return URL(fileURLWithPath: configured)
        }
        for directory in (environment["PATH"] ?? "").split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent("python3.14")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        throw WebBrowserError.invalidWebOperation(reason: "fixture requires VERDICTUI_TEST_PYTHON or python3.14 on PATH")
    }

    /// The HTTP origin stays identical across both launches. A fresh named
    /// profile is the negative isolation control, not a substitute for reopening.
    func testHTTPStorageSurvivesImmediateCloseAndReopen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("verdictui-http-persistence-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "server", withExtension: "py", subdirectory: "Fixtures"))
        let portFile = root.appendingPathComponent("server.port")
        let server = try GuardedProcess.spawn(executable: fixturePython(),
            arguments: [fixture.path, fixture.deletingLastPathComponent().path, portFile.path],
            directory: root, environment: ProcessInfo.processInfo.environment)
        var sessions: [WebSession] = []
        do {
            let deadline = ContinuousClock.now + .seconds(5)
            var port: Int?
            while ContinuousClock.now < deadline {
                if let text = try? String(contentsOf: portFile, encoding: .utf8), let value = Int(text) {
                    port = value; break
                }
                guard try server.status() == nil else { throw CocoaError(.executableRuntimeMismatch) }
                try await Task.sleep(for: .milliseconds(25))
            }
            let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(try XCTUnwrap(port))/login.html"))
            let registry = ProfileRegistry(root: root.appendingPathComponent("profiles"))
            let first = try await WebSession.open(profile: "persistent", url: url, registry: registry,
                environment: [:], width: 1280, height: 800)
            sessions.append(first)
            let before = try await state(first, write: true)
            XCTAssertEqual(before["stored"], .bool(true))
            XCTAssertEqual(before["protocol"], .string("http:"))
            let started = ContinuousClock.now
            // No settling delay or persistence retry between the acknowledged
            // renderer write and the production close path.
            try await first.close()
            let elapsed = started.duration(to: .now)
            let reopened = try await WebSession.open(profile: "persistent", url: url, registry: registry,
                environment: [:], width: 1280, height: 800)
            sessions.append(reopened)
            let after = try await state(reopened)
            let verdict = try await reopened.verify(expectText: "Task complete")
            let evidence: [String: CDPValue] = ["before": .object(before), "after": .object(after),
                "closeDuration": .string(String(describing: elapsed))]
            print("HTTP-PROFILE-PERSISTENCE " + String(decoding: try JSONEncoder().encode(evidence), as: UTF8.self))
            XCTAssertEqual(after["origin"], before["origin"])
            XCTAssertEqual(after["stored"], .bool(true), "HTTP storage must survive actual browser retirement")
            XCTAssertEqual(verdict.status, .pass, "\(verdict.findings)")
            try await reopened.close()
            let isolated = try await WebSession.open(profile: "isolated", url: url, registry: registry,
                environment: [:], width: 1280, height: 800)
            sessions.append(isolated)
            let other = try await state(isolated)
            XCTAssertEqual(other["stored"], .bool(false), "a different profile must not inherit persisted state")
            try await isolated.close()
            _ = try server.stop()
        } catch {
            let original = error
            var cleanupFailure: (any Error)?
            for session in sessions {
                do { try await session.close() }
                catch { cleanupFailure = error }
            }
            do { _ = try server.stop() }
            catch { cleanupFailure = error }
            if let cleanupFailure { throw cleanupFailure }
            throw original
        }
    }

    private func state(_ session: WebSession, write: Bool = false) async throws -> [String: CDPValue] {
        let prefix = write ? "localStorage.setItem('task-complete','yes');" : ""
        let result = try await session.transport.send(method: "Runtime.evaluate", params: [
            "expression": .string(prefix + "({stored:localStorage.getItem('task-complete')==='yes',origin:location.origin,protocol:location.protocol})"),
            "returnByValue": .bool(true)], sessionID: session.pageSessionID)
        guard case let .object(remote) = result["result"], case let .object(value) = remote["value"], result["exceptionDetails"] == nil else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return value
    }
}
