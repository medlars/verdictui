import XCTest
@testable import VerdictUIWeb

final class OwnedCommandProcessTests: XCTestCase {
    func testExitEventTimesOutThenObservesExitWithoutReaping() throws {
        let process = try OwnedCommandProcess.spawn(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "/bin/sleep 0.2; exit 17"], directory: FileManager.default.temporaryDirectory,
            environment: [:])
        defer { _ = try? process.stop(grace: 0) }
        XCTAssertFalse(process.waitForExitEvent(timeout: 0.01))
        XCTAssertFalse(process.waitForExitEvent(timeout: .infinity))
        XCTAssertFalse(process.waitForExitEvent(timeout: -1))
        XCTAssertTrue(process.waitForExitEvent(timeout: 3))
        XCTAssertEqual(try process.status(), 17)
        // Successful observation leaves the process unreaped; waitid still
        // returns this exact child until the owner finishes its group cleanup.
        var info = siginfo_t()
        XCTAssertEqual(waitid(P_PID, id_t(process.processIdentifier), &info, WEXITED | WNOHANG | WNOWAIT), 0)
        XCTAssertEqual(info.si_pid, process.processIdentifier)
        XCTAssertTrue(process.waitForExitEvent(timeout: 0))
        XCTAssertEqual(try process.stop(grace: 0), 17)
        XCTAssertTrue(process.waitForExitEvent(timeout: 0))
    }

    func testStopGraceWakesOnActualChildExit() throws {
        let process = try OwnedCommandProcess.spawn(executable: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["30"], directory: FileManager.default.temporaryDirectory, environment: [:])
        defer { _ = try? process.stop(grace: 0) }
        for _ in 0..<3 { XCTAssertFalse(process.waitForExitEvent(timeout: 0.001)) }
        let start = ContinuousClock.now
        XCTAssertEqual(try process.stop(grace: 3), 128 + SIGTERM)
        XCTAssertLessThan(start.duration(to: .now), .seconds(2), "event delivery must end grace when the child exits")
    }
}
