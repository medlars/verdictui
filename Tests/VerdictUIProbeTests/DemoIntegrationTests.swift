// Wave 2 Task 6: the wave's end-to-end proof.
//
// Everything before this file verifies one layer in isolation — the probe reports
// frames, the assembler builds a tree, the kernel judges a hand-built one, the
// catalog renders. This file is the only place where a scenario goes in and a
// verdict comes out, and it is where "the tool catches a planted bug" stops being
// a design intention and becomes an assertion.
import Foundation
import SwiftUI
import VerdictUIDemoScenarios
import VerdictUIKernel
import VerdictUIProbe
import XCTest

/// Renders every demo scenario through ``OracleHost``, lints the resulting tree
/// with ``RuleEngine/standardRules``, and holds the findings to the exact set this
/// file expects.
///
/// ### Why the expectations live here and not in the catalog
///
/// ``DemoScenarioEntry`` deliberately carries no expected findings, and this file
/// is the reason: an assertion written against a rule id published by the module
/// under test passes whatever that module claims, including a claim that changed
/// in the same commit that broke the rule. So the table below is written out by
/// hand, in string literals, from each scenario's own doc comment — the one place
/// a human states what the planted defect is. The catalog supplies the render;
/// this file supplies the truth.
///
/// ### Why the catalog is iterated rather than listed
///
/// A seventh scenario added without an expectation must not quietly render
/// unverified, and an expectation left behind by a deleted scenario must not
/// quietly pass. ``testTheCatalogAndTheExpectationsCoverEachOther()`` closes both
/// directions, and every other test in this file walks ``DemoScenarios/all``.
final class DemoIntegrationTests: XCTestCase {
    /// Every test here builds an AppKit view hierarchy, and `swift test` has no
    /// window-server run loop to drain the autorelease pool between tests. Without
    /// this the hosted hierarchies and their layers accumulate until the suite
    /// wedges at 0% CPU, each test still passing in isolation.
    override func invokeTest() {
        autoreleasepool { super.invokeTest() }
    }

    // MARK: - Expectations

    /// One expected finding, reduced to the three facts that make a finding a
    /// proof rather than a rumour: which rule fired, how loudly, and about which
    /// node.
    ///
    /// The message and suggestion are deliberately not pinned here — they are
    /// prose containing measured point values, and pinning them would make this
    /// file fail on a reworded message while a rule that stopped firing on the
    /// right node went unnoticed. That the message names its node, and that a
    /// suggestion exists at all, *is* asserted; see
    /// ``testEveryPlantedDefectIsCaughtByExactlyTheRightRule()``.
    private struct ExpectedFinding: Equatable, CustomStringConvertible {
        let rule: String
        let severity: Finding.Severity
        let nodeID: String

        init(rule: String, severity: Finding.Severity, nodeID: String) {
            self.rule = rule
            self.severity = severity
            self.nodeID = nodeID
        }

        /// The same three facts, read off a finding the kernel actually produced.
        init(_ finding: Finding) {
            rule = finding.rule
            severity = finding.severity
            nodeID = finding.nodeID
        }

        var description: String { "\(rule)/\(severity.rawValue) on '\(nodeID)'" }
    }

    /// What each scenario in the catalog must produce, keyed by scenario name.
    ///
    /// String literals throughout, for the reason the type's documentation gives.
    /// An empty array is a claim as strong as a populated one: it says every rule
    /// in ``RuleEngine/standardRules`` must stay silent, which is what makes
    /// `demo-clean-settings` a false-positive guard rather than scenery.
    ///
    /// Where a scenario expects more than one finding, the order is
    /// ``RuleEngine/run(rules:on:context:includeTree:)``'s: rule order first
    /// (``RuleEngine/standardRules``), then each rule's own traversal order.
    private static let expectedFindings: [String: [ExpectedFinding]] = [
        "demo-truncating-label": [
            ExpectedFinding(rule: "truncation", severity: .error, nodeID: "storage-detail")
        ],
        "demo-overlapping-badges": [
            ExpectedFinding(rule: "sibling-overlap", severity: .error, nodeID: "badge-sale")
        ],
        "demo-offscreen-button": [
            ExpectedFinding(rule: "offscreen", severity: .error, nodeID: "apply-button")
        ],
        "demo-undersized-tap-target": [
            ExpectedFinding(rule: "tap-target", severity: .error, nodeID: "dismiss-button")
        ],
        "demo-toggle-layout": [],
        "demo-clean-settings": [],
    ]

    /// How many times the determinism test re-renders a scenario on a fresh host.
    /// Ten, because that is the figure the Wave 2 exit gate names.
    private static let determinismRuns = 10

    // MARK: - Coverage

    /// The catalog and the expectation table describe the same six scenarios.
    ///
    /// Both directions, because they fail for different reasons and have different
    /// fixes: a catalog entry with no expectation is a scenario nothing in this
    /// file verifies, and an expectation with no catalog entry is a defect nobody
    /// renders any more.
    func testTheCatalogAndTheExpectationsCoverEachOther() {
        let catalog = Set(DemoScenarios.all.map(\.name))
        let expected = Set(Self.expectedFindings.keys)

        let unverified = catalog.subtracting(expected).sorted()
        XCTAssertTrue(
            unverified.isEmpty,
            "catalog scenarios with no expectation in this file, so nothing asserts what "
                + "they must find: \(unverified)"
        )

        let orphaned = expected.subtracting(catalog).sorted()
        XCTAssertTrue(
            orphaned.isEmpty,
            "expectations for scenarios no longer in the catalog, so they can never fail: "
                + "\(orphaned)"
        )

        // Names are the join key. Two entries sharing one would let a single
        // expectation stand in for two renders.
        XCTAssertEqual(
            catalog.count,
            DemoScenarios.all.count,
            "the catalog contains a duplicate scenario name: \(DemoScenarios.all.map(\.name))"
        )
    }

    // MARK: - The proof

    /// Every planted defect is caught by exactly the right rule, on exactly the
    /// right node, at exactly the right severity — and nothing else is reported.
    ///
    /// The "nothing else" half is not a formality. A rule that fires on a second,
    /// unplanted node is reporting a false positive, and a false positive in a
    /// verification engine costs more than a miss: the miss loses one defect, the
    /// false positive loses the user's belief in every finding. So the comparison
    /// is array equality against the expected list, not a containment check.
    @MainActor
    func testEveryPlantedDefectIsCaughtByExactlyTheRightRule() async throws {
        for entry in DemoScenarios.all {
            guard let expected = Self.expectedFindings[entry.name] else {
                XCTFail(
                    "'\(entry.name)' is in the catalog with no expectation in this file; "
                        + "add one rather than letting it render unverified"
                )
                continue
            }

            let verdict = try await Self.verdict(for: entry)
            let actual = verdict.findings.map(ExpectedFinding.init)

            XCTAssertEqual(
                actual,
                expected,
                "'\(entry.name)' findings differ.\n"
                    + "  expected: \(Self.list(expected))\n"
                    + "  actual:   \(Self.list(actual))\n"
                    + Self.evidence(verdict.findings)
            )

            // A finding an agent cannot act on is a finding that sends it
            // guessing, which is the failure mode this product exists to remove.
            for finding in verdict.findings {
                XCTAssertTrue(
                    finding.message.contains(finding.nodeID),
                    "'\(entry.name)': \(finding.rule) reported a message that does not name its "
                        + "own node '\(finding.nodeID)': \(finding.message)"
                )
                XCTAssertNotNil(
                    finding.suggestion,
                    "'\(entry.name)': \(finding.rule) on '\(finding.nodeID)' carries no "
                        + "suggestion, so the verdict names a defect without naming a fix"
                )
            }
        }
    }

    /// The derived-status invariant, exercised end to end: a scenario with an
    /// expected error finding produces a FAIL, and one with none produces a PASS.
    ///
    /// ``Verdict/Status/derived(from:)`` is unit-tested against hand-built finding
    /// arrays in the kernel suite. What is unproven until here is that the status
    /// of a verdict drawn from a *rendered* tree agrees with the defect someone
    /// planted in a SwiftUI body — which is the claim a caller reads when it greps
    /// for `FAIL`.
    @MainActor
    func testFailingScenariosFailAndCleanScenariosPass() async throws {
        for entry in DemoScenarios.all {
            guard let expected = Self.expectedFindings[entry.name] else {
                XCTFail("'\(entry.name)' is in the catalog with no expectation in this file")
                continue
            }

            let verdict = try await Self.verdict(for: entry)
            let expectedStatus: Verdict.Status = expected.isEmpty ? .pass : .fail

            XCTAssertEqual(
                verdict.status,
                expectedStatus,
                "'\(entry.name)' reported \(verdict.status.rawValue), expected "
                    + "\(expectedStatus.rawValue).\n\(Self.evidence(verdict.findings))"
            )
            // The verdict has to be filed under the scenario it describes, or a
            // Wave 5 baseline keyed by name records the wrong screen's evidence.
            XCTAssertEqual(
                verdict.scenario,
                entry.name,
                "the verdict for '\(entry.name)' was filed as '\(verdict.scenario)'"
            )
        }
    }

    /// ``ToggleLayoutScenario`` is clean in *both* states.
    ///
    /// The catalog enumerates the collapsed state only — a scenario's name is its
    /// identity and does not vary with its state — so the expanded branch would
    /// otherwise be a layout no end-to-end test ever lints. It is Wave 3's
    /// act-and-observe target, and a Wave 3 test that drives the toggle and
    /// compares verdicts needs both sides to be clean today, or it will be
    /// diffing a defect it did not introduce.
    ///
    /// Both states read their expectation from the same
    /// ``expectedFindings`` entry, so there is one statement of "the toggle
    /// scenario is clean" rather than two that can drift.
    @MainActor
    func testToggleLayoutIsCleanInBothStates() async throws {
        let name = "demo-toggle-layout"
        let expected = try XCTUnwrap(
            Self.expectedFindings[name],
            "the expectation table lost its entry for '\(name)'"
        )
        let viewport = try XCTUnwrap(
            DemoScenarios.entry(named: name)?.recommendedViewport,
            "'\(name)' left the catalog"
        )

        for isExpanded in [false, true] {
            let host = OracleHost(
                scenario: ToggleLayoutScenario(isExpanded: isExpanded),
                viewport: viewport
            )
            let tree = try await host.currentTree()
            let verdict = RuleEngine.run(
                rules: RuleEngine.standardRules,
                on: tree,
                context: .macOS(viewport: tree.frame, scenario: host.scenarioName)
            )
            let actual = verdict.findings.map(ExpectedFinding.init)

            XCTAssertEqual(
                actual,
                expected,
                "'\(name)' (isExpanded: \(isExpanded)) findings differ.\n"
                    + "  expected: \(Self.list(expected))\n"
                    + "  actual:   \(Self.list(actual))\n"
                    + Self.evidence(verdict.findings)
            )
        }
    }

    // MARK: - Determinism

    /// Ten fresh hosts, one scenario, ten byte-identical encoded trees — for a
    /// clean scenario and for a failing one.
    ///
    /// The failing scenario is not decoration. `demo-clean-settings` is all fixed
    /// frames, so it would keep re-encoding identically even if a font metric
    /// wobbled; `demo-truncating-label` carries the glyph measurements
    /// (``TextMetrics/intrinsicWidth``) that a drifting environment pin moves
    /// first. A determinism test that only rendered the clean layout would be
    /// blind to exactly the instability that matters.
    ///
    /// Fresh hosts rather than ten `currentTree()` calls on one host: repeating
    /// the call on a settled host re-reads the same delivered tree and would prove
    /// only that the sink is not lossy. The claim worth having is that the whole
    /// pipeline — construct, lay out, settle, assemble, encode — lands on the same
    /// bytes from a cold start every time.
    @MainActor
    func testTenFreshHostsProduceByteIdenticalTrees() async throws {
        for name in ["demo-clean-settings", "demo-truncating-label"] {
            let entry = try XCTUnwrap(
                DemoScenarios.entry(named: name),
                "'\(name)' left the catalog, so the determinism claim covers nothing"
            )

            var encodings: [Data] = []
            for _ in 1...Self.determinismRuns {
                let tree = try await entry.makeHost().currentTree()
                encodings.append(try Self.canonicalEncoding(of: tree))
            }

            // A loop that rendered fewer times than it claimed would pass every
            // comparison below by having nothing to compare.
            XCTAssertEqual(
                encodings.count,
                Self.determinismRuns,
                "'\(name)' produced \(encodings.count) renders, not \(Self.determinismRuns)"
            )
            let reference = try XCTUnwrap(encodings.first, "'\(name)' produced no renders at all")
            XCTAssertFalse(
                reference.isEmpty,
                "'\(name)' encoded to zero bytes, which would make every run identically empty"
            )

            for (index, encoding) in encodings.enumerated().dropFirst()
            where encoding != reference {
                XCTFail(
                    "'\(name)' run \(index + 1) of \(Self.determinismRuns) did not re-encode "
                        + "identically to run 1.\n"
                        + Self.diffHint(reference: reference, actual: encoding)
                )
            }
        }
    }

    /// Determinism where "identical" is not enough: a layout that only reaches its
    /// real geometry after a run-loop turn, rendered ten times, must land on the
    /// *settled* tree every time.
    ///
    /// ### Why the demo catalog cannot make this claim
    ///
    /// Measured, not assumed: with
    /// ``LayoutSettle/requiredAgreeingChecks`` temporarily reduced to 1 — the
    /// harness accepting the first delivery instead of a confirmed one — all six
    /// demo scenarios still render byte-identically, ten runs out of ten, with
    /// every finding unchanged. Their layouts resolve inside the constructor's own
    /// layout pass, so the first delivery *is* the settled one and there is no
    /// second delivery for the confirming check to catch. A determinism test built
    /// only on them would pass while the settle rule that protects it was gone.
    ///
    /// What is insensitive there is cross-run comparison itself: ten runs that all
    /// return the same placeholder agree perfectly. So this test pins the settled
    /// geometry as a value it owns — arithmetic over ``StagedSettleScenario``'s own
    /// constants, not a number read back from the harness — and only then compares
    /// the runs to each other. Identical *and* right, in that order.
    @MainActor
    func testTenFreshHostsAgreeOnTheSettledTreeOfAStagedLayout() async throws {
        let viewport = StagedSettleScenario.viewport
        // The measured strip is the widest child, so the stack is its width and the
        // settled bar matches it; centred in the viewport, with the strip's height
        // above it. Every term is a constant this file declares.
        let stackWidth = StagedSettleScenario.measuredWidth
        let stackHeight = StagedSettleScenario.stripHeight + StagedSettleScenario.barHeight
        let settledBarFrame = Rect(
            x: (viewport.width - stackWidth) / 2,
            y: (viewport.height - stackHeight) / 2 + StagedSettleScenario.stripHeight,
            width: StagedSettleScenario.measuredWidth,
            height: StagedSettleScenario.barHeight
        )

        var encodings: [Data] = []
        for run in 1...Self.determinismRuns {
            let host = OracleHost(scenario: StagedSettleScenario(), viewport: viewport)
            let tree = try await host.currentTree()
            let bar = try XCTUnwrap(
                tree.node(withID: StagedSettleScenario.barID),
                "run \(run) produced a tree with no '\(StagedSettleScenario.barID)' node"
            )

            XCTAssertEqual(
                bar.frame,
                settledBarFrame,
                "run \(run): the harness returned an unsettled tree — the bar is at "
                    + "\(bar.frame), and \(StagedSettleScenario.placeholderWidth) pt of width "
                    + "means the first delivery was accepted before the layout stopped changing"
            )
            XCTAssertNotEqual(
                bar.frame.width,
                StagedSettleScenario.placeholderWidth,
                "run \(run): this is the placeholder geometry, not the settled geometry"
            )
            encodings.append(try Self.canonicalEncoding(of: tree))
        }

        XCTAssertEqual(
            encodings.count,
            Self.determinismRuns,
            "the staged layout rendered \(encodings.count) times, not \(Self.determinismRuns)"
        )
        let reference = try XCTUnwrap(encodings.first, "the staged layout produced no renders")
        for (index, encoding) in encodings.enumerated().dropFirst() where encoding != reference {
            XCTFail(
                "the staged layout's run \(index + 1) of \(Self.determinismRuns) did not "
                    + "re-encode identically to run 1.\n"
                    + Self.diffHint(reference: reference, actual: encoding)
            )
        }
    }

    // MARK: - Whole-catalog smoke

    /// Every scenario settles without throwing, at the viewport it recommends,
    /// with no host clamping.
    ///
    /// The clamp check is the one that would otherwise poison every assertion in
    /// this file: a clamped host lays content out under a constraint the scenario
    /// did not choose (``OracleHost/wasClamped``), so its frames describe a
    /// different screen than the one whose defect was planted, and a finding drawn
    /// from them is about neither.
    @MainActor
    func testEveryScenarioSettlesUnclampedAtItsRecommendedViewport() async throws {
        var settled: [String] = []
        for entry in DemoScenarios.all {
            let host = entry.makeHost()
            let tree = try await host.currentTree()

            XCTAssertFalse(
                host.wasClamped,
                "'\(entry.name)' was clamped to \(host.hostSize), so its frames describe a "
                    + "viewport the scenario did not ask for"
            )
            XCTAssertEqual(
                tree.frame,
                Rect(
                    x: 0,
                    y: 0,
                    width: entry.recommendedViewport.width,
                    height: entry.recommendedViewport.height
                ),
                "'\(entry.name)' settled into a viewport other than the one it recommends"
            )
            settled.append(entry.name)
        }

        XCTAssertEqual(
            settled,
            DemoScenarios.all.map(\.name),
            "not every catalog entry reached a settled tree"
        )
    }

    // MARK: - Helpers

    /// Render `entry` at its recommended viewport and lint the tree.
    ///
    /// The lint context's viewport is the tree's own root frame rather than the
    /// requested size, so `offscreen` is measured against the rectangle the host
    /// actually used.
    @MainActor
    private static func verdict(for entry: DemoScenarioEntry) async throws -> Verdict {
        let host = entry.makeHost()
        let tree = try await host.currentTree()
        return RuleEngine.run(
            rules: RuleEngine.standardRules,
            on: tree,
            context: .macOS(viewport: tree.frame, scenario: host.scenarioName)
        )
    }

    /// Canonical encoding: sorted keys, so a byte comparison compares content and
    /// not dictionary iteration order — the same encoding `OracleHostTests` uses.
    private static func canonicalEncoding(of tree: SemanticNode) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(tree)
    }

    /// A determinism mismatch a future reader can act on: where the two encodings
    /// diverge, and both of them in full.
    ///
    /// Without this a flake reports "not equal" for a 2 KB payload, and the next
    /// person has to reproduce an intermittent failure to learn which frame moved.
    private static func diffHint(reference: Data, actual: Data) -> String {
        // Indexed as arrays rather than through `Data`'s own indices, which are
        // not guaranteed to start at zero for every `Data` a caller might pass.
        let referenceBytes = [UInt8](reference)
        let actualBytes = [UInt8](actual)
        let shared = min(referenceBytes.count, actualBytes.count)
        let offset =
            (0..<shared).first { referenceBytes[$0] != actualBytes[$0] }
            ?? shared
        var hint =
            "  first difference at byte \(offset) "
            + "(run 1 is \(referenceBytes.count) bytes, this run \(actualBytes.count))\n"
        if offset < shared {
            hint +=
                "  run 1 has 0x\(String(referenceBytes[offset], radix: 16)), "
                + "this run 0x\(String(actualBytes[offset], radix: 16))\n"
        }
        hint +=
            "  run 1: \(String(decoding: reference, as: UTF8.self))\n"
            + "  this run: \(String(decoding: actual, as: UTF8.self))"
        return hint
    }

    /// Expected/actual finding lists, rendered for a failure message.
    private static func list(_ findings: [ExpectedFinding]) -> String {
        findings.isEmpty ? "none" : findings.map(\.description).joined(separator: ", ")
    }

    /// The findings' own prose, so a failure shows the measurements the rules saw
    /// rather than only the identifiers they were filed under.
    private static func evidence(_ findings: [Finding]) -> String {
        guard !findings.isEmpty else { return "  (no findings reported)" }
        return findings
            .map { "  - \($0.rule) [\($0.severity.rawValue)] \($0.nodeID): \($0.message)" }
            .joined(separator: "\n")
    }
}

// MARK: - Staged-layout fixture

/// Published upward by the strip so the bar below it can be sized from a
/// measurement rather than a constant.
private struct StagedWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// A layout that cannot finish in one pass, used by
/// ``DemoIntegrationTests/testTenFreshHostsAgreeOnTheSettledTreeOfAStagedLayout()``.
///
/// No demo scenario is staged — see that test for the measurement — so this
/// fixture lives here rather than in the catalog: the catalog is the product's
/// demo surface, and a scenario that exists only to make a settle rule observable
/// does not belong in it. Every dimension is a constant this file declares, so the
/// settled geometry the test pins is arithmetic rather than a font metric.
private struct StagedSettleScenario: VerdictScenario {
    /// Probe id of the node whose width is the placeholder-versus-settled tell.
    static let barID = "staged-bar"

    /// Viewport the pinned geometry is stated at.
    static let viewport = Size(width: 200, height: 100)

    /// Width the strip measures and publishes upward — and therefore the bar's
    /// settled width.
    static let measuredWidth: Double = 84

    /// Height of the measuring strip.
    static let stripHeight: Double = 12

    /// Height of the bar, unaffected by the staging.
    static let barHeight: Double = 24

    /// The bar's width before the measurement lands: the geometry a harness that
    /// trusted the first delivery would return. Far enough from
    /// ``measuredWidth`` that no rounding could confuse the two.
    static let placeholderWidth: Double = 14

    let name = "staged-settle"

    func body(state: ScenarioState) -> some View {
        StagedSettleContent()
    }
}

private struct StagedSettleContent: View {
    @State private var measured: CGFloat?

    var body: some View {
        VStack(spacing: 0) {
            Color.green
                .frame(
                    width: StagedSettleScenario.measuredWidth,
                    height: StagedSettleScenario.stripHeight
                )
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(key: StagedWidthKey.self, value: proxy.size.width)
                    }
                }

            Color.blue
                .frame(
                    width: measured ?? CGFloat(StagedSettleScenario.placeholderWidth),
                    height: StagedSettleScenario.barHeight
                )
                .verdictProbe(StagedSettleScenario.barID, role: .image)
        }
        .onPreferenceChange(StagedWidthKey.self) { width in
            // Deferred by a run-loop turn on purpose: that is what makes the first
            // delivered tree observably different from the settled one, and what
            // gives the confirming check something to catch.
            Task { @MainActor in measured = width }
        }
    }
}
