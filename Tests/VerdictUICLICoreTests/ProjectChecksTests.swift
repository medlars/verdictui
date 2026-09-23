import Foundation
import Darwin
import XCTest
import VerdictUIKernel
import VerdictUIWeb
@testable import VerdictUICLICore

final class ProjectChecksTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".verdictui"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func manifest(_ json: String, root: URL) throws {
        try Data(json.utf8).write(to: root.appendingPathComponent(".verdictui/checks.json"))
    }

    func testEmptyDuplicateAndUnknownDeclarationsAreRejected() throws {
        let root = try directory()
        for json in [#"{"checks":[]}"#,
                     #"{"checks":[{"name":"a","kind":"web"},{"name":"a","kind":"web"}]}"#,
                     #"{"checks":[{"name":"a","kind":"unknown"}]}"#,
                     #"{"checks":[{"name":"","kind":"web"}]}"#,
                     #"{"checks":[{"name":"a","kind":"web","expectText":""}]}"#] {
            try manifest(json, root: root)
            XCTAssertThrowsError(try ProjectChecks.load(root: root), json)
        }
    }

    func testAggregateNeverPassesEmptyOrUnavailableCoverage() {
        XCTAssertEqual(ProjectCheckReport.aggregate([]).exitCode, .couldNotVerify)
        let pass = ProjectCheckReport.Entry(name: "good", status: "pass", verdict: nil, error: nil)
        let fail = ProjectCheckReport.Entry(name: "broken", status: "fail", verdict: nil, error: nil)
        let unavailable = ProjectCheckReport.Entry(name: "absent", status: "unavailable", verdict: nil, error: nil)
        XCTAssertEqual(ProjectCheckReport.aggregate([pass]).exitCode, .pass)
        XCTAssertEqual(ProjectCheckReport.aggregate([pass, fail]).exitCode, .verdictFailed)
        XCTAssertEqual(ProjectCheckReport.aggregate([fail, unavailable]).exitCode, .couldNotVerify)
    }

    @MainActor
    func testUnconfiguredAndMissingRunnerNeverUseDemoCatalog() async throws {
        let root = try directory()
        let sessions = WebSessionManager(root: root.appendingPathComponent("profiles"))
        let executable = URL(fileURLWithPath: "/usr/bin/true")
        let missing = await ProjectCheckRuntime.run(root: root, executable: executable, sessions: sessions)
        XCTAssertEqual(missing.exitCode, .couldNotVerify)
        XCTAssertTrue(missing.checks.isEmpty)
        try manifest(#"{"checks":[{"name":"mine","kind":"scenario","scenario":"demo-clean-settings"}]}"#, root: root)
        let undeclared = await ProjectCheckRuntime.run(root: root, executable: executable, sessions: sessions)
        XCTAssertEqual(undeclared.checks.first?.status, "unavailable")
        XCTAssertNil(undeclared.checks.first?.verdict)
    }

    @MainActor
    func testConsumerVerdictPreservesFailureAndISODate() async throws {
        let root = try directory()
        let binary = root.appendingPathComponent("consumer")
        let verdict = Verdict(scenario: "settings", findings: [Finding(rule: "fixture", severity: .error, nodeID: "save", message: "broken")])
        let output = try VerdictOutput.json(verdict, pretty: false)
        try Data("#!/bin/sh\ncat <<'VERDICT'\n\(output)\nVERDICT\nexit 1\n".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        try Data(#"{"runner":"consumer"}"#.utf8).write(to: root.appendingPathComponent(".verdictui/config.json"))
        try manifest(#"{"checks":[{"name":"settings","kind":"scenario","scenario":"settings"}]}"#, root: root)
        let report = await ProjectCheckRuntime.run(root: root, executable: binary, sessions: WebSessionManager(root: root))
        XCTAssertEqual(report.exitCode, .verdictFailed)
        XCTAssertEqual(report.checks.first?.verdict?.findings.first?.nodeID, "save")
        // A runner that lies about the scenario cannot certify the requested screen.
        try manifest(#"{"checks":[{"name":"settings","kind":"scenario","scenario":"other"}]}"#, root: root)
        let wrong = await ProjectCheckRuntime.run(root: root, executable: binary, sessions: WebSessionManager(root: root))
        XCTAssertEqual(wrong.exitCode, .couldNotVerify)
    }

    func testSubprocessBoundsOutputAndTime() async throws {
        let root = try directory()
        do {
            _ = try await BoundedCommand.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"], root: root, timeout: 0.05)
            XCTFail("hanging command accepted")
        } catch BoundedCommand.Failure.timeout {} catch { XCTFail("\(error)") }
        do {
            _ = try await BoundedCommand.run(executable: URL(fileURLWithPath: "/usr/bin/printf"), arguments: ["too much output"], root: root, limit: 3)
            XCTFail("large output accepted")
        } catch BoundedCommand.Failure.excessiveOutput {} catch { XCTFail("\(error)") }
    }

    func testCheckKindsRejectIgnoredFieldsAndMissingTargets() throws {
        let invalid = [
            #"{"name":"a","kind":"web"}"#,
            #"{"name":"a","kind":"scenario"}"#,
            #"{"name":"a","kind":"appkit","runner":"consumer"}"#,
            #"{"name":"a","kind":"scenario","scenario":"settings","runner":"ignored"}"#,
            #"{"name":"a","kind":"scenario","scenario":"settings","expectText":"ignored"}"#,
            #"{"name":"a","kind":"appkit","runner":"consumer","subject":"settings","expectText":"ignored"}"#,
            #"{"name":"a","kind":"web","url":"file:///tmp/page.html","expectText":"   "}"#,
            #"{"name":"a","kind":"web","url":"https://user:secret@example.org"}"#,
            #"{"name":"a","kind":"web","url":"javascript:void(0)"}"#,
            #"{"name":"a","kind":"web","url":"file:///tmp/page.html","pid":10}"#,
            #"{"name":"a","kind":"live","pid":1}"#,
            #"{"name":"a","kind":"live","pid":2147483648}"#,
            #"{"name":"a","kind":"live","pid":123,"surface":"all"}"#,
            #"{"name":"a","kind":"live","pid":123,"unknown":true}"#,
        ]
        for declaration in invalid {
            XCTAssertThrowsError(try ProjectChecks.decode(Data("{\"checks\":[\(declaration)]}".utf8)), declaration)
        }
        for declaration in [#"{"name":"a","kind":"scenario","scenario":"settings"}"#,
            #"{"name":"a","kind":"appkit","runner":"consumer","subject":"settings"}"#,
            #"{"name":"a","kind":"web","url":"file:///tmp/page.html","expectText":"Ready"}"#,
            #"{"name":"a","kind":"live","pid":123,"surface":"window:0","expectText":"Ready"}"#] {
            XCTAssertNoThrow(try ProjectChecks.decode(Data("{\"checks\":[\(declaration)]}".utf8)))
        }
        let oversized: [String: Any] = ["checks": [["name": "a", "kind": "web", "url": "file:///tmp/page.html", "expectText": String(repeating: "x", count: 4097)]]]
        XCTAssertThrowsError(try ProjectChecks.decode(JSONSerialization.data(withJSONObject: oversized)))
    }

    private func sleepingRunner(_ root: URL) throws -> URL {
        let runner = root.appendingPathComponent("runner")
        try Data("""
        #!/bin/sh
        trap '' TERM
        echo $$ > "$(dirname "$0")/leader.pid"
        /bin/sleep 60 &
        echo $! > "$(dirname "$0")/child.pid"
        wait
        """.utf8).write(to: runner)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: runner.path)
        return runner
    }

    private static func pid(_ name: String, in root: URL) async throws -> pid_t {
        let file = root.appendingPathComponent(name)
        let deadline = ContinuousClock.now + .seconds(8)
        while ContinuousClock.now < deadline {
            if let text = try? String(contentsOf: file, encoding: .utf8), let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 { return pid }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw CocoaError(.fileReadNoSuchFile)
    }

    private static func assertGone(_ pids: [pid_t]) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while pids.contains(where: { kill($0, 0) == 0 }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        for pid in pids { XCTAssertNotEqual(kill(pid, 0), 0, "owned process \(pid) survived cleanup") }
    }

    func testCancellationStopsOwnedRunnerAndDescendant() async throws {
        let root = try directory()
        let runner = try sleepingRunner(root)
        let operation = Task { try await BoundedCommand.run(executable: runner, arguments: [], root: root) }
        let leader = try await Self.pid("leader.pid", in: root)
        let child = try await Self.pid("child.pid", in: root)
        defer { for pid in [child, leader] where getpgid(pid) == leader { kill(pid, SIGKILL) } }
        XCTAssertEqual(getpgid(child), leader)
        XCTAssertNotEqual(leader, getpgrp(), "must never signal the test runner's group")
        operation.cancel()
        do { _ = try await operation.value; XCTFail("cancelled operation succeeded") }
        catch is CancellationError {} catch { XCTFail("\(error)") }
        try await Self.assertGone([leader, child])
    }

    @MainActor
    func testCancelledProjectCheckReportsCancellationAndCleansRunner() async throws {
        let root = try directory()
        let runner = try sleepingRunner(root)
        let declaration: [String: Any] = ["checks": [["name": "owned", "kind": "appkit", "runner": runner.path, "subject": "witness"]]]
        try JSONSerialization.data(withJSONObject: declaration).write(to: root.appendingPathComponent(".verdictui/checks.json"))
        let operation = Task { await ProjectCheckRuntime.run(root: root, executable: runner, sessions: WebSessionManager(root: root)) }
        let leader = try await Self.pid("leader.pid", in: root)
        let child = try await Self.pid("child.pid", in: root)
        defer { for pid in [child, leader] where getpgid(pid) == leader { kill(pid, SIGKILL) } }
        operation.cancel()
        let report = await operation.value
        XCTAssertEqual(report.status, "unavailable")
        XCTAssertEqual(report.checks.first?.error, "Cancelled before verification completed")
        try await Self.assertGone([leader, child])
    }

    func testExitedLeaderRemainsPinnedUntilDescendantCleanup() async throws {
        let root = try directory()
        let script = "/bin/sleep 60 & echo $! > child.pid; exit 0"
        let process = try OwnedCommandProcess.spawn(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script], directory: root, environment: ProcessInfo.processInfo.environment)
        let child = try await Self.pid("child.pid", in: root)
        defer { if getpgid(child) == process.processIdentifier { kill(child, SIGKILL) } }
        let deadline = ContinuousClock.now + .seconds(3)
        while try process.status() == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(try process.status(), 0)
        XCTAssertEqual(kill(process.processIdentifier, 0), 0, "waitid must not reap the identity anchor")
        XCTAssertEqual(try process.stop(grace: 0), 0)
        XCTAssertEqual(try process.stop(grace: 0), 0, "repeated cleanup must not signal a reused PID")
        try await Self.assertGone([process.processIdentifier, child])
    }

    func testCheckSIGTERMCleansChildAndGrandchildBeforeExit() async throws {
        let root = try directory()
        let runner = try sleepingRunner(root)
        let declaration: [String: Any] = ["checks": [["name": "owned", "kind": "appkit", "runner": runner.path, "subject": "witness"]]]
        try JSONSerialization.data(withJSONObject: declaration).write(to: root.appendingPathComponent(".verdictui/checks.json"))
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let process = Process()
        process.executableURL = repository.appendingPathComponent(".build/debug/verdictui")
        process.arguments = ["check", "--project", root.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        let leader = try await Self.pid("leader.pid", in: root)
        let child = try await Self.pid("child.pid", in: root)
        defer { for pid in [child, leader] where getpgid(pid) == leader { kill(pid, SIGKILL) } }
        process.terminate()
        let deadline = ContinuousClock.now + .seconds(8)
        while process.isRunning && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(process.isRunning)
        if !process.isRunning { XCTAssertEqual(process.terminationStatus, 128 + SIGTERM) }
        try await Self.assertGone([leader, child])
    }

    func testSubprocessRejectsInvalidLimitsAndNulArguments() async throws {
        let root = try directory()
        for timeout in [Double.nan, .infinity, 0, -1] {
            do { _ = try await BoundedCommand.run(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [], root: root, timeout: timeout); XCTFail("invalid deadline") }
            catch BoundedCommand.Failure.invalidLimits {} catch { XCTFail("\(error)") }
        }
        do { _ = try await BoundedCommand.run(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [], root: root, limit: 0); XCTFail("invalid output limit") }
        catch BoundedCommand.Failure.invalidLimits {} catch { XCTFail("\(error)") }
        XCTAssertThrowsError(try OwnedCommandProcess.spawn(executable: URL(fileURLWithPath: "/usr/bin/true"),
            arguments: ["a\0b"], directory: root, environment: [:]))
    }
}
