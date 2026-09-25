import Foundation
import XCTest

@testable import VerdictUICLICore

/// Runs the BUILT `verdictui` binary as a subprocess.
///
/// ### Why this exists, given the whole command surface is already tested
///
/// `VerdictEngineTests` drives the same command objects `main.swift` calls, and
/// it was 8/8 green against a binary that could not execute a single command.
/// The root command was `AsyncParsableCommand` reached through a synchronous
/// `main()`, which compiles, links, and then refuses at RUN time with
/// "Asynchronous root command needs availability annotation" — a failure with
/// no compile-time signal and no in-process test that can observe it, because
/// the defect is in how the process STARTS.
///
/// That is `no.md` #277's shape: a suite verifies code, and cannot see the
/// artifact that ships. So this file asserts on the artifact, and is
/// deliberately thin — three questions the library tests structurally cannot
/// answer: does it start, does it exit with the documented code, and does it
/// keep stdout parseable.
final class CLIBinarySmokeTests: XCTestCase {
    /// The built product, or `nil` when it has not been built.
    ///
    /// Returning `nil` rather than failing is deliberate: `swift test` does not
    /// build executable products, so on a bare `swift test` this suite has no
    /// subject. It says so out loud and skips — an absent binary is "could not
    /// observe", never "observed and fine". The PM's `stage_cli_smoke` builds
    /// the product first, which is where this suite is meant to bite.
    private static var binaryURL: URL? {
        // `#filePath` is Tests/VerdictUICLICoreTests/<this file>; the package
        // root is two levels up, and the build directory is a sibling of it.
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let candidates = ["debug", "release"].map {
            packageRoot.appendingPathComponent(".build/\($0)/verdictui")
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Result of one subprocess run.
    private struct Run {
        let exitCode: Int32
        let standardOutput: String
        let standardError: String
    }

    private func run(_ arguments: [String], in directory: URL, binary: URL? = nil) throws -> Run? {
        guard let binary = binary ?? Self.binaryURL else { return nil }

        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        process.currentDirectoryURL = directory

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()

        // Read BEFORE waiting: a pipe buffer that fills while the parent waits
        // deadlocks the child, and this tool's `render` output is large enough
        // to matter.
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return Run(
            exitCode: process.terminationStatus,
            standardOutput: String(decoding: outData, as: UTF8.self),
            standardError: String(decoding: errData, as: UTF8.self)
        )
    }

    private func temporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("verdictui-smoke-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// The binary starts at all, and its stdout is a parseable document.
    func testTheBinaryRunsAndListsScenarios() throws {
        guard let result = try run(["list"], in: try temporaryDirectory()) else {
            throw XCTSkip("verdictui has not been built — run `swift build --product verdictui`")
        }

        XCTAssertEqual(
            result.exitCode,
            0,
            "the binary did not start cleanly.\nstderr: \(result.standardError)"
        )
        let names = try JSONDecoder().decode(
            [String].self,
            from: Data(result.standardOutput.utf8)
        )
        XCTAssertFalse(names.isEmpty, "list returned no scenarios")
    }

    /// The pid-based reader must be REACHABLE from the shipped binary.
    ///
    /// `AXReader.readTree(pid:)` and `AXReader.press(pid:named:)` have existed
    /// as library API, tested and correct, while no CLI verb, MCP tool or
    /// production caller could reach them. That is a PORT, not an integration:
    /// the capability is available only to someone writing Swift against the
    /// package, which is precisely the audience that does not need a tool.
    ///
    /// It is the same defect this session already guarded against one level
    /// down — a Core rule is only worth the call site that invokes it — and it
    /// shipped anyway, which is why the assertion lives on the ARTIFACT rather
    /// than on the command object: an in-process test of `InspectCommand` would
    /// pass against a binary that never registered the subcommand.
    ///
    /// Asserts on `--help` rather than a live read, deliberately: a real
    /// inspection needs a windowed app and Accessibility trust, so gating this
    /// on either would make it skip on exactly the machines that most need to
    /// know the verb is wired.
    func testTheInspectVerbIsReachableFromTheBinary() throws {
        guard let result = try run(["inspect", "--help"], in: try temporaryDirectory()) else {
            throw XCTSkip("verdictui has not been built — run `swift build --product verdictui`")
        }

        XCTAssertEqual(
            result.exitCode, 0,
            """
            `verdictui inspect --help` did not run, so the pid-based AX reader \
            is unreachable from the shipped tool no matter how correct the \
            library API is.\nstderr: \(result.standardError)
            """
        )
        let help = result.standardOutput + result.standardError
        XCTAssertTrue(
            help.contains("--pid"),
            "inspect does not take a --pid, so it cannot target a running app: \(help)"
        )
    }

    /// The live-app verbs added for CIS-009B4F22 / CIS-B5DA3C41 / CIS-1DDD35B2,
    /// asserted on the ARTIFACT for the same reason as `inspect` above.
    func testTheLiveAppVerbsAreReachableFromTheBinary() throws {
        let cases: [([String], [String])] = [
            (["capture", "--help"], ["--pid", "--out", "--window"]),
            (["judge", "--help"], ["--pid", "--app", "--colors"]),
            (["sweep", "--help"], ["--app", "--launch-arg"]),
            (["inspect", "--help"], ["--surface", "--act", "--colors", "--app"]),
        ]
        for (argv, flags) in cases {
            guard let result = try run(argv, in: try temporaryDirectory()) else {
                throw XCTSkip("verdictui has not been built — run `swift build --product verdictui`")
            }
            XCTAssertEqual(result.exitCode, 0, "\(argv): \(result.standardError)")
            let help = result.standardOutput + result.standardError
            for flag in flags {
                XCTAssertTrue(help.contains(flag), "\(argv.joined(separator: " ")) lacks \(flag)")
            }
        }
    }

    /// The three-valued exit contract, asserted on the shipped artifact.
    ///
    /// Table-driven across all three codes in one test because the contract is
    /// that they DIFFER: a binary returning 1 for everything satisfies any test
    /// that only ever checks the failing case.
    func testTheDocumentedExitCodesAreWhatTheBinaryReturns() throws {
        let directory = try temporaryDirectory()

        let cases: [(arguments: [String], expected: Int32, why: String)] = [
            (["verify", "demo-clean-settings"], 0, "a passing verdict is 0"),
            (["verify", "demo-offscreen-button"], 1, "a FAILING verdict is 1 — the UI is wrong"),
            (
                ["verify", "no-such-scenario"], 2,
                "an unverifiable request is 2 — it says nothing about any UI, and returning 1 "
                    + "would blame a screen the tool never rendered"
            ),
        ]

        for testCase in cases {
            guard let result = try run(testCase.arguments, in: directory) else {
                throw XCTSkip("verdictui has not been built")
            }
            XCTAssertEqual(
                result.exitCode,
                testCase.expected,
                "\(testCase.arguments.joined(separator: " ")): \(testCase.why).\n"
                    + "stderr: \(result.standardError)"
            )
        }
    }

    /// stdout stays a machine contract even when the verdict fails.
    ///
    /// The failing path is the one where a stray progress line is most likely
    /// to be added later, and an agent parsing the document would break on it.
    func testAFailingVerdictStillWritesOnlyJSONToStandardOutput() throws {
        guard
            let result = try run(
                ["verify", "demo-offscreen-button"],
                in: try temporaryDirectory()
            )
        else {
            throw XCTSkip("verdictui has not been built")
        }

        XCTAssertEqual(result.exitCode, 1)
        XCTAssertNoThrow(
            try JSONSerialization.jsonObject(with: Data(result.standardOutput.utf8)),
            "stdout must be one complete JSON document on the failing path too. Got:\n"
                + result.standardOutput
        )
    }

    /// The destructive command refuses without `--accept`, from the artifact.
    func testTheBinaryRefusesToReplaceABaselineWithoutAccept() throws {
        let directory = try temporaryDirectory()

        guard
            let created = try run(["baseline", "demo-clean-settings", "--update"], in: directory)
        else {
            throw XCTSkip("verdictui has not been built")
        }
        XCTAssertEqual(created.exitCode, 0, "creating a first baseline destroys nothing")

        let refused = try XCTUnwrap(
            try run(["baseline", "demo-clean-settings", "--update"], in: directory)
        )
        XCTAssertEqual(
            refused.exitCode,
            2,
            "replacing a baseline without --accept must be refused"
        )
        XCTAssertTrue(
            refused.standardError.contains("--accept"),
            "the refusal must name the flag that would proceed: \(refused.standardError)"
        )
    }

    func testScenarioActBinaryPreservesStepWireAndThreeValuedExits() throws {
        let directory = try temporaryDirectory()
        let cases: [([String], Int32)] = [
            (["act", "demo-toggle-layout", "toggle", "advanced-toggle", "--include-tree", "--pretty"], 0),
            (["act", "demo-toggle-layout", "tap", "missing-act-probe"], 1),
            (["act", "missing-act-scenario", "tap", "p"], 2),
        ]
        for (arguments, expected) in cases {
            guard let result = try run(arguments, in: directory) else {
                throw XCTSkip("verdictui has not been built")
            }
            XCTAssertEqual(result.exitCode, expected, result.standardError + result.standardOutput)
            if expected == 2 {
                XCTAssertTrue(result.standardOutput.isEmpty)
                XCTAssertTrue(result.standardError.contains("missing-act-scenario"))
            } else {
                let wire = try JSONDecoder().decode(StepResultWire.self, from: Data(result.standardOutput.utf8))
                XCTAssertEqual(wire.status, expected == 0 ? "PASS" : "FAIL")
                XCTAssertEqual(wire.probe, arguments[3])
                if expected == 0 {
                    XCTAssertNotNil(wire.tree?.expand()?.node(withID: "advanced-detail"))
                    XCTAssertNil(wire.tree?.expand()?.node(withID: "collapsed-summary"))
                    XCTAssertTrue(result.standardOutput.contains("\n  "))
                } else {
                    XCTAssertNil(wire.tree)
                    XCTAssertTrue(wire.findings.contains { $0.nodeID == "missing-act-probe" && !$0.rule.isEmpty })
                }
            }
        }
    }

    func testScenarioActBinaryRejectsMalformedRequestsWithoutAVerdict() throws {
        let directory = try temporaryDirectory()
        for arguments in [
            ["act", "demo-toggle-layout", "click", "advanced-toggle"],
            ["act", "demo-toggle-layout", "setText", "advanced-toggle"],
            ["act", "demo-toggle-layout", "setSlider", "advanced-toggle"],
            ["act", "demo-toggle-layout", "setSlider", "advanced-toggle", "--value=nan"],
            ["act", "demo-toggle-layout", "setSlider", "advanced-toggle", "--value=inf"],
        ] {
            guard let result = try run(arguments, in: directory) else {
                throw XCTSkip("verdictui has not been built")
            }
            XCTAssertEqual(result.exitCode, 2, "\(arguments): \(result.standardError)")
            XCTAssertTrue(result.standardOutput.isEmpty, "invalid input must not manufacture a verdict")
            XCTAssertFalse(result.standardError.isEmpty)
        }
    }

    /// This shell fixture proves launcher routing/argv only; custom-registry
    /// action semantics are separately covered by ActToolTests.
    func testScenarioActBinaryForwardsToDeclaredRunnerWithoutDemoFallback() throws {
        let directory = try temporaryDirectory()
        let config = directory.appendingPathComponent(".verdictui")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try Data(#"{"runner":"fixture-runner"}"#.utf8).write(to: config.appendingPathComponent("config.json"))
        let runner = directory.appendingPathComponent("fixture-runner")
        try Data("""
            #!/bin/sh
            printf '%s\\n' "$@" > received-argv.txt
            printf '%s\\n' '{"fixture":"declared-runner"}'
            """.utf8).write(to: runner)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runner.path)
        let arguments = ["act", "consumer-only-screen", "setText", "consumer-field", "--text=--help", "--include-tree"]
        guard let result = try run(arguments, in: directory) else {
            throw XCTSkip("verdictui has not been built")
        }
        XCTAssertEqual(result.exitCode, 0, result.standardError)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.standardOutput.utf8)) as? [String: String])
        XCTAssertEqual(object, ["fixture": "declared-runner"])
        let received = try String(contentsOf: directory.appendingPathComponent("received-argv.txt"), encoding: .utf8)
        XCTAssertEqual(received.split(separator: "\n").map(String.init), arguments)

        try Data(#"{"runner":"missing-runner"}"#.utf8).write(to: config.appendingPathComponent("config.json"))
        let refused = try XCTUnwrap(try run(["act", "demo-toggle-layout", "toggle", "advanced-toggle"], in: directory))
        XCTAssertEqual(refused.exitCode, 2, "a broken consumer runner must not fall back to a passing demo")
        XCTAssertTrue(refused.standardOutput.isEmpty)
        XCTAssertTrue(refused.standardError.contains("missing-runner"))
    }

    /// Stock main() and compiled consumer main(arguments) must select the same
    /// concrete overloads. This runner's demo registry proves entrypoint parity,
    /// while the consumer-only TaskLocal control verifies registry ownership.
    func testSharedEntrypointsPreserveHelpSyntaxAndVerdictExits() throws {
        guard let stock = Self.binaryURL else { throw XCTSkip("verdictui has not been built") }
        let consumer = stock.deletingLastPathComponent().appendingPathComponent("VerdictUIProjectRunner")
        guard FileManager.default.isExecutableFile(atPath: consumer.path) else {
            throw XCTSkip("VerdictUIProjectRunner has not been built")
        }
        let directory = try temporaryDirectory()
        for binary in [stock, consumer] {
            for arguments in [[], ["list"]] {
                let result = try XCTUnwrap(try run(arguments, in: directory, binary: binary))
                XCTAssertEqual(result.exitCode, 0, result.standardError)
                let names = try JSONDecoder().decode([String].self, from: Data(result.standardOutput.utf8))
                XCTAssertTrue(names.contains("demo-toggle-layout"))
            }
            for arguments in [["--help"], ["act", "--help"], ["help", "act"], ["--version"]] {
                let result = try XCTUnwrap(try run(arguments, in: directory, binary: binary))
                XCTAssertEqual(result.exitCode, 0, "\(binary.lastPathComponent) \(arguments): \(result.standardError)")
                XCTAssertFalse(result.standardOutput.isEmpty)
                XCTAssertTrue(result.standardError.isEmpty)
            }
            for arguments in [
                ["act"],
                ["act", "demo-toggle-layout", "toggle"],
                ["act", "demo-toggle-layout", "setSlider", "advanced-toggle", "--value=oops"],
                ["act", "demo-toggle-layout", "toggle", "advanced-toggle", "--imaginary"],
            ] {
                let result = try XCTUnwrap(try run(arguments, in: directory, binary: binary))
                XCTAssertEqual(result.exitCode, 2, "\(binary.lastPathComponent) \(arguments): \(result.standardError)")
                XCTAssertTrue(result.standardOutput.isEmpty)
                XCTAssertFalse(result.standardError.isEmpty)
            }
            let cases: [([String], Int32)] = [
                (["act", "demo-toggle-layout", "toggle", "advanced-toggle", "--include-tree"], 0),
                (["act", "demo-toggle-layout", "setText", "missing-text-probe", "--text=--help"], 1),
                (["act", "missing-scenario", "tap", "p"], 2),
            ]
            for (arguments, expected) in cases {
                let result = try XCTUnwrap(try run(arguments, in: directory, binary: binary))
                XCTAssertEqual(result.exitCode, expected, result.standardError)
                if expected == 2 {
                    XCTAssertTrue(result.standardOutput.isEmpty)
                    XCTAssertTrue(result.standardError.contains("missing-scenario"))
                } else {
                    let wire = try JSONDecoder().decode(StepResultWire.self, from: Data(result.standardOutput.utf8))
                    XCTAssertEqual(wire.status, expected == 0 ? "PASS" : "FAIL")
                    XCTAssertEqual(wire.probe, arguments[3])
                    if expected == 0 {
                        XCTAssertNotNil(wire.tree?.expand()?.node(withID: "advanced-detail"))
                    } else {
                        XCTAssertTrue(wire.findings.contains { $0.nodeID == "missing-text-probe" })
                    }
                    XCTAssertTrue(result.standardError.isEmpty)
                }
            }
        }
    }
}
