// `verdictui appkit` — the CLI half of the AppKit path.
//
// The runner is a shell script standing in for a consumer's compiled binary.
// Spawning a process IS the behaviour under test here — the command's whole job
// is to run something it did not write and judge what it prints — so faking the
// process away would leave the interesting half unexercised.
import Foundation
import VerdictUIDemoScenarios
import VerdictUIKernel
import XCTest

@testable import VerdictUICLICore

final class AppKitCommandTests: XCTestCase {

    // MARK: - Fixtures

    /// A tree whose text needs more width than its frame gives it.
    /// `TruncationRule` must find it.
    private static let defectiveTree = """
        {"id":"root","role":"container",
         "frame":{"x":0,"y":0,"width":400,"height":200},
         "children":[
           {"id":"squeezed","role":"text",
            "frame":{"x":0,"y":0,"width":60,"height":20},
            "text":"a string far wider than sixty points allows",
            "textMetrics":{"intrinsicWidth":375,"renderedLineCount":1,"idealLineCount":1},
            "children":[]}]}
        """

    /// The SAME shape with the text comfortably inside its frame.
    ///
    /// CONTROL. Without it, "the command reports findings" is satisfied by an
    /// implementation that reports findings on everything, and the defective
    /// case above would pass against a rule engine that failed unconditionally.
    private static let cleanTree = """
        {"id":"root","role":"container",
         "frame":{"x":0,"y":0,"width":400,"height":200},
         "children":[
           {"id":"roomy","role":"text",
            "frame":{"x":0,"y":0,"width":380,"height":20},
            "text":"short",
            "textMetrics":{"intrinsicWidth":40,"renderedLineCount":1,"idealLineCount":1},
            "children":[]}]}
        """

    /// A tree in which nothing carries an id — what a producer emits when it
    /// walks a view and observes nothing. `RuleEngine` must refuse it as
    /// vacuous rather than hand back a clean bill of health for a screen nobody
    /// looked at.
    private static let vacuousTree = """
        {"id":"","role":"container",
         "frame":{"x":0,"y":0,"width":400,"height":200},
         "children":[]}
        """

    /// Writes an executable standing in for the consumer's runner.
    ///
    /// - Parameters:
    ///   - tree: what the script prints for `render`.
    ///   - exitCode: what it exits with for `render`, so the non-zero path is
    ///     reachable.
    private func makeRunner(
        tree: String,
        exitCode: Int32 = 0,
        stderr: String = ""
    ) throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("appkit-cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("runner")
        let script = """
            #!/bin/bash
            if [ "$1" = "list" ]; then
              echo "login-form"
              echo "settings"
              exit 0
            fi
            if [ "$1" = "render" ] && [ "$2" = "unknown" ]; then
              echo "unknown subject 'unknown'" >&2
              exit 2
            fi
            \(stderr.isEmpty ? "" : "echo \"\(stderr)\" >&2")
            cat <<'TREE'
            \(tree)
            TREE
            exit \(exitCode)
            """
        try script.write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: path.path)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return path.path
    }

    @MainActor
    private func environment() -> (CommandEnvironment, CapturedOutput) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("appkit-env-\(UUID().uuidString)", isDirectory: true)
        let output = CapturedOutput()
        return (
            CommandEnvironment(
                engine: VerdictEngine(
                    registry: DemoScenarios.registry,
                    baselines: BaselineStore.standard(root: root)
                ),
                output: output,
                pixelArtifactRoot: root.appendingPathComponent(PixelArtifact.directory)
            ),
            output
        )
    }

    // MARK: - list

    @MainActor
    func testOmittingTheSubjectListsWhatTheRunnerHas() async throws {
        let runner = try makeRunner(tree: Self.cleanTree)
        let (environment, output) = self.environment()

        let code = await AppKitCommand(runner: runner, subject: nil, judge: false)
            .run(environment, pretty: false, summary: false)

        XCTAssertEqual(code, .pass)
        XCTAssertTrue(output.standardOutput.contains("login-form"), output.standardOutput)
        XCTAssertTrue(output.standardOutput.contains("settings"), output.standardOutput)
    }

    // MARK: - render

    @MainActor
    func testRenderingPrintsTheTreeWithoutJudgingIt() async throws {
        let runner = try makeRunner(tree: Self.defectiveTree)
        let (environment, output) = self.environment()

        let code = await AppKitCommand(runner: runner, subject: "login-form", judge: false)
            .run(environment, pretty: false, summary: false)

        // A DEFECTIVE tree, printed rather than judged, is still exit 0: the
        // caller asked to see the tree, and the command answered that question.
        XCTAssertEqual(code, .pass)
        let tree = try JSONDecoder().decode(
            SemanticNode.self, from: Data(output.standardOutput.utf8))
        XCTAssertEqual(tree.id, "root")
        XCTAssertTrue(tree.flattened().contains { $0.id == "squeezed" })
    }

    // MARK: - judge, and the positive control

    @MainActor
    func testADefectiveScreenFailsWithACitedFinding() async throws {
        let runner = try makeRunner(tree: Self.defectiveTree)
        let (environment, output) = self.environment()

        let code = await AppKitCommand(runner: runner, subject: "login-form", judge: true)
            .run(environment, pretty: false, summary: false)

        XCTAssertEqual(code, .verdictFailed, output.standardOutput)
        let verdict = try JSONDecoder().decode(
            Verdict.self, from: Data(output.standardOutput.utf8))
        XCTAssertEqual(verdict.status, .fail)
        XCTAssertTrue(
            verdict.findings.contains { $0.rule == "truncation" && $0.nodeID == "squeezed" },
            "expected a truncation finding citing 'squeezed', got "
                + "\(verdict.findings.map { "\($0.rule)/\($0.nodeID)" })"
        )
    }

    /// The other half of the control: the same command on a clean tree must
    /// PASS. A command that failed everything would satisfy the test above and
    /// be exactly as useless as one that passed everything.
    @MainActor
    func testACleanScreenPasses() async throws {
        let runner = try makeRunner(tree: Self.cleanTree)
        let (environment, output) = self.environment()

        let code = await AppKitCommand(runner: runner, subject: "login-form", judge: true)
            .run(environment, pretty: false, summary: false)

        XCTAssertEqual(code, .pass, output.standardOutput)
        let verdict = try JSONDecoder().decode(
            Verdict.self, from: Data(output.standardOutput.utf8))
        XCTAssertEqual(verdict.status, .pass, "\(verdict.findings.map(\.rule))")
    }

    /// A runner that built a view and observed nothing must NOT exit 0.
    ///
    /// This is the AppKit-side counterpart of
    /// `testJudgeRefusesATreeWithNothingObservable`. Without it, the easiest
    /// possible broken producer — one that emits a shell and walks no children —
    /// earns a clean bill of health for a screen nobody looked at, which is the
    /// single most dangerous wrong answer this tool can give.
    @MainActor
    func testAnEmptyTreeIsRefusedAsVacuousRatherThanPassed() async throws {
        let runner = try makeRunner(tree: Self.vacuousTree)
        let (environment, output) = self.environment()

        let code = await AppKitCommand(runner: runner, subject: "login-form", judge: true)
            .run(environment, pretty: false, summary: false)

        XCTAssertEqual(code, .verdictFailed, output.standardOutput)
        let verdict = try JSONDecoder().decode(
            Verdict.self, from: Data(output.standardOutput.utf8))
        XCTAssertTrue(
            verdict.findings.contains { $0.rule == RuleEngine.vacuousVerdictRule },
            "an unobserved screen was not reported as vacuous: "
                + "\(verdict.findings.map(\.rule))"
        )
    }

    // MARK: - The three-valued contract

    /// A missing runner says NOTHING about the UI, so it is 2 — never 1.
    @MainActor
    func testAMissingRunnerCannotVerifyRatherThanFails() async throws {
        let (environment, output) = self.environment()

        let code = await AppKitCommand(
            runner: "/nonexistent/definitely-not-here", subject: "login-form", judge: true
        ).run(environment, pretty: false, summary: false)

        XCTAssertEqual(code, .couldNotVerify)
        XCTAssertTrue(
            output.standardError.contains("not an executable file"), output.standardError)
        XCTAssertTrue(output.standardOutput.isEmpty, output.standardOutput)
    }

    @MainActor
    func testARunnerExitingNonZeroCannotVerify() async throws {
        let runner = try makeRunner(tree: Self.cleanTree, exitCode: 2, stderr: "boom")
        let (environment, output) = self.environment()

        let code = await AppKitCommand(runner: runner, subject: "login-form", judge: true)
            .run(environment, pretty: false, summary: false)

        XCTAssertEqual(code, .couldNotVerify)
        XCTAssertTrue(output.standardError.contains("runner exited 2"), output.standardError)
    }

    @MainActor
    func testUnparseableRunnerOutputCannotVerify() async throws {
        let runner = try makeRunner(tree: "this is not json at all")
        let (environment, output) = self.environment()

        let code = await AppKitCommand(runner: runner, subject: "login-form", judge: true)
            .run(environment, pretty: false, summary: false)

        XCTAssertEqual(code, .couldNotVerify)
        XCTAssertTrue(
            output.standardError.contains("not a semantic tree"), output.standardError)
    }

    /// All three codes must be DISTINCT in one run. Asserting them separately
    /// leaves open the case where two of them are the same value and each test
    /// passes on its own.
    @MainActor
    func testTheThreeOutcomesAreDistinct() async throws {
        let clean = try makeRunner(tree: Self.cleanTree)
        let broken = try makeRunner(tree: Self.defectiveTree)

        let (envA, _) = environment()
        let passed = await AppKitCommand(runner: clean, subject: "s", judge: true)
            .run(envA, pretty: false, summary: false)
        let (envB, _) = environment()
        let failed = await AppKitCommand(runner: broken, subject: "s", judge: true)
            .run(envB, pretty: false, summary: false)
        let (envC, _) = environment()
        let unavailable = await AppKitCommand(runner: "/nope", subject: "s", judge: true)
            .run(envC, pretty: false, summary: false)

        XCTAssertEqual(Set([passed, failed, unavailable]).count, 3)
        XCTAssertEqual(passed, .pass)
        XCTAssertEqual(failed, .verdictFailed)
        XCTAssertEqual(unavailable, .couldNotVerify)
    }

    // MARK: - Formatting

    /// `--summary` must produce the human rendering, as it does for every other
    /// verdict-producing verb. It was accepted and silently ignored: the flag
    /// parsed, the option group carried it, and the call site passed only
    /// `pretty` — so a developer asking for a summary got JSON and had no way to
    /// tell the flag had done nothing.
    @MainActor
    func testSummaryPrintsTheHumanRenderingRatherThanJSON() async throws {
        let runner = try makeRunner(tree: Self.defectiveTree)
        let (environment, output) = self.environment()

        let code = await AppKitCommand(runner: runner, subject: "login-form", judge: true)
            .run(environment, pretty: false, summary: true)

        XCTAssertEqual(code, .verdictFailed)
        XCTAssertTrue(output.standardOutput.hasPrefix("FAIL"), output.standardOutput)
        XCTAssertTrue(output.standardOutput.contains("truncation"), output.standardOutput)
        XCTAssertFalse(
            output.standardOutput.contains("\"schemaVersion\""),
            "summary printed JSON: \(output.standardOutput)"
        )
    }

    /// The verdict is filed under the SUBJECT's name, so a caller judging
    /// several screens can tell the reports apart.
    @MainActor
    func testTheVerdictIsFiledUnderTheSubjectName() async throws {
        let runner = try makeRunner(tree: Self.cleanTree)
        let (environment, output) = self.environment()

        _ = await AppKitCommand(runner: runner, subject: "settings", judge: true)
            .run(environment, pretty: false, summary: false)

        let verdict = try JSONDecoder().decode(
            Verdict.self, from: Data(output.standardOutput.utf8))
        XCTAssertEqual(verdict.scenario, "settings")
    }
}
