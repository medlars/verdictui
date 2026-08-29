"""Mutation rows for the kernel: verdicts, baselines, schema (Sources/VerdictUIKernel).

Part of the `mutation_catalog` package; see its `__init__` for why the
catalog is split and for the rule about quoting text from these files.
"""

from mutation_catalog_types import Mutation, Runner  # noqa: F401

MUTATIONS: list[Mutation] = [
    Mutation(
        # The false-clean failure mode: with the guard inverted, a tree carrying
        # no probes yields zero findings and derives to PASS. Measured on a real
        # app view before the guard existed -- squeezed to an eighth of its
        # width, visibly broken, reported PASS with findings: [].
        name="a probeless tree is reported clean again",
        path="Sources/VerdictUIKernel/RuleEngine.swift",
        old="            if !containsProbedNode(root) {",
        new="            if false {",
        test="VerdictUIKernelTests.VacuousVerdictTests/testAProbelessTreeCannotProduceAPassVerdict",
    ),
    Mutation(
        # The search must cover the WHOLE tree. Restricting it to the root's
        # direct children makes a probe nested under an unprobed container
        # invisible, so a correctly-instrumented screen reports vacuous.
        name="the probe search stops at the root's direct children",
        path="Sources/VerdictUIKernel/RuleEngine.swift",
        old="            if !child.id.isEmpty || containsProbedNode(child) { return true }",
        new="            if !child.id.isEmpty { return true }",
        test="VerdictUIKernelTests.VacuousVerdictTests/testAProbeNestedDeepCountsAsObservation",
    ),
    Mutation(
        name="the ZStack layering exemption becomes case-sensitive",
        path="Sources/VerdictUIKernel/Rules/SiblingOverlapRule.swift",
        old='node.role.identifier.lowercased() == "zstack"',
        new='node.role.identifier == "ZStack"',
        test="SiblingOverlapRuleTests/testZStackParentRoleReadsAsIntentionalLayering",
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
        # The macOS tap-target floor reverts to the touch metric it was until
        # 2026-08-14. Every standard macOS control is 16-26 pt tall (measured:
        # Toggle 60x18, Button 54x24, Stepper 65x26, Slider 200x16), so a 28 pt
        # floor reports EVERY native control as a defect — the rule fires on
        # idiomatic SwiftUI and gets switched off rather than fixed (no.md #25).
        #
        # The witness asserts the platform's own control sizes are accepted, so
        # this row proves the calibration is load-bearing rather than incidental.
        # Its sibling test (a 6x6 control must STILL fail) is what stops the
        # opposite mutation — a floor of 0 — passing as a "fix".
        name="the macOS tap-target floor reverts to the touch metric",
        path="Sources/VerdictUIKernel/RuleEngine.swift",
        old="    public static let macOSMinimumTapTarget = Size(width: 12, height: 12)",
        new="    public static let macOSMinimumTapTarget = Size(width: 28, height: 28)",
        test="VerdictUIKernelTests.TapTargetPlatformMetricsTests/testEveryStandardMacOSControlSizeIsAccepted",
        runner=Runner.SWIFT,
    ),
    Mutation(
        # The rule stops discriminating and reports EVERY wrap. That is the
        # failure mode the measurements ruled out: two-line wraps at ratios
        # 1.54/1.88/2.00 are ordinary, and a rule reporting them would be
        # switched off within a day. The witness is the control test, not the
        # positive one — the positive still passes with the budget removed,
        # because an over-reporting rule also reports the real defect.
        name="excessive-wrap reports ordinary two-line wrapping",
        path="Sources/VerdictUIKernel/Rules/ExcessiveWrapRule.swift",
        old="guard metrics.idealLineCount > context.maximumWrappedLines else { return nil }",
        new="guard metrics.idealLineCount > 1 else { return nil }",
        test="ExcessiveWrapRuleTests/testOrdinaryTwoLineWrappingIsNotReported",
    ),
    Mutation(
        # The rule starts judging CHILDLESS containers, which the layout pass
        # cannot distinguish from decorative shapes that paint themselves. This
        # is the exact defect measured on the first draft: it reported
        # `card-surface` and `card-pill` in CleanSettingsScenario -- the
        # reference CORRECT UI whose whole job is producing zero findings. The
        # witness is the control test, not a positive one: an over-reporting
        # rule still reports the real nested defect, so only the negative case
        # can see the difference.
        name="empty-container judges childless containers it cannot observe",
        path="Sources/VerdictUIKernel/Rules/EmptyContainerRule.swift",
        old="        guard !node.children.isEmpty else { return false }",
        new="        guard true else { return false }",
        test="EmptyContainerRuleTests/testAChildlessContainerIsNotReportedBecauseItMayPaintItself",
    ),
    Mutation(
        # A container holding one BLANK container reads as filled, so the walk
        # never reaches the outermost empty region and reports only the deepest
        # wrapper -- naming the symptom instead of the blank box a human sees.
        # Measured before the fix: `VStack { HStack { } }` reported `inner`
        # alone.
        name="empty-container treats a blank child container as content",
        path="Sources/VerdictUIKernel/Rules/EmptyContainerRule.swift",
        old="            if policedRoles.contains(child.role.identifier) {",
        new="            if false {",
        test="EmptyContainerRuleTests/testANestedChainOfEmptyContainersReportsOnlyTheOutermost",
    ),
    Mutation(
        # The upper end of the alignment window disappears and every deliberate
        # indent, nested hierarchy and two-column layout becomes a finding. The
        # positive test still passes -- an over-reporting rule also reports the
        # real near-miss -- so the control is the only witness that can fail.
        name="misalignment reports deliberate indents as near-misses",
        path="Sources/VerdictUIKernel/Rules/MisalignmentRule.swift",
        old="                guard deviation < alignmentTolerance else { continue }",
        new="                guard deviation < .infinity else { continue }",
        test="MisalignmentRuleTests/testADeliberateIndentIsNotReported",
    ),
    Mutation(
        # A node exactly aligned with an earlier sibling stops being satisfied,
        # so one sloppy element makes every correctly-aligned row around it
        # report -- the rule blaming the innocent rows for their neighbour.
        name="misalignment blames rows that are correctly aligned",
        path="Sources/VerdictUIKernel/Rules/MisalignmentRule.swift",
        old="                if deviation <= coincidenceTolerance {",
        new="                if false {",
        test="MisalignmentRuleTests/"
        "testANodeAlignedWithAnEarlierSiblingIsSilentDespiteANearMissElsewhere",
    ),
    Mutation(
        # The majority requirement disappears, so a MINORITY gap can be crowned
        # as the rhythm and every element following the real spacing is reported
        # instead of the outlier -- the rule inverted, still green, still
        # emitting findings. Only the no-rhythm control can see it.
        name="inconsistent-spacing invents a rhythm where none exists",
        path="Sources/VerdictUIKernel/Rules/InconsistentSpacingRule.swift",
        old="        guard Double(winner.value.count) > Double(gaps.count) * minimumRhythmShare else {",
        new="        guard true else {",
        test="InconsistentSpacingRuleTests/testALayoutWithNoDominantRhythmIsNotReported",
    ),
    Mutation(
        # Axis inference stops declining ambiguous arrangements, so grids and
        # overlays get judged on whichever axis happens to be tried first and
        # every grid in a real app reports.
        name="inconsistent-spacing judges a grid on an arbitrary axis",
        path="Sources/VerdictUIKernel/Rules/InconsistentSpacingRule.swift",
        old="        case (true, false): return .vertical\n        case (false, true): return .horizontal\n        default: return nil",
        new="        case (true, false): return .vertical\n        default: return .horizontal",
        test="InconsistentSpacingRuleTests/testAGridIsDeclinedRatherThanJudgedOnOneAxis",
    ),
    Mutation(
        # Containment is checked against the immediate parent only, so the case
        # that actually reaches a user goes silent: a label inside an HStack
        # inside a card overflows the CARD while fitting its parent perfectly,
        # because the HStack grew to fit its child and pushed the problem up.
        name="clipped-content only checks the immediate parent",
        path="Sources/VerdictUIKernel/Rules/ClippedContentRule.swift",
        old="        ancestors.first { escapes(node.frame, from: $0.frame) }",
        new="        ancestors.suffix(1).first { escapes(node.frame, from: $0.frame) }",
        test="ClippedContentRuleTests/testContentEscapingAGrandparentIsReported",
    ),
    Mutation(
        # A missing expectation subject stops being a finding, so a renamed or
        # deleted probe turns every predicate on it into a green no-op. That is
        # the vacuity shape `vacuous-verdict` guards at tree level arriving one
        # layer down: the expectation still "passes" while testing nothing.
        name="a missing expectation subject passes vacuously",
        path="Sources/VerdictUIKernel/Expectations.swift",
        old="        guard let node = tree.node(withID: nodeID) else {",
        new="        guard let node = tree.node(withID: nodeID) else { return [] }\n        if false {",
        test="ExpectationsTests/testAMissingSubjectIsAnErrorRatherThanSilence",
    ),
    Mutation(
        # Baseline canonicalization stops snapping coordinates, so sub-pixel
        # layout jitter -- which SwiftUI produces between runs and machines --
        # reads as drift and every baseline fails everywhere. A regression
        # channel that cries wolf on unchanged code gets deleted.
        name="baseline canonicalization stops removing layout jitter",
        path="Sources/VerdictUIKernel/Baselines.swift",
        old="        return (value / quantum).rounded() * quantum",
        new="        return value",
        test="BaselinesTests/testSubQuantumJitterIsNotDrift",
    ),
    Mutation(
        # Per-node suppression stops reaching baseline drift, so a node the
        # author explicitly silenced reports anyway. Measured on the first
        # draft: the two branches shared a fallback, so `makeFinding` returning
        # nil for a SUPPRESSED node fell through and re-emitted the finding the
        # directive had just silenced.
        name="baseline drift ignores a node's suppression directive",
        path="Sources/VerdictUIKernel/Baselines.swift",
        old="        return context.makeFinding(\n            rule: id,\n            node: node,",
        new=(
            "        return context.makeFinding(\n"
            "            rule: id,\n"
            "            node: SemanticNode(id: node.id, role: node.role, frame: node.frame),"
        ),
        test="BaselinesTests/testSuppressionOnALiveNodeSilencesItsDrift",
    ),
    Mutation(
        # The per-channel tolerance stops applying, so every rounding difference
        # in colour conversion counts as a visual change. That is the noisy
        # direction rather than the silent one, but it is what makes the channel
        # unusable: a diff that fires on delta-1 noise trains its reader to
        # ignore it, and the border regression it exists to catch arrives in the
        # same inbox as the noise. Multiplying by zero keeps `allowance` LIVE --
        # deleting the guard orphans the binding, which is an error under
        # -warnings-as-errors and scores a compile failure as a proven guard
        # (no.md #25/#31). Hand-verified: 737 tests / 2 failures naming
        # testAChannelDeltaWithinToleranceIsNotADifference, restored to a
        # byte-identical sha256.
        name="the pixel diff stops honouring its per-channel tolerance",
        path="Sources/VerdictUIKernel/PixelDiff.swift",
        old="        let allowance = Int(tolerance.perChannel)\n        for y in 0..<baseline.height {",
        new="        let allowance = Int(tolerance.perChannel) * 0\n        for y in 0..<baseline.height {",
        test="PixelDiffTests/testAChannelDeltaWithinToleranceIsNotADifference",
    ),
    Mutation(
        # The region crop rounds INWARD instead of outward, so a frame landing on
        # a fractional point loses a row and a column -- and the edge is exactly
        # where a border, a shadow or a focus ring lives, i.e. the content this
        # channel exists to judge. The failure is silent in the expensive
        # direction: the crop is still a valid raster of a plausible size, both
        # sides are cropped identically, so the comparison MATCHES and reports
        # PASS for a regression it clipped out of view.
        name="the region crop rounds inward and clips the element's own edge",
        path="Sources/VerdictUIKernel/PixelDiff.swift",
        old="        let maxX = Int(((rect.x + rect.width) * scale).rounded(.up))",
        new="        let maxX = Int(((rect.x + rect.width) * scale).rounded(.down))",
        test="PixelDiffTests/testAFractionalFrameRoundsOutwardSoTheEdgeIsNeverClipped",
    ),
    Mutation(
        # The out-of-bounds region is CLAMPED rather than refused. A clamped crop
        # compares a different area than the caller asked for while reporting the
        # answer as the requested one, so a node that moved partly offscreen is
        # diffed against the wrong pixels and can report a match. `|| true` keeps
        # every binding live and compiles (no.md #31).
        name="an out-of-bounds pixel region is accepted instead of refused",
        path="Sources/VerdictUIKernel/PixelDiff.swift",
        old="            minX >= 0, minY >= 0, cropWidth > 0, cropHeight > 0,\n"
        "            maxX <= width, maxY <= height",
        new="            minX >= 0 || true, minY >= 0, cropWidth > 0, cropHeight > 0,\n"
        "            maxX <= width || true, maxY <= height",
        test="PixelDiffTests/testARegionOutsideTheCaptureIsRefusedRatherThanClamped",
    ),
]
