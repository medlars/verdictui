import XCTest

@testable import VerdictUIKernel

/// Baselines catch the class neither rules nor expectations can: *unintended
/// change*, where nothing is detectably wrong and nothing was asserted, but the
/// screen is no longer the one that was reviewed.
///
/// Two properties decide whether the channel is usable, and both are pinned
/// harder than the happy path. **Canonicalization must be idempotent and
/// jitter-proof** — a baseline that fails on sub-pixel layout noise fails on
/// every machine and gets deleted within a day. And **a schema-incompatible
/// baseline must say so** rather than reporting every field as drift, because
/// the useful answer ("this file predates a schema change") would otherwise be
/// buried under noise it caused itself.
final class BaselinesTests: XCTestCase {
    private static let viewport = Rect(x: 0, y: 0, width: 400, height: 300)

    private func context(scenario: String = "settings") -> LintContext {
        LintContext(scenario: scenario, viewport: Self.viewport)
    }

    private func tree(
        saveFrame: Rect = Rect(x: 112, y: 200, width: 80, height: 32),
        saveText: String? = "Save",
        extra: [SemanticNode] = []
    ) -> SemanticNode {
        SemanticNode(
            id: "root",
            role: .container,
            frame: Self.viewport,
            children: [
                SemanticNode(
                    id: "save-button",
                    role: .button,
                    frame: saveFrame,
                    text: saveText
                )
            ] + extra
        )
    }

    // MARK: - Canonical form

    /// The property the whole channel rests on: two recordings of unchanged
    /// code must be identical, or every baseline is a flake.
    func testAnUnchangedTreeMatchesItsOwnBaseline() {
        let baseline = Baseline(scenario: "settings", tree: tree())

        let comparison = BaselineCheck.compare(tree(), to: baseline, context: context())

        XCTAssertTrue(comparison.matches, "got: \(comparison.findings.map(\.message))")
        XCTAssertTrue(comparison.delta.isEmpty)
    }

    /// Sub-quantum jitter is what SwiftUI's layout arithmetic produces between
    /// runs and machines. If it read as drift the channel would be unusable.
    func testSubQuantumJitterIsNotDrift() {
        let baseline = Baseline(scenario: "settings", tree: tree())
        let jittered = tree(saveFrame: Rect(x: 112.1, y: 199.9, width: 80.2, height: 31.8))

        let comparison = BaselineCheck.compare(jittered, to: baseline, context: context())

        XCTAssertTrue(comparison.matches, "got: \(comparison.findings.map(\.message))")
    }

    /// The other end of the same window: a move large enough to see must be
    /// reported, or the significance filter has swallowed the signal.
    func testARealMoveIsDrift() {
        let baseline = Baseline(scenario: "settings", tree: tree())
        let moved = tree(saveFrame: Rect(x: 160, y: 200, width: 80, height: 32))

        let comparison = BaselineCheck.compare(moved, to: baseline, context: context())

        XCTAssertFalse(comparison.matches)
        XCTAssertEqual(comparison.findings.count, 1)
        XCTAssertEqual(comparison.findings.first?.rule, "baseline-drift")
        XCTAssertEqual(comparison.findings.first?.severity, .error)
        XCTAssertTrue(
            comparison.findings.first?.message.contains("moved from") == true,
            "got: \(comparison.findings.first?.message ?? "none")"
        )
    }

    /// Canonicalization is applied on the way IN, so what is stored is what is
    /// compared and a reader of the file sees the values the engine uses.
    func testCanonicalizationSnapsCoordinatesOnConstruction() throws {
        let baseline = Baseline(
            scenario: "settings",
            tree: tree(saveFrame: Rect(x: 112.1, y: 199.9, width: 80.2, height: 31.8))
        )
        let stored = try XCTUnwrap(baseline.tree.node(withID: "save-button"))

        XCTAssertEqual(stored.frame.x, 112.0)
        XCTAssertEqual(stored.frame.y, 200.0)
        XCTAssertEqual(stored.frame.width, 80.0)
        XCTAssertEqual(stored.frame.height, 32.0)
    }

    /// Canonicalizing an already-canonical tree must change nothing, or a
    /// re-recorded baseline would differ from the one it replaced for no reason.
    func testCanonicalizationIsIdempotent() {
        let once = Baseline.canonicalize(tree(saveFrame: Rect(x: 112.1, y: 199.9, width: 80.2, height: 31.8)))
        let twice = Baseline.canonicalize(once)

        XCTAssertEqual(once, twice)
    }

    /// A non-finite coordinate is a defect `zero-size` owns. Rounding it would
    /// launder a broken frame into a plausible-looking one.
    func testNonFiniteCoordinatesAreLeftAloneRatherThanLaundered() {
        let broken = Baseline.canonicalize(
            SemanticNode(id: "x", role: .container, frame: Rect(x: .nan, y: 0, width: 10, height: 10))
        )

        XCTAssertTrue(broken.frame.x.isNaN, "a NaN coordinate must survive canonicalization")
    }

    /// `BaselineComparison` carries the delta ALONGSIDE the findings, and both
    /// halves are load-bearing: the findings are what a verdict reports, and the
    /// delta is what an agent replays to see exactly what moved. `matches` must
    /// be derived from the findings rather than from the delta, because a
    /// suppressed change leaves the delta non-empty while the comparison is, by
    /// the author's own directive, a match.
    func testAComparisonReportsBothItsDeltaAndItsFindingsAndMatchesOnTheFindings() {
        var recorded = tree()
        recorded.children[0].attributes[LintContext.suppressionKey] = .string("baseline-drift")
        let baseline = Baseline(scenario: "settings", tree: recorded)

        var moved = tree(saveFrame: Rect(x: 160, y: 200, width: 80, height: 32))
        moved.children[0].attributes[LintContext.suppressionKey] = .string("baseline-drift")

        let comparison: BaselineComparison = BaselineCheck.compare(
            moved, to: baseline, context: context()
        )

        XCTAssertEqual(comparison.scenario, "settings")
        XCTAssertTrue(comparison.matches, "a suppressed change is a match")
        XCTAssertTrue(comparison.findings.isEmpty)
        XCTAssertFalse(
            comparison.delta.isEmpty,
            "the delta must still record what moved — suppression silences the FINDING, "
                + "not the observation an agent replays"
        )
    }

    // MARK: - Every drift category is reported

    func testAnAddedNodeIsReported() {
        let baseline = Baseline(scenario: "settings", tree: tree())
        let grown = tree(extra: [
            SemanticNode(id: "new-badge", role: .text, frame: Rect(x: 0, y: 0, width: 20, height: 20))
        ])

        let findings = BaselineCheck.compare(grown, to: baseline, context: context()).findings

        XCTAssertEqual(findings.count, 1)
        XCTAssertTrue(
            findings.first?.message.contains("is new since the baseline") == true,
            "got: \(findings.first?.message ?? "none")"
        )
    }

    func testARemovedNodeIsReported() {
        let baseline = Baseline(
            scenario: "settings",
            tree: tree(extra: [
                SemanticNode(id: "badge", role: .text, frame: Rect(x: 0, y: 0, width: 20, height: 20))
            ])
        )

        let findings = BaselineCheck.compare(tree(), to: baseline, context: context()).findings

        XCTAssertEqual(findings.count, 1)
        XCTAssertTrue(
            findings.first?.message.contains("was in the baseline and is now gone") == true,
            "got: \(findings.first?.message ?? "none")"
        )
    }

    func testAChangedFieldNamesBothValues() {
        let baseline = Baseline(scenario: "settings", tree: tree())
        let retitled = tree(saveText: "Submit")

        let findings = BaselineCheck.compare(retitled, to: baseline, context: context()).findings

        XCTAssertEqual(findings.count, 1)
        XCTAssertTrue(
            findings.first?.message.contains("Save → Submit") == true,
            "the message must name both values, got: \(findings.first?.message ?? "none")"
        )
    }

    /// A field GAINED and a field LOST are different events, and collapsing
    /// both to "text changed" leaves a reader unable to tell which happened.
    func testAGainedOrLostFieldReadsAsAbsenceRatherThanEmptiness() {
        let baseline = Baseline(scenario: "settings", tree: tree(saveText: nil))
        let gained = tree(saveText: "Save")

        let findings = BaselineCheck.compare(gained, to: baseline, context: context()).findings

        XCTAssertTrue(
            findings.first?.message.contains("nothing → Save") == true,
            "got: \(findings.first?.message ?? "none")"
        )
    }

    // MARK: - Schema compatibility

    /// An incompatible baseline must say SO. Comparing across a schema change
    /// reports every differing field as drift, burying the real answer under
    /// noise the comparison itself created.
    func testAnIncompatibleSchemaIsNamedRatherThanDiffed() {
        let stale = Baseline(scenario: "settings", schemaVersion: "0.9", tree: tree())

        let comparison = BaselineCheck.compare(tree(), to: stale, context: context())

        XCTAssertEqual(comparison.findings.count, 1)
        XCTAssertTrue(
            comparison.findings.first?.message.contains("cannot compare against") == true,
            "got: \(comparison.findings.first?.message ?? "none")"
        )
        // The delta is deliberately empty: reporting differences computed across
        // incompatible field sets would be evidence for a claim the kernel
        // cannot make.
        XCTAssertTrue(comparison.delta.isEmpty)
    }

    func testACompatibleMinorVersionStillCompares() {
        let baseline = Baseline(scenario: "settings", schemaVersion: "1.0", tree: tree())

        XCTAssertTrue(BaselineCheck.compare(tree(), to: baseline, context: context()).matches)
    }

    // MARK: - Round trip

    /// The file on disk is the contract; a baseline that cannot survive a
    /// round trip cannot be committed and reviewed.
    func testABaselineRoundTripsThroughJSON() throws {
        let original = Baseline(scenario: "settings", tree: tree())

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(original)
        let decoded = try JSONDecoder().decode(Baseline.self, from: data)

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.scenario, "settings")
        XCTAssertEqual(decoded.schemaVersion, SchemaVersion.current)
    }

    /// Byte-stability across encodes is what makes a baseline reviewable in a
    /// diff: an unstable encoding shows spurious changes in every pull request.
    func testEncodingIsByteStableAcrossRuns() throws {
        let baseline = Baseline(scenario: "settings", tree: tree())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let first = try encoder.encode(baseline)
        let second = try encoder.encode(baseline)

        XCTAssertEqual(first, second)
    }

    /// A file recorded with un-snapped coordinates must be canonicalized on
    /// DECODE too — otherwise a hand-edited or older baseline compares against a
    /// canonical live tree and every coordinate reads as drift.
    func testDecodingCanonicalizesAHandWrittenBaseline() throws {
        let raw = """
            {"scenario":"settings","schemaVersion":"1.0","tree":{"id":"root","role":"container",
            "frame":{"x":0,"y":0,"width":400,"height":300},"isVisible":true,"children":[
            {"id":"save-button","role":"button","frame":{"x":112.1,"y":199.9,"width":80.2,
            "height":31.8},"text":"Save","isVisible":true}]}}
            """

        let decoded = try JSONDecoder().decode(Baseline.self, from: Data(raw.utf8))
        let button = try XCTUnwrap(decoded.tree.node(withID: "save-button"))

        XCTAssertEqual(button.frame.x, 112.0)
        XCTAssertEqual(button.frame.height, 32.0)
    }

    // MARK: - Suppression

    func testSuppressionOnALiveNodeSilencesItsDrift() {
        // The directive must be present in BOTH trees. Adding it only to the
        // live tree changes the node's attributes, which is itself drift — so
        // the test would fail for a second, unrelated reason and read as the
        // suppression not working. Measured on the first draft, which reported
        // an `attributes` change alongside the move it meant to silence.
        var recorded = tree()
        recorded.children[0].attributes[LintContext.suppressionKey] = .string("baseline-drift")
        let baseline = Baseline(scenario: "settings", tree: recorded)

        var moved = tree(saveFrame: Rect(x: 160, y: 200, width: 80, height: 32))
        moved.children[0].attributes[LintContext.suppressionKey] = .string("baseline-drift")

        XCTAssertTrue(
            BaselineCheck.compare(moved, to: baseline, context: context()).matches,
            "the move should be silenced by the node's own suppression directive"
        )
    }

    /// A REMOVED node cannot be silenced by its own markup — it is not in the
    /// live tree, so there is nothing to read a suppression directive from. A
    /// deletion that could hide its own deletion is not suppressible in practice.
    func testARemovalIsReportedEvenWhenTheBaselineNodeCarriedSuppression() {
        let baseline = Baseline(
            scenario: "settings",
            tree: tree(extra: [
                SemanticNode(
                    id: "badge",
                    role: .text,
                    frame: Rect(x: 0, y: 0, width: 20, height: 20),
                    attributes: [LintContext.suppressionKey: .string("baseline-drift")]
                )
            ])
        )

        let findings = BaselineCheck.compare(tree(), to: baseline, context: context()).findings

        XCTAssertEqual(findings.count, 1)
    }

    /// The suggestion must name the scenario the caller is actually verifying,
    /// or an author reads a copy-pasteable command that updates the wrong file.
    func testTheSuggestionNamesTheScenarioUnderTest() {
        let baseline = Baseline(scenario: "settings", tree: tree())
        let moved = tree(saveFrame: Rect(x: 160, y: 200, width: 80, height: 32))

        let findings = BaselineCheck.compare(
            moved, to: baseline, context: context(scenario: "settings-dark")
        ).findings

        XCTAssertTrue(
            findings.first?.suggestion?.contains("baseline update settings-dark") == true,
            "got: \(findings.first?.suggestion ?? "none")"
        )
    }
}
