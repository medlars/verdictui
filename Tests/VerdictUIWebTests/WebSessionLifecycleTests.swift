import Foundation
import XCTest
import VerdictUIKernel
@testable import VerdictUIWeb

final class WebSessionLifecycleTests: XCTestCase {
    /// The HTTP origin stays identical across both launches. A fresh named
    /// profile is the negative isolation control, not a substitute for reopening.
    func testHTTPStorageSurvivesImmediateCloseAndReopen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("verdictui-http-persistence-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var cleanupComplete = false
        defer {
            if cleanupComplete {
                do { try FileManager.default.removeItem(at: root) }
                catch { XCTFail("fixture directory cleanup failed: \(error)") }
            }
        }
        let server = try await LocalHTTPFixture.start(root: root)
        var sessions: [WebSession] = []
        do {
            let url = server.origin.appendingPathComponent("login.html")
            let registry = ProfileRegistry(root: root.appendingPathComponent("profiles"))
            let first = try await WebSession.open(profile: "persistent", url: url, registry: registry,
                environment: [:], width: 1280, height: 800)
            sessions.append(first)
            let before = try await state(first, write: true)
            XCTAssertEqual(before["stored"], .bool(true))
            XCTAssertEqual(before["protocol"], .string("http:"))
            XCTAssertEqual(before["origin"], .string(server.origin.absoluteString))
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
            XCTAssertEqual(after["protocol"], .string("http:"))
            XCTAssertEqual(after["stored"], .bool(true), "HTTP storage must survive actual browser retirement")
            XCTAssertEqual(verdict.status, .pass, "\(verdict.findings)")
            try await reopened.close()
            let isolated = try await WebSession.open(profile: "isolated", url: url, registry: registry,
                environment: [:], width: 1280, height: 800)
            sessions.append(isolated)
            let other = try await state(isolated)
            XCTAssertEqual(other["origin"], before["origin"])
            XCTAssertEqual(other["stored"], .bool(false), "a different profile must not inherit persisted state")
            try await isolated.close()
            try server.stop()
            cleanupComplete = true
        } catch {
            let original = error
            var cleanupFailure: (any Error)?
            for session in sessions {
                do { try await session.close() }
                catch { XCTFail("browser cleanup failed: \(error)"); cleanupFailure = error }
            }
            do { try server.stop() }
            catch { XCTFail("HTTP fixture cleanup failed: \(error)"); cleanupFailure = error }
            if let cleanupFailure { throw cleanupFailure }
            cleanupComplete = true
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
