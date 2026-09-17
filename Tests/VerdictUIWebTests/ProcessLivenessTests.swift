import XCTest

@testable import VerdictUIWeb

/// The liveness primitive: kill(pid, 0) with EPERM counted alive.
final class ProcessLivenessTests: XCTestCase {
    func testThisProcessIsAlive() {
        XCTAssertTrue(
            ProcessLiveness.isAlive(ProcessInfo.processInfo.processIdentifier))
    }

    /// A process that has exited must read dead. A freshly-exited child is
    /// the deterministic dead case: `waitUntilExit` reaps it, so no zombie
    /// ambiguity remains.
    func testADeadPidIsReportedDead() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try child.run()
        child.waitUntilExit()
        XCTAssertFalse(ProcessLiveness.isAlive(child.processIdentifier))
    }
}
