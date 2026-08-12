import Foundation
import VerdictUIDemoScenarios
import VerdictUIKernel
import VerdictUIProbe
import XCTest

@testable import VerdictUICLICore

/// The `act` tool: the act-then-observe loop as an agent-callable verb.
///
/// Three properties carry this file, and they are different claims.
///
/// The ROUND TRIP is correctness: ``TreeDiff/apply(_:to:)`` replays a delta onto
/// the before-tree to reproduce the after-tree exactly, and that invariant is
/// the entire licence for shipping a delta instead of a tree. A compaction that
/// silently dropped a field would leave a delta that still LOOKS like a delta,
/// and the tree a client rebuilt from it would differ from the one the engine
/// saw — a divergence nothing downstream could detect.
///
/// The BUDGET is the product feature. Measured before it was chosen: the raw
/// `TreeDelta` for `ToggleLayoutScenario`'s toggle — 2 added, 1 removed, 1
/// moved, a SMALL change — is 704 B, against the plan's 300 B. So the budget is
/// not decoration on an already-adequate format; it is the reason the format
/// exists.
///
/// The KEY SHAPE is the contract. A round trip through one `Codable` tests the
/// PAIR and never the format — `no.md` #35, where the daemon shipped a
/// `_0`-wrapped wire for a whole wave behind green tests. So one test here reads
/// raw JSON with `JSONSerialization`, the way a foreign client does.
final class ActToolTests: XCTestCase {
    override func invokeTest() {
        autoreleasepool { super.invokeTest() }
    }

    private static var encoder: JSONEncoder { VerdictOutput.encoder(pretty: false) }

    private static var engine: VerdictEngine {
        VerdictEngine(
            registry: DemoScenarios.registry,
            baselines: BaselineStore.standard(
                root: URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("verdictui-act-tests-\(UUID().uuidString)")
            )
        )
    }

    /// The one demo scenario with an action binding, and the act that changes it.
    private static let scenario = ToggleLayoutScenario.scenarioName
    private static let toggle = ToggleLayoutScenario.toggleProbeID

    @MainActor
    private func toggleStep() async throws -> StepResult {
        try await Self.engine.act(scenario: Self.scenario, action: .toggle(Self.toggle))
    }

    // MARK: - The delta describes the act

    /// `act` reports what actually changed, not merely that something did.
    @MainActor
    func testActReportsTheNodesThatAppearedAndDisappeared() async throws {
        let step = try await toggleStep()

        let added = Set(step.delta.added.map(\.node.id))
        let removed = Set(step.delta.removed.map(\.leaf))

        XCTAssertTrue(
            added.contains("advanced-detail"),
            "expanding must report advanced-detail as added, got \(added)"
        )
        XCTAssertTrue(
            removed.contains("collapsed-summary"),
            "expanding must report collapsed-summary as removed, got \(removed)"
        )
    }

    /// The engine's `act` and the harness's `perform` are the same operation.
    ///
    /// The single-handle rule is what stops the CLI, the daemon and the MCP
    /// server drifting into three answers, and it is only true while `act`
    /// DELEGATES. A reimplementation would pass every other test in this file
    /// while diverging from the harness the rest of the product is tested
    /// against — so this compares the two directly.
    @MainActor
    func testActDelegatesToTheHarnessRatherThanReimplementingIt() async throws {
        let viaEngine = try await toggleStep()
        let viaHarness = await Harness(
            scenario: ToggleLayoutScenario(isExpanded: false),
            viewport: ToggleLayoutScenario.recommendedViewport
        ).perform(.toggle(Self.toggle))

        XCTAssertEqual(viaEngine.delta, viaHarness.delta)
        XCTAssertEqual(viaEngine.verdict.status, viaHarness.verdict.status)
        XCTAssertEqual(viaEngine.probeID, viaHarness.probeID)
    }

    // MARK: - Round trip

    /// A compacted delta expands back to exactly the delta that went in.
    @MainActor
    func testTheCompactDeltaSurvivesTheRoundTrip() async throws {
        let delta = try await toggleStep().delta
        XCTAssertFalse(delta.isEmpty, "the fixture must produce a real delta to compact")

        let expanded = CompactDelta(delta).expand()
        XCTAssertEqual(expanded, delta, "the compact delta did not reproduce its input")
    }

    /// And it survives the JSON crossing, not just the in-memory transform.
    @MainActor
    func testTheCompactDeltaSurvivesEncodingAndDecoding() async throws {
        let delta = try await toggleStep().delta

        let data = try Self.encoder.encode(CompactDelta(delta))
        let decoded = try JSONDecoder().decode(CompactDelta.self, from: data)

        XCTAssertEqual(decoded.expand(), delta)
    }

    /// A replayed delta reproduces the after-tree the engine actually saw.
    ///
    /// This is the property the whole delta-instead-of-tree design rests on. The
    /// two tests above prove the COMPACTION is lossless; this proves the thing
    /// being compacted is sufficient — an agent holding the before-tree and this
    /// delta has the after-tree, and never needs to ask for it.
    @MainActor
    func testAnAgentCanRebuildTheAfterTreeFromTheDeltaAlone() async throws {
        let step = try await toggleStep()
        let after = try XCTUnwrap(step.after)

        let shipped = try XCTUnwrap(CompactDelta(step.delta).expand())
        let rebuilt = try TreeDiff.apply(shipped, to: step.before)

        XCTAssertEqual(
            rebuilt,
            after,
            "replaying the shipped delta onto the before-tree did not reproduce the after-tree, "
                + "so a client that skipped include_tree would hold a tree the engine never saw"
        )
    }

    // MARK: - The budget

    /// A STRUCTURAL act — one that adds or removes nodes — stays under 512 B.
    ///
    /// ### Why this number and not the plan's 300
    ///
    /// The plan budgeted "typical act delta ≤ 300 bytes", written before
    /// anything could be measured. It is unreachable for any act that changes
    /// the tree, and the reason is content rather than encoding: an act adding
    /// two nodes must name them, their roles, their text and their structural
    /// paths, which is ~400 B of the 498 measured here. Four rounds of
    /// compaction took the toggle from 702 B raw to 498 B and could go no
    /// further without dropping information the verdict layer reads —
    /// `structuralPath` is what a finding cites for an unprobed node, and
    /// `TextMetrics` is what `TruncationRule` judges against.
    ///
    /// So the budget is set from the measurement, at 512 B, with headroom over
    /// the worst case in the catalog (expand 498 B, collapse 419 B). Owner
    /// decision 2026-08-12; recorded in `no.md` #41. This is the same discipline
    /// SLO 1 and SLO 3 follow — a threshold moved to fit today's number is a
    /// silencer, but a threshold that was never a measurement is a guess, and
    /// replacing a guess with a measurement is not weakening a gate.
    ///
    /// The raw form is asserted to be OVER budget in the same test, which is not
    /// decoration: without it, "the delta fits" would also be satisfied by a
    /// format that saves nothing on a delta that was already small, and the
    /// compaction could be deleted with every test still green.
    @MainActor
    func testATypicalActDeltaFitsTheWireBudget() async throws {
        let budget = 512
        let delta = try await toggleStep().delta

        let compactBytes = try Self.encoder.encode(CompactDelta(delta)).count
        let rawBytes = try Self.encoder.encode(delta).count

        print("WIRE act-delta compact=\(compactBytes) raw=\(rawBytes) census=\(delta.summary)")

        XCTAssertLessThanOrEqual(
            compactBytes,
            budget,
            "a \(delta.summary) delta serializes to \(compactBytes) B against a \(budget) B budget"
        )
        XCTAssertGreaterThan(
            rawBytes,
            budget,
            "the RAW delta is \(rawBytes) B, already inside the \(budget) B budget — so this "
                + "test would pass with the compaction deleted, and proves nothing about it"
        )

        // The reverse act is a DIFFERENT delta — one added, two removed — and
        // a budget pinned on a single direction is a claim about one fixture
        // rather than about acts.
        let collapse = await Harness(
            scenario: ToggleLayoutScenario(isExpanded: true),
            viewport: ToggleLayoutScenario.recommendedViewport
        ).perform(.toggle(Self.toggle))
        let collapseBytes = try Self.encoder.encode(CompactDelta(collapse.delta)).count
        print("WIRE act-delta-collapse compact=\(collapseBytes) census=\(collapse.delta.summary)")

        XCTAssertFalse(collapse.delta.isEmpty, "collapsing must change the tree")
        XCTAssertLessThanOrEqual(
            collapseBytes,
            budget,
            "collapsing serializes to \(collapseBytes) B against a \(budget) B budget"
        )
    }

    /// An act that changes nothing costs almost nothing.
    ///
    /// This is the commonest act in a real loop — a tap that toggles internal
    /// state, a keystroke into a field that does not resize — and it is the case
    /// the compaction originally made WORSE: spelling all twelve empty lists
    /// cost 170 B to say "nothing happened", against a raw form of 49 B. A
    /// format that wins on the rare payload and loses on the frequent one has
    /// optimized for the wrong distribution, so this pins the frequent case
    /// directly rather than trusting the structural budget to cover it.
    @MainActor
    func testAnActThatChangesNothingIsNearlyFree() async throws {
        let budget = 64
        let step = await Harness(
            scenario: ToggleLayoutScenario(isExpanded: true),
            viewport: ToggleLayoutScenario.recommendedViewport
        ).perform(.tap("clear-cache-button"))

        XCTAssertTrue(step.delta.isEmpty, "the fixture must produce an empty delta")

        let bytes = try Self.encoder.encode(CompactDelta(step.delta)).count
        print("WIRE act-delta-inert bytes=\(bytes)")

        XCTAssertLessThanOrEqual(
            bytes,
            budget,
            "an act that changed nothing costs \(bytes) B to say so, against \(budget) B"
        )
    }

    /// The whole step result, not merely its delta, stays affordable.
    ///
    /// What an agent pays for is the RESPONSE, and the delta is only part of it:
    /// the verdict's findings travel too. A budget measured on the delta alone
    /// would be a true number about a thing nobody receives.
    @MainActor
    func testTheWholeStepResponseStaysUnderAKilobyte() async throws {
        let budget = 1_024
        let step = try await toggleStep()

        let bytes = try Self.encoder.encode(StepResultWire(step)).count
        print("WIRE act-step bytes=\(bytes)")

        XCTAssertLessThanOrEqual(
            bytes,
            budget,
            "a clean act responds with \(bytes) B against a \(budget) B budget"
        )
    }

    /// `include_tree` is what it costs, and it is off by default.
    @MainActor
    func testTheAfterTreeIsAbsentUnlessAskedForAndCostsMoreWhenItIs() async throws {
        let step = try await toggleStep()

        let lean = StepResultWire(step)
        let full = StepResultWire(step, includeTree: true)

        XCTAssertNil(lean.tree, "the after-tree must not travel unless the caller asked")
        XCTAssertNotNil(full.tree, "include_tree:true must actually carry the tree")

        let leanBytes = try Self.encoder.encode(lean).count
        let fullBytes = try Self.encoder.encode(full).count
        XCTAssertGreaterThan(
            fullBytes,
            leanBytes,
            "include_tree cost nothing (\(fullBytes) B vs \(leanBytes) B), which means the "
                + "default is already paying for a tree nobody asked for"
        )
    }

    // MARK: - The published key shape

    /// A foreign client reads the documented keys, not our `Codable`.
    ///
    /// Parsed with `JSONSerialization` deliberately: decoding with the type that
    /// encoded it tests the pair and agrees with itself no matter what bytes
    /// travel (`no.md` #35). Every key asserted here appears in
    /// `contracts/mcp-tools.md`, so this test fails when the wire and the
    /// contract part company.
    @MainActor
    func testTheStepResponsePublishesTheDocumentedKeys() async throws {
        let step = try await toggleStep()
        let data = try Self.encoder.encode(StepResultWire(step))

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any],
            "the step response must be a JSON object"
        )

        XCTAssertEqual(object["probe"] as? String, Self.toggle)
        XCTAssertNotNil(object["status"] as? String)
        XCTAssertNotNil(object["settled"] as? Bool)
        XCTAssertNotNil(object["elapsedMs"] as? Double)
        XCTAssertNotNil(object["findings"] as? [Any])
        XCTAssertNil(object["tree"], "the after-tree must be absent by default")

        let delta = try XCTUnwrap(object["delta"] as? [String: Any], "delta must be an object")
        // The toggle populates these three; `changed` is empty and therefore
        // OMITTED, which is the documented shape — absent and empty mean the
        // same thing, and spelling every empty list costs the frequent
        // non-structural act more than the whole delta is worth.
        for key in ["added", "removed", "moved", "strings"] {
            XCTAssertNotNil(delta[key], "the delta must publish a '\(key)' key")
        }
        XCTAssertNil(delta["changed"], "an empty list must be omitted, not spelled")

        // The compaction is visible in the bytes: a path travels as integers
        // into the string table, not as the strings themselves. If this ever
        // decodes as [[String]] the format has silently reverted to the raw
        // shape while every round-trip test still passes.
        let removed = try XCTUnwrap(delta["removed"] as? [[Int]], "paths must travel as indices")
        XCTAssertFalse(removed.isEmpty, "the fixture removes a node, so removed must be populated")
    }

    // MARK: - The daemon surface

    /// `act` answers over the daemon method surface every transport shares.
    @MainActor
    func testTheDaemonAnswersAnActWithAStepResult() async {
        let response = await VerdictDaemon.handle(
            DaemonRequest(
                method: "act",
                scenario: Self.scenario,
                action: DaemonAction(kind: "toggle", probe: Self.toggle)
            ),
            engine: Self.engine
        )

        XCTAssertTrue(response.ok, "a well-formed act must be answered: \(response.error ?? "")")
        guard case .step(let step)? = response.result else {
            return XCTFail("expected a step result, got \(String(describing: response.result))")
        }
        XCTAssertEqual(step.probe, Self.toggle)
        XCTAssertTrue(step.settled, "a plain toggle must settle")
        XCTAssertFalse(step.delta.removed.isEmpty, "the toggle removes the collapsed summary")
    }

    /// An act with no action is refused, not guessed at.
    @MainActor
    func testAnActWithoutAnActionIsRefused() async {
        let response = await VerdictDaemon.handle(
            DaemonRequest(method: "act", scenario: Self.scenario),
            engine: Self.engine
        )

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error, "method 'act' requires an action")
    }

    /// An act with no scenario is refused by the same guard every method uses.
    @MainActor
    func testAnActWithoutAScenarioIsRefused() async {
        let response = await VerdictDaemon.handle(
            DaemonRequest(method: "act", action: DaemonAction(kind: "tap", probe: "x")),
            engine: Self.engine
        )

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error, "method 'act' requires a scenario")
    }

    /// An unknown probe comes back as a FAILING step, not as a refusal.
    ///
    /// The distinction is the one the whole product draws: "I could not look" is
    /// an infrastructure fault, while "I looked and this is wrong" is a verdict.
    /// A well-formed act against a probe that does not exist is the SECOND —
    /// the request was understood, and the answer is that the UI has no such
    /// control — so it must arrive as evidence an agent can read.
    @MainActor
    func testAnUnknownProbeIsAFailingStepRatherThanARefusal() async {
        let response = await VerdictDaemon.handle(
            DaemonRequest(
                method: "act",
                scenario: Self.scenario,
                action: DaemonAction(kind: "tap", probe: "no-such-probe")
            ),
            engine: Self.engine
        )

        XCTAssertTrue(
            response.ok,
            "the daemon understood the request, so it must answer rather than refuse"
        )
        guard case .step(let step)? = response.result else {
            return XCTFail("expected a step result, got \(String(describing: response.result))")
        }
        XCTAssertEqual(step.status, Verdict.Status.fail.rawValue)
        XCTAssertTrue(
            step.findings.contains { $0.nodeID == "no-such-probe" },
            "the failing step must cite the probe that could not be found: \(step.findings)"
        )
    }

    // MARK: - Translating a wire action

    /// Every advertised verb translates to an in-process action.
    ///
    /// Walks ``DaemonAction/kinds`` rather than listing verbs again here: a verb
    /// added to the catalog and forgotten in `probeAction()` would otherwise be
    /// advertised to clients and rejected at call time.
    func testEveryAdvertisedVerbTranslates() throws {
        for kind in DaemonAction.kinds {
            let action = DaemonAction(kind: kind, probe: "p", text: "t", value: 1)
            let translated = try action.probeAction()
            XCTAssertEqual(
                translated.probeID,
                "p",
                "\(kind) lost its probe id in translation"
            )
        }
    }

    /// A verb nobody advertises is refused, naming the ones that exist.
    func testAnUnknownVerbIsRefusedWithTheVocabulary() {
        XCTAssertThrowsError(try DaemonAction(kind: "clcik", probe: "p").probeAction()) { error in
            let message = String(describing: error)
            XCTAssertTrue(message.contains("clcik"), "the refusal must name what was sent")
            for kind in DaemonAction.kinds {
                XCTAssertTrue(message.contains(kind), "the refusal must offer '\(kind)'")
            }
        }
    }

    /// A verb missing its payload is refused rather than defaulted.
    ///
    /// Both directions matter. `setText` without `text` must not become an empty
    /// string — that types nothing into the field and then reports a verdict
    /// about a screen the caller never asked for — and `setSlider` without
    /// `value` must not become 0, which is a real slider position.
    func testAVerbMissingItsPayloadIsRefusedRatherThanDefaulted() {
        XCTAssertThrowsError(try DaemonAction(kind: "setText", probe: "p").probeAction()) {
            XCTAssertEqual(
                $0 as? DaemonAction.TranslationError,
                .missingArgument(kind: "setText", argument: "text")
            )
        }
        XCTAssertThrowsError(try DaemonAction(kind: "setSlider", probe: "p").probeAction()) {
            XCTAssertEqual(
                $0 as? DaemonAction.TranslationError,
                .missingArgument(kind: "setSlider", argument: "value")
            )
        }
    }

    /// A payload-carrying verb keeps its payload.
    ///
    /// The control for the test above: "refuses without an argument" is also
    /// satisfied by an implementation that refuses always.
    func testAPayloadCarryingVerbKeepsItsValue() throws {
        guard
            case .setText(let id, let text) =
                try DaemonAction(kind: "setText", probe: "field", text: "hello").probeAction()
        else {
            return XCTFail("setText did not translate to .setText")
        }
        XCTAssertEqual(id, "field")
        XCTAssertEqual(text, "hello")

        guard
            case .setSlider(_, let value) =
                try DaemonAction(kind: "setSlider", probe: "s", value: 0.75).probeAction()
        else {
            return XCTFail("setSlider did not translate to .setSlider")
        }
        XCTAssertEqual(value, 0.75)
    }

    // MARK: - Malformed input

    /// A path index outside the string table is refused, not crashed on.
    ///
    /// These arrays arrive from a process this one does not control, so a
    /// malformed payload is untrusted input rather than a hypothetical.
    func testAMalformedCompactDeltaExpandsToNil() {
        let bogus = CompactDelta(
            added: [],
            removed: [[7]],
            moved: [],
            changed: [],
            strings: ["$root"]
        )
        XCTAssertNil(bogus.expand(), "a path index past the string table must be refused")

        let shortRect = CompactDelta(
            added: [],
            removed: [],
            moved: [CompactDelta.CompactMove(path: [0], from: [1, 2], to: [1, 2, 3, 4])],
            changed: [],
            strings: ["$root"]
        )
        XCTAssertNil(shortRect.expand(), "a frame that is not four numbers must be refused")

        // An addition pointing into the node table at a node that is not a
        // subtree root would rebuild a DIFFERENT tree than the sender had —
        // the one malformed case that produces a plausible answer rather than
        // a crash, which is why it is refused explicitly.
        let danglingAddition = CompactDelta(
            added: [CompactDelta.CompactAddition(path: [0], index: 0, node: 3)],
            removed: [],
            moved: [],
            changed: [],
            nodeIDs: [-1],
            nodeRoles: [1],
            nodeTexts: [-1],
            nodeFrames: [0, 0, 1, 1],
            nodeParents: [-1],
            nodePaths: [0],
            nodeMetrics: [-1, -1, -1],
            strings: ["$root", "text"]
        )
        XCTAssertNil(
            danglingAddition.expand(),
            "an addition pointing outside the node table must be refused"
        )

        // Columns that disagree in length describe no consistent node: metrics
        // run three per node, so two entries for one node is malformed.
        let raggedColumns = CompactDelta(
            added: [],
            removed: [],
            moved: [],
            changed: [],
            nodeIDs: [-1],
            nodeRoles: [1],
            nodeTexts: [-1],
            nodeFrames: [0, 0, 1, 1],
            nodeParents: [-1],
            nodePaths: [0],
            nodeMetrics: [-1, -1],
            strings: ["$root", "text"]
        )
        XCTAssertNil(raggedColumns.expand(), "a ragged node table must be refused")

        // A node table carrying a node NO addition references. This is the one
        // malformed case that rebuilds a PLAUSIBLE tree rather than failing a
        // bounds check: every index is in range, so a reader that only checked
        // bounds would hand back a delta silently missing a node the sender
        // meant to add. Found by the mutation harness — the guard existed and
        // nothing exercised it.
        let orphanNode = CompactDelta(
            added: [CompactDelta.CompactAddition(path: [0], index: 0, node: 0)],
            removed: [],
            moved: [],
            changed: [],
            nodeIDs: [-1, -1],
            nodeRoles: [1, 1],
            nodeTexts: [-1, -1],
            nodeFrames: [0, 0, 1, 1, 0, 0, 1, 1],
            // Both are addition ROOTS, but only the first is claimed by `added`.
            nodeParents: [-1, -1],
            nodePaths: [0, 0],
            nodeMetrics: [-1, -1, -1, -1, -1, -1],
            strings: ["$root", "text"]
        )
        XCTAssertNil(
            orphanNode.expand(),
            "a node table carrying a node no addition references must be refused"
        )

        // A half-sentinel metrics triple describes a measurement nobody made,
        // and guessing which half to trust is how a rule ends up judging
        // truncation against an invented width.
        let halfMetrics = CompactDelta(
            added: [CompactDelta.CompactAddition(path: [0], index: 0, node: 0)],
            removed: [],
            moved: [],
            changed: [],
            nodeIDs: [-1],
            nodeRoles: [1],
            nodeTexts: [-1],
            nodeFrames: [0, 0, 1, 1],
            nodeParents: [-1],
            nodePaths: [0],
            nodeMetrics: [119, -1, 1],
            strings: ["$root", "text"]
        )
        XCTAssertNil(halfMetrics.expand(), "a partially-sentinel metrics triple must be refused")
    }
}
