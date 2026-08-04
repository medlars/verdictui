import XCTest

@testable import VerdictUIKernel

/// Keeps `contracts/fixtures/` honest: every fixture is exactly what
/// `Verdict.encode(to:)` produces today, byte for byte.
///
/// The fixtures exist so `contracts/validate-contracts.py` can check the Swift
/// encoder against `verdict-schema.json` without a Swift toolchain (the Python CI
/// job runs on Linux). That only proves anything while the files still match the
/// encoder — a stale fixture would validate happily and tell us nothing about the
/// code. Hence this test: the fixtures are generated, never hand-edited.
///
/// To regenerate after an intentional wire-format change:
/// `VERDICTUI_WRITE_FIXTURES=1 swift test --filter ContractFixtureTests`
/// then read the diff, because a diff here is a change to a published contract.
final class ContractFixtureTests: XCTestCase {

    private static let regenerateEnvironmentKey = "VERDICTUI_WRITE_FIXTURES"

    /// Repository root, derived from this file's path — the test bundle has no
    /// resources and the kernel must not learn about the filesystem layout.
    private var fixtureDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // VerdictUIKernelTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repository root
            .appendingPathComponent("contracts/fixtures", isDirectory: true)
    }

    /// 2026-08-04T09:20:31Z. Fixed, because a fixture regenerated from `Date()`
    /// would differ on every run and teach everyone to ignore the diff.
    private let instant = Date(timeIntervalSince1970: 1_785_835_231)

    /// Sorted keys and a trailing newline so the file is diffable and
    /// git-friendly; unescaped slashes so structural paths stay readable.
    private func encoded(_ verdict: Verdict) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(verdict) + Data("\n".utf8)
    }

    // MARK: - Fixture subjects

    /// A clean verdict with every optional field absent — the omission contract.
    private func passingVerdict() -> Verdict {
        Verdict(
            scenario: "settings-pane-clean",
            findings: [],
            timestamp: instant,
            timing: Verdict.Timing(evaluateMs: 0.42)
        )
    }

    /// A failing verdict carrying every optional field at once: both severities,
    /// a finding with and without a suggestion, an embedded tree, and a delta
    /// with all four categories populated.
    private func failingVerdict() -> Verdict {
        let before = SemanticNode(
            id: "root",
            role: .container,
            frame: Rect(x: 0, y: 0, width: 320, height: 240),
            structuralPath: "root",
            children: [
                SemanticNode(
                    id: "title",
                    role: .text,
                    frame: Rect(x: 16, y: 16, width: 120, height: 20),
                    text: "Monthly summary",
                    textMetrics: TextMetrics(
                        intrinsicWidth: 212,
                        renderedLineCount: 1,
                        idealLineCount: 1
                    ),
                    structuralPath: "root/text[0]"
                ),
                SemanticNode(
                    id: "close",
                    role: .button,
                    frame: Rect(x: 280, y: 16, width: 24, height: 18),
                    attributes: ["role.hint": .string("dismiss"), "enabled": .bool(true)],
                    structuralPath: "root/button[1]"
                ),
                SemanticNode(
                    id: "legend",
                    role: .text,
                    frame: Rect(x: 16, y: 48, width: 100, height: 16),
                    text: "Totals",
                    isVisible: false,
                    zIndex: 2,
                    structuralPath: "root/text[2]"
                ),
                SemanticNode(
                    id: "footer",
                    role: .container,
                    frame: Rect(x: 0, y: 208, width: 320, height: 32),
                    structuralPath: "root/container[3]"
                ),
            ]
        )
        var after = before
        after.children[0].frame = Rect(x: 16, y: 20, width: 120, height: 20)
        after.children[1].attributes["enabled"] = .bool(false)
        after.children.removeLast()  // 'footer' — populates delta.removed
        after.children.append(
            SemanticNode(
                id: "retry",
                role: .button,
                frame: Rect(x: 16, y: 72, width: 88, height: 32),
                structuralPath: "root/button[3]"
            )
        )
        let delta = TreeDiff.compute(before: before, after: after)

        return Verdict(
            scenario: "settings-pane-regression",
            findings: [
                Finding(
                    rule: TruncationRule.id,
                    severity: .error,
                    nodeID: "title",
                    message: "'title' needs 212 pt of width on one line but was given 120 pt",
                    suggestion: "increase frame width to >= intrinsicWidth 212 pt, or allow wrapping"
                ),
                Finding(
                    rule: TapTargetRule.id,
                    severity: .warning,
                    nodeID: "close",
                    message: "'close' is 24 x 18 pt, below the 28 x 28 pt minimum hit size"
                ),
            ],
            timestamp: instant,
            tree: after,
            delta: delta,
            timing: Verdict.Timing(settleMs: 8.5, evaluateMs: 0.42)
        )
    }

    private func fixtures() -> [(name: String, verdict: Verdict)] {
        [
            ("verdict-pass.json", passingVerdict()),
            ("verdict-fail.json", failingVerdict()),
        ]
    }

    // MARK: - Tests

    func testCommittedFixturesAreExactlyWhatTheEncoderProduces() throws {
        let regenerating = ProcessInfo.processInfo.environment[Self.regenerateEnvironmentKey] != nil
        if regenerating {
            try FileManager.default.createDirectory(
                at: fixtureDirectory,
                withIntermediateDirectories: true
            )
        }
        for (name, verdict) in fixtures() {
            let url = fixtureDirectory.appendingPathComponent(name)
            let produced = try encoded(verdict)
            if regenerating {
                try produced.write(to: url)
                continue
            }
            let committed = try Data(contentsOf: url)
            XCTAssertEqual(
                String(decoding: committed, as: UTF8.self),
                String(decoding: produced, as: UTF8.self),
                """
                \(name) no longer matches Verdict.encode(to:). If the wire format \
                changed on purpose, regenerate with \
                \(Self.regenerateEnvironmentKey)=1 swift test --filter ContractFixtureTests \
                and review the diff as a contract change.
                """
            )
        }
        XCTAssertFalse(regenerating, "fixtures rewritten — re-run without the env var to verify")
    }

    /// The fixtures are also a decoder corpus: whatever the encoder wrote, this
    /// kernel must read back into the same value.
    func testEveryFixtureDecodesBackToItsSubject() throws {
        for (name, verdict) in fixtures() {
            let url = fixtureDirectory.appendingPathComponent(name)
            let decoded = try JSONDecoder().decode(Verdict.self, from: try Data(contentsOf: url))
            XCTAssertEqual(decoded, verdict, "\(name) did not round-trip")
        }
    }

    /// What the Python validator will be asked to prove, asserted here too so a
    /// broken fixture fails in the Swift suite as well as in the contract gate.
    func testFixturesCoverBothTheOmittedAndThePopulatedOptionalFields() throws {
        let passing = try String(
            contentsOf: fixtureDirectory.appendingPathComponent("verdict-pass.json"),
            encoding: .utf8
        )
        XCTAssertTrue(passing.contains("\"status\" : \"PASS\""), passing)
        XCTAssertFalse(passing.contains("\"tree\""), "the PASS fixture must exercise omission")
        XCTAssertFalse(passing.contains("\"delta\""), "the PASS fixture must exercise omission")
        XCTAssertFalse(passing.contains("null"), "absent means absent, never null")

        let failing = try String(
            contentsOf: fixtureDirectory.appendingPathComponent("verdict-fail.json"),
            encoding: .utf8
        )
        XCTAssertTrue(failing.contains("\"status\" : \"FAIL\""), failing)
        let everyOptionalField = [
            "\"tree\"", "\"delta\"", "\"added\"", "\"removed\"", "\"moved\"", "\"changed\"",
            "\"settleMs\"", "\"evaluateMs\"", "\"suggestion\"", "\"attributes\"",
            "\"textMetrics\"", "\"zIndex\"", "\"text\"", "\"isVisible\" : false",
            "\"severity\" : \"error\"", "\"severity\" : \"warning\"",
        ]
        for required in everyOptionalField {
            XCTAssertTrue(failing.contains(required), "FAIL fixture is missing \(required)")
        }
        XCTAssertFalse(failing.contains("null"), "absent means absent, never null")
    }

    func testFixturesDeclareTheKernelsCurrentSchemaVersion() throws {
        for (name, _) in fixtures() {
            let text = try String(
                contentsOf: fixtureDirectory.appendingPathComponent(name),
                encoding: .utf8
            )
            XCTAssertTrue(
                text.contains("\"schemaVersion\" : \"\(SchemaVersion.current)\""),
                "\(name) declares a schema version this kernel does not emit"
            )
        }
    }
}
