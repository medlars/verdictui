// Team-lead's independently-written CLI suite, kept ALONGSIDE
// `AppKitCommandTests` rather than merged into it.
//
// The two were written in parallel against the same command and converged: the
// SOURCE files were byte-identical once comments were stripped, and both cover
// the same ten concerns. The test bodies differ in fixtures and naming, and two
// assertions exist only here (`testWithoutSummaryTheOutputIsStillJSON` — because
// "summary is not JSON" alone is satisfied by a command that never emits JSON —
// and a distinct rendering path check). Keeping both is strictly more coverage
// than picking a winner, and the duplication is honest: two independent
// derivations agreeing is evidence, where one derivation is only an assertion.
import Foundation
import VerdictUIDemoScenarios
import VerdictUIKernel
import XCTest

@testable import VerdictUICLICore

/// The CLI half of the AppKit path: `verdictui appkit`.
///
/// WHY THE COMMAND EXISTS. Before it, an AppKit product had NO way to be judged.
/// `inspect --pid` needs an `AXGroup` coordinate anchor and exits 2 on a pure
/// AppKit app (CIS-C5D9A5E8), and `verdictProbe` is `extension View`, i.e.
/// SwiftUI only. Both documented on-ramps were closed, leaving screenshots and
/// Automator — the things the owner's directive rules out.
///
/// The command drives a CONSUMER-BUILT RUNNER rather than loading views itself,
/// because an `NSView` subclass exists only in the binary that compiled it. The
/// tests below stand a shell script in for that runner: the process boundary is
/// the behaviour under test, so faking it away would test nothing.
final class AppKitCommandRunnerTests: XCTestCase {

    private func boundedRunner(_ body: String) throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("appkit-bounded-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let runner = directory.appendingPathComponent("runner")
        try ("#!/bin/sh\n" + body + "\n").write(to: runner, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: runner.path)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return runner.path
    }

    @MainActor
    func testCombinedDiagnosticAndTreeOutputIsBounded() async throws {
        let body = "printf '%s' '\(String(repeating: "a", count: 48))'; "
            + "printf '%s' '\(String(repeating: "b", count: 48))' >&2"
        let runner = try boundedRunner(body)
        switch await AppKitCommand.invoke(runner: runner, arguments: [], limit: 80) {
        case .produced: XCTFail("Both streams must share one output budget")
        case .failed(let detail): XCTAssertTrue(detail.contains("excessiveOutput"))
        }
        switch await AppKitCommand.invoke(runner: runner, arguments: [], limit: 96) {
        case .produced(let value): XCTAssertEqual(value, String(repeating: "a", count: 48))
        case .failed(let detail): XCTFail("An exact-boundary result is valid: \(detail)")
        }
    }

    @MainActor
    func testRunnerTimeoutIsUnavailableAndCannotReturnLateOutput() async throws {
        let runner = try boundedRunner("/bin/sleep 0.3; printf late")
        switch await AppKitCommand.invoke(runner: runner, arguments: [], timeout: 0.01) {
        case .produced: XCTFail("A timed-out runner cannot produce a verified tree")
        case .failed(let detail): XCTAssertTrue(detail.contains("timeout"))
        }
    }

    @MainActor
    func testRunnerCancellationIsUnavailableAndCannotReturnLateOutput() async throws {
        let runner = try boundedRunner("/bin/sleep 0.3; printf late")
        let operation = Task { await AppKitCommand.invoke(runner: runner, arguments: []) }
        try await Task.sleep(for: .milliseconds(30))
        operation.cancel()
        switch await operation.value {
        case .produced: XCTFail("A cancelled runner cannot produce a verified tree")
        case .failed(let detail): XCTAssertTrue(detail.contains("CancellationError"))
        }
    }

    @MainActor
    func testNonzeroExitPreservesSeparateDiagnostics() async throws {
        let runner = try boundedRunner("printf tree; printf diagnostic >&2; exit 7")
        switch await AppKitCommand.invoke(runner: runner, arguments: []) {
        case .produced: XCTFail("Nonzero status cannot produce a tree")
        case .failed(let detail):
            XCTAssertTrue(detail.contains("exited 7: diagnostic"))
            XCTAssertFalse(detail.contains("tree"))
        }
    }

    @MainActor
    func testLargeDiagnosticStreamCannotBlockTreeDelivery() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("appkit-diagnostics-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let release = directory.appendingPathComponent("release")
        let runner = directory.appendingPathComponent("runner")
        let script = """
            #!/usr/bin/python3
            import os, pathlib, threading, time
            release = pathlib.Path(__file__).parent / "release"
            def cleanup():
                while not release.exists(): time.sleep(0.01)
                os._exit(93)
            threading.Thread(target=cleanup, daemon=True).start()
            os.write(2, b"diagnostic" * 32768)
            os.write(1, b'{"id":"root","role":"container","frame":{"x":0,"y":0,"width":200,"height":100},"children":[]}\\n')
            """
        try script.write(to: runner, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: runner.path)
        let cleanup = Task.detached {
            try await Task.sleep(for: .seconds(3))
            try Data().write(to: release)
        }
        defer {
            cleanup.cancel()
            try? Data().write(to: release)
            try? FileManager.default.removeItem(at: directory)
        }
        let output = CapturedOutput()
        let code = await AppKitCommand(runner: runner.path, subject: "proof", judge: false)
            .run(makeEnvironment(output), pretty: false)
        XCTAssertEqual(code, .pass)
        XCTAssertTrue(output.standardOutput.contains("\"root\""))
    }

    fileprivate func makeEnvironment(_ output: CapturedOutput) -> CommandEnvironment {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("appkit-cli-\(UUID().uuidString)")
        return CommandEnvironment(
            engine: VerdictEngine(
                registry: DemoScenarios.registry,
                baselines: BaselineStore.standard(root: root)
            ),
            output: output,
            pixelArtifactRoot: root.appendingPathComponent(PixelArtifact.directory)
        )
    }

    /// A script standing in for a consumer's runner executable.
    fileprivate func makeRunner(
        renderOutput: String,
        renderExit: Int32 = 0,
        listOutput: String = "subject-a"
    ) throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("appkit-runner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("runner")
        let script = """
            #!/bin/bash
            if [ "$1" = "list" ]; then echo "\(listOutput)"; exit 0; fi
            cat <<'VERDICTUI_TREE'
            \(renderOutput)
            VERDICTUI_TREE
            exit \(renderExit)
            """
        try script.write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: path.path)
        return path.path
    }

    /// A tree with nothing wrong with it.
    private let cleanTree = """
        {"id":"root","role":"container",
         "frame":{"x":0,"y":0,"width":200,"height":100},
         "children":[
           {"id":"label","role":"text",
            "frame":{"x":0,"y":0,"width":180,"height":20},
            "text":"short",
            "textMetrics":{"intrinsicWidth":40,"renderedLineCount":1,"idealLineCount":1},
            "children":[]}]}
        """

    /// The same shape with the text far wider than its frame.
    private let overflowingTree = """
        {"id":"root","role":"container",
         "frame":{"x":0,"y":0,"width":200,"height":100},
         "children":[
           {"id":"label","role":"text",
            "frame":{"x":0,"y":0,"width":100,"height":20},
            "text":"a string far wider than its frame allows",
            "textMetrics":{"intrinsicWidth":260,"renderedLineCount":1,"idealLineCount":1},
            "children":[]}]}
        """

    @MainActor
    func testRenderingThroughARunnerEmitsTheTree() async throws {
        let runner = try makeRunner(renderOutput: cleanTree)
        let output = CapturedOutput()
        let code = await AppKitCommand(runner: runner, subject: "subject-a", judge: false)
            .run(makeEnvironment(output), pretty: false)

        XCTAssertEqual(code, .pass)
        XCTAssertTrue(
            output.standardOutput.contains("\"role\""),
            "the tree must reach stdout — got \(output.standardOutput.prefix(120))")
    }

    @MainActor
    func testListingSubjectsAsksTheRunner() async throws {
        let runner = try makeRunner(renderOutput: cleanTree, listOutput: "login-form")
        let output = CapturedOutput()
        let code = await AppKitCommand(runner: runner, subject: nil, judge: false)
            .run(makeEnvironment(output), pretty: false)

        XCTAssertEqual(code, .pass)
        XCTAssertTrue(output.standardOutput.contains("login-form"))
    }

    @MainActor
    func testJudgingACleanTreeExitsPass() async throws {
        let runner = try makeRunner(renderOutput: cleanTree)
        let output = CapturedOutput()
        let code = await AppKitCommand(runner: runner, subject: "subject-a", judge: true)
            .run(makeEnvironment(output), pretty: false)

        XCTAssertEqual(code, .pass, "a clean tree must PASS — got \(output.standardOutput)")
    }

    /// THE POSITIVE CONTROL. A command that can only ever pass is worthless, and
    /// `docs/adoption.md` records a real consumer view that PASSED with text
    /// overflowing its frame 4x. Without this, `testJudgingACleanTreeExitsPass`
    /// is satisfied by an implementation that returns `.pass` unconditionally.
    @MainActor
    func testJudgingADefectiveTreeExitsVerdictFailed() async throws {
        let runner = try makeRunner(renderOutput: overflowingTree)
        let output = CapturedOutput()
        let code = await AppKitCommand(runner: runner, subject: "subject-a", judge: true)
            .run(makeEnvironment(output), pretty: false)

        XCTAssertEqual(
            code, .verdictFailed,
            "260 pt of text in a 100 pt frame must FAIL — got \(output.standardOutput)")
    }

    // MARK: - The three-valued contract

    /// A missing runner says NOTHING about the UI. Reporting it as
    /// `verdictFailed` would turn an infrastructure fault into a product defect,
    /// which is the exact confusion the exit codes exist to prevent.
    @MainActor
    func testAMissingRunnerIsUnobservableNotAFailedVerdict() async {
        let output = CapturedOutput()
        let code = await AppKitCommand(
            runner: "/nonexistent/runner-\(UUID().uuidString)",
            subject: "subject-a",
            judge: true
        ).run(makeEnvironment(output), pretty: false)

        XCTAssertEqual(code, .couldNotVerify)
        XCTAssertTrue(output.standardError.contains("not an executable"))
    }

    @MainActor
    func testARunnerThatExitsNonZeroIsUnobservable() async throws {
        let runner = try makeRunner(renderOutput: "unknown subject", renderExit: 2)
        let output = CapturedOutput()
        let code = await AppKitCommand(runner: runner, subject: "nope", judge: true)
            .run(makeEnvironment(output), pretty: false)

        XCTAssertEqual(code, .couldNotVerify)
    }

    /// Output that is not a tree is also unobservable — the runner ran, but
    /// produced nothing judgeable.
    @MainActor
    func testUnparseableRunnerOutputIsUnobservable() async throws {
        let runner = try makeRunner(renderOutput: "this is not json")
        let output = CapturedOutput()
        let code = await AppKitCommand(runner: runner, subject: "subject-a", judge: true)
            .run(makeEnvironment(output), pretty: false)

        XCTAssertEqual(code, .couldNotVerify)
        XCTAssertTrue(output.standardError.contains("not a semantic tree"))
    }

    /// A runner that builds a view and walks nothing must not earn a clean bill
    /// of health. The kernel refuses a tree with nothing observable in it; this
    /// asserts the AppKit path inherits that refusal rather than passing an
    /// empty shell for a screen nobody looked at.
    @MainActor
    func testAnEmptyTreeIsRefusedRatherThanPassed() async throws {
        let empty = """
            {"id":"root","role":"container",
             "frame":{"x":0,"y":0,"width":200,"height":100},"children":[]}
            """
        let runner = try makeRunner(renderOutput: empty)
        let output = CapturedOutput()
        let code = await AppKitCommand(runner: runner, subject: "subject-a", judge: true)
            .run(makeEnvironment(output), pretty: false)

        XCTAssertNotEqual(
            code, .pass,
            "an empty tree is vacuous and must never pass — got \(output.standardOutput)")
    }
}

extension AppKitCommandRunnerTests {
    /// `--summary` must produce prose, not JSON.
    ///
    /// A flag the parser ACCEPTS and the command IGNORES is worse than an
    /// unsupported one: the caller believes they asked for prose, gets JSON, and
    /// only finds out when a human tries to read it. Found by the renderer agent
    /// dogfooding the verb rather than by any assertion here — which is why this
    /// test now exists.
    @MainActor
    func testSummaryPrintsProseRatherThanJSON() async throws {
        let runner = try makeRunnerForSummary()
        let output = CapturedOutput()
        let code = await AppKitCommand(runner: runner, subject: "subject-a", judge: true)
            .run(makeEnvironment(output), pretty: false, summary: true)

        XCTAssertEqual(code, .pass)
        XCTAssertFalse(
            output.standardOutput.hasPrefix("{"),
            "--summary must not emit JSON — got \(output.standardOutput.prefix(80))")
    }

    /// CONTROL: without the flag the same call still emits JSON. Without this,
    /// the assertion above is satisfied by a command that never emits JSON.
    @MainActor
    func testWithoutSummaryTheOutputIsStillJSON() async throws {
        let runner = try makeRunnerForSummary()
        let output = CapturedOutput()
        _ = await AppKitCommand(runner: runner, subject: "subject-a", judge: true)
            .run(makeEnvironment(output), pretty: false, summary: false)

        XCTAssertTrue(output.standardOutput.hasPrefix("{"))
    }

    private func makeRunnerForSummary() throws -> String {
        try makeRunner(
            renderOutput: """
                {"id":"root","role":"container",
                 "frame":{"x":0,"y":0,"width":200,"height":100},
                 "children":[
                   {"id":"label","role":"text",
                    "frame":{"x":0,"y":0,"width":180,"height":20},
                    "text":"short",
                    "textMetrics":{"intrinsicWidth":40,"renderedLineCount":1,
                                   "idealLineCount":1},
                    "children":[]}]}
                """)
    }
}
