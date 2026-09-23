import Darwin
import Foundation
import XCTest
@testable import VerdictUIWeb

private final class TestBrowserIdentity: BrowserProcessIdentity, @unchecked Sendable {
    let pid: pid_t = ProcessInfo.processInfo.processIdentifier
    private let lock = NSLock()
    private var running: Bool
    private var sent: [Int32] = []
    init(running: Bool) { self.running = running }
    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }
    var signals: [Int32] { lock.lock(); defer { lock.unlock() }; return sent }
    func signal(_ value: Int32) {
        lock.lock(); defer { lock.unlock() }
        sent.append(value)
        running = false
    }
}

final class BrowserProcessIdentityTests: XCTestCase {
    func testReusedLivePIDDoesNotAuthorizeTerminatingADeadChild() async throws {
        let identity = TestBrowserIdentity(running: false)
        XCTAssertTrue(ProcessLiveness.isAlive(identity.pid), "positive control: this recycled identity names a real live PID")
        var browser: HeadlessBrowser? = HeadlessBrowser(process: identity,
            endpoint: DevtoolsEndpoint(port: 12345, browserPath: "/devtools/browser/test"),
            profileDirectory: FileManager.default.temporaryDirectory)
        try await browser?.terminate(grace: 0)
        XCTAssertTrue(identity.signals.isEmpty, "termination must consult the original child, not PID liveness")
        browser = nil
        XCTAssertTrue(identity.signals.isEmpty, "deinit must not signal a recycled PID")
    }

    func testOwnedLiveChildStillReceivesTerminationAndStops() async throws {
        let identity = TestBrowserIdentity(running: true)
        var browser: HeadlessBrowser? = HeadlessBrowser(process: identity,
            endpoint: DevtoolsEndpoint(port: 12345, browserPath: "/devtools/browser/test"),
            profileDirectory: FileManager.default.temporaryDirectory)
        try await browser?.terminate(grace: 0)
        XCTAssertEqual(identity.signals, [SIGTERM])
        browser = nil
        XCTAssertEqual(identity.signals, [SIGTERM], "deinit must not signal an already stopped child")
    }
}
