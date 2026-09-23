import Foundation
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
}
