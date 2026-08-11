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

    private func run(_ arguments: [String], in directory: URL) throws -> Run? {
        guard let binary = Self.binaryURL else { return nil }

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
}
