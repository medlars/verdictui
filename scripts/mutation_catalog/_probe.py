"""Mutation rows for the probe and tree-assembly layer (Sources/VerdictUIProbe).

Part of the `mutation_catalog` package; see its `__init__` for why the
catalog is split and for the rule about quoting text from these files.
"""

from mutation_catalog_types import Mutation, Runner  # noqa: F401

MUTATIONS: list[Mutation] = [
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
        path="Sources/VerdictUIProbe/LayoutSettle.swift",
        old="guard value.isFinite, value == value.rounded(), value.magnitude < 1e15 else {",
        # Only the integrality clause is dropped. Dropping the finiteness clause
        # instead would trap in `Int64(Double.nan)` and the run would report a
        # signal rather than a failed assertion — noticed, but for the wrong
        # reason, and unreadable as evidence.
        new="guard value.isFinite, value.magnitude < 1e15 else {",
        test="OracleHostTests/testANonIntegralHostSizeIsReportedWithoutBeingRounded",
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
        path="Sources/VerdictUIProbe/LayoutSettle.swift",
        old="public nonisolated static let minimumQuietInterval: TimeInterval = 0.030",
        new="public nonisolated static let minimumQuietInterval: TimeInterval = 0.0",
        test="HostileSettleTests/testSettleWaitsOutAMutationScheduledBeyondOnePumpInterval",
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
        # Removes the wall-clock floor, restoring "two agreeing checks" to a
        # single 5 ms window — the false quiet that let settle report a still
        # UI while a mutation was still pending.
        name="the quiet floor is weakened below what the scenario needs",
        path="Sources/VerdictUIProbe/LayoutSettle.swift",
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
        path="Sources/VerdictUIProbe/LayoutSettle.swift",
        old="public nonisolated static let minimumQuietInterval: TimeInterval = 0.030",
        new="public nonisolated static let minimumQuietInterval: TimeInterval = 0.090",
        test="HarnessPerformanceTests/testPerformCycleMeetsTheSLO1Gate",
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
        new=(
            "        _ = settleStarted.duration(to: .now)\n"
            "        let settleMs = timeout.asMilliseconds"
        ),
        test="HarnessTests/testSettleMsIsMeasuredNotAssumedOnTheTimeoutPath",
    ),
    Mutation(
        # The host ignores the variant and pins its baseline instead, so every
        # sweep cell renders identically while reporting a different name -- a
        # matrix that runs, produces a full report, and measures one thing N
        # times. Silent in the worst direction: the grid reads clean.
        name="a sweep variant is ignored and every cell renders the baseline",
        path="Sources/VerdictUIProbe/OracleHost.swift",
        old="            .environment(\\.layoutDirection, overriding?.layoutDirection ?? .leftToRight)",
        new="            .environment(\\.layoutDirection, .leftToRight)",
        test="SweepTests/testVariantsActuallyChangeTheRenderedTree",
    ),
    Mutation(
        # A duplicate registration is silently dropped instead of reported, so
        # two scenarios file verdicts under one name and one of them vanishes
        # from a run with nothing anywhere saying so.
        name="registry hides duplicate scenario names",
        path="Sources/VerdictUIProbe/ScenarioRegistry.swift",
        old="                duplicates.insert(name)",
        new='                duplicates.insert("@never-a-real-scenario-name")',
        test=(
            "VerdictUIMacroTests.VerdictScenarioCompilationTests/"
            "testDuplicateNamesAreReportedRatherThanSilentlyDropped"
        ),
        runner=Runner.SWIFT,
    ),
    Mutation(
        # A state with no expectations is accepted, so arriving in it asserts
        # nothing. This is the defect that makes a whole walk unfalsifiable: a
        # machine of bare names still applies every action, still settles, and
        # still reports PASS while the UI never left the first screen. Every
        # other walk test is satisfied by that broken engine, because they all
        # walk machines whose states DO carry expectations -- only the rejection
        # separates a working guard from an absent one.
        name="a state with no expectations is accepted, making arrival vacuous",
        path="Sources/VerdictUIProbe/StateMachine.swift",
        old="            guard !state.expectations.expectations.isEmpty else {",
        new="            guard true else {",
        test=("VerdictUIProbeTests.StateMachineTests/testAStateWithNoExpectationsIsRejected"),
        runner=Runner.SWIFT,
    ),
    Mutation(
        # The arrival check stops evaluating the state's expectations, so every
        # step reports only its lint findings. A walk then verifies that the
        # screen is not visibly broken while saying nothing about WHICH screen
        # it is -- the "walked login -> dashboard -> settings without ever
        # leaving login" false-green, reported as a clean path table.
        name="a walk stops verifying arrival and only lints",
        path="Sources/VerdictUIProbe/StateMachine.swift",
        # The `new` still CALLS evaluate and merely discards its result, rather
        # than deleting the statement. Deleting it leaves `tree`, `context` and
        # `machineState` unused, which is an ERROR under -warnings-as-errors, so
        # the row fails to BUILD and scores INCONCLUSIVE having executed zero
        # tests -- measured here on 2026-08-11, the fourth occurrence of the
        # shape `no.md` #25 records. Discarding the result keeps every binding
        # live and breaks exactly the behaviour under test: arrival is computed
        # and then thrown away.
        old=(
            "            findings.append(\n"
            "                contentsOf: machineState.expectations.evaluate(in: tree, "
            "context: context)\n"
            "            )"
        ),
        new=("            _ = machineState.expectations.evaluate(in: tree, context: context)"),
        test=(
            "VerdictUIProbeTests.StateMachineTests/"
            "testArrivingInADifferentStateThanTheGraphClaimsIsAFailure"
        ),
        runner=Runner.SWIFT,
    ),
    Mutation(
        # A multi-path walk reuses one harness, so each path starts wherever the
        # previous one ended. Every result still carries its own path's name, so
        # the wrong answer is indistinguishable from the right one at the point
        # of use -- and it depends on the order the paths happen to be listed in.
        name="multi-path walks reuse one host instead of re-rendering",
        path="Sources/VerdictUIProbe/StateMachine.swift",
        old=(
            "        for path in paths {\n"
            "            let harness = Harness(scenario: scenario, viewport: viewport, "
            "rules: rules)"
        ),
        new=(
            "        let harness = Harness(scenario: scenario, viewport: viewport, "
            "rules: rules)\n"
            "        for path in paths {"
        ),
        test=(
            "VerdictUIProbeTests.StateMachineTests/"
            "testEachPathStartsFromAFreshRenderRatherThanWhereTheLastOneEnded"
        ),
        runner=Runner.SWIFT,
    ),
    Mutation(
        # The entry check is skipped, so a scenario that does not start in the
        # state the machine claims gets its FIRST TRANSITION blamed instead --
        # sending debugging at an innocent action while the real defect (the
        # starting state) goes unnamed.
        name="the walk skips its entry check",
        path="Sources/VerdictUIProbe/StateMachine.swift",
        old="        steps.append(entry)\n        if entry.status == .fail {",
        new="        steps.append(entry)\n        if false {",
        test=(
            "VerdictUIProbeTests.StateMachineTests/"
            "testAFailingEntryCheckStopsTheWalkBeforeAnyAction"
        ),
        runner=Runner.SWIFT,
    ),
    Mutation(
        # Discovery starts reporting every probe it was ever asked about
        # rather than only the ones with a binding. That is the always-true
        # failure (no.md #17): an agent reading it would act on probes that
        # refuse -- the exact state this feature was built to end -- and it
        # reads as a MORE helpful answer, so nothing about it looks wrong.
        # The `new` keeps every binding live and compiles (no.md #31): it
        # widens the map rather than deleting the computation.
        name="actionability reports unbound probes as actionable",
        path="Sources/VerdictUIProbe/Scenario.swift",
        old='        for id in strings.keys { result[id, default: []].append("setText") }',
        new="""        for id in strings.keys { result[id, default: []].append("setText") }
        result["never-registered", default: []].append("tap")""",
        test="ActionDiscoveryTests/testStateReportsRegisteredProbesAndOmitsUnregisteredOnes",
    ),
    Mutation(
        # The pixel capture stops pinning its scale and takes the DEVICE scale.
        # `bitmapImageRepForCachingDisplay(in:)` is the obvious AppKit call and
        # is exactly wrong here: it answers at the display's backing scale, so a
        # baseline written on a Retina machine mismatches every capture from a
        # 1x one -- a CI runner, a non-Retina display -- and the diff reports
        # that as a UI regression. Substituting a wrong-but-typed value rather
        # than deleting the guard keeps every binding live and COMPILES
        # (no.md #31). Hand-verified 2026-08-12 in both directions: mutated,
        # exit 1 with 8 tests executed and 4 failures reading "400 is not equal
        # to 200 - width must be points, not device pixels"; restored, 8 tests /
        # 0 failures with a byte-identical restore.
        name="the pixel capture stops pinning 1x and follows the device scale",
        path="Sources/VerdictUIProbe/PixelCapture.swift",
        old="    public nonisolated static let pixelScale: CGFloat = 1.0",
        new="    public nonisolated static let pixelScale: CGFloat = 2.0",
        test="PixelCaptureTests/testCaptureIsPinnedToOnePixelPerPoint",
    ),
    Mutation(
        # The determinism check stops comparing and accepts everything, so a
        # scenario that renders differently each time is handed a pixel baseline
        # anyway. The baseline then fails at RANDOM on some later unrelated
        # commit, and the reader hunts a regression in code that never changed --
        # strictly worse than having no baseline, which is why the refusal
        # exists. `false` keeps both bindings live and COMPILES (no.md #31);
        # deleting the comparison would orphan `second`.
        name="the determinism check accepts every scenario without comparing",
        path="Sources/VerdictUIProbe/PixelDeterminism.swift",
        old="        let first = try await renderOnce(scenario, viewport: viewport, backend: backend)\n"
        "        let second = try await renderOnce(scenario, viewport: viewport, backend: backend)\n"
        "\n"
        "        guard first.png != second.png else {",
        new="        let first = try await renderOnce(scenario, viewport: viewport, backend: backend)\n"
        "        let second = try await renderOnce(scenario, viewport: viewport, backend: backend)\n"
        "\n"
        "        guard false, second.png.isEmpty else {",
        test="PixelDeterminismTests/testAScenarioThatChangesBetweenRendersIsRefused",
    ),
    Mutation(
        # The cross-backend refusal stops refusing. Measured in Wave 9 Task 1:
        # the two backends produce different bytes for the SAME view even at
        # matched dimensions, so without this guard every comparison across them
        # reports the backend as a UI regression -- a confident, well-formed
        # finding about a change that did not happen, which is the most
        # expensive shape this product has. Comparing each operand to ITSELF
        # keeps both live and compiles. Hand-verified: 737 tests / 1 failure
        # naming testACrossBackendComparisonIsRefusedBeforeAnyBytesAreRead.
        # Anchored on the WHOLE-FRAME site specifically. Task 4 gave
        # `compareRegion` the identical guard, so the bare `guard baseline.backend
        # == candidate.backend else {` line now matches TWO sites and
        # --verify-targets correctly refuses it: the harness could not say which
        # of the two it had broken. Including the following line disambiguates,
        # and the region site keeps its own row below.
        name="the pixel comparison stops refusing a cross-backend baseline",
        path="Sources/VerdictUIProbe/PixelCompare.swift",
        old="        guard baseline.backend == candidate.backend else {\n"
        "            throw PixelDiffError.backendMismatch(\n"
        "                baseline: baseline.backend.rawValue,\n"
        "                candidate: candidate.backend.rawValue\n"
        "            )\n"
        "        }\n"
        "\n"
        "        let baseRaster = try PixelRaster(decoding: baseline)",
        new="        guard baseline.backend == baseline.backend, candidate.backend == candidate.backend else {\n"
        "            throw PixelDiffError.backendMismatch(\n"
        "                baseline: baseline.backend.rawValue,\n"
        "                candidate: candidate.backend.rawValue\n"
        "            )\n"
        "        }\n"
        "\n"
        "        let baseRaster = try PixelRaster(decoding: baseline)",
        test="PixelCompareTests/testACrossBackendComparisonIsRefusedBeforeAnyBytesAreRead",
    ),
    Mutation(
        # The tree hash leaves the cache key, so a screen that has CHANGED is
        # served the pixels it had before the change. This is the single most
        # dangerous mutation in the catalog: it does not merely serve stale data,
        # it reports PASS for a regression using evidence from before the
        # regression existed -- the exact failure this whole product exists to
        # prevent, arriving through its own optimisation. Substituting a constant
        # keeps the parameter live and compiles (no.md #31).
        name="the pixel cache key stops including the tree, so a changed screen hits",
        path="Sources/VerdictUIProbe/PixelCache.swift",
        old="            treeHash: PixelCacheKey.hash(tree: tree),",
        new='            treeHash: "fixed",',
        test="PixelCacheTests/testAChangedScreenMissesEvenThoughTheHarnessInputsAreIdentical",
    ),
    Mutation(
        # A cache entry whose bytes do not match their recorded hash is SERVED
        # instead of missing. That is the shape a crash mid-write leaves behind,
        # and serving it hands a verification run a truncated image as if it were
        # a valid capture.
        name="the pixel cache serves an entry whose bytes contradict its own hash",
        path="Sources/VerdictUIProbe/PixelCache.swift",
        old="        guard capture.contentHash == stored.contentHash else { return nil }",
        new="        guard capture.contentHash == capture.contentHash else { return nil }",
        test="PixelCacheTests/testACorruptEntryMissesRatherThanBeingServed",
    ),
    Mutation(
        # Restores the mode-bit check the write probe replaced. The two agree on
        # healthy developer hardware, so the sibling test that reads the REAL
        # cache paths holds under either implementation and cannot fail for this
        # reason -- the no.md #17 shape, where a predicate's tests only ever
        # exercise the agreeing branch. Measured 2026-08-18: this mutation passed
        # 2/2 before the negative control existed. A writable REGULAR FILE
        # separates them without a sandbox: isWritableFile returns true for it
        # while writing a child into it fails, because it is not a directory.
        name="the SwiftPM cache check trusts permission bits over a real write",
        path="Sources/VerdictUIProbe/ConstrainedTimingEnvironment.swift",
        old="                && !canWriteExistingDirectory(at: path)",
        new="                && !FileManager.default.isWritableFile(atPath: path)",
        test=(
            "ConstrainedTimingEnvironmentTests"
            "/testTheCacheCheckRejectsAPathOnlyARealWriteCanRuleOut"
        ),
    ),
    Mutation(
        # The overshoot discriminator (no.md #18) is a RELATION between two
        # durations from one clock, so a slow host is still a valid witness for
        # it -- unlike the six wall-clock BUDGET lanes, which must record rather
        # than assert on a shared runner. Re-coupling the two is silent in the
        # expensive direction: widening isActive to cover an unwritable SwiftPM
        # cache is right for the budgets and would retire the overshoot check on
        # any read-only-cache host, while every signal stayed green. Measured
        # 2026-08-15: forcing the record-only lane runs 784 tests to 0 failures
        # with 3 skipped. Substituting the clock predicate keeps every binding
        # live and compiles (no.md #31).
        name="the overshoot invariant is gated on the wall-clock lane again",
        path="Sources/VerdictUIProbe/ConstrainedTimingEnvironment.swift",
        old="        ProcessInfo.processInfo.environment[recordTimingOnlyOverride] == nil",
        new="        !hasUnwritableSwiftPMCache",
        test=(
            "Tests/test_verdictui_bench.py::TestStageRuntimeBench"
            "::test_the_elapsed_invariant_lane_is_not_the_clock_lane"
        ),
        runner=Runner.PYTEST,
    ),
    Mutation(
        # The load threshold is spelled in TWO languages that cannot read each
        # other -- 2.0 here and SEVERE_OVERSUBSCRIPTION in verdictui-pm.py --
        # so the agreement is only real while something compares them. Drift is
        # silent in the expensive direction: the side holding the HIGHER number
        # keeps asserting an absolute wall clock on a host the other side has
        # already ruled unable to hold one, which is the no.md #17 shape one
        # constant along. Same joint as the marker-set parity row above: that
        # pins WHICH hosts are constrained, this pins the ratio at which a host
        # joins them.
        name="the Swift and Python oversubscription thresholds drift apart",
        path="Sources/VerdictUIProbe/ConstrainedTimingEnvironment.swift",
        old="    public static let severeOversubscription = 2.0",
        new="    public static let severeOversubscription = 3.0",
        test=(
            "Tests/test_verdictui_bench.py::TestStageRuntimeBench"
            "::test_the_swift_and_python_oversubscription_thresholds_agree"
        ),
        runner=Runner.PYTEST,
    ),
    Mutation(
        # Flips the load lane from fail-toward-NOISE to fail-toward-SILENCE. An
        # unreadable load average would then read as "severely oversubscribed",
        # so every host that declines to report one drops to record-only and
        # stops asserting the AX read budget -- a SAFETY bound whose absence
        # SIGSEGV'd the entire runner (no.md #44). "Could not measure" and
        # "measured and constrained" are opposite states, and collapsing them
        # to the permissive one is a check that cannot fail for the reason it
        # exists (lesson 202). Keeps every binding live and compiles (no.md
        # #31): `ratio` is still bound and still read on the line below.
        name="an unreadable load average silently disables the AX read budget",
        path="Sources/VerdictUIProbe/ConstrainedTimingEnvironment.swift",
        old="        guard let ratio = oversubscription else { return false }",
        new="        guard let ratio = oversubscription else { return true }",
        test=(
            "Tests/test_verdictui_bench.py::TestStageRuntimeBench"
            "::test_an_unreadable_load_still_asserts_its_budget"
        ),
        runner=Runner.PYTEST,
    ),
]
