import Darwin
import Foundation
import XCTest
@testable import VerdictUIWeb

final class GuardedProcessTests: XCTestCase {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vui-command-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func waitForExit(_ process: GuardedProcess, seconds: TimeInterval = 3) throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        repeat {
            if try process.status() != nil { return true }
            _ = process.waitForExitEvent(timeout: 0.01)
        } while ContinuousClock.now < deadline
        return try process.status() != nil
    }

    func testWorkingDirectoryEnvironmentBinaryStreamsAndActualExitCode() throws {
        let root = try root(), input = Pipe(), output = Pipe(), errors = Pipe()
        try Data().write(to: root.appendingPathComponent("cwd-marker"))
        let process = try GuardedProcess.spawn(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "test -f cwd-marker || exit 99; printf '%s' \"$PRIVATE_VALUE|\"; /bin/cat; printf '\\000\\377err' >&2; exit 37"],
            directory: root, environment: ["PRIVATE_VALUE": "value with spaces"],
            standardInput: input.fileHandleForReading.fileDescriptor,
            standardOutput: output.fileHandleForWriting.fileDescriptor,
            standardError: errors.fileHandleForWriting.fileDescriptor)
        defer { _ = try? process.stop(grace: 0) }
        for borrowed in [input.fileHandleForReading, output.fileHandleForWriting, errors.fileHandleForWriting] {
            XCTAssertNotEqual(fcntl(borrowed.fileDescriptor, F_GETFD), -1,
                              "launch borrows caller stdio; only its private descriptor snapshots may be closed")
        }
        try input.fileHandleForReading.close(); try output.fileHandleForWriting.close(); try errors.fileHandleForWriting.close()
        let binary = Data([0, 255, 10, 13, 65])
        try input.fileHandleForWriting.write(contentsOf: binary); try input.fileHandleForWriting.close()
        XCTAssertTrue(try waitForExit(process))
        XCTAssertEqual(try process.status(), 37)
        XCTAssertEqual(try process.stop(grace: 0), 37)
        XCTAssertEqual(try process.stop(grace: 0), 37)
        XCTAssertEqual(try output.fileHandleForReading.readToEnd(), Data("value with spaces|".utf8) + binary)
        XCTAssertEqual(try errors.fileHandleForReading.readToEnd(), Data([0, 255, 101, 114, 114]))
    }

    func testGuardianDoesNotKeepOutputPipeAliveAfterCommandClosesIt() throws {
        let root = try root(), input = Pipe(), output = Pipe()
        let process = try GuardedProcess.spawn(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "exec 1>&-; read value"], directory: root, environment: [:],
            standardInput: input.fileHandleForReading.fileDescriptor,
            standardOutput: output.fileHandleForWriting.fileDescriptor)
        defer { _ = try? process.stop(grace: 0) }
        try input.fileHandleForReading.close(); try output.fileHandleForWriting.close()
        var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
        XCTAssertGreaterThan(poll(&descriptor, 1, 2000), 0, "guardian cannot retain caller output writers")
        XCTAssertNil(try output.fileHandleForReading.read(upToCount: 1))
        XCTAssertNil(try process.status(), "EOF is observed while the command is still waiting for stdin")
        try input.fileHandleForWriting.close()
        XCTAssertTrue(try waitForExit(process, seconds: 2))
        XCTAssertEqual(try process.stop(grace: 0), 1)
    }

    func testClosedAndNegativeDescriptorsAndInvalidDirectoryFailBeforeCommandRuns() throws {
        let root = try root(), marker = root.appendingPathComponent("ran")
        let descriptor = open("/dev/null", O_RDONLY)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        XCTAssertEqual(close(descriptor), 0)
        for fd in [descriptor, -1, -2] {
            XCTAssertThrowsError(try GuardedProcess.spawn(executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "touch ran"], directory: root, environment: [:], standardOutput: fd))
        }
        XCTAssertThrowsError(try GuardedProcess.spawn(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "touch ran"], directory: root.appendingPathComponent("absent"), environment: [:]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testClosedDescriptorCannotBeReusedByEarlierStreamSnapshot() throws {
        let root = try root()
        let first = open("/dev/null", O_RDONLY), second = dup(first)
        XCTAssertGreaterThan(second, first)
        close(second); defer { close(first) }
        XCTAssertThrowsError(try GuardedProcess.spawn(executable: URL(fileURLWithPath: "/usr/bin/true"),
            arguments: [], directory: root, environment: [:], standardInput: first, standardOutput: second))
    }

    func testCallerGraceAllowsDelayedFlushAndReturnsCommandStatus() throws {
        let root = try root(), ready = root.appendingPathComponent("ready"), flushed = root.appendingPathComponent("flushed")
        let process = try GuardedProcess.spawn(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "trap '/bin/sleep 1.5; printf done > flushed; exit 23' TERM; printf ready > ready; while :; do /bin/sleep .02; done"],
            directory: root, environment: [:])
        defer { _ = try? process.stop(grace: 0) }
        let deadline = ContinuousClock.now + .seconds(3)
        while !FileManager.default.fileExists(atPath: ready.path), ContinuousClock.now < deadline { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: ready.path))
        XCTAssertEqual(try process.stop(grace: 3), 23)
        XCTAssertEqual(try String(contentsOf: flushed, encoding: .utf8), "done")
    }

    func testLostGuardianMakesRunningCommandUnavailableUntilCleanup() throws {
        let process = try GuardedProcess.spawn(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"],
            directory: try root(), environment: [:])
        defer { _ = try? process.stop(grace: 0) }
        let guardian = getpgid(process.processIdentifier)
        XCTAssertNotEqual(guardian, process.processIdentifier)
        var info = siginfo_t()
        XCTAssertEqual(waitid(P_PID, id_t(guardian), &info, WEXITED | WNOHANG | WNOWAIT), 0)
        XCTAssertEqual(info.si_pid, 0, "test holds its own direct live guardian unreaped")
        XCTAssertEqual(kill(guardian, SIGKILL), 0)
        let deadline = ContinuousClock.now + .seconds(2)
        repeat {
            XCTAssertEqual(waitid(P_PID, id_t(guardian), &info, WEXITED | WNOHANG | WNOWAIT), 0)
            if info.si_pid == guardian { break }
            Thread.sleep(forTimeInterval: 0.01)
        } while ContinuousClock.now < deadline
        XCTAssertEqual(info.si_pid, guardian)
        XCTAssertThrowsError(try process.status()) { error in
            guard case OwnedCommandProcess.Failure.guardianUnavailable = error else { return XCTFail("unexpected \(error)") }
        }
        XCTAssertEqual(try process.stop(grace: 1), 128 + SIGTERM)
    }

    func testLaunchRejectsNulArgumentsAndNonFileURLs() throws {
        let root = try root()
        XCTAssertThrowsError(try GuardedProcess.spawn(executable: URL(fileURLWithPath: "/usr/bin/printf"),
            arguments: ["truncated\0argument"], directory: root, environment: [:]))
        XCTAssertThrowsError(try GuardedProcess.spawn(executable: URL(string: "https://example.invalid/tool")!,
            arguments: [], directory: root, environment: [:]))
    }

    func testNullStreamsAndInvalidGrace() throws {
        let process = try GuardedProcess.spawn(executable: URL(fileURLWithPath: "/bin/cat"), arguments: [],
            directory: try root(), environment: [:])
        defer { _ = try? process.stop(grace: 0) }
        XCTAssertTrue(try waitForExit(process, seconds: 2))
        for grace in [TimeInterval.nan, .infinity, -1] { XCTAssertThrowsError(try process.stop(grace: grace)) }
        XCTAssertEqual(try process.stop(grace: 0), 0)
    }
}
