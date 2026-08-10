"""The mutation catalog: every guard in this repo, and the test that must notice it.

Split out of `mutation-check.py` (CTS-47AA0547), and the split does more than
cut a long file in half — it removes a constraint the harness could not escape.

A `Mutation.old` must quote the source text it replaces. While the catalog lived
INSIDE `mutation-check.py`, any row targeting the harness itself matched twice:
once at the real site, once in its own quoting of it, and `--verify-targets`
refused it (correctly — the harness could not say which site it broke). That is
`no.md` #16, which records a guard left with a hand-run control because no row
could be written for it. With the catalog in a separate module, a row may quote
harness code freely: the two files do not contain each other's text.

The rule that replaces it is narrower and easier to keep: a row must not quote
text from THIS file. Rows targeting the catalog itself would self-match here for
exactly the same reason.
"""

from __future__ import annotations

from mutation_catalog_types import Mutation, Runner

MUTATIONS = [
    Mutation(
        name="hard line breaks other than \\n stop withholding TextMetrics",
        path="Sources/VerdictUIProbe/TreeAssembly.swift",
        old="!text.contains(where: \\.isNewline)",
        new='!text.contains("\\n")',
        test="TreeAssemblyTests/testTextMetricsAreWithheldWhereTheDerivationHasNoHonestBasis",
    ),
    Mutation(
        name="'@'-prefixed probe ids stop being refused",
        path="Sources/VerdictUIProbe/VerdictProbe.swift",
        old='if candidate.hasPrefix("@") {',
        new="if false {",
        test="VerdictUIProbeTests/testAnEmptyOrStructuralPathShapedProbeIDIsRefused",
    ),
    Mutation(
        name="empty probe ids stop being refused",
        path="Sources/VerdictUIProbe/VerdictProbe.swift",
        old="if candidate.isEmpty {",
        new="if false {",
        test="VerdictUIProbeTests/testAnEmptyOrStructuralPathShapedProbeIDIsRefused",
    ),
    Mutation(
        name="a pass with no viewport invents one instead of not delivering",
        path="Sources/VerdictUIProbe/VerdictProbe.swift",
        old="guard let viewport = snapshot.viewport else { return nil }",
        new="let viewport = snapshot.viewport ?? Rect(x: 0, y: 0, width: 1, height: 1)",
        test="VerdictUIProbeTests/testAPassWithNoViewportDeliversNoTree",
    ),
    Mutation(
        # This replaced a mutation on a `recorded.filter { ids.contains(...) }`
        # line in `assembledTree`, which went unnoticed for a good reason: the
        # filter changed no output, because `TreeAssembly` reads only
        # `measurements[record.id]`. The line was deleted rather than papered over
        # with a test, and the guard that *is* load-bearing — that a node's
        # metrics come from its own probe id — is mutated instead.
        name="a node's text metrics stop being keyed by its own probe id",
        path="Sources/VerdictUIProbe/TreeAssembly.swift",
        old="measurements: measurements[record.id] ?? []",
        # Sorted so the wrong answer is deterministic: dictionary order is not.
        new="measurements: measurements.sorted { $0.key < $1.key }.last?.value ?? []",
        test="VerdictUIProbeTests/testAMeasurementWithoutARecordNeitherBecomesNorAltersANode",
    ),
    Mutation(
        name="a multi-subview probe forwards its first subview's explicit guide",
        path="Sources/VerdictUIProbe/ProbeLayout.swift",
        old="guard subviews.count == 1, let subview = subviews.first else { return nil }",
        new="guard let subview = subviews.first else { return nil }",
        test="ProbeLayoutTests/testAProbeWrappingSeveralSubviewsForwardsNoExplicitGuide",
    ),
    Mutation(
        # The reuse-the-intrinsic-answer shortcut in `sizeThatFits`. Inverting the
        # ternary keeps the width-unconstrained case correct by coincidence (both
        # arms measure `.unspecified` there) and breaks the constrained one, which
        # is exactly the asymmetry the named test pins.
        name="the ideal-at-width measurement is reused when a width WAS proposed",
        path="Sources/VerdictUIProbe/ProbeLayout.swift",
        old="                proposal.width == nil\n                ? intrinsic",
        new="                proposal.width != nil\n                ? intrinsic",
        test="ProbeLayoutTests/testWidthConstrainedMeasurementReportsTheHeightWrappingWouldNeed",
    ),
    Mutation(
        name="a non-integral host size is rounded in the error message",
        path="Sources/VerdictUIProbe/OracleHost.swift",
        old="guard value.isFinite, value == value.rounded(), value.magnitude < 1e15 else {",
        # Only the integrality clause is dropped. Dropping the finiteness clause
        # instead would trap in `Int64(Double.nan)` and the run would report a
        # signal rather than a failed assertion — noticed, but for the wrong
        # reason, and unreadable as evidence.
        new="guard value.isFinite, value.magnitude < 1e15 else {",
        test="OracleHostTests/testANonIntegralHostSizeIsReportedWithoutBeingRounded",
    ),
    Mutation(
        name="the demo swallows a scenario that cannot settle",
        path="Sources/VerdictUIDemoScenarios/DemoReport.swift",
        old="let tree = try await host.currentTree()",
        new="guard let tree = try? await host.currentTree() else { continue }",
        test="DemoReportTests/testAScenarioThatCannotSettleFailsTheRunAndNamesItself",
    ),
    Mutation(
        # `renderJSON` is what `main.swift` calls, so its failure branch gets its
        # own mutation rather than riding on `verdicts`'.
        name="renderJSON turns an unsettleable run into an empty document",
        path="Sources/VerdictUIDemoScenarios/DemoReport.swift",
        old="let data = try encoder.encode(try await verdicts(deadline: deadline))",
        new="let data = try encoder.encode((try? await verdicts(deadline: deadline)) ?? [])",
        test=(
            "DemoReportTests/testRenderJSONPropagatesTheFailureRatherThanEmittingAnEmptyDocument"
        ),
    ),
    Mutation(
        name="an entry ignores an explicit viewport override",
        path="Sources/VerdictUIDemoScenarios/DemoScenarios.swift",
        old="host(viewport ?? recommendedViewport, deadline)",
        new="host(recommendedViewport, deadline)",
        test=(
            "DemoScenarioCatalogTests/"
            "testAnEntryHostsAtAnExplicitViewportOrFallsBackToItsRecommendation"
        ),
    ),
    Mutation(
        name="each body evaluation gets a fresh ScenarioState",
        path="Sources/VerdictUIProbe/OracleHost.swift",
        # Enough context to miss the identical string in `ScenarioRoot`'s own doc
        # comment, which explains why this line reads the stored state.
        old="    var body: some View {\n        scenario.body(state: state)\n    }",
        new="    var body: some View {\n        scenario.body(state: ScenarioState())\n    }",
        test="ScenarioTests/testOneHostHandsEveryReEvaluationTheSameScenarioState",
    ),
    Mutation(
        # The false-clean failure mode: with the guard inverted, a tree carrying
        # no probes yields zero findings and derives to PASS. Measured on a real
        # app view before the guard existed -- squeezed to an eighth of its
        # width, visibly broken, reported PASS with findings: [].
        name="a probeless tree is reported clean again",
        path="Sources/VerdictUIKernel/RuleEngine.swift",
        old="            if !containsProbedNode(root) {",
        new="            if false {",
        test="VerdictUIKernelTests/testAProbelessTreeCannotProduceAPassVerdict",
    ),
    Mutation(
        # The search must cover the WHOLE tree. Restricting it to the root's
        # direct children makes a probe nested under an unprobed container
        # invisible, so a correctly-instrumented screen reports vacuous.
        name="the probe search stops at the root's direct children",
        path="Sources/VerdictUIKernel/RuleEngine.swift",
        old="            if !child.id.isEmpty || containsProbedNode(child) { return true }",
        new="            if !child.id.isEmpty { return true }",
        test="VerdictUIKernelTests/testAProbeNestedDeepCountsAsObservation",
    ),
    Mutation(
        # Mutates the MANIFEST, because the floor is the thing consumers collide
        # with. A .v14 floor makes SwiftPM refuse every consumer pinned lower and
        # blame the PRODUCT rather than the one API responsible, so nothing in
        # this repo would report it -- LaunchGate (.v13) was locked out entirely.
        name="the package floor rises above the lowest fleet target again",
        path="Package.swift",
        old="        .macOS(.v13)",
        new="        .macOS(.v14)",
        test=(
            "Tests/test_verdictui_pm.py::TestDeploymentFloor::"
            "test_the_package_floor_stays_at_the_lowest_fleet_target"
        ),
        runner=Runner.PYTEST,
    ),
    Mutation(
        name="the demo stage re-enters SwiftPM instead of running the built executable",
        path="scripts/verdictui-pm.py",
        old="[str(demo)]",
        new='["swift", "run", str(demo)]',
        test=(
            "Tests/test_verdictui_pm.py::TestStageWrappers::"
            "test_stage_demo_runs_the_built_executable_not_swiftpm"
        ),
        runner=Runner.PYTEST,
    ),
    Mutation(
        # The mutation is the ORIGINAL defect (CIS-9EC205DF), not merely a
        # different spelling: `setattr` -> attribute syntax WITH a type-ignore is
        # also pyright-clean, so that variant is correctly UNNOTICED -- both
        # honestly satisfy the test's claim. Dropping the suppression entirely is
        # what the guard exists to catch, so that is what this row mutates to.
        name="the runtime attribute stash stops being type-checkable",
        path="scripts/verdictui-pm.py",
        old="    setattr(swift_runner, _RAW_KILL_ATTR, raw_kill)",
        new="    swift_runner._verdictui_raw_kill_zombie_swift_processes = raw_kill",
        test=("Tests/test_verdictui_pm.py::TestStageBuild::test_the_pm_script_is_pyright_clean"),
        runner=Runner.PYTEST,
    ),
    Mutation(
        name="the demo stage accepts an empty verdict array",
        path="scripts/verdictui-pm.py",
        old="if not isinstance(verdicts, list) or not verdicts:",
        new="if not isinstance(verdicts, list):",
        test=(
            "Tests/test_verdictui_pm.py::TestStageWrappers::"
            "test_stage_demo_fails_on_an_empty_verdict_array"
        ),
        runner=Runner.PYTEST,
    ),
    # The bench stage gates the MEDIAN, not the tail. Three rows, because the
    # decision has three independently-breakable halves and one row would let
    # the other two rot silently.
    Mutation(
        # The regression direction. Without this the stage could stop failing
        # altogether and the "does not fail on a contended tail" row below
        # would still pass — a gate that never fails satisfies it perfectly.
        name="the bench stage stops failing on a regressed median",
        path="scripts/verdictui-pm.py",
        old="if p50 >= SLO1_P50_BUDGET_MS:",
        new="if False:",
        test=(
            "Tests/test_verdictui_bench.py::TestStageRuntimeBench::"
            "test_a_regressed_median_fails_even_with_a_healthy_tail"
        ),
        runner=Runner.PYTEST,
    ),
    Mutation(
        # The false-positive direction — the actual 2026-08-07 defect restored
        # verbatim. This is the row that would have caught it: the stage asserted
        # a statistic that moves with machine load, so it failed at p95 105.51 ms
        # on a healthy p50 of 49.09 ms.
        name="the bench stage goes back to gating the contended tail",
        path="scripts/verdictui-pm.py",
        old="if p50 >= SLO1_P50_BUDGET_MS:",
        new="if tail is not None and float(tail.group(1)) >= SLO1_P95_BUDGET_MS:",
        test=(
            "Tests/test_verdictui_bench.py::TestStageRuntimeBench::"
            "test_a_contended_tail_does_not_fail_the_stage"
        ),
        runner=Runner.PYTEST,
    ),
    Mutation(
        # The two thresholds live in different languages and neither file can
        # see the other, so their agreement is only real while something
        # compares them. Moving one here must fail.
        name="the PM's p50 budget drifts from the Swift test's",
        path="scripts/verdictui-pm.py",
        old="SLO1_P50_BUDGET_MS = 70.0",
        new="SLO1_P50_BUDGET_MS = 85.0",
        test=(
            "Tests/test_verdictui_bench.py::TestStageRuntimeBench::"
            "test_the_gated_budget_agrees_with_the_swift_test"
        ),
        runner=Runner.PYTEST,
    ),
    # Wave 4 Task 1 — the macro target's isolation. All three of these are
    # manifest-shaped: they change no behaviour and break no Swift test, so
    # `swift test` is blind to every one of them. That is precisely why they
    # need witnesses; the cost they impose (SwiftSyntax on every consumer's
    # build) is invisible to a suite that only measures what the code does.
    Mutation(
        name="a shipping target is allowed to depend on SwiftSyntax",
        path="Package.swift",
        old='.target(name: "VerdictUIKernel", swiftSettings: strictSettings)',
        new=(
            '.target(name: "VerdictUIKernel", dependencies: '
            '[.product(name: "SwiftSyntax", package: "swift-syntax")], '
            "swiftSettings: strictSettings)"
        ),
        test=(
            "Tests/test_macro_isolation.py::TestMacroTargetIsolation::"
            "test_the_shipping_targets_never_reach_swiftsyntax"
        ),
        runner=Runner.PYTEST,
    ),
    Mutation(
        name="the macro plugin is demoted to a regular target",
        path="Package.swift",
        old='        .macro(\n            name: "VerdictUIMacros",',
        new='        .target(\n            name: "VerdictUIMacros",',
        test=(
            "Tests/test_macro_isolation.py::TestMacroTargetIsolation::"
            "test_the_plugin_is_declared_as_a_macro_target"
        ),
        runner=Runner.PYTEST,
    ),
    Mutation(
        name="the SwiftSyntax pin is loosened from exact to a range",
        path="Package.swift",
        old='exact: "603.0.2"',
        new='from: "603.0.0"',
        test=(
            "Tests/test_macro_isolation.py::TestMacroTargetIsolation::"
            "test_swiftsyntax_is_pinned_exactly"
        ),
        runner=Runner.PYTEST,
    ),
    Mutation(
        name="an empty mutation catalog reports success",
        path="scripts/mutation-check.py",
        old='        print("the mutation catalog is empty — nothing was verified")\n        return 1\n    problems = [',
        new="        pass\n    problems = [",
        test=(
            "Tests/test_mutation_check.py::TestVerifyTargets::"
            "test_an_empty_catalog_fails_rather_than_reporting_nothing_wrong"
        ),
        runner=Runner.PYTEST,
    ),
    Mutation(
        name="a broken build is blamed on a renamed test",
        path="scripts/mutation-check.py",
        old='        if "error:" in combined:\n            return "unmutated source does not build',
        new='        if False:\n            return "unmutated source does not build',
        test=(
            "Tests/test_mutation_check.py::TestBaselineProblem::"
            "test_a_tree_that_does_not_build_says_so_instead_of_blaming_the_name"
        ),
        runner=Runner.PYTEST,
    ),
    Mutation(
        name="the ZStack layering exemption becomes case-sensitive",
        path="Sources/VerdictUIKernel/Rules/SiblingOverlapRule.swift",
        old='node.role.identifier.lowercased() == "zstack"',
        new='node.role.identifier == "ZStack"',
        test="SiblingOverlapRuleTests/testZStackParentRoleReadsAsIntentionalLayering",
    ),
    Mutation(
        name="CLAUDE.md's SSoT table points at a file that does not exist",
        path="CLAUDE.md",
        old="Sources/VerdictUIProbe/OracleHost.swift",
        new="Sources/VerdictUIProbe/OracleHostRenamed.swift",
        test=("Tests/test_claude_md_ssot.py::TestClaudeMdSSoT::test_every_ssot_location_exists"),
        runner=Runner.PYTEST,
    ),
    Mutation(
        name="CLAUDE.md's SSoT table names a symbol that moved",
        path="CLAUDE.md",
        old="`VerdictScenario`",
        new="`VerdictScenarioProtocol`",
        test=(
            "Tests/test_claude_md_ssot.py::TestClaudeMdSSoT::"
            "test_every_ssot_symbol_lives_where_the_table_says"
        ),
        runner=Runner.PYTEST,
    ),
    Mutation(
        # Retargeting a row rather than deleting one: this leaves every row
        # pointing at a real file, so only the completeness direction can catch it.
        name="a source file loses its FILE_REGISTRY row",
        path="docs/FILE_REGISTRY.md",
        old="| `scripts/dev.sh`",
        new="| `scripts/floor-check.py`",
        test=(
            "Tests/test_file_registry.py::TestFileRegistry::"
            "test_every_authored_source_file_has_an_active_row"
        ),
        runner=Runner.PYTEST,
    ),
    Mutation(
        # The one guard here whose subject is a policy constant rather than a
        # file: it fails when a tracked file's type is in neither classification
        # set, and no edit to a *document* can produce that. Dropping `.swift`
        # from the source set is the honest equivalent of adding an unclassified
        # file type, and proves the canary reads the tree instead of itself.
        name="a file type drops out of both classification sets",
        path="Tests/test_file_registry.py",
        old='".swift", ',
        new="",
        test=(
            "Tests/test_file_registry.py::TestFileRegistry::test_every_tracked_suffix_is_classified"
        ),
        runner=Runner.PYTEST,
    ),
    Mutation(
        # Anchored on the widest Purpose cell, the one row the markdown formatter
        # leaves unpadded, so this target does not depend on column alignment. If
        # a longer purpose is ever written, --verify-targets reports this STALE.
        name="a source file's registry row is flipped out of Active",
        path="docs/FILE_REGISTRY.md",
        old="tree delivery | Active |",
        new="tree delivery | Removed |",
        test=(
            "Tests/test_file_registry.py::TestFileRegistry::"
            "test_every_authored_source_file_has_an_active_row"
        ),
        runner=Runner.PYTEST,
    ),
    Mutation(
        name="a FILE_REGISTRY row is left behind by a rename",
        path="docs/FILE_REGISTRY.md",
        old="| `scripts/floor-check.py`",
        new="| `scripts/floor-check-renamed.py`",
        test=(
            "Tests/test_file_registry.py::TestFileRegistry::"
            "test_every_active_row_points_at_a_path_that_exists"
        ),
        runner=Runner.PYTEST,
    ),
    Mutation(
        name="toggle action stops flipping the bool binding",
        path="Sources/VerdictUIProbe/Scenario.swift",
        old="bools[id] = !current",
        new="bools[id] = current",
        test="ActionInjectionTests/testToggleActionExpandsToggleLayoutScenario",
    ),
    Mutation(
        name="unknown probe toggle is silently ignored instead of throwing",
        path="Sources/VerdictUIProbe/Scenario.swift",
        old="""\
        guard let current = bools[id] else {
            if strings[id] != nil || doubles[id] != nil || taps[id] != nil {
                throw ProbeActionError.typeMismatch(id: id, expected: "bool")
            }
            throw ProbeActionError.unknownProbe(id)
        }
""",
        new="""\
        guard let current = bools[id] else {
            return
        }
""",
        test="ActionInjectionTests/testUnknownProbeIDThrowsWithEvidence",
    ),
    Mutation(
        name="flow keeps running after a step FAILs instead of exiting early",
        path="Sources/VerdictUIProbe/Harness.swift",
        old="if step.status == .fail {",
        new="if false {",
        test="HarnessTests/testRunStopsEarlyOnTheFirstFailure",
    ),
    Mutation(
        name="act-failure finding cites a probe id the agent never asked for",
        path="Sources/VerdictUIProbe/Harness.swift",
        old="nodeID: error.probeID,",
        new='nodeID: "wrong-id",',
        test="HarnessTests/testUnknownProbeIDBecomesAFailVerdictNamingTheProbe",
    ),
    Mutation(
        # Re-anchored when the count became a single `pendingWaiters` sample:
        # it used to read `clock.pendingWaiterCount` inline here AND again below
        # the CATransaction.flush, so a waiter registering between the two made
        # the token hash a count the guard never saw (CTS-8DDE6D09).
        name="settle stops censusing pending virtual-clock timers",
        path="Sources/VerdictUIProbe/Settle.swift",
        old="if pendingWaiters > 0 { return nil }",
        new="if false { return nil }",
        test="HostileSettleTests/testDelayedMutationBlocksQuietUntilTheClockAdvances",
    ),
    Mutation(
        # Was `requiredAgreeingChecks = 2 -> 1`, which the 30 ms quiet floor now
        # SUBSUMES: with a wall-clock span required, the count is no longer what
        # keeps a moving layout from settling, so the old mutation went
        # UNNOTICED and correctly so. Mutating the floor instead targets the
        # guard that is actually load-bearing today.
        name="quiet is accepted without the wall-clock floor holding",
        path="Sources/VerdictUIProbe/OracleHost.swift",
        old="public nonisolated static let minimumQuietInterval: TimeInterval = 0.030",
        new="public nonisolated static let minimumQuietInterval: TimeInterval = 0.0",
        test="HostileSettleTests/testSettleWaitsOutAMutationScheduledBeyondOnePumpInterval",
    ),
    Mutation(
        # Re-admits idealLineCount == 0 into the single-line clipping branch,
        # which reports text with NO lines as truncated.
        name="text with no ideal lines is reported as truncated again",
        path="Sources/VerdictUIKernel/Rules/TruncationRule.swift",
        old="guard metrics.idealLineCount == 1, available < metrics.intrinsicWidth",
        new="guard metrics.idealLineCount <= 1, available < metrics.intrinsicWidth",
        test="TruncationRuleTests/testTextWithNoIdealLinesIsNotReportedAsTruncated",
    ),
    Mutation(
        # Restores the lost-cancellation race: a `cancel()` that beats the
        # continuation body to the lock leaves no mark, so the body registers a
        # waiter nothing will ever resume. Unmutated, this hung the whole xctest
        # process about one run in three.
        # Points at the DETERMINISTIC witness, not the 200-attempt race test.
        # The race version catches this 5/5 in isolation but was UNNOTICED in a
        # full sweep, where each case runs straight after a cold rebuild under
        # load — a guard whose detection power varies with machine load reports
        # coverage it cannot always deliver.
        name="a cancel arriving before registration is silently dropped again",
        path="Sources/VerdictUIProbe/VerdictClock.swift",
        old="if cancelledBeforeRegistration.remove(id) != nil {",
        new="if false {",
        test="VerdictClockTests/testAPreMarkedCancellationIsConsumedByTheRegisteringBody",
    ),
    Mutation(
        # Actually DROPS the last catalog entry while its file stays on disk —
        # the exact drift the three hand-maintained counts cannot see, since
        # they only ever agree with each other. A comment-only edit here would
        # score MISSED while changing nothing, which is a worse signal than no
        # mutation at all.
        name="a scenario file stops being registered in the catalog",
        path="Sources/VerdictUIDemoScenarios/DemoScenarios.swift",
        old="""\
                make: { CleanSettingsScenario() }
            ),
        ]""",
        new="""\
                make: { CleanSettingsScenario() }
            ),
        ].dropLast()""",
        test="DemoScenarioCatalogTests/testEveryScenarioFileOnDiskIsRegisteredInTheCatalog",
    ),
    Mutation(
        # Restores the NaN blindness: without the finite guard, `nan <= 0` is
        # false, so a NaN frame reads as RENDERABLE and all six rules skip it.
        name="a non-finite frame reads as renderable again",
        path="Sources/VerdictUIKernel/SemanticNode.swift",
        old="guard x.isFinite, y.isFinite, width.isFinite, height.isFinite else { return true }",
        new="guard true else { return true }",
        test="SemanticNodeTests/testANonFiniteFrameIsEmptyRatherThanRenderable",
    ),
    Mutation(
        # Restores the other half: a rect that cannot be placed intersecting
        # everything, which is how a NaN node read as on-screen.
        # Anchored on the line that FOLLOWS the guard, because `contains` now
        # carries a byte-identical guard for the same reason and the bare
        # target text stopped naming exactly one site (caught by
        # `--verify-targets`, which is what that check is for). Two mutations
        # sharing a target is not a near-miss — the harness refuses to run
        # either, since it cannot say which site it broke.
        name="an unplaceable rect intersects everything again",
        path="Sources/VerdictUIKernel/SemanticNode.swift",
        old=(
            "guard !isEmpty, !other.isEmpty else { return false }\n        return !(other.x >= maxX"
        ),
        new="guard true else { return false }\n        return !(other.x >= maxX",
        test="SemanticNodeTests/testANonFiniteRectIntersectsNothing",
    ),
    Mutation(
        # The same arithmetic fact one function down. Without the guard an
        # INVERTED rect has maxX < x, so every inequality in `contains` holds
        # for a rectangle sitting entirely outside it. Zero call sites today,
        # which is why it is worth pinning now: the first Wave 5 clipping rule
        # to reach for it would inherit a silent wrong answer, exactly as a NaN
        # frame once passed all six rules through `intersects`.
        name="a rect with no area contains things again",
        path="Sources/VerdictUIKernel/SemanticNode.swift",
        old=("guard !isEmpty, !other.isEmpty else { return false }\n        return other.x >= x"),
        new="guard true else { return false }\n        return other.x >= x",
        test="SemanticNodeTests/testContainsIsFalseForDegenerateRectanglesInBothDirections",
    ),
    Mutation(
        # Removes the wall-clock floor, restoring "two agreeing checks" to a
        # single 5 ms window — the false quiet that let settle report a still
        # UI while a mutation was still pending.
        name="the quiet floor is weakened below what the scenario needs",
        path="Sources/VerdictUIProbe/OracleHost.swift",
        old="public nonisolated static let minimumQuietInterval: TimeInterval = 0.030",
        new="public nonisolated static let minimumQuietInterval: TimeInterval = 0.005",
        test="HostileSettleTests/testSettleWaitsOutAMutationScheduledBeyondOnePumpInterval",
    ),
    Mutation(
        # A 3x latency regression. Caught by the p50 gate, which is asserted in
        # EVERY environment because the median is load-stable (49.6-51.2 ms
        # across isolated, full-suite, and breaching runs) — unlike p95, which
        # moves 56.7 -> 102.6 ms purely from contention with the other 318 tests.
        name="the settle floor triples, tripling inner-loop latency",
        path="Sources/VerdictUIProbe/OracleHost.swift",
        old="public nonisolated static let minimumQuietInterval: TimeInterval = 0.030",
        new="public nonisolated static let minimumQuietInterval: TimeInterval = 0.090",
        test="HarnessPerformanceTests/testPerformCycleMeetsTheSLO1Gate",
    ),
    Mutation(
        # The p50 gate is asserted on developer hardware and RECORDED on a
        # shared runner (five CI medians on unchanged code spanned 74-120 ms
        # against a 70 ms budget). INVERTING the lane predicate is the
        # single-edit break that a healthy tree can witness: the local run then
        # takes the record-only branch and stops asserting, while a run with
        # CI set starts asserting the very figure it must not.
        #
        # Deliberately NOT `if true {`. That reads like the obvious mutation
        # and is unfalsifiable on healthy code — the assertion simply never
        # runs and everything passes, so the row would score UNNOTICED while
        # the guard is fine (no.md #12: an assertion that both the correct and
        # the broken implementation satisfy is not a weak test, it is not a
        # test). The inversion is caught by a different assertion in the same
        # test: `stage_runtime_bench` and the local lane both expect the
        # SLO1-PERFORM-P50 recorded line to be ABSENT off-CI.
        name="the SLO 1 lane predicate is inverted, gating CI and exempting dev",
        path="Tests/VerdictUIProbeTests/HarnessPerformanceTests.swift",
        old="private static var assertsP50Locally: Bool { !isSharedCIRunner }",
        new="private static var assertsP50Locally: Bool { isSharedCIRunner }",
        test="HarnessPerformanceTests/testTheP50GateIsAssertedOnDeveloperHardware",
    ),
    Mutation(
        # `settleMs` on the settle-TIMEOUT path reverts to reporting the
        # REQUESTED budget instead of the time actually spent. Four earlier
        # attempts at this guard all passed under mutation, because `> 0` and
        # `<= elapsedMs` are satisfied by a budget as readily as by a
        # measurement (no.md #12). The witness discriminates on the OVERSHOOT:
        # a settle that gives up at its deadline has spent strictly more than
        # the deadline, while an echoed budget reports exactly 150.0 for a
        # 150 ms budget. Hand-verified: 2 failures naming both budgets.
        name="settleMs on the timeout path reports the budget, not the measurement",
        path="Sources/VerdictUIProbe/Harness.swift",
        old="        let settleMs = settleStarted.duration(to: .now).asMilliseconds",
        new="        let settleMs = timeout.asMilliseconds",
        test="HarnessTests/testSettleMsIsMeasuredNotAssumedOnTheTimeoutPath",
    ),
    Mutation(
        # The PM-side half of the same lane. Every marker test asserts a marker
        # turns record-only ON, and `if True` satisfies all of them -- measured
        # 2026-08-09 at 199/199 passing with the guard fully defeated. That is
        # the expensive direction: record-only everywhere means the p50 budget
        # is enforced NOWHERE while the suite reads green, so the gate stops
        # being a gate without one test noticing (no.md #12, #15).
        #
        # Unlike the Swift row above, `if True` IS the right mutation here:
        # the predicate returns a value rather than guarding an assertion, so
        # a healthy tree can witness it through the negative control.
        name="every host is treated as timing-constrained, so p50 gates nothing",
        path="scripts/verdictui-pm.py",
        old="    if any(name in os.environ for name in CONSTRAINED_TIMING_ENV_MARKERS):",
        new="    if True:",
        test=(
            "Tests/test_verdictui_pm.py::TestSkipSentinel"
            "::test_unmarked_writable_host_still_asserts_its_timings"
        ),
        runner=Runner.PYTEST,
    ),
    Mutation(
        # Removes the mid-run clean-tree check, restoring the state where an
        # edit landing during a ~30 minute sweep makes every later case measure
        # a tree nobody intended and report SETUP FAILED as if a guard broke.
        name="a tree going dirty mid-sweep is no longer noticed",
        path="scripts/mutation-check.py",
        old='        if not git_is_clean():\n            print("  ABORTED: the working tree changed mid-run")',
        new='        if False:\n            print("  ABORTED: the working tree changed mid-run")',
        test="Tests/test_mutation_check.py::TestMidRunTreeGuard::test_main_aborts_when_the_tree_goes_dirty_mid_run",
        runner=Runner.PYTEST,
    ),
    Mutation(
        # stage_lint stops reporting any failure. Every pre-existing lint test
        # checked the tool-missing path, the clean-repo path, or grepped the
        # PM's own source for the argv it builds — none ran the stage against
        # BROKEN code, so this mutation passed the whole suite.
        name="stage_lint stops reporting lint and format failures",
        path="scripts/verdictui-pm.py",
        old='            if r.returncode != 0:\n                detail = (r.stdout.strip() or r.stderr.strip() or "no output")[:400]',
        new='            if False:\n                detail = (r.stdout.strip() or r.stderr.strip() or "no output")[:400]',
        test="Tests/test_verdictui_pm.py::TestStageWrappers::test_stage_lint_reports_a_format_failure_distinctly",
        runner=Runner.PYTEST,
    ),
    Mutation(
        # content-overlap stops exempting ancestors, so every child overlapping
        # its own parent reports. Guards the rule against the false-positive
        # flood that would make it unusable on any real tree.
        #
        # The witness is the SEAM test, not the evaluate()-level one. This row
        # first pointed at testContentInsideItsOwnAncestorsIsNotOverlap and came
        # back UNNOTICED: only leaves become subjects, so no pair reaching
        # isCrossBranch is ever ancestor-related and the branch is unreachable
        # from the public entry point. A tree-level test can never kill this
        # mutation — only a direct assertion on the guard can.
        name="content-overlap compares a node with its own ancestors",
        path="Sources/VerdictUIKernel/Rules/ContentOverlapRule.swift",
        old="        guard shared < first.count, shared < second.count else { return false }",
        new="        guard shared < first.count, shared < second.count else { return true }",
        test="VerdictUIKernelTests.ContentOverlapRuleTests/testAncestryIsRejectedAndUnrelatedBranchesAreAcceptedAtTheSeam",
        runner=Runner.SWIFT,
    ),
    Mutation(
        # content-overlap stops deferring direct siblings to sibling-overlap, so
        # a single overlap is billed twice under two different rule names.
        name="content-overlap double-bills direct siblings",
        path="Sources/VerdictUIKernel/Rules/ContentOverlapRule.swift",
        old="        if shared == first.count - 1 && shared == second.count - 1 { return false }",
        new="        if false { return false }",
        test="VerdictUIKernelTests.ContentOverlapRuleTests/testDirectSiblingsAreLeftToSiblingOverlapRule",
        runner=Runner.SWIFT,
    ),
    # NOT MUTATED: the `-B` on the pytest argv in `run_named_test`. A mutation's
    # `old=` must name the text it replaces, and the only text that identifies
    # that flag is the argv itself — which this catalog would then contain
    # verbatim, in the very file it mutates. `--verify-targets` counts two sites
    # and refuses the row, correctly: the harness could not say which one it
    # broke. Three one-line anchors and one line-spanning anchor were tried; the
    # line-spanning one needs a wrap that `ruff format` immediately collapses,
    # so it would rot on the next format run. The guard is covered instead by
    # `test_a_mutated_module_is_not_served_from_stale_bytecode`, which was
    # confirmed to FAIL with `-B` removed and PASS with it present — the control
    # a mutation row would have provided, run by hand. See `no.md` #16.
    Mutation(
        # The same widening one rule over. sibling-overlap had NO tolerance at
        # all until this row's guard shipped, so a 0.01 pt sliver was an ERROR
        # here and silently fine in content-overlap on identical geometry. The
        # mutation restores the silencer direction rather than the missing-guard
        # direction because a tolerance that can grow untested is the failure
        # that outlives the fix: the test's second arm (a real 1 pt overlap)
        # is what has to stay red.
        name="sibling-overlap tolerance widens into silence",
        path="Sources/VerdictUIKernel/Rules/SiblingOverlapRule.swift",
        old="    public static let tolerance = 0.5",
        new="    public static let tolerance = 50.0",
        test=(
            "VerdictUIKernelTests.SiblingOverlapRuleTests/"
            "testSubPixelOverlapIsToleratedButRealOverlapIsStillCaught"
        ),
        runner=Runner.SWIFT,
    ),
    Mutation(
        # The sub-pixel tolerance widens far enough to swallow a real 20 pt
        # overflow. A tolerance that can grow without failing a test is a
        # silencer, so the control arm has to fail here.
        name="content-overlap tolerance widens into silence",
        path="Sources/VerdictUIKernel/Rules/ContentOverlapRule.swift",
        old="    public static let tolerance = 0.5",
        new="    public static let tolerance = 50.0",
        test="VerdictUIKernelTests.ContentOverlapRuleTests/testSubPixelOverlapIsToleratedButRealOverlapIsNot",
        runner=Runner.SWIFT,
    ),
    Mutation(
        # Layering is checked only at the node itself rather than along the whole
        # ancestor path, so a zIndex on a parent or grandparent stops reading as
        # intent and deliberate ZStack layouts report as defects.
        name="content-overlap checks layering only at the node, not the path",
        path="Sources/VerdictUIKernel/Rules/ContentOverlapRule.swift",
        old='        path.contains { $0.zIndex != nil || $0.role.identifier.lowercased() == "zstack" }',
        new='        path.suffix(1).contains { $0.zIndex != nil || $0.role.identifier.lowercased() == "zstack" }',
        test="VerdictUIKernelTests.ContentOverlapRuleTests/testDeclaredLayeringOnEitherNodeOrAnyAncestorIsIntent",
        runner=Runner.SWIFT,
    ),
    Mutation(
        # The walk stops honouring an existing probe, so a hand-probed element
        # gets a second, generated id. `DuplicateProbeIDRule` then reports the
        # instrumentation itself as a defect.
        name="body walk re-probes an already-probed element",
        path="Sources/VerdictUIMacros/BodyProbeWalk.swift",
        old="        if Self.carriesExplicitProbe(expression) {",
        new="        if false {",
        test="VerdictUIMacroTests.VerifiableMacroTests/testAnElementThatAlreadyHasAProbeIsNotProbedAgain",
        runner=Runner.SWIFT,
    ),
    Mutation(
        # Recognition stops looking through the modifier chain, so any element
        # carrying a `.padding()` or a `.foregroundStyle()` — which is nearly
        # every real one — goes unprobed while a suite of bare elements passes.
        name="body walk fails to see an element through its modifiers",
        path="Sources/VerdictUIMacros/BodyProbeWalk.swift",
        # Single-line and uniquely anchored on purpose. The first version of this
        # row was a multi-line block written to disambiguate a repeated `return
        # calleeIdentifier(of: base)`, and the sweep scored it INCONCLUSIVE — the
        # mutated source did not compile, so it measured nothing. A mutation that
        # cannot build is not a weak witness, it is no witness.
        old="        guard let callee = calleeIdentifier(of: expression) else { return nil }",
        new="        guard let callee = expression.as(FunctionCallExprSyntax.self)?.calledExpression\n            .as(DeclReferenceExprSyntax.self)?.baseName.text else { return nil }",
        test="VerdictUIMacroTests.VerifiableMacroTests/testAModifiedElementIsStillRecognisedThroughItsChain",
        runner=Runner.SWIFT,
    ),
    Mutation(
        # An interpolated string is forwarded as `text:`, putting the literal
        # source `\\(name)` where TruncationRule reads what the user sees. A
        # false value is worse than an absent one — the rule acts on it.
        name="body walk forwards an interpolated string as literal text",
        path="Sources/VerdictUIMacros/BodyProbeWalk.swift",
        old="                literal.segments.count == 1,",
        new="                literal.segments.count >= 1,",
        test="VerdictUIMacroTests.VerifiableMacroTests/testAnInterpolatedStringIsNotForwardedAsText",
        runner=Runner.SWIFT,
    ),
    Mutation(
        # The per-role counter stops advancing, so every element of a role gets
        # the SAME id. Ids are what TreeDiff matches on and what Wave 5's
        # baselines key on, so a collision silently merges two elements.
        name="body walk mints a colliding id for every element of a role",
        path="Sources/VerdictUIMacros/BodyProbeWalk.swift",
        old="        counts[role] = index + 1",
        new="        counts[role] = index",
        test="VerdictUIMacroTests.VerifiableMacroTests/testTheIdIsDerivedFromTheTypeNameAndTheElementsPosition",
        runner=Runner.SWIFT,
    ),
    Mutation(
        # A body the walk cannot rewrite silently expands to an unprobed
        # passthrough instead of reporting. It compiles, renders, and yields a
        # tree with a root and nothing under it, so every rule reports PASS on
        # a screen nobody instrumented.
        name="macro accepts a multi-statement body and probes nothing",
        path="Sources/VerdictUIMacros/VerifiableMacro.swift",
        old="                Diagnostic(node: node, message: VerdictMacroDiagnostic.bodyIsNotASingleExpression)",
        new="                Diagnostic(node: node, message: VerdictMacroDiagnostic.noBodyMember)",
        test="VerdictUIMacroTests.VerifiableMacroTests/testAMultiStatementBodyIsReportedRatherThanSilentlyLeftUnprobed",
        runner=Runner.SWIFT,
    ),
    Mutation(
        # `descendingChain` walks INTO a modifier-chain link to reach the
        # element's children; making it probe instead leaves everything inside
        # `VStack { … }.padding(7)` unprobed, which is how this shipped as a
        # real bug. It exists as a named method precisely so this is ONE edit:
        # its two call sites are jointly required, so while they were spelled
        # inline every single-line mutation scored UNNOTICED on correct code.
        #
        # The witness is a SNAPSHOT, and specifically the modifier-chain one:
        # making `descendingChain` probe wraps the element MID-CHAIN, which is
        # what `testAModifiedElementIsStillRecognisedThroughItsChain` pins.
        # `testElementsInsideAModifiedContainerAreStillProbed` — the obvious
        # candidate by name — does NOT fail, and the witness was chosen by
        # reading which tests the mutated build actually failed rather than by
        # picking the one whose name matched the defect.
        #
        # No runtime test can witness this: the rendered tree still resolves the
        # child through SwiftUI's own builder, so it is identical either way. A
        # runtime test is the stronger oracle for "does this reach the kernel"
        # and the weaker one for "did the macro emit the probe" — the layer has
        # to match the claim.
        name="body walk probes a modified container instead of descending it",
        path="Sources/VerdictUIMacros/BodyProbeWalk.swift",
        old="        rewriteChildren(of: expression)",
        new="        rewrite(expression)",
        test="VerdictUIMacroTests.VerifiableMacroTests/testAModifiedElementIsStillRecognisedThroughItsChain",
        runner=Runner.SWIFT,
    ),
    Mutation(
        # The guard `no.md` #16 recorded as UNROWABLE, now rowable — which is the
        # point of splitting the catalog out of the harness.
        #
        # `-B` makes the pytest witness COMPILE the source the harness just
        # wrote instead of reading `__pycache__`. Without it, two rows touching
        # one file inside the same second make the witness judge the PREVIOUS
        # row's compile (CPython validates its cache on mtime plus size at
        # one-second granularity), so a working guard reports UNNOTICED — which
        # reads as "untested" and invites rewriting correct code. Measured
        # 2026-08-07: exactly one of six went UNNOTICED in a full sweep and
        # NOTICED when re-run alone.
        #
        # While the catalog lived inside `mutation-check.py` this row could not
        # exist: its own `old=` string was a second occurrence of the argv, so
        # `--verify-targets` refused it. Two files that do not quote each other
        # is what makes it expressible.
        name="the pytest witness may be served a stale __pycache__ compile",
        path="scripts/mutation-check.py",
        old='return run([sys.executable, "-B", "-m", "pytest"',
        new='return run([sys.executable, "-m", "pytest"',
        test=(
            "Tests/test_mutation_check.py::TestPytestRunner"
            "::test_a_mutated_module_is_not_served_from_stale_bytecode"
        ),
        runner=Runner.PYTEST,
    ),
]
