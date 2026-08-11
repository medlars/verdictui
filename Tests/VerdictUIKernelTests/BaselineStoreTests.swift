import Foundation
import XCTest

@testable import VerdictUIKernel

/// The storage half of baselines — the only part of the product that can
/// destroy anything, so the tests are weighted toward what it refuses.
final class BaselineStoreTests: XCTestCase {
    private var root: URL!
    private var store: BaselineStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("verdictui-baseline-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = BaselineStore.standard(root: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private func tree(width: Double = 100) -> SemanticNode {
        SemanticNode(
            id: "root",
            role: .container,
            frame: Rect(x: 0, y: 0, width: 200, height: 200),
            children: [
                SemanticNode(
                    id: "save-button",
                    role: .button,
                    frame: Rect(x: 10, y: 10, width: width, height: 32),
                    text: "Save"
                )
            ]
        )
    }

    // MARK: - Round trip

    func testARecordedBaselineLoadsBackIdentically() throws {
        try store.update(scenario: "demo", tree: tree(), accepted: false)
        let loaded = try store.load(scenario: "demo")

        XCTAssertEqual(loaded.scenario, "demo")
        XCTAssertEqual(loaded.schemaVersion, SchemaVersion.current)
        XCTAssertEqual(
            loaded.tree,
            Baseline.canonicalize(tree()),
            "a baseline stores the CANONICAL tree, so what loads back must equal the "
                + "canonicalization of what went in — not the raw input"
        )
    }

    func testLoadingAnUnrecordedScenarioIsAnErrorRatherThanAnEmptyBaseline() {
        XCTAssertThrowsError(try store.load(scenario: "never-recorded")) { error in
            XCTAssertEqual(
                error as? BaselineStore.StoreError,
                .notRecorded(scenario: "never-recorded"),
                "an absent baseline must be an error: returning an empty one would make every "
                    + "live tree 'drift' from nothing, and the real answer is that no record exists"
            )
        }
    }

    // MARK: - The destructive guard

    /// The load-bearing refusal, and the reason this type exists separately
    /// from `Baselines.swift`.
    func testReplacingAnExistingBaselineWithoutAcceptIsRefused() throws {
        try store.update(scenario: "demo", tree: tree(width: 100), accepted: false)

        XCTAssertThrowsError(
            try store.update(scenario: "demo", tree: tree(width: 999), accepted: false)
        ) { error in
            XCTAssertEqual(
                error as? BaselineStore.StoreError,
                .updateNotAccepted(scenario: "demo")
            )
        }

        let survivor = try store.load(scenario: "demo")
        XCTAssertEqual(
            survivor.tree.children.first?.frame.width,
            100,
            "the refused update must not have partially written — the original baseline is "
                + "still the 100 pt one"
        )
    }

    /// The control for the refusal above: a FIRST baseline destroys nothing, so
    /// requiring `--accept` for it would train users to pass the flag
    /// reflexively and the guard would stop being a guard.
    func testCreatingAFirstBaselineNeedsNoAcceptance() throws {
        let outcome = try store.update(scenario: "fresh", tree: tree(), accepted: false)
        XCTAssertEqual(outcome, .created)
        XCTAssertTrue(store.exists(scenario: "fresh"))
    }

    func testAnAcceptedReplacementSucceedsAndReportsThatItReplaced() throws {
        try store.update(scenario: "demo", tree: tree(width: 100), accepted: false)
        let outcome = try store.update(scenario: "demo", tree: tree(width: 120), accepted: true)

        XCTAssertEqual(outcome, .replaced)
        XCTAssertEqual(try store.load(scenario: "demo").tree.children.first?.frame.width, 120)
    }

    // MARK: - The audit log

    func testReplacingABaselineLogsTheSupersededContentHash() throws {
        try store.update(scenario: "demo", tree: tree(width: 100), accepted: false)
        XCTAssertEqual(
            try store.auditEntries(),
            [],
            "creating a first baseline supersedes nothing, so it must not write an audit line — "
                + "a log that records non-destructive acts buries the destructive ones"
        )

        try store.update(scenario: "demo", tree: tree(width: 120), accepted: true)
        let entries = try store.auditEntries()

        XCTAssertEqual(entries.count, 1)
        let entry = try XCTUnwrap(entries.first)
        XCTAssertTrue(entry.contains("scenario=demo"), entry)
        XCTAssertTrue(entry.contains("superseded-sha256="), entry)

        // The hash must be of the OVERWRITTEN content: after the fact the
        // question is "what did I destroy", and the replacement is still on
        // disk for anyone who wants its hash.
        let superseded = Baseline(scenario: "demo", tree: tree(width: 100))
        let expected = BaselineStore.hash(of: try BaselineStore.encoder.encode(superseded))
        XCTAssertTrue(
            entry.contains(expected),
            "the logged hash is not the superseded baseline's.\nentry: \(entry)\n"
                + "expected to contain: \(expected)"
        )
    }

    func testTheAuditLogAppendsRatherThanRewrites() throws {
        try store.update(scenario: "demo", tree: tree(width: 100), accepted: false)
        for width in [110.0, 120.0, 130.0] {
            try store.update(scenario: "demo", tree: tree(width: width), accepted: true)
        }

        XCTAssertEqual(
            try store.auditEntries().count,
            3,
            "three replacements must leave three lines — a log that rewrites keeps only the "
                + "most recent destruction, which is the one you least need explained"
        )
    }

    // MARK: - Layout

    /// The audit log is a SIBLING of the baseline directory, never a child.
    ///
    /// Not a cosmetic path choice: a careless `rm -rf verdict-baselines` must
    /// destroy the baselines without also destroying the record that they were
    /// destroyed, and a log stored inside the directory it audits is deleted by
    /// the same command.
    func testTheAuditLogLivesOutsideTheDirectoryItAudits() {
        let standard = BaselineStore.standard(root: root)

        XCTAssertEqual(standard.directory.lastPathComponent, "verdict-baselines")
        XCTAssertFalse(
            standard.auditLog.path.hasPrefix(standard.directory.path + "/"),
            "the audit log (\(standard.auditLog.path)) is inside the baseline directory "
                + "(\(standard.directory.path)), so deleting the baselines erases their history too"
        )
    }

    /// ``BaselineStore/UpdateOutcome`` reports which branch ran, so a caller
    /// states a fact rather than inferring one.
    ///
    /// The two cases must DIFFER for the same store across the two calls: an
    /// implementation returning `.created` unconditionally would satisfy any
    /// test that only ever recorded a first baseline.
    func testTheUpdateOutcomeDistinguishesCreationFromReplacement() throws {
        let first = try store.update(scenario: "outcome", tree: tree(), accepted: false)
        let second = try store.update(scenario: "outcome", tree: tree(width: 140), accepted: true)

        XCTAssertEqual(first, .created)
        XCTAssertEqual(second, .replaced)
        XCTAssertNotEqual(first, second)
    }

    // MARK: - Name safety

    /// A scenario name reaches the store from a consumer-populated registry, so
    /// for filesystem purposes it is untrusted input.
    func testAScenarioNameThatEscapesTheDirectoryIsRefused() {
        for hostile in ["../escape", "nested/name", "", ".", ".."] {
            XCTAssertThrowsError(
                try store.url(for: hostile),
                "'\(hostile)' must not resolve to a writable path"
            ) { error in
                XCTAssertEqual(
                    error as? BaselineStore.StoreError,
                    .unusableScenarioName(hostile),
                    "the refusal must be `unusableScenarioName` naming the input — a different "
                        + "error would mean the name was rejected for an unrelated reason and "
                        + "the escape guard is untested"
                )
            }
        }

        // The control: a legal name still resolves, or "rejects hostile names"
        // is satisfied by a guard that rejects every name.
        XCTAssertEqual(
            try store.url(for: "demo-clean-settings").lastPathComponent,
            "demo-clean-settings.tree.json"
        )
    }

    // MARK: - The hash itself

    /// A hand-rolled SHA-256 that is subtly wrong produces audit entries that
    /// look authoritative and identify nothing, so it is pinned to the
    /// published FIPS 180-4 vectors rather than to its own output.
    ///
    /// Values confirmed against the system `shasum -a 256` before being written
    /// here — a self-consistent test ("hashing twice agrees") would pass for
    /// any deterministic function, including a broken one.
    func testTheHashMatchesThePublishedVectors() {
        let vectors: [(String, String)] = [
            ("", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
            ("abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
            (
                "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
                "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
            ),
        ]

        for (input, expected) in vectors {
            let data = Data(input.utf8)
            XCTAssertEqual(
                BaselineStore.hash(of: data),
                expected,
                "SHA-256(\"\(input)\") is wrong — every audit entry written by this build "
                    + "identifies nothing"
            )
        }
    }

    /// Multi-block input: the compression loop runs once for inputs under
    /// 56 bytes, so a padding or chunking defect is invisible on short vectors.
    func testTheHashHandlesInputSpanningMultipleBlocks() {
        let long = String(repeating: "verdictui", count: 100)  // 900 bytes, 15 blocks
        let digest = BaselineStore.hash(of: Data(long.utf8))

        XCTAssertEqual(digest.count, 64, "a SHA-256 digest is 32 bytes / 64 hex characters")
        XCTAssertNotEqual(
            digest,
            BaselineStore.hash(of: Data(String(repeating: "verdictui", count: 99).utf8)),
            "inputs differing by one block must not hash alike"
        )
    }
}
