"""Web-engine guards and their real browser / pure CDP witnesses."""

from mutation_catalog_types import Mutation, Runner

_BASE = "Sources/VerdictUIWeb/"
_TEST = "VerdictUIWebTests."

MUTATIONS: list[Mutation] = [
    Mutation(
        name="web editable inline inventory requires pruned descendants",
        path=_BASE + "DOMSnapshotAssembly.swift",
        old='&& !tag.hasPrefix("::") && !prunedByControl[index] {',
        new='&& !tag.hasPrefix("::") {',
        test=_TEST
        + "DOMSnapshotAssemblyTests/testInlineInventoryMatchesRetainedEditableEvidenceWithoutExposingValues",
    ),
    Mutation(
        name="web editable inline inventory loses nested pruning",
        path=_BASE + "DOMSnapshotAssembly.swift",
        old="prunedByControl[parent] || prunesControlDescendants[parent]",
        new="prunesControlDescendants[parent]",
        test=_TEST
        + "WebFrameIntegrationTests/testEditableInlineValuesRemainRedactedWhileOutsideButtonActs",
    ),
    Mutation(
        name="web editable inline inventory skips retained measurements",
        path=_BASE + "DOMSnapshotAssembly.swift",
        old='&& !tag.hasPrefix("::") && !prunedByControl[index] {',
        new='&& !tag.hasPrefix("::") && !prunedByControl[index] && prunedByControl[index] {',
        test=_TEST
        + "DOMSnapshotAssemblyTests/testInlineInventoryMatchesRetainedEditableEvidenceWithoutExposingValues",
    ),
    Mutation(
        name="web containing raw DOM depth becomes semantic depth",
        path=_BASE + "DOMSnapshotAssembly.swift",
        old='metadata["web.domDepth"] = .number(Double(depths[index]))',
        new='metadata["web.domDepth"] = .number(Double(depths[index] - 1))',
        test=_TEST
        + "DOMSnapshotAssemblyTests/testContainingBlockDepthUsesRawDOMAndPropagatesToText",
    ),
    Mutation(
        name="web containing interval is not inherited by text",
        path=_BASE + "DOMSnapshotAssembly.swift",
        old="contexts[index] = contexts[parent]\n                absoluteDepth[index]",
        new="contexts[index] = nil\n                absoluteDepth[index]",
        test=_TEST
        + "DOMSnapshotAssemblyTests/testContainingBlockDepthUsesRawDOMAndPropagatesToText",
    ),
    Mutation(
        name="web containing text styles establish positioned boxes",
        path=_BASE + "DOMSnapshotAssembly.swift",
        old="guard types[index] == 1, let (_, style) = geometry[index] else { continue }",
        new="guard types[index] == 1 || types[index] == 3, let (_, style) = geometry[index] else { continue }",
        test=_TEST
        + "DOMSnapshotAssemblyTests/testContainingBlockDepthDistinguishesPositionAndTransformForAbsoluteAndFixed",
    ),
    Mutation(
        name="web containing unlaid ancestors establish boxes",
        path=_BASE + "DOMSnapshotAssembly.swift",
        old="let (_, style) = geometry[index] else { continue }",
        new="let (_, style) = geometry[index] ?? geometry[parent] else { continue }",
        test=_TEST
        + "DOMSnapshotAssemblyTests/testUnlaidContainingBoxesAndUnknownPositionsCannotInventEscapeProof",
    ),
    Mutation(
        name="web containing unknown positions claim valid ancestry",
        path=_BASE + "DOMSnapshotAssembly.swift",
        old='["static", "relative", "absolute", "fixed", "sticky"].contains(position)',
        new='["static", "relative", "absolute", "fixed", "sticky", "unknown"].contains(position)',
        test=_TEST
        + "DOMSnapshotAssemblyTests/testUnlaidContainingBoxesAndUnknownPositionsCannotInventEscapeProof",
    ),
    Mutation(
        name="web containing fixed boxes use absolute containing block",
        path=_BASE + "DOMSnapshotAssembly.swift",
        old='position == "fixed" ? fixedDepth[index] : absoluteDepth[index]',
        new='position == "fixed" ? absoluteDepth[index] : absoluteDepth[index]',
        test=_TEST
        + "DOMSnapshotAssemblyTests/testContainingBlockDepthDistinguishesPositionAndTransformForAbsoluteAndFixed",
    ),
    Mutation(
        name="web containing unknown block permits escape proof",
        path=_BASE + "DOMSnapshotAssembly.swift",
        old="container >= -1 ? (depths[index], container) : nil",
        new="container >= -2 ? (depths[index], container) : nil",
        test=_TEST
        + "DOMSnapshotAssemblyTests/testUnlaidContainingBoxesAndUnknownPositionsCannotInventEscapeProof",
    ),
    Mutation(
        name="web containing transforms cannot establish blocks",
        path=_BASE + "DOMSnapshotAssembly.swift",
        old="let fixedContainer = WebLint.establishesFixedContainer(styles: style)",
        new="let fixedContainer = WebLint.establishesFixedContainer(styles: style) && false",
        test=_TEST
        + "DOMSnapshotAssemblyTests/testContainingBlockDepthDistinguishesPositionAndTransformForAbsoluteAndFixed",
    ),
    Mutation(
        name="web containing relative boxes fail absolute ancestry",
        path=_BASE + "DOMSnapshotAssembly.swift",
        old='if position != "static" || fixedContainer { absoluteDepth[index]',
        new='if position == "absolute" || fixedContainer { absoluteDepth[index]',
        test=_TEST
        + "DOMSnapshotAssemblyTests/testContainingBlockDepthDistinguishesPositionAndTransformForAbsoluteAndFixed",
    ),
    Mutation(
        name="web containing relative boxes establish fixed ancestry",
        path=_BASE + "DOMSnapshotAssembly.swift",
        old="if fixedContainer { fixedDepth[index]",
        new='if fixedContainer || position != "static" { fixedDepth[index]',
        test=_TEST
        + "DOMSnapshotAssemblyTests/testContainingBlockDepthDistinguishesPositionAndTransformForAbsoluteAndFixed",
    ),
    Mutation(
        name="web font flow mistakes displacement for transform identity",
        path=_BASE + "DOMSnapshotAssembly.swift",
        old='value == "matrix(1,0,0,1,0,0)"',
        new='value == "matrix(1,0,0,1,0,1)"',
        test=_TEST
        + "DOMSnapshotAssemblyTests/testPositionFloatTransformAndOffsetsCannotClaimNormalFontFlow",
    ),
    Mutation(
        name="web font flow accepts transformed branches",
        path=_BASE + "DOMSnapshotAssembly.swift",
        old="guard !transformed[index] else",
        new="guard transformed[index] || !transformed[index] else",
        test=_TEST
        + "DOMSnapshotAssemblyTests/"
        + "testPositionFloatTransformAndOffsetsCannotClaimNormalFontFlow",
    ),
    Mutation(
        name="web font flow accepts positioned nodes",
        path=_BASE + "DOMSnapshotAssembly.swift",
        old='style[4] == "static", style[14] == "none"',
        new='style[4] != "invalid", style[14] == "none"',
        test=_TEST
        + "DOMSnapshotAssemblyTests/"
        + "testPositionFloatTransformAndOffsetsCannotClaimNormalFontFlow",
    ),
    Mutation(
        name="web font flow accepts floated nodes",
        path=_BASE + "DOMSnapshotAssembly.swift",
        old='style[4] == "static", style[14] == "none"',
        new='style[4] == "static", style[14] != "invalid"',
        test=_TEST
        + "DOMSnapshotAssemblyTests/"
        + "testPositionFloatTransformAndOffsetsCannotClaimNormalFontFlow",
    ),
    Mutation(
        name="web font flow accepts explicit offsets",
        path=_BASE + "DOMSnapshotAssembly.swift",
        old='style[36...39].allSatisfy({ $0 == "auto" })',
        new="style[36...39].allSatisfy({ _ in true })",
        test=_TEST
        + "DOMSnapshotAssemblyTests/"
        + "testPositionFloatTransformAndOffsetsCannotClaimNormalFontFlow",
    ),
    Mutation(
        name="web font flow accepts negative block margins",
        path=_BASE + "DOMSnapshotAssembly.swift",
        old="cssPixels($0).map { $0 >= 0 } == true",
        new="cssPixels($0).map { $0 >= -100 } == true",
        test=_TEST
        + "DOMSnapshotAssemblyTests/"
        + "testPositionFloatTransformAndOffsetsCannotClaimNormalFontFlow",
    ),
    Mutation(
        name="web font flow accepts mixed anonymous contexts",
        path=_BASE + "DOMSnapshotAssembly.swift",
        old="if inlineChildren { contexts[index]",
        new="if inlineChildren || !children[index].isEmpty { contexts[index]",
        test=_TEST
        + "DOMSnapshotAssemblyTests/"
        + "testFontBoxMetadataRequiresOneMeasuredNormalInlineFormattingContext",
    ),
    Mutation(
        name="web font flow accepts shifted vertical alignment",
        path=_BASE + "DOMSnapshotAssembly.swift",
        old='style[32] == "baseline"',
        new='style[32] != "invalid"',
        test=_TEST
        + "DOMSnapshotAssemblyTests/"
        + "testPositionFloatTransformAndOffsetsCannotClaimNormalFontFlow",
    ),
    Mutation(
        name="web font flow accepts nonzero inline margins",
        path=_BASE + "DOMSnapshotAssembly.swift",
        old="style[15...18].allSatisfy({ cssPixels($0) == 0 })",
        new="style[15...18].allSatisfy({ cssPixels($0).map { $0 >= 0 } == true })",
        test=_TEST
        + "DOMSnapshotAssemblyTests/"
        + "testPositionFloatTransformAndOffsetsCannotClaimNormalFontFlow",
    ),
    Mutation(
        name="web font flow accepts nonfinite computed lengths",
        path=_BASE + "DOMSnapshotAssembly.swift",
        old="Double(raw.dropLast(2)), value.isFinite",
        new="Double(raw.dropLast(2)), !value.isNaN",
        test=_TEST
        + "DOMSnapshotAssemblyTests/"
        + "testPositionFloatTransformAndOffsetsCannotClaimNormalFontFlow",
    ),
    Mutation(
        name="web font paint ignores border and padding",
        path=_BASE + "DOMSnapshotAssembly.swift",
        old="style[19...26].allSatisfy({ cssPixels($0) == 0 })",
        new="style[19...26].allSatisfy({ _ in true })",
        test=_TEST
        + "DOMSnapshotAssemblyTests/"
        + "testPaintedPaddedInteractiveAndReplacedInlineBoxesRemainOrdinaryEvidence",
    ),
    Mutation(
        name="web font paint ignores painted outlines",
        path=_BASE + "DOMSnapshotAssembly.swift",
        old='(style[40] == "none" || cssPixels(style[27]) == 0)',
        new='(style[40] == "none" || cssPixels(style[27]).map { $0 >= 0 } == true)',
        test=_TEST
        + "DOMSnapshotAssemblyTests/"
        + "testPaintedPaddedInteractiveAndReplacedInlineBoxesRemainOrdinaryEvidence",
    ),
    Mutation(
        name="web font paint ignores box shadows",
        path=_BASE + "DOMSnapshotAssembly.swift",
        old='style[28] == "none"',
        new='style[28] != "invalid"',
        test=_TEST
        + "DOMSnapshotAssemblyTests/"
        + "testPaintedPaddedInteractiveAndReplacedInlineBoxesRemainOrdinaryEvidence",
    ),
    Mutation(
        name="web font paint ignores background painting",
        path=_BASE + "DOMSnapshotAssembly.swift",
        old='(style[29] == "rgba(0, 0, 0, 0)" && style[30] == "none")',
        new="(style[29].count >= 0 && style[30].count >= 0)",
        test=_TEST
        + "DOMSnapshotAssemblyTests/"
        + "testPaintedPaddedInteractiveAndReplacedInlineBoxesRemainOrdinaryEvidence",
    ),
    Mutation(
        name="web font paint ignores interaction evidence",
        path=_BASE + "DOMSnapshotAssembly.swift",
        old="let fontOnly = inert && (",
        new="let fontOnly = (inert || !inert) && (",
        test=_TEST
        + "DOMSnapshotAssemblyTests/"
        + "testPaintedPaddedInteractiveAndReplacedInlineBoxesRemainOrdinaryEvidence",
    ),
    Mutation(
        name="web font paint qualifies replaced content",
        path=_BASE + "DOMSnapshotAssembly.swift",
        old="&& role == .container && textOnlyChildren",
        new='&& role != .custom("never") && textOnlyChildren',
        test=_TEST
        + "DOMSnapshotAssemblyTests/"
        + "testPaintedPaddedInteractiveAndReplacedInlineBoxesRemainOrdinaryEvidence",
    ),
    Mutation(
        name="web font paint rejects measured text-only inline content",
        path=_BASE + "DOMSnapshotAssembly.swift",
        old="textOnlyChildren && fontOnlyInlinePaint(style)",
        new="!textOnlyChildren && fontOnlyInlinePaint(style)",
        test=_TEST
        + "DOMSnapshotAssemblyTests/"
        + "testFontBoxMetadataRequiresOneMeasuredNormalInlineFormattingContext",
    ),
    Mutation(
        name="web inline cancellation prevents remote object cleanup",
        path=_BASE + "WebInlineGeometry.swift",
        old='_ = try await Task.detached {\n            try await command("Runtime.releaseObjectGroup", ["objectGroup": .string(group)], .seconds(1))\n        }.value',
        new='try Task.checkCancellation()\n        _ = try await command("Runtime.releaseObjectGroup", ["objectGroup": .string(group)], .seconds(1))',
        test=_TEST
        + "WebInlineGeometryTests/testResolutionBatchesAreBoundedAndCancellationStillReleasesObjects",
    ),
    Mutation(
        name="web absent clickability column fabricates measured interaction",
        path=_BASE + "DOMSnapshotAssembly.swift",
        old='metadata["web.interactionMeasured"] = .bool(nodes["isClickable"] != nil)',
        new='metadata["web.interactionMeasured"] = .bool(true)',
        test=_TEST
        + "DOMSnapshotAssemblyTests/testClickableIndicesAndConservativeFocusableEvidenceAreValidated",
    ),
    Mutation(
        name="web omitted interactive ancestors lose conservative evidence",
        path=_BASE + "DOMSnapshotAssembly.swift",
        old='metadata["web.hasInteractiveAncestor"] = .bool(interactiveAncestors[index])',
        new='metadata["web.hasInteractiveAncestor"] = .bool(false)',
        test=_TEST
        + "DOMSnapshotAssemblyTests/testOmittedAncestorsRetainClickAndFocusEvidenceOnDescendants",
    ),
    Mutation(
        name="web inline candidate limit is bypassed",
        path=_BASE + "WebInlineGeometry.swift",
        old="count <= candidates",
        new="count <= Int.max",
        test=_TEST
        + "WebInlineGeometryTests/testNonHTMLIsExplicitAndBudgetsAreGlobalAndDeadlineBounded",
    ),
    Mutation(
        name="web inline fragment limit is bypassed",
        path=_BASE + "WebInlineGeometry.swift",
        old="count <= fragments",
        new="count <= Int.max",
        test=_TEST
        + "WebInlineGeometryTests/testNonHTMLIsExplicitAndBudgetsAreGlobalAndDeadlineBounded",
    ),
    Mutation(
        name="web inline deadline is ignored",
        path=_BASE + "WebInlineGeometry.swift",
        old="remaining > .zero",
        new="remaining > .seconds(-2)",
        test=_TEST
        + "WebInlineGeometryTests/testNonHTMLIsExplicitAndBudgetsAreGlobalAndDeadlineBounded",
    ),
    Mutation(
        name="web inline isolated context identity is not checked",
        path=_BASE + "WebInlineGeometry.swift",
        old="context > 0",
        new="context >= -1",
        test=_TEST
        + "WebInlineGeometryTests/testInvalidRemoteContextNodeAndScriptExceptionRemainUnavailable",
    ),
    Mutation(
        name="web inline remote object identity is empty",
        path=_BASE + "WebInlineGeometry.swift",
        old="!objectID.isEmpty",
        new="objectID.count >= 0",
        test=_TEST
        + "WebInlineGeometryTests/testInvalidRemoteContextNodeAndScriptExceptionRemainUnavailable",
    ),
    Mutation(
        name="web inline script exceptions are accepted",
        path=_BASE + "WebInlineGeometry.swift",
        old='response["exceptionDetails"] == nil',
        new='response["exceptionDetails"] == response["exceptionDetails"]',
        test=_TEST
        + "WebInlineGeometryTests/testInvalidRemoteContextNodeAndScriptExceptionRemainUnavailable",
    ),
    Mutation(
        name="web inline missing rows yield partial measurements",
        path=_BASE + "WebInlineGeometry.swift",
        old="rows.count == batch.count",
        new="rows.count <= batch.count",
        test=_TEST
        + "WebInlineGeometryTests/testIncompleteAndOversizedMeasurementsFailWithoutPartialRecords",
    ),
    Mutation(
        name="web inline empty fragments are accepted",
        path=_BASE + "WebInlineGeometry.swift",
        old="case let .array(rects) = row, !rects.isEmpty",
        new="case let .array(rects) = row, rects.count >= 0",
        test=_TEST
        + "WebInlineGeometryTests/testIncompleteAndOversizedMeasurementsFailWithoutPartialRecords",
    ),
    Mutation(
        name="web inline remote objects are not released after failure",
        path=_BASE + "WebInlineGeometry.swift",
        old="        } catch {\n            try await release(group, command: command)",
        new="        } catch {\n            // Deliberate leak for the ownership witness.",
        test=_TEST
        + "WebInlineGeometryTests/testCollectionUsesExactNodesAndReleasesObjectsOnSuccessAndEveryFailure",
    ),
    Mutation(
        name="web inline remote objects are not released after success",
        path=_BASE + "WebInlineGeometry.swift",
        old="        try await release(group, command: command)\n        return records",
        new="        return records",
        test=_TEST
        + "WebInlineGeometryTests/testCollectionUsesExactNodesAndReleasesObjectsOnSuccessAndEveryFailure",
    ),
    Mutation(
        name="web inline border union consistency is ignored",
        path=_BASE + "DOMSnapshotAssembly.swift",
        old="abs(measuredUnion.height - frame.height) <= 0.1",
        new="abs(measuredUnion.height - frame.height) <= 1000",
        test=_TEST
        + "DOMSnapshotAssemblyTests/testInlineBorderFragmentsPreserveUnionAndRejectIncompleteOrChangedGeometry",
    ),
    Mutation(
        name="web inline missing border geometry becomes union fallback",
        path=_BASE + "WebLint.swift",
        old='if inline { throw WebBrowserError.invalidCDPResponse(reason: "missing inline border geometry") }',
        new="if inline { return [node.frame] }",
        test=_TEST
        + "WebLintTests/testInlineBorderFragmentsAvoidUnionOverlapAndRetainPaddingCollisions",
    ),
    Mutation(
        name="web inline overlap ignores measured border fragments",
        path=_BASE + "WebLint.swift",
        old='let key = inline ? "web.inlineFragment" : "web.textFragment"',
        new='let key = inline ? "web.textFragment" : "web.textFragment"',
        test=_TEST
        + "WebLintTests/testInlineBorderFragmentsAvoidUnionOverlapAndRetainPaddingCollisions",
    ),
    Mutation(
        name="web inline frame transforms lose border fragment coordinates",
        path=_BASE + "WebFrameGeometry.swift",
        old='rectangleKeys += (0..<count).map { "web.inlineFragment\\($0)" }',
        new='rectangleKeys += (0..<count).map { "web.ignoredInlineFragment\\($0)" }',
        test=_TEST
        + "DOMSnapshotAssemblyTests/testInlineBorderFragmentsPreserveUnionAndRejectIncompleteOrChangedGeometry",
    ),
    Mutation(
        name="web inline reader replaces border fragments with union",
        path=_BASE + "WebInlineGeometry.swift",
        old="const read = Element.prototype.getClientRects;",
        new="const read = function() { return [Element.prototype.getBoundingClientRect.call(this)]; };",
        test=_TEST
        + "WebFrameIntegrationTests/testWrappedInlineBorderMeasurementsAcrossFramesAndScroll",
    ),
    Mutation(
        name="web measured clickable duplicate indices are accepted",
        path=_BASE + "DOMSnapshotAssembly.swift",
        old="indices.count <= count, Set(indices).count == indices.count",
        new="indices.count <= count, Set(indices).count <= indices.count",
        test=_TEST
        + "DOMSnapshotAssemblyTests/testClickableIndicesAndConservativeFocusableEvidenceAreValidated",
    ),
    Mutation(
        name="web measured clickable index bounds are ignored",
        path=_BASE + "DOMSnapshotAssembly.swift",
        old="indices.allSatisfy({ (0..<count).contains($0) })",
        new="indices.allSatisfy({ _ in true })",
        test=_TEST
        + "DOMSnapshotAssemblyTests/testClickableIndicesAndConservativeFocusableEvidenceAreValidated",
    ),
    Mutation(
        name="web measured clickability is discarded",
        path=_BASE + "DOMSnapshotAssembly.swift",
        old='metadata["web.isClickable"] = .bool(clickable.contains(index))',
        new='metadata["web.isClickable"] = .bool(clickable.contains(index) && false)',
        test=_TEST
        + "DOMSnapshotAssemblyTests/testClickableIndicesAndConservativeFocusableEvidenceAreValidated",
    ),
    Mutation(
        name="web measured explicit tabindex is ignored",
        path=_BASE + "DOMSnapshotAssembly.swift",
        old='if attributes["tabindex"] != nil { return true }',
        new='if attributes["tabindex"] != nil { return false }',
        test=_TEST
        + "DOMSnapshotAssemblyTests/testFocusabilityUsesExplicitDOMEvidenceConservatively",
    ),
    Mutation(
        name="web overlap budget exhaustion continues to verdict",
        path=_BASE + "WebLint.swift",
        old='throw WebBrowserError.invalidWebOperation(reason: "web overlap inspection exceeded its bounded work budget")',
        new="return",
        test=_TEST + "WebLintTests/testOverlapBudgetExhaustionIsUnavailableAndNeverPartialPass",
    ),
    Mutation(
        name="web overlap original candidate work is uncharged",
        path=_BASE + "WebLint.swift",
        old="try budget.charge(); budget.originalPairs += 1",
        new="try budget.charge(0); budget.originalPairs += 1",
        test=_TEST + "WebLintTests/testOverlapBudgetExhaustionIsUnavailableAndNeverPartialPass",
    ),
    Mutation(
        name="web overlap raw fragments bypass work preflight",
        path=_BASE + "WebLint.swift",
        old="try budget.charge(count)",
        new="try budget.charge(0)",
        test=_TEST
        + "WebLintTests/testClippedFragmentsConsumeRawWorkBeforeDecodingEvenWhenNoneSurvive",
    ),
    Mutation(
        name="web overlap sweep events bypass work preflight",
        path=_BASE + "WebLint.swift",
        old="try budget.charge(rectangles.count)",
        new="try budget.charge(0)",
        test=_TEST + "WebLintTests/testOverlapBudgetExhaustionIsUnavailableAndNeverPartialPass",
    ),
    Mutation(
        name="web overlap active comparisons bypass budget",
        path=_BASE + "WebLint.swift",
        old="try budget.charge(); budget.fragmentComparisons += 1",
        new="try budget.charge(0); budget.fragmentComparisons += 1",
        test=_TEST + "WebLintTests/testOverlapBudgetExhaustionIsUnavailableAndNeverPartialPass",
    ),
    Mutation(
        name="web overlap ended fragments remain active",
        path=_BASE + "WebLint.swift",
        old="rectangles[ends[end]].maxY <= box.y",
        new="rectangles[ends[end]].maxY <= box.y - 100",
        test=_TEST + "WebLintTests/testInterleavedLongTextsUseBoundedSortedEvents",
    ),
    Mutation(
        name="web overlap actual fragment collision is ignored",
        path=_BASE + "WebLint.swift",
        old="let intersection = box.intersection(rectangles[other]),",
        new="let intersection = box.intersection(Rect(x: 0, y: 0, width: 0, height: 0)),",
        test=_TEST
        + "WebLintTests/testTextFragmentsAvoidUnionOverlapAndRetainRealCollisionEvidence",
    ),
    Mutation(
        name="web overlap fragments ignore paint clipping",
        path=_BASE + "WebLint.swift",
        old="return measured.compactMap { $0.intersection(clip) }",
        new="return measured.compactMap { clip.width >= 0 ? $0 : $0.intersection(clip) }",
        test=_TEST + "WebLintTests/testFragmentPaintClipAppliesToActualBoxesNotOnlyUnion",
    ),
    Mutation(
        name="web overlap merge insertions bypass budget",
        path=_BASE + "WebLint.swift",
        old="for finding in incoming {\n                try budget.charge()",
        new="for finding in incoming {\n                try budget.charge(0)",
        test=_TEST
        + "WebLintTests/testFindingDeduplicationPreservesEveryFieldAndHasLinearChargedWork",
    ),
    Mutation(
        name="web overlap deduplication loses node identity",
        path=_BASE + "WebLint.swift",
        old="nodeID = finding.nodeID; message = finding.message; suggestion = finding.suggestion",
        new='nodeID = ""; message = finding.message; suggestion = finding.suggestion',
        test=_TEST
        + "WebLintTests/testFindingDeduplicationPreservesEveryFieldAndHasLinearChargedWork",
    ),
    Mutation(
        name="web overlap duplicate findings are appended",
        path=_BASE + "WebLint.swift",
        old="if seen.insert(Key(finding)).inserted { values.append(finding) }",
        new="if seen.insert(Key(finding)).inserted || !finding.rule.isEmpty { values.append(finding) }",
        test=_TEST
        + "WebLintTests/testFindingDeduplicationPreservesEveryFieldAndHasLinearChargedWork",
    ),
    Mutation(
        name="web scroll transform containing block is ignored",
        path=_BASE + "WebLint.swift",
        old='styles[9] != "none"',
        new='styles[9] == "unsupported"',
        test=_TEST + "WebLintTests/testComputedContainingBlockPropertiesHaveIndependentWitnesses",
    ),
    Mutation(
        name="web scroll filter containing block is ignored",
        path=_BASE + "WebLint.swift",
        old='styles[10] != "none"',
        new='styles[10] == "unsupported"',
        test=_TEST + "WebLintTests/testComputedContainingBlockPropertiesHaveIndependentWitnesses",
    ),
    Mutation(
        name="web scroll perspective containing block is ignored",
        path=_BASE + "WebLint.swift",
        old='styles[11] != "none"',
        new='styles[11] == "unsupported"',
        test=_TEST + "WebLintTests/testComputedContainingBlockPropertiesHaveIndependentWitnesses",
    ),
    Mutation(
        name="web scroll contain property is ignored",
        path=_BASE + "WebLint.swift",
        old='!contain.isDisjoint(with: ["layout", "paint", "strict", "content"])',
        new='!contain.isDisjoint(with: ["unsupported"])',
        test=_TEST + "WebLintTests/testComputedContainingBlockPropertiesHaveIndependentWitnesses",
    ),
    Mutation(
        name="web scroll will change containing block is ignored",
        path=_BASE + "WebLint.swift",
        old='!willChange.isDisjoint(with: ["transform", "filter", "perspective", "contain", "translate", "rotate", "scale"])',
        new='!willChange.isDisjoint(with: ["unsupported"])',
        test=_TEST + "WebLintTests/testComputedContainingBlockPropertiesHaveIndependentWitnesses",
    ),
    Mutation(
        name="web scroll empty paint proof is not applied",
        path=_BASE + "DOMSnapshotAssembly.swift",
        old="&& !WebLint.emptyPaint(position: style[4], clip: style[5], clipPath: style[6], frame: frame)",
        new='&& (!WebLint.emptyPaint(position: style[4], clip: style[5], clipPath: style[6], frame: frame) || style[0] != "none")',
        test=_TEST
        + "DOMSnapshotAssemblyTests/testMeasuredEmptyPaintClipHidesDescendantsAndFocusRestoresThem",
    ),
    Mutation(
        name="web paint scrollable descendant inherits outer clipping axis",
        path=_BASE + "WebLint.swift",
        old="y: $0.y && !scrollY)",
        new="y: $0.y && (scrollY || $0.y))",
        test=_TEST + "WebLintTests/testScrollPanelInsideHiddenCardDoesNotClipReachableContent",
    ),
    Mutation(
        name="web paint text box row budget is removed",
        path=_BASE + "DOMSnapshotAssembly.swift",
        old="rawIndices.count <= 100_000",
        new="rawIndices.count <= 200_000",
        test=_TEST + "DOMSnapshotAssemblyTests/testTextBoxBudgetAndLineBreakRoles",
    ),
    Mutation(
        name="web paint line breaks become visible containers",
        path=_BASE + "DOMSnapshotAssembly.swift",
        old='case "br", "wbr": return .spacer',
        new='case "br", "wbr": return .container',
        test=_TEST + "DOMSnapshotAssemblyTests/testTextBoxBudgetAndLineBreakRoles",
    ),
    Mutation(
        name="web paint line breaks fabricate evidence",
        path=_BASE + "WebLint.swift",
        old='if node.role == .spacer { node.id = "" }',
        new="if node.role == .spacer { node.id = source.id }",
        test=_TEST + "WebLintTests/testLineBreakIsLayoutOnlyAndCannotFabricateEvidence",
    ),
    Mutation(
        name="web paint text overlap uses union rectangle",
        path=_BASE + "WebLint.swift",
        old="guard inline || node.role == .text else",
        new="guard inline || node.role == .spacer else",
        test=_TEST
        + "WebLintTests/testTextFragmentsAvoidUnionOverlapAndRetainRealCollisionEvidence",
    ),
    Mutation(
        name="web paint overlap cites the wrong original node",
        path=_BASE + "WebLint.swift",
        old="rule: SiblingOverlapRule.id, node: children[second],",
        new="rule: SiblingOverlapRule.id, node: children[first],",
        test=_TEST
        + "WebLintTests/testTextFragmentsAvoidUnionOverlapAndRetainRealCollisionEvidence",
    ),
    Mutation(
        name="web paint text boxes ignore document scroll",
        path=_BASE + "DOMSnapshotAssembly.swift",
        old="y: box.y - scrollY,",
        new="y: box.y - scrollY * 0,",
        test=_TEST
        + "DOMSnapshotAssemblyTests/testTextFragmentGeometryTracksScrollAndFrameTransforms",
    ),
    Mutation(
        name="web paint text boxes remain in child coordinates",
        path=_BASE + "WebFrameGeometry.swift",
        old='rectangleKeys += (0..<count).map { "web.textFragment\\($0)" }',
        new='rectangleKeys += (0..<min(count, 0)).map { "web.textFragment\\($0)" }',
        test=_TEST
        + "DOMSnapshotAssemblyTests/testTextFragmentGeometryTracksScrollAndFrameTransforms",
    ),
    Mutation(
        name="web paint visible overflow is treated as clipping",
        path=_BASE + "WebLint.swift",
        old='value == "hidden" || value == "clip"',
        new='value == "hidden" || value == "clip" || value == "visible"',
        test=_TEST + "WebLintTests/testVisibleFontInkIsNotClippedButHiddenAxisStillFails",
    ),
    Mutation(
        name="web paint real clipped ink is ignored",
        path=_BASE + "WebLint.swift",
        old="if amount > ClippedContentRule.tolerance {",
        new="if amount > ClippedContentRule.tolerance + 100 {",
        test=_TEST + "WebLintTests/testVisibleFontInkIsNotClippedButHiddenAxisStillFails",
    ),
    Mutation(
        name="web scroll iframe fixed child escapes outer scroll clip",
        path=_BASE + "WebLint.swift",
        old="Clip.combined(ownDocument, documentClip, Boundary.combined(childScroll), Boundary.combined(childCSS))",
        new="Clip.combined(ownDocument, documentClip, Boundary.combined(childCSS))",
        test=_TEST + "WebLintTests/testFixedChildCannotEscapeOuterScrollPanelThroughIframe",
    ),
    Mutation(
        name="web scroll hidden-only tree supplies evidence",
        path=_BASE + "WebLint.swift",
        old="node.children = source.children.filter(\\.isVisible).map(visibleEvidence)",
        new="node.children = source.children.map(visibleEvidence)",
        test=_TEST + "WebLintTests/testHiddenOnlyFrameCannotSupplyVisibleEvidence",
    ),
    Mutation(
        name="web scroll invalid extent becomes geometry",
        path=_BASE + "WebLint.swift",
        old='throw WebBrowserError.invalidCDPResponse(reason: "invalid web scroll geometry")',
        new="return Rect(x: 0, y: 0, width: 0, height: 0)",
        test=_TEST + "WebLintTests/testInvalidAndOverflowedExtentsFailClosed",
    ),
    Mutation(
        name="web scroll missing document extent becomes empty evidence",
        path=_BASE + "DOMSnapshotAssembly.swift",
        old='throw malformed("missing document scroll extent")',
        new="return []",
        test=_TEST
        + "DOMSnapshotAssemblyTests/testDocumentExtentRequiredFiniteAndZeroDimensionsRemainValid",
    ),
    Mutation(
        name="web scroll embedded content uses parent document extent",
        path=_BASE + "WebLint.swift",
        old="if frame != scope.frame, let bounds",
        new="if false && frame != scope.frame, let bounds",
        test=_TEST + "WebLintTests/testEmbeddedDocumentDoesNotClipAtOwnerButOwnerRemainsChecked",
    ),
    Mutation(
        name="web scroll scroll content uses outer document bounds",
        path=_BASE + "WebLint.swift",
        old='if let bounds = rect(key: "web.scrollBounds", in: source.attributes) {',
        new='if let bounds = rect(key: "web.scrollBounds", in: source.attributes), bounds.width < 0 {',
        test=_TEST + "WebLintTests/testScrollPanelRetainsOwnerAndSeparatesContentClipping",
    ),
    Mutation(
        name="web scroll fixed content uses document extent",
        path=_BASE + "WebLint.swift",
        old='if source.attributes["web.position"] == .string("fixed"), viewportFixed, !scope.fixed {',
        new='if source.attributes["web.position"] == .string("fixed"), viewportFixed, !scope.fixed, scope.bounds.width < 0 {',
        test=_TEST + "WebLintTests/testNegativeAndFixedDisplacementStillFailWithOriginalIDs",
    ),
    Mutation(
        name="web scroll transformed containing block is ignored",
        path=_BASE + "WebLint.swift",
        old='let childContained = contained || source.attributes["web.fixedContainer"] == .bool(true)',
        new="let childContained = contained",
        test=_TEST + "WebLintTests/testTransformedAncestorPreventsViewportFixedClassification",
    ),
    Mutation(
        name="web scroll cross scope overlaps are unexamined",
        path=_BASE + "WebLint.swift",
        old="try accumulated.append(overlaps, budget: &budget)",
        new="try accumulated.append(Array(overlaps.prefix(0)), budget: &budget)",
        test=_TEST + "WebLintTests/testFixedAndFlowOverlapRemainObservableAcrossLintScopes",
    ),
    Mutation(
        name="web scroll clipped paint is treated visible",
        path=_BASE + "WebLint.swift",
        old="else { node.isVisible = false }",
        new="else { node.isVisible = source.isVisible }",
        test=_TEST + "WebLintTests/testOffPanelAndOffFrameContentCannotPaintOverOuterContent",
    ),
    Mutation(
        name="web scroll iframe scroll target is hidden",
        path=_BASE + "WebFrameGeometry.swift",
        old="node.isVisible = visible && source.isVisible",
        new="node.isVisible = visible && source.isVisible && node.frame.y < 600",
        test=_TEST + "WebLintTests/testEmbeddedDocumentDoesNotClipAtOwnerButOwnerRemainsChecked",
    ),
    Mutation(
        name="web scroll iframe viewport uses main viewport",
        path=_BASE + "WebFrameGeometry.swift",
        old='WebLint.store(viewport, key: "web.documentViewport", in: &child.attributes)',
        new='WebLint.store(viewport.width >= 0 ? source.frame : viewport, key: "web.documentViewport", in: &child.attributes)',
        test=_TEST + "WebLintTests/testEmbeddedViewportUsesOwnerClientSizeAndTransformedBounds",
    ),
    Mutation(
        name="web scroll iframe bounds do not transform",
        path=_BASE + "WebFrameGeometry.swift",
        old="WebLint.store(shifted, key: key, in: &node.attributes)",
        new="WebLint.store(shifted.width >= 0 ? rect : shifted, key: key, in: &node.attributes)",
        test=_TEST + "WebLintTests/testEmbeddedViewportUsesOwnerClientSizeAndTransformedBounds",
    ),
    Mutation(
        name="web scroll hit test omits renderer horizontal scroll",
        path=_BASE + "WebFrameGeometry.swift",
        old="let px = Int64(exactly: (x + sx).rounded(.towardZero))",
        new="let px = Int64(exactly: (x + sx * 0).rounded(.towardZero))",
        test=_TEST + "WebLintTests/testHitTestUsesRendererDocumentScrollAndRejectsOverflow",
    ),
    Mutation(
        name="web scroll hit test omits renderer vertical scroll",
        path=_BASE + "WebFrameGeometry.swift",
        old="let py = Int64(exactly: (y + sy).rounded(.towardZero))",
        new="let py = Int64(exactly: (y + sy * 0).rounded(.towardZero))",
        test=_TEST + "WebLintTests/testHitTestUsesRendererDocumentScrollAndRejectsOverflow",
    ),
    Mutation(
        name="web scroll hit test invalid input is accepted",
        path=_BASE + "WebFrameGeometry.swift",
        old='throw WebBrowserError.invalidCDPResponse(reason: "invalid document hit-test coordinates")',
        new='return ["x": .integer(0), "y": .integer(0)]',
        test=_TEST + "WebLintTests/testHitTestUsesRendererDocumentScrollAndRejectsOverflow",
    ),
    Mutation(
        name="web scroll legacy clip hides static content",
        path=_BASE + "WebLint.swift",
        old='if (position == "absolute" || position == "fixed"), let parts',
        new='if (position == "absolute" || position == "fixed" || position == "static"), let parts',
        test=_TEST + "WebLintTests/testEmptyClipOnlyHidesSupportedComputedFormsAndRestoresOnFocus",
    ),
    Mutation(
        name="web scroll empty percentage clip remains visible",
        path=_BASE + "WebLint.swift",
        old="return top + bottom >= 100 || left + right >= 100",
        new="return top + bottom > 100 || left + right > 100",
        test=_TEST + "WebLintTests/testEmptyClipOnlyHidesSupportedComputedFormsAndRestoresOnFocus",
    ),
    Mutation(
        name="web scroll transformed pixel inset hides painted content",
        path=_BASE + "WebLint.swift",
        old='if sides.allSatisfy({ $0.hasSuffix("%") }),',
        new="if !sides.isEmpty,",
        test=_TEST + "WebLintTests/testEmptyClipOnlyHidesSupportedComputedFormsAndRestoresOnFocus",
    ),
    Mutation(
        name="web unlaid frame owners are discarded",
        path=_BASE + "DOMSnapshotAssembly.swift",
        old='if geometry[index] == nil && types[index] == 1 && (tag == "iframe" || tag == "frame") {',
        new='if false && geometry[index] == nil && types[index] == 1 && (tag == "iframe" || tag == "frame") {',
        test=_TEST
        + "DOMSnapshotAssemblyTests/testUnlaidFrameOwnersPreserveIdentityWithoutInventingVisibleEvidence",
    ),
    Mutation(
        name="web unlaid generic containers hide their visible descendants",
        path=_BASE + "DOMSnapshotAssembly.swift",
        old='if geometry[index] == nil && types[index] == 1 && (tag == "iframe" || tag == "frame") {',
        new="if geometry[index] == nil && types[index] == 1 {",
        test=_TEST
        + "DOMSnapshotAssemblyTests/testGenericUnlaidContainersDoNotHideVisibleDescendants",
    ),
    Mutation(
        name="web unlaid frame owner is reported visible",
        path=_BASE + "DOMSnapshotAssembly.swift",
        old="attributes: metadata, isVisible: false, children: descendants.map(hidden)",
        new="attributes: metadata, isVisible: true, children: descendants.map(hidden)",
        test=_TEST
        + "DOMSnapshotAssemblyTests/testUnlaidFrameOwnersPreserveIdentityWithoutInventingVisibleEvidence",
    ),
    Mutation(
        name="web unlaid frame scaffold becomes fabricated probe evidence",
        path=_BASE + "DOMSnapshotAssembly.swift",
        old='descendants = [SemanticNode(id: "", role: .container, frame: Rect(x: 0, y: 0, width: 0, height: 0),',
        new='descendants = [SemanticNode(id: "fabricated-probe", role: .container, frame: Rect(x: 0, y: 0, width: 0, height: 0),',
        test=_TEST
        + "DOMSnapshotAssemblyTests/testUnlaidFrameOwnersPreserveIdentityWithoutInventingVisibleEvidence",
    ),
    Mutation(
        name="web fragmented layout duplicates are rejected again",
        path=_BASE + "DOMSnapshotAssembly.swift",
        old="guard parents.indices.contains(index) else {",
        new="guard parents.indices.contains(index), geometry[index] == nil else {",
        test=_TEST + "DOMSnapshotAssemblyTests/testMeasuredPseudoElementCanHaveMultipleLayoutRows",
    ),
    Mutation(
        name="web fragmented layout later geometry is discarded",
        path=_BASE + "DOMSnapshotAssembly.swift",
        old="geometry[index] = (try union(previous, shifted), style)",
        new="geometry[index] = (previous, style)",
        test=_TEST
        + "DOMSnapshotAssemblyTests/testLayoutFragmentsPreserveUnionTextAndLayoutRowTextBoxes",
    ),
    Mutation(
        name="web fragmented layout trailing empty boxes expand the union",
        path=_BASE + "DOMSnapshotAssembly.swift",
        old="if second.isEmpty { return first }",
        new="if false { return first }",
        test=_TEST
        + "DOMSnapshotAssemblyTests/testEmptyLayoutFragmentsDoNotExpandDisplacedGeometry",
    ),
    Mutation(
        name="web fragmented layout leading empty boxes expand the union",
        path=_BASE + "DOMSnapshotAssembly.swift",
        old="if first.isEmpty { return second }",
        new="if false { return second }",
        test=_TEST
        + "DOMSnapshotAssemblyTests/testEmptyLayoutFragmentsDoNotExpandDisplacedGeometry",
    ),
    Mutation(
        name="web fragmented layout conflicting styles are accepted",
        path=_BASE + "DOMSnapshotAssembly.swift",
        old="guard previousStyle == style else",
        new="guard previousStyle.count == style.count else",
        test=_TEST
        + "DOMSnapshotAssemblyTests/testDuplicateLayoutRowsStillValidateEveryRectangleAndStyle",
    ),
    Mutation(
        name="web fragmented layout row budget is removed",
        path=_BASE + "DOMSnapshotAssembly.swift",
        old="rawLayoutNodes.count <= 100_000",
        new="true",
        test=_TEST + "DOMSnapshotAssemblyTests/testLayoutRowBudgetStillAppliesWhenDOMIndicesRepeat",
    ),
    Mutation(
        name="web fragmented layout union overflow is accepted",
        path=_BASE + "DOMSnapshotAssembly.swift",
        old='throw malformed("layout fragment union overflow")',
        new="return first",
        test=_TEST
        + "DOMSnapshotAssemblyTests/testFiniteRectangleInputsCannotOverflowDerivedGeometry",
    ),
    Mutation(
        name="web fragmented layout rectangle endpoint overflow is accepted",
        path=_BASE + "DOMSnapshotAssembly.swift",
        old='throw malformed("rectangle coordinate overflow")',
        new="return Rect(x: 0, y: 0, width: 0, height: 0)",
        test=_TEST
        + "DOMSnapshotAssemblyTests/testFiniteRectangleInputsCannotOverflowDerivedGeometry",
    ),
    Mutation(
        name="web fragmented layout translated coordinate overflow is accepted",
        path=_BASE + "DOMSnapshotAssembly.swift",
        old='throw malformed("layout coordinate overflow")',
        new="return []",
        test=_TEST
        + "DOMSnapshotAssemblyTests/testFiniteRectangleInputsCannotOverflowDerivedGeometry",
    ),
    Mutation(
        name="web fragmented layout text line overflow is accepted",
        path=_BASE + "DOMSnapshotAssembly.swift",
        old='throw malformed("text box line coordinate out of range")',
        # Preserve a throwing path so the map's try still compiles under strict Swift.
        new='if box.y == 0 { throw malformed("mutant control") }; return 0',
        test=_TEST
        + "DOMSnapshotAssemblyTests/testTextBoxLineCoordinatesOutsideIntegerRangeFailWithoutTrapping",
    ),
    Mutation(
        name="web fragmented layout text boxes use DOM indices as layout rows",
        path=_BASE + "DOMSnapshotAssembly.swift",
        old="textBoxes[layoutNodes[index], default: []].append",
        new="textBoxes[index, default: []].append",
        test=_TEST
        + "DOMSnapshotAssemblyTests/testLayoutFragmentsPreserveUnionTextAndLayoutRowTextBoxes",
    ),
    Mutation(
        name="web loopback fixture waits for reverse DNS before listening",
        path="Tests/VerdictUIWebTests/Fixtures/server.py",
        old="socketserver.TCPServer.server_bind(self)",
        new="super().server_bind()",
        test="Tests/test_web_fixture.py::test_loopback_fixture_starts_and_serves_without_reverse_dns",
        runner=Runner.PYTEST,
    ),
    Mutation(
        name="web fixture ignores its configured interpreter",
        path="Tests/VerdictUIWebTests/WebFrameIntegrationTests.swift",
        old='if let configured = environment["VERDICTUI_TEST_PYTHON"]',
        new='if let configured = environment["VERDICTUI_IGNORED_PYTHON"]',
        test=_TEST
        + "WebFrameIntegrationTests/testConfiguredFixtureInterpreterReportsExitAndBoundedOutput",
    ),
    Mutation(
        name="web fixture accepts an invalid configured interpreter",
        path="Tests/VerdictUIWebTests/WebFrameIntegrationTests.swift",
        old='guard configured.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: configured) else',
        new="guard true else",
        test=_TEST
        + "WebFrameIntegrationTests/testFixtureInterpreterUsesPATHAndRefusesInvalidConfiguration",
    ),
    Mutation(
        name="web fixture selects a missing PATH interpreter",
        path="Tests/VerdictUIWebTests/WebFrameIntegrationTests.swift",
        old="if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }",
        new="if true { return candidate }",
        test=_TEST
        + "WebFrameIntegrationTests/testFixtureInterpreterUsesPATHAndRefusesInvalidConfiguration",
    ),
    Mutation(
        name="web fixture emits unbounded startup diagnostics",
        path="Tests/VerdictUIWebTests/WebFrameIntegrationTests.swift",
        old="reader.read(upToCount: 4096)",
        new="reader.readToEnd()",
        test=_TEST
        + "WebFrameIntegrationTests/testConfiguredFixtureInterpreterReportsExitAndBoundedOutput",
    ),
    Mutation(
        name="web fixture stops the server after handing it to its caller",
        path="Tests/VerdictUIWebTests/WebFrameIntegrationTests.swift",
        old="return (fixtureProcess, port)",
        new="try await fixtureProcess.stop(); return (fixtureProcess, port)",
        test=_TEST
        + "WebFrameIntegrationTests/testSameAndCrossOriginFramesRenderAndActWithCorrectRootCoordinates",
    ),
    Mutation(
        name="owned process ignores its requested working directory",
        path=_BASE + "OwnedCommandProcess.swift",
        old="try checked(addWorkingDirectory(&actions, path: directory.path))",
        new="try checked(0)",
        test=_TEST
        + "OwnedCommandProcessTests/testSpawnUsesRequestedWorkingDirectoryWithoutChangingParent",
    ),
    Mutation(
        name="web page commands omit their flattened session identity",
        path=_BASE + "CDPTransport.swift",
        old="params: params, sessionId: sessionID)",
        new="params: params, sessionId: nil)",
        test=_TEST + "CDPTransportTests/testPageSessionEnvelopeAndNetworkSettlingIsolation",
    ),
    Mutation(
        name="web network activity is ignored while settling",
        path=_BASE + "CDPTransport.swift",
        old="inFlightNetwork[sessionID]?.count ?? 0",
        new="0",
        test=_TEST + "CDPTransportTests/testPageSessionEnvelopeAndNetworkSettlingIsolation",
    ),
    Mutation(
        name="web orphaned embedded document is silently ignored",
        path=_BASE + "DOMSnapshotAssembly.swift",
        old="guard visited.count == trees.count else",
        new="guard trees.count >= visited.count else",
        test=_TEST + "DOMSnapshotAssemblyTests/testOrphanedEmbeddedDocumentIsUnavailable",
    ),
    Mutation(
        name="web DOM snapshot mismatch becomes an empty observed tree",
        path=_BASE + "DOMSnapshotAssembly.swift",
        old='else { throw malformed("mismatched or oversized node columns") }',
        new="else { return [] }",
        test=_TEST + "DOMSnapshotAssemblyTests/testMalformedColumnsAndInvalidTopologyFailClosed",
    ),
    Mutation(
        name="web invalid topology becomes an empty observed tree",
        path=_BASE + "DOMSnapshotAssembly.swift",
        old='else { throw malformed("invalid parent topology") }',
        new="else { return [] }",
        test=_TEST + "DOMSnapshotAssemblyTests/testMalformedColumnsAndInvalidTopologyFailClosed",
    ),
    Mutation(
        name="web invalid backend identity becomes empty observed content",
        path=_BASE + "DOMSnapshotAssembly.swift",
        old='throw malformed("invalid parent topology or backend identity")',
        new="return []",
        test=_TEST + "DOMSnapshotAssemblyTests/testMalformedColumnsAndInvalidTopologyFailClosed",
    ),
    Mutation(
        name="web malformed attribute pairs are silently accepted",
        path=_BASE + "DOMSnapshotAssembly.swift",
        old='else { throw malformed("odd attribute column") }',
        new="else { return [] }",
        test=_TEST + "DOMSnapshotAssemblyTests/testMalformedColumnsAndInvalidTopologyFailClosed",
    ),
    Mutation(
        name="web malformed layout indices silently disappear",
        path=_BASE + "DOMSnapshotAssembly.swift",
        old='throw malformed("invalid layout index")',
        new="return []",
        test=_TEST + "DOMSnapshotAssemblyTests/testMalformedColumnsAndInvalidTopologyFailClosed",
    ),
    Mutation(
        name="web missing computed styles become unobserved content",
        path=_BASE + "DOMSnapshotAssembly.swift",
        old='else { throw malformed("missing computed styles") }',
        new="else { return [] }",
        test=_TEST + "DOMSnapshotAssemblyTests/testMalformedColumnsAndInvalidTopologyFailClosed",
    ),
    Mutation(
        name="web malformed text box index becomes unobserved content",
        path=_BASE + "DOMSnapshotAssembly.swift",
        old='else { throw malformed("invalid text box index") }',
        new="else { return [] }",
        test=_TEST + "DOMSnapshotAssemblyTests/testMalformedColumnsAndInvalidTopologyFailClosed",
    ),
    Mutation(
        name="web malformed string index becomes empty text",
        path=_BASE + "DOMSnapshotAssembly.swift",
        old='else { throw malformed("string index out of range") }',
        new='else { return "" }',
        test=_TEST + "DOMSnapshotAssemblyTests/testMalformedColumnsAndInvalidTopologyFailClosed",
    ),
    Mutation(
        name="web negative geometry is normalized instead of refused",
        path=_BASE + "DOMSnapshotAssembly.swift",
        old='else { throw malformed("negative rectangle extent") }',
        new="else { return Rect(x: 0, y: 0, width: 0, height: 0) }",
        test=_TEST + "DOMSnapshotAssemblyTests/testMalformedColumnsAndInvalidTopologyFailClosed",
    ),
    Mutation(
        name="web generic scaffolding counts as probe evidence",
        path=_BASE + "DOMSnapshotAssembly.swift",
        old='id: role == .container ? "" : (frameID == "main"',
        new='id: (frameID == "main"',
        test=_TEST
        + "DOMSnapshotAssemblyTests/testHiddenAncestorHidesTextAndEmptyContainersDoNotCountAsEvidence",
    ),
    Mutation(
        name="web hidden ancestors expose child content",
        path=_BASE + "DOMSnapshotAssembly.swift",
        old="if !visible { descendants = descendants.map(hidden) }",
        new="if visible { descendants = descendants.map(hidden) }",
        test=_TEST + "DOMSnapshotAssemblyTests/testSnapshotRolesGeometryTextAndMetrics",
    ),
    Mutation(
        name="web redaction leaves reflected credential literals",
        path=_BASE + "WebRedaction.swift",
        old='result = result.replacingOccurrences(of: secret, with: "[REDACTED]")',
        new="result = result.replacingOccurrences(of: secret, with: secret)",
        test=_TEST + "DOMSnapshotAssemblyTests/testRedactionRemovesReflectionsAndSensitiveURLs",
    ),
    Mutation(
        name="web redaction includes authentication query strings",
        path=_BASE + "WebRedaction.swift",
        old="parts.query = nil",
        new="parts.query = url.query",
        test=_TEST + "DOMSnapshotAssemblyTests/testRedactionRemovesReflectionsAndSensitiveURLs",
    ),
    Mutation(
        name="web credential references bypass resolution",
        path=_BASE + "WebCredentials.swift",
        old="return configured\n    }",
        new="return reference\n    }",
        test=_TEST + "WebCredentialsTests/testReferenceResolutionDoesNotTreatReferenceAsSecret",
    ),
    Mutation(
        name="web declared onepassword reference silently uses fallback",
        path=_BASE + "WebCredentials.swift",
        old='return try await runOnePassword(["read", opReference, "--no-newline"], executable: onePassword)',
        new='do { return try await runOnePassword(["read", opReference, "--no-newline"], executable: onePassword) } catch { return sharedValue(key) ?? "unresolved" }',
        test=_TEST + "WebCredentialsTests/testSharedFileFallbackAndOnePasswordReferencePrecedence",
    ),
    Mutation(
        name="web same-pid lock contention ignores the kernel lock",
        path=_BASE + "ProfileLock.swift",
        old="guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else",
        new="guard descriptor >= 0 else",
        test=_TEST
        + "ProfileLockTests/testKernelLockRejectsEvenAnEmptyPidfileAndReleaseIsIdempotent",
    ),
    Mutation(
        name="web profile live-owner liveness gate is bypassed",
        path=_BASE + "ProfileLock.swift",
        old="if let holder = readHolder(at: path), liveness(holder)",
        new="if let holder = readHolder(at: path), !liveness(holder)",
        test=_TEST + "ProfileLockTests/testALiveHoldersLockIsNeverStolen",
    ),
    Mutation(
        name="web password fields allow literal credentials",
        path=_BASE + "WebSession.swift",
        old='guard node.attributes["web.password"] != .bool(true) else',
        new='guard node.attributes["web.password"] != .bool(false) else',
        test=_TEST
        + "WebSessionIntegrationTests/testLoginTaskBadPasswordSecretRedactionAndProfilePersistence",
    ),
    Mutation(
        name="web unmet action expectation is accepted",
        path=_BASE + "WebSession.swift",
        old='rule: "web-expectation", severity: .error',
        new='rule: "web-expectation", severity: .warning',
        test=_TEST
        + "WebSessionIntegrationTests/testLoginTaskBadPasswordSecretRedactionAndProfilePersistence",
    ),
    Mutation(
        name="web typing appends instead of replacing selected field text",
        path=_BASE + "WebSession.swift",
        old='parameters["commands"] = .array([.string("selectAll")])',
        new='parameters["commands"] = .array([])',
        test=_TEST
        + "WebSessionIntegrationTests/testLoginTaskBadPasswordSecretRedactionAndProfilePersistence",
    ),
    Mutation(
        name="web named onepassword item loses to environment fallback",
        path=_BASE + "WebCredentials.swift",
        old='return try await runOnePassword(["item", "get", reference, "--fields", "label=password", "--reveal"], executable: onePassword)',
        new='let resolved = try await runOnePassword(["item", "get", reference, "--fields", "label=password", "--reveal"], executable: onePassword); return configured ?? resolved',
        test=_TEST + "WebCredentialsTests/testOnePasswordNamedItemWinsBeforeSharedFallback",
    ),
    Mutation(
        name="web custom roles expose reflected credentials",
        path=_BASE + "DOMSnapshotAssembly.swift",
        old="role = .custom(WebRedaction.clean(raw, secrets: secrets))",
        new="role = .custom(raw)",
        test=_TEST + "DOMSnapshotAssemblyTests/testCredentialReflectedIntoCustomRoleIsRedacted",
    ),
    Mutation(
        name="web dead owned process signals a recycled live pid on terminate",
        path=_BASE + "HeadlessBrowser.swift",
        old="guard process.isRunning else { return }",
        new="guard pid > 0 else { return }",
        test=_TEST
        + "BrowserProcessIdentityTests/testReusedLivePIDDoesNotAuthorizeTerminatingADeadChild",
    ),
    Mutation(
        name="web dead owned process signals a recycled live pid on deinit",
        path=_BASE + "HeadlessBrowser.swift",
        old="if process.isRunning { process.signal(SIGKILL) }",
        new="if pid > 0 { process.signal(SIGKILL) }",
        test=_TEST
        + "BrowserProcessIdentityTests/testReusedLivePIDDoesNotAuthorizeTerminatingADeadChild",
    ),
    Mutation(
        name="web compact tree drops control accessible names",
        path=_BASE + "DOMSnapshotAssembly.swift",
        old="} ?? accessibleName,",
        new="},",
        test=_TEST
        + "DOMSnapshotAssemblyTests/testControlNameSurvivesCompactTextAndNeverUsesValueChildren",
    ),
    Mutation(
        name="web field descendants expose existing values",
        path=_BASE + "DOMSnapshotAssembly.swift",
        old="if prunesControlDescendants[index] { descendants = [] }",
        new="if !prunesControlDescendants[index] { descendants = [] }",
        test=_TEST
        + "DOMSnapshotAssemblyTests/testControlNameSurvivesCompactTextAndNeverUsesValueChildren",
    ),
    Mutation(
        name="web aria labelledby loses naming priority",
        path=_BASE + "DOMAccessibleNames.swift",
        old='if let references = attrs["aria-labelledby"]',
        new='if let references = attrs["not-aria-labelledby"]',
        test=_TEST
        + "DOMSnapshotAssemblyTests/testAssociatedLabelsAndAriaNamesHaveDeterministicPriority",
    ),
    Mutation(
        name="web explicit labels lose control association",
        path=_BASE + "DOMAccessibleNames.swift",
        old='if let target = attributes[index]["for"]',
        new='if let target = attributes[index]["not-for"]',
        test=_TEST
        + "DOMSnapshotAssemblyTests/testAssociatedLabelsAndAriaNamesHaveDeterministicPriority",
    ),
    Mutation(
        name="web wrapping labels lose control association",
        path=_BASE + "DOMAccessibleNames.swift",
        old='if tags[ancestor] == "label",',
        new='if tags[ancestor] == "not-label",',
        test=_TEST
        + "DOMSnapshotAssemblyTests/testAssociatedLabelsAndAriaNamesHaveDeterministicPriority",
    ),
    Mutation(
        name="web field values become parent label content",
        path=_BASE + "DOMAccessibleNames.swift",
        old='contents[index] = ""',
        new='contents[index] += ""',
        test=_TEST + "DOMSnapshotAssemblyTests/testAccessibleLabelsExcludeEditableValues",
    ),
    Mutation(
        name="web availability trusts a recycled live pid",
        path=_BASE + "HeadlessBrowser.swift",
        old="func isRunning() -> Bool { process.isRunning }",
        new="func isRunning() -> Bool { ProcessLiveness.isAlive(pid) }",
        test=_TEST
        + "BrowserProcessIdentityTests/testReusedLivePIDDoesNotAuthorizeTerminatingADeadChild",
    ),
    Mutation(
        name="web dead session retains transport and profile ownership",
        path=_BASE + "WebSession.swift",
        old="guard await browser.isRunning() else",
        new="guard browser.pid > 0 else",
        test=_TEST + "WebSessionIntegrationTests/testBrowserDownIsUnavailableAndReleasesProfile",
    ),
    Mutation(
        name="web session list advertises a dead browser",
        path=_BASE + "WebSessionManager.swift",
        old="if await session.isAvailable() { result.append",
        new="if !key.isEmpty { result.append",
        test=_TEST + "WebSessionIntegrationTests/testBrowserDownIsUnavailableAndReleasesProfile",
    ),
    Mutation(
        name="web reopen navigates a dead session",
        path=_BASE + "WebSessionManager.swift",
        old="if await session.isAvailable() {\n                try await session.navigate",
        new="if !profile.isEmpty {\n                try await session.navigate",
        test=_TEST + "WebSessionIntegrationTests/testBrowserDownIsUnavailableAndReleasesProfile",
    ),
    Mutation(
        name="web session lookup bypasses dead child eviction",
        path=_BASE + "WebSessionManager.swift",
        old="guard await session.isAvailable() else",
        new="guard !profile.isEmpty else",
        test=_TEST + "WebSessionIntegrationTests/testBrowserDownIsUnavailableAndReleasesProfile",
    ),
    Mutation(
        name="owned process event wait returns before an exit event",
        path=_BASE + "OwnedCommandProcess.swift",
        old="_ = completion.wait(timeout: .now() + timeout)",
        new="_ = timeout",
        test=_TEST + "OwnedCommandProcessTests/testExitEventTimesOutThenObservesExitWithoutReaping",
    ),
    Mutation(
        name="web resolver shutdown forgets its active owned groups",
        path=_BASE + "WebCredentials.swift",
        old="let pending = operations",
        new="let pending: [UUID: Operation] = [:]",
        test=_TEST
        + "WebCredentialLifecycleTests/testCloseAndCancellationAwaitOwnedResolverGroupAndRefuseFallback",
    ),
    Mutation(
        name="web resolver task cancellation is not forwarded",
        path=_BASE + "WebCredentials.swift",
        old="} onCancel: { worker.cancel() }",
        new="} onCancel: {}",
        test=_TEST
        + "WebCredentialLifecycleTests/testCloseAndCancellationAwaitOwnedResolverGroupAndRefuseFallback",
    ),
    Mutation(
        name="web closed resolver returns an environment fallback",
        path=_BASE + "WebCredentials.swift",
        old="public func resolve(_ reference: String) async throws -> String {\n        guard !closed, !Task.isCancelled else",
        new="public func resolve(_ reference: String) async throws -> String {\n        guard !Task.isCancelled else",
        test=_TEST
        + "WebCredentialLifecycleTests/testClosedResolverRefusesFallbackAndOversizedOutputIsRejected",
    ),
    Mutation(
        name="web resolver closing in flight falls back to another credential",
        path=_BASE + "WebCredentials.swift",
        old="if closed || Task.isCancelled { throw WebBrowserError.credentialUnavailable }",
        new="if Task.isCancelled { throw WebBrowserError.credentialUnavailable }",
        test=_TEST
        + "WebCredentialLifecycleTests/testCloseAndCancellationAwaitOwnedResolverGroupAndRefuseFallback",
    ),
    Mutation(
        name="web credential output exceeds the bounded field size",
        path=_BASE + "WebCredentials.swift",
        old="guard output.count + chunk.count <= 65_536 else",
        new="guard output.count + chunk.count <= 131_072 else",
        test=_TEST
        + "WebCredentialLifecycleTests/testClosedResolverRefusesFallbackAndOversizedOutputIsRejected",
    ),
    Mutation(
        name="web session shutdown leaves an active credential group behind",
        path=_BASE + "WebSession.swift",
        old="try await credentials.close()",
        new="_ = credentials",
        test=_TEST
        + "WebCredentialLifecycleTests/testMCPSIGTERMAwaitsInFlightCredentialGroupBeforeExit",
    ),
    Mutation(
        name="web concurrent close returns before existing shutdown completes",
        path=_BASE + "WebSession.swift",
        old="if let closingTask { return try await closingTask.value }",
        new="if closingTask != nil { return }",
        test=_TEST
        + "WebCredentialLifecycleTests/testSessionCloseAwaitsCredentialLookupAndReleasesProfile",
    ),
    Mutation(
        name="web shutdown omits opening browser ownership",
        path=_BASE + "WebSessionManager.swift",
        old="let pending = launches",
        new="let pending: [String: Task<WebSession, Error>] = [:]",
        test=_TEST
        + "WebOpeningLifecycleTests/testOpeningCancellationAndCloseAllAwaitTheUnpublishedBrowser",
    ),
    Mutation(
        name="web caller cancellation does not cancel its opening browser",
        path=_BASE + "WebSessionManager.swift",
        old="} onCancel: { launch.cancel() }",
        new="} onCancel: {}",
        test=_TEST
        + "WebOpeningLifecycleTests/testOpeningCancellationAndCloseAllAwaitTheUnpublishedBrowser",
    ),
    Mutation(
        name="web failed discovery leaves its exact launched child alive",
        path=_BASE + "HeadlessBrowser.swift",
        old="owned.signal(SIGKILL)",
        new="_ = owned",
        test=_TEST
        + "WebOpeningLifecycleTests/testMCPSIGTERMAwaitsBrowserStillDiscoveringItsEndpoint",
    ),
    Mutation(
        name="web paint SVG composition remains independent layout shapes",
        path=_BASE + "WebPaintSemantics.swift",
        old='if tag == "svg", children.allSatisfy({ $0.1 }) {',
        new='if tag == "svg", children.isEmpty {',
        test=_TEST
        + "WebPaintSemanticsTests/testPassiveSVGCompositionIsAtomicButOwnerStillCollides",
    ),
    Mutation(
        name="web paint SVG composition ignores measured interaction",
        path=_BASE + "WebPaintSemantics.swift",
        old="let passiveGraphic = inert && unnamed",
        new="let passiveGraphic = unnamed",
        test=_TEST
        + "WebPaintSemanticsTests/testSVGTextLinksForeignContentLabelsAndInteractionPreventAtomicity",
    ),
    Mutation(
        name="web paint SVG composition erases labelled graphics",
        path=_BASE + "WebPaintSemantics.swift",
        old="let passiveGraphic = inert && unnamed",
        new="let passiveGraphic = inert",
        test=_TEST
        + "WebPaintSemanticsTests/testSVGTextLinksForeignContentLabelsAndInteractionPreventAtomicity",
    ),
    Mutation(
        name="web paint SVG composition erases semantic controls",
        path=_BASE + "WebPaintSemantics.swift",
        old="source.role == .container && graphicTags.contains(tag)",
        new="graphicTags.contains(tag)",
        test=_TEST
        + "WebPaintSemanticsTests/testSVGTextLinksForeignContentLabelsAndInteractionPreventAtomicity",
    ),
    Mutation(
        name="web paint SVG composition ignores meaningful descendants",
        path=_BASE + "WebPaintSemantics.swift",
        old="&& children.allSatisfy { $0.1 }",
        new="&& children.allSatisfy { _ in true }",
        test=_TEST
        + "WebPaintSemanticsTests/testSVGTextLinksForeignContentLabelsAndInteractionPreventAtomicity",
    ),
    Mutation(
        name="web paint SVG composition accepts foreign content",
        path=_BASE + "WebPaintSemantics.swift",
        old='"polyline", "polygon", "g",',
        new='"polyline", "polygon", "g", "foreignobject",',
        test=_TEST
        + "WebPaintSemanticsTests/testSVGTextLinksForeignContentLabelsAndInteractionPreventAtomicity",
    ),
    Mutation(
        name="web paint SVG composition assumes use references are passive",
        path=_BASE + "WebPaintSemantics.swift",
        old='"polyline", "polygon", "g",',
        new='"polyline", "polygon", "g", "use",',
        test=_TEST
        + "WebPaintSemanticsTests/testSVGTextLinksForeignContentLabelsAndInteractionPreventAtomicity",
    ),
    Mutation(
        name="web paint presentation ignores measured interaction",
        path=_BASE + "WebPaintSemantics.swift",
        old="let presentation = inert && unnamed",
        new="let presentation = unnamed",
        test=_TEST
        + "WebPaintSemanticsTests/testMeaningfulOrUnmeasuredContentNeverBecomesPresentation",
    ),
    Mutation(
        name="web paint presentation erases text and labels",
        path=_BASE + "WebPaintSemantics.swift",
        old="let presentation = inert && unnamed",
        new="let presentation = inert",
        test=_TEST
        + "WebPaintSemanticsTests/testMeaningfulOrUnmeasuredContentNeverBecomesPresentation",
    ),
    Mutation(
        name="web paint presentation erases semantic roles",
        path=_BASE + "WebPaintSemantics.swift",
        old="source.role == .container && presentationTags.contains(tag)",
        new="presentationTags.contains(tag)",
        test=_TEST
        + "WebPaintSemanticsTests/testMeaningfulOrUnmeasuredContentNeverBecomesPresentation",
    ),
    Mutation(
        name="web paint presentation accepts arbitrary paint sources",
        path=_BASE + "WebPaintSemantics.swift",
        old='["div", "span", "::before", "::after"]',
        new='["div", "span", "::before", "::after", "canvas"]',
        test=_TEST
        + "WebPaintSemanticsTests/testMeaningfulOrUnmeasuredContentNeverBecomesPresentation",
    ),
    Mutation(
        name="web paint presentation ignores retained interaction ancestors",
        path=_BASE + "WebPaintSemantics.swift",
        old="&& !inheritedInteraction && children.allSatisfy { $0.2 }",
        new="&& children.allSatisfy { $0.2 }",
        test=_TEST
        + "WebPaintSemanticsTests/testSVGInsideControlKeepsOwnerWhileGenericInteractiveDescendantsRemainMeaningful",
    ),
    Mutation(
        name="web paint presentation ignores omitted interaction ancestors",
        path=_BASE + "WebPaintSemantics.swift",
        old='interactiveAncestor || attributes["web.hasInteractiveAncestor"] == .bool(true)',
        new="interactiveAncestor",
        test=_TEST
        + "WebPaintSemanticsTests/testSVGInsideControlKeepsOwnerWhileGenericInteractiveDescendantsRemainMeaningful",
    ),
    Mutation(
        name="web paint presentation ignores meaningful descendants",
        path=_BASE + "WebPaintSemantics.swift",
        old="&& !inheritedInteraction && children.allSatisfy { $0.2 }",
        new="&& !inheritedInteraction",
        test=_TEST
        + "WebPaintSemanticsTests/testMeaningfulOrUnmeasuredContentNeverBecomesPresentation",
    ),
    Mutation(
        name="web paint presentation classification trusts incoming marker",
        path=_BASE + "WebPaintSemantics.swift",
        old="node.attributes.removeValue(forKey: presentationKey)",
        new="_ = presentationKey",
        test=_TEST
        + "WebPaintSemanticsTests/testClassificationCannotBeForgedAndWarningsHonorSuppression",
    ),
    Mutation(
        name="web paint presentation intersection is asserted as functional defect",
        path=_BASE + "WebPaintSemantics.swift",
        old="if isPresentation(node) || other.map(isPresentation) == true {",
        new="if false && (isPresentation(node) || other.map(isPresentation) == true) {",
        test=_TEST
        + "WebPaintSemanticsTests/testPresentationClippingAndOpaquePointerInertOverlayStayUnverified",
    ),
    Mutation(
        name="web paint presentation first subject is treated as content",
        path=_BASE + "WebPaintSemantics.swift",
        old="if isPresentation(node) || other.map(isPresentation) == true {",
        new="if isPresentation(node) {",
        test=_TEST
        + "WebPaintSemanticsTests/testPresentationClippingAndOpaquePointerInertOverlayStayUnverified",
    ),
    Mutation(
        name="web paint presentation warning ignores original suppression",
        path=_BASE + "WebPaintSemantics.swift",
        old="guard !context.isSuppressed(rule: rule, on: node) else { return nil }",
        new="_ = rule",
        test=_TEST
        + "WebPaintSemanticsTests/testClassificationCannotBeForgedAndWarningsHonorSuppression",
    ),
    Mutation(
        name="web paint SVG single-axis clipping loses uncertainty evidence",
        path=_BASE + "WebPaintSemantics.swift",
        old="if clipX || clipY {",
        new="if clipX && clipY {",
        test=_TEST
        + "WebPaintSemanticsTests/testSVGInternalClipRemainsUnverifiedAndOwnerClipStillErrors",
    ),
    Mutation(
        name="web paint SVG clipping ignores original suppression",
        path=_BASE + "WebPaintSemantics.swift",
        old="!context.isSuppressed(rule: ClippedContentRule.id, on: child),",
        new="child.isVisible,",
        test=_TEST
        + "WebPaintSemanticsTests/testSVGInternalClipRemainsUnverifiedAndOwnerClipStillErrors",
    ),
    Mutation(
        name="web paint CSS single-axis clipping is ignored",
        path=_BASE + "WebLint.swift",
        old="let ownCSS = clipsX || clipsY ? Boundary(Clip(source.frame, x: clipsX, y: clipsY), owner: source) : nil",
        new="let ownCSS = clipsX && clipsY ? Boundary(Clip(source.frame, x: clipsX, y: clipsY), owner: source) : nil",
        test=_TEST
        + "WebPaintSemanticsTests/testCSSPaintClipsOnlySpecifiedAxisAndKeepsRealClippedContentError",
    ),
    Mutation(
        name="web paint CSS clip hides the unclipped axis",
        path=_BASE + "WebLint.swift",
        old="Clip(source.frame, x: clipsX, y: clipsY)",
        new="Clip(source.frame)",
        test=_TEST
        + "WebPaintSemanticsTests/testCSSPaintClipsOnlySpecifiedAxisAndKeepsRealClippedContentError",
    ),
    Mutation(
        name="web paint CSS clip traps viewport fixed content",
        path=_BASE + "WebLint.swift",
        old="let activeCSS = fixed ? [] : cssClips.filter { !$0.escaped(by: source) }",
        new="let activeCSS = cssClips.filter { !$0.escaped(by: source) }",
        test=_TEST
        + "WebPaintSemanticsTests/testFixedPaintEscapesOrdinaryCSSClipButNotTransformedClip",
    ),
    Mutation(
        name="web paint iframe fixed content escapes outer CSS clip",
        path=_BASE + "WebLint.swift",
        old="Clip.combined(ownDocument, documentClip, Boundary.combined(childScroll), Boundary.combined(childCSS))",
        new="Clip.combined(ownDocument, documentClip, Boundary.combined(childScroll))",
        test=_TEST + "WebPaintSemanticsTests/testFixedChildCannotEscapeOuterCSSClipThroughIframe",
    ),
    Mutation(
        name="web paint overlap uses independent SVG internals again",
        path=_BASE + "WebLint.swift",
        old="= [(semantic.tree, [], false)]",
        new="= [(tree, [], false)]",
        test=_TEST
        + "WebPaintSemanticsTests/testPassiveSVGCompositionIsAtomicButOwnerStillCollides",
    ),
    Mutation(
        name="web paint followup reachable scroll scope discards hidden axes",
        path=_BASE + "WebLint.swift",
        old="childClips.map { $0.removing(x: scrollX, y: scrollY) }",
        new="childClips.map { $0.removing(x: scrollX || clipsX, y: scrollY || clipsY) }",
        test=_TEST
        + "WebPaintSemanticsTests/testReachableScrollScopeRetainsHiddenAxisWithoutLosingScrollableAxis",
    ),
    Mutation(
        name="web paint followup reachable scroll scope retains its scrolling-axis clips",
        path=_BASE + "WebLint.swift",
        old="childClips.map { $0.removing(x: scrollX, y: scrollY) }",
        new="childClips.map { $0.removing(x: !scrollX, y: !scrollY) }",
        test=_TEST
        + "WebPaintSemanticsTests/testReachableScrollScopeRetainsAncestorClipOnItsNonScrollingAxis",
    ),
    Mutation(
        name="web paint followup reachable scroll scope discards ancestor clipping",
        path=_BASE + "WebLint.swift",
        old="let activeClips = fixed ? [] : inheritedClips.filter { !$0.escaped(by: node) }",
        new="let activeClips = fixed ? [] : inheritedClips.filter { _ in false }",
        test=_TEST
        + "WebPaintSemanticsTests/testReachableScrollScopeRetainsAncestorClipOnItsNonScrollingAxis",
    ),
    Mutation(
        name="web paint followup viewport fixed scroll scope keeps ancestor clipping",
        path=_BASE + "WebLint.swift",
        old="let activeClips = fixed ? [] : inheritedClips.filter { !$0.escaped(by: node) }",
        new="let activeClips = fixed ? inheritedClips : inheritedClips.filter { !$0.escaped(by: node) }",
        test=_TEST + "WebPaintSemanticsTests/testViewportFixedScrollScopeEscapesAncestorCSSClip",
    ),
    Mutation(
        name="web paint followup reachable scroll root loses fixed-container state",
        path=_BASE + "WebLint.swift",
        old="retainedClips, changesDocument ? false : childContained)",
        new="retainedClips, false)",
        test=_TEST + "WebPaintSemanticsTests/testReachableScrollScopeRetainsFixedContainerAncestry",
    ),
    Mutation(
        name="web paint followup reachable scroll traversal loses fixed-container ancestry",
        path=_BASE + "WebLint.swift",
        old="contained: changed ? false : childContained)",
        new="contained: changed ? false : contained)",
        test=_TEST + "WebPaintSemanticsTests/testReachableScrollScopeRetainsFixedContainerAncestry",
    ),
    Mutation(
        name="web paint followup independent document inherits outer CSS clipping",
        path=_BASE + "WebLint.swift",
        old="let retainedClips = changesDocument ? [] : childClips.map",
        new="let retainedClips = childClips.map",
        test=_TEST
        + "WebPaintSemanticsTests/testIndependentDocumentScopeKeepsItsReachableInternalCollisions",
    ),
    Mutation(
        name="web paint followup nested document scroll scope inherits outer CSS clipping",
        path=_BASE + "WebLint.swift",
        old="inheritedClips: changed ? [] : childClips",
        new="inheritedClips: childClips",
        test=_TEST
        + "WebPaintSemanticsTests/testIndependentDocumentScopeKeepsItsReachableInternalCollisions",
    ),
    Mutation(
        name="web paint followup scrolling X clears the wrong axis",
        path=_BASE + "WebPaintSemantics.swift",
        old="if x { result.minX = nil; result.maxX = nil }",
        new="if !x { result.minX = nil; result.maxX = nil }",
        test=_TEST
        + "WebPaintSemanticsTests/testReachableScrollScopeRetainsHiddenAxisWithoutLosingScrollableAxis",
    ),
    Mutation(
        name="web paint followup scrolling Y clears the wrong axis",
        path=_BASE + "WebPaintSemantics.swift",
        old="if y { result.minY = nil; result.maxY = nil }",
        new="if !y { result.minY = nil; result.maxY = nil }",
        test=_TEST
        + "WebPaintSemanticsTests/testReachableScrollScopeRetainsHiddenAxisWithoutLosingScrollableAxis",
    ),
    Mutation(
        name="web paint followup font warning accepts controls or replaced content",
        path=_BASE + "WebPaintSemantics.swift",
        old='node.role == .text || (node.role == .container && node.attributes["web.inlineCandidate"] == .bool(true))',
        new="node.role != .spacer",
        test=_TEST
        + "WebPaintSemanticsTests/testFontWarningRequiresBothMeasurementsSameContextAndTextOnlyRoles",
    ),
    Mutation(
        name="web paint followup font warning accepts an unmeasured first subject",
        path=_BASE + "WebPaintSemantics.swift",
        old='first.attributes["web.fontBoxOnly"] == .bool(true), second.attributes["web.fontBoxOnly"] == .bool(true)',
        new='second.attributes["web.fontBoxOnly"] == .bool(true)',
        test=_TEST
        + "WebPaintSemanticsTests/testFontWarningRequiresBothMeasurementsSameContextAndTextOnlyRoles",
    ),
    Mutation(
        name="web paint followup font warning accepts an unmeasured second subject",
        path=_BASE + "WebPaintSemantics.swift",
        old='first.attributes["web.fontBoxOnly"] == .bool(true), second.attributes["web.fontBoxOnly"] == .bool(true)',
        new='first.attributes["web.fontBoxOnly"] == .bool(true)',
        test=_TEST
        + "WebPaintSemanticsTests/testFontWarningRequiresBothMeasurementsSameContextAndTextOnlyRoles",
    ),
    Mutation(
        name="web paint followup font warning accepts an empty flow context",
        path=_BASE + "WebPaintSemantics.swift",
        old='let context = first.attributes["web.inlineFormattingContext"]?.stringValue, !context.isEmpty,',
        new='let context = first.attributes["web.inlineFormattingContext"]?.stringValue,',
        test=_TEST
        + "WebPaintSemanticsTests/testFontWarningRequiresBothMeasurementsSameContextAndTextOnlyRoles",
    ),
    Mutation(
        name="web paint followup font warning combines separate flow contexts",
        path=_BASE + "WebPaintSemantics.swift",
        old='second.attributes["web.inlineFormattingContext"] == .string(context)',
        new='second.attributes["web.inlineFormattingContext"] != nil',
        test=_TEST
        + "WebPaintSemanticsTests/testFontWarningRequiresBothMeasurementsSameContextAndTextOnlyRoles",
    ),
    Mutation(
        name="web paint followup font warning accepts an empty frame identity",
        path=_BASE + "WebPaintSemantics.swift",
        old='let frame = first.attributes["web.frame"]?.stringValue, !frame.isEmpty,',
        new='let frame = first.attributes["web.frame"]?.stringValue,',
        test=_TEST
        + "WebPaintSemanticsTests/testFontWarningRequiresBothMeasurementsSameContextAndTextOnlyRoles",
    ),
    Mutation(
        name="web paint followup font warning combines separate frames",
        path=_BASE + "WebPaintSemantics.swift",
        old='second.attributes["web.frame"] == .string(frame)',
        new='second.attributes["web.frame"] != nil',
        test=_TEST
        + "WebPaintSemanticsTests/testFontWarningRequiresBothMeasurementsSameContextAndTextOnlyRoles",
    ),
    Mutation(
        name="web paint followup font warning demotes same-line intersections",
        path=_BASE + "WebPaintSemantics.swift",
        old="abs(firstBox.y - secondBox.y) > SiblingOverlapRule.tolerance",
        new="abs(firstBox.y - secondBox.y) >= 0",
        test=_TEST
        + "WebPaintSemanticsTests/testSameLineFontCollisionUsesFragmentsInsteadOfDifferentUnionOrigins",
    ),
    Mutation(
        name="web paint followup font warning uses union origins instead of fragment origins",
        path=_BASE + "WebLint.swift",
        old="firstBox: box, secondBox: rectangles[other]",
        new="firstBox: first.frame, secondBox: second.frame",
        test=_TEST
        + "WebPaintSemanticsTests/testNormalFlowFontIntersectionUsesActualFragmentsAndStaysUnverified",
    ),
    Mutation(
        name="web paint followup uncertain font match short circuits later defects",
        path=_BASE + "WebLint.swift",
        old="if uncertain == nil, let fontMatch { uncertain = fontMatch.1 }",
        new="if uncertain == nil, let fontMatch { uncertain = fontMatch.1; return (fontMatch.1, true) }",
        test=_TEST
        + "WebPaintSemanticsTests/testLaterSameLineFragmentCollisionOverridesEarlierUncertainFontOverlap",
    ),
    Mutation(
        name="web paint followup later confirmed collision is demoted by prior font uncertainty",
        path=_BASE + "WebLint.swift",
        old="if let match { return (match.1, false) }",
        new="if let match { return (match.1, uncertain != nil) }",
        test=_TEST
        + "WebPaintSemanticsTests/testLaterSameLineFragmentCollisionOverridesEarlierUncertainFontOverlap",
    ),
    Mutation(
        name="web paint followup font-only sweep result loses uncertainty",
        path=_BASE + "WebLint.swift",
        old="return uncertain.map { ($0, true) }",
        new="return uncertain.map { ($0, false) }",
        test=_TEST
        + "WebPaintSemanticsTests/testNormalFlowFontIntersectionUsesActualFragmentsAndStaysUnverified",
    ),
    Mutation(
        name="web paint followup font warning is emitted as a confirmed defect",
        path=_BASE + "WebPaintSemantics.swift",
        old="if fontPaintUnverified {",
        new="if fontPaintUnverified && node.role == .spacer {",
        test=_TEST
        + "WebPaintSemanticsTests/testNormalFlowFontIntersectionUsesActualFragmentsAndStaysUnverified",
    ),
    Mutation(
        name="web paint followup sibling evidence drops font uncertainty",
        path=_BASE + "WebLint.swift",
        old="other: children[first], fontPaintUnverified: collision.fontPaintUnverified",
        new="other: children[first], fontPaintUnverified: false",
        test=_TEST
        + "WebPaintSemanticsTests/testNormalFlowFontIntersectionUsesActualFragmentsAndStaysUnverified",
    ),
    Mutation(
        name="web paint followup cross-parent evidence drops font uncertainty",
        path=_BASE + "WebLint.swift",
        old="other: leaves[first].node, fontPaintUnverified: collision.fontPaintUnverified",
        new="other: leaves[first].node, fontPaintUnverified: false",
        test=_TEST
        + "WebPaintSemanticsTests/testQualifiedFontUncertaintySurvivesCrossParentComparison",
    ),
    Mutation(
        name="web paint positioning raw depth bound is ignored",
        path=_BASE + "WebPaintSemantics.swift",
        old="(0...256).contains(depth), (0...depth).contains(root)",
        new="(0...512).contains(depth), (0...depth).contains(root)",
        test=_TEST
        + "WebPaintSemanticsTests/testPositioningProofRequiresFiniteOrderedSameFrameDepths",
    ),
    Mutation(
        name="web paint positioning positioned root may exceed target depth",
        path=_BASE + "WebPaintSemantics.swift",
        old="(0...depth).contains(root)",
        new="(0...256).contains(root)",
        test=_TEST
        + "WebPaintSemanticsTests/testPositioningProofRequiresFiniteOrderedSameFrameDepths",
    ),
    Mutation(
        name="web paint positioning unknown negative containing block is accepted",
        path=_BASE + "WebPaintSemantics.swift",
        old="(-1..<root).contains(block)",
        new="(-2..<root).contains(block)",
        test=_TEST
        + "WebPaintSemanticsTests/testPositioningProofRequiresFiniteOrderedSameFrameDepths",
    ),
    Mutation(
        name="web paint positioning containing block may equal positioned root",
        path=_BASE + "WebPaintSemantics.swift",
        old="(-1..<root).contains(block)",
        new="(-1...root).contains(block)",
        test=_TEST
        + "WebPaintSemanticsTests/testPositioningProofRequiresFiniteOrderedSameFrameDepths",
    ),
    Mutation(
        name="web paint positioning containing block own clip is discarded",
        path=_BASE + "WebPaintSemantics.swift",
        old="range.block < depth && depth < range.root",
        new="range.block <= depth && depth < range.root",
        test=_TEST
        + "WebPaintSemanticsTests/testPositionedEscapeKeepsVisibleControlAndInheritedTextCollision",
    ),
    Mutation(
        name="web paint positioning positioned root own clip is discarded",
        path=_BASE + "WebPaintSemantics.swift",
        old="range.block < depth && depth < range.root",
        new="range.block < depth && depth <= range.root",
        test=_TEST
        + "WebPaintSemanticsTests/testPositionedRootOwnClipAndNestedClipsRemainEffective",
    ),
    Mutation(
        name="web paint positioning frame identity cannot bound clip escape",
        path=_BASE + "WebPaintSemantics.swift",
        old='node.attributes["web.frame"] == .string(frame) else { return false }',
        new='node.attributes["web.frame"] != nil else { return false }',
        test=_TEST
        + "WebPaintSemanticsTests/testPositioningProofRequiresFiniteOrderedSameFrameDepths",
    ),
    Mutation(
        name="web paint positioning CSS boundary ignores containing block",
        path=_BASE + "WebLint.swift",
        old="cssClips.filter { !$0.escaped(by: source) }",
        new="cssClips.filter { _ in true }",
        test=_TEST
        + "WebPaintSemanticsTests/testPositionedEscapeKeepsMeasuredFragmentsBeyondStaticClip",
    ),
    Mutation(
        name="web paint positioning scroll boundary ignores containing block",
        path=_BASE + "WebLint.swift",
        old="scrollClips.filter { !$0.escaped(by: source) }",
        new="scrollClips.filter { _ in true }",
        test=_TEST
        + "WebPaintSemanticsTests/testStaticScrollEscapeUsesEnclosingReachabilityAndSkipsExtraScrollComparisons",
    ),
    Mutation(
        name="web paint positioning clipping findings ignore containing block",
        path=_BASE + "WebLint.swift",
        old="!WebPaintSemantics.Boundary(WebPaintSemantics.Clip($0.node.frame), owner: $0.node).escaped(by: node)",
        new="WebPaintSemantics.Boundary(WebPaintSemantics.Clip($0.node.frame), owner: $0.node).depth != nil",
        test=_TEST
        + "WebPaintSemanticsTests/testPositionedEscapeKeepsVisibleControlAndInheritedTextCollision",
    ),
    Mutation(
        name="web paint positioning escaped scroller loses genuine outer clip",
        path=_BASE + "WebLint.swift",
        old="inherited = restored + inherited.filter { !paths.contains($0.node.structuralPath) }",
        new="inherited = inherited.filter { !paths.contains($0.node.structuralPath) }",
        test=_TEST + "WebPaintSemanticsTests/testStaticScrollerEscapeStillHonorsGenuineOuterClip",
    ),
    Mutation(
        name="web paint positioning escaped control stays in scroll reachability",
        path=_BASE + "WebLint.swift",
        old="enclosing.firstIndex(where: { $0.boundary.escaped(by: source) })",
        new="enclosing.firstIndex(where: { _ in false })",
        test=_TEST
        + "WebPaintSemanticsTests/testStaticScrollEscapeUsesEnclosingReachabilityAndSkipsExtraScrollComparisons",
    ),
    Mutation(
        name="web paint positioning escaped controls enter extra scroll comparisons",
        path=_BASE + "WebLint.swift",
        old="guard !owner.escaped(by: node) else { return nil }",
        new="guard node.isVisible else { return nil }",
        test=_TEST
        + "WebPaintSemanticsTests/testStaticScrollEscapeUsesEnclosingReachabilityAndSkipsExtraScrollComparisons",
    ),
    Mutation(
        name="web paint positioning interactive bounds are hidden by glyph children",
        path=_BASE + "WebLint.swift",
        old="node.children.isEmpty || node.role.isInteractive || node.role == .image",
        new="node.children.isEmpty || (node.role.isInteractive && false) || node.role == .image",
        test=_TEST
        + "WebPaintSemanticsTests/testControlAndImageBorderOverlapCannotHideBehindSeparatedGlyphs",
    ),
    Mutation(
        name="web paint positioning image bounds are hidden by descendants",
        path=_BASE + "WebLint.swift",
        old="node.children.isEmpty || node.role.isInteractive || node.role == .image",
        new="node.children.isEmpty || node.role.isInteractive || (node.role == .image && false)",
        test=_TEST
        + "WebPaintSemanticsTests/testControlAndImageBorderOverlapCannotHideBehindSeparatedGlyphs",
    ),
    Mutation(
        name="web paint positioning ordinary wrappers hide contained controls",
        path=_BASE + "WebLint.swift",
        old="node.children.isEmpty || node.role.isInteractive || node.role == .image",
        new="node.children.isEmpty || node.role.isInteractive || node.role == .image || node.role == .container",
        test=_TEST
        + "WebPaintSemanticsTests/testControlAndImageBorderOverlapCannotHideBehindSeparatedGlyphs",
    ),
    Mutation(
        name="web paint positioning empty frame identity proves clip escape",
        path=_BASE + "WebPaintSemantics.swift",
        old='let frame, !frame.isEmpty, node.attributes["web.frame"]',
        new='let frame, frame.isEmpty || !frame.isEmpty, node.attributes["web.frame"]',
        test=_TEST
        + "WebPaintSemanticsTests/testPositioningProofRequiresFiniteOrderedSameFrameDepths",
    ),
    Mutation(
        name="web paint positioning omitted fixed container becomes viewport scope",
        path=_BASE + "WebLint.swift",
        old="WebPaintSemantics.positioningRange(source).map { $0.block == -1 } ?? !contained",
        new="WebPaintSemantics.positioningRange(source).map { _ in true } ?? !contained",
        test=_TEST
        + "WebPaintSemanticsTests/testMeasuredFixedContainingBlockSurvivesOmittedSemanticAncestor",
    ),
    Mutation(
        name="web paint positioning nested scroll projection resurrects skipped clips",
        path=_BASE + "WebLint.swift",
        old="inheritedClips.filter { !$0.escaped(by: node) }",
        new="inheritedClips.filter { _ in true }",
        test=_TEST
        + "WebPaintSemanticsTests/testEscapingScrollScopeCannotResurrectEarlierClipsForNestedPositionedControls",
    ),
    Mutation(
        name="web paint positioning legacy style bounds disable actual transforms",
        path=_BASE + "WebLint.swift",
        old='styles.indices.contains($0) && styles[$0] != "none"',
        new='styles.indices.contains($0 + 3) && styles[$0] != "none"',
        test=_TEST
        + "WebPaintSemanticsTests/testIndividualTransformsAndWillChangeEstablishContainingBlocks",
    ),
    Mutation(
        name="web paint positioning none individual transform creates containing block",
        path=_BASE + "WebLint.swift",
        old='styles[$0] != "none"',
        new='styles[$0] == "none"',
        test=_TEST
        + "WebPaintSemanticsTests/testIndividualTransformsAndWillChangeEstablishContainingBlocks",
    ),
    Mutation(
        name="web paint positioning individual translate is ignored",
        path=_BASE + "WebLint.swift",
        old="[33, 34, 35].contains(where:",
        new="[34, 35].contains(where:",
        test=_TEST
        + "WebPaintSemanticsTests/testIndividualTransformsAndWillChangeEstablishContainingBlocks",
    ),
    Mutation(
        name="web paint positioning will change translate is ignored",
        path=_BASE + "WebLint.swift",
        old='["transform", "filter", "perspective", "contain", "translate", "rotate", "scale"]',
        new='["transform", "filter", "perspective", "contain", "rotate", "scale"]',
        test=_TEST
        + "WebPaintSemanticsTests/testIndividualTransformsAndWillChangeEstablishContainingBlocks",
    ),
    Mutation(
        name="web paint positioning individual rotate is ignored",
        path=_BASE + "WebLint.swift",
        old="[33, 34, 35].contains(where:",
        new="[33, 35].contains(where:",
        test=_TEST
        + "WebPaintSemanticsTests/testIndividualTransformsAndWillChangeEstablishContainingBlocks",
    ),
    Mutation(
        name="web paint positioning will change rotate is ignored",
        path=_BASE + "WebLint.swift",
        old='["transform", "filter", "perspective", "contain", "translate", "rotate", "scale"]',
        new='["transform", "filter", "perspective", "contain", "translate", "scale"]',
        test=_TEST
        + "WebPaintSemanticsTests/testIndividualTransformsAndWillChangeEstablishContainingBlocks",
    ),
    Mutation(
        name="web paint positioning individual scale is ignored",
        path=_BASE + "WebLint.swift",
        old="[33, 34, 35].contains(where:",
        new="[33, 34].contains(where:",
        test=_TEST
        + "WebPaintSemanticsTests/testIndividualTransformsAndWillChangeEstablishContainingBlocks",
    ),
    Mutation(
        name="web paint positioning will change scale is ignored",
        path=_BASE + "WebLint.swift",
        old='["transform", "filter", "perspective", "contain", "translate", "rotate", "scale"]',
        new='["transform", "filter", "perspective", "contain", "translate", "rotate"]',
        test=_TEST
        + "WebPaintSemanticsTests/testIndividualTransformsAndWillChangeEstablishContainingBlocks",
    ),
    Mutation(
        name="web paint positioning reachable scope copies escape work limit",
        path=_BASE + "WebLint.swift",
        old="try budget.charge() // Bound each copied reachable-scope node before materializing it.",
        new="try budget.charge(0) // Bound each copied reachable-scope node before materializing it.",
        test=_TEST
        + "WebPaintSemanticsTests/testOverlapScopeDiscoveryAndReachableCopiesShareWorkBudget",
    ),
    Mutation(
        name="web paint positioning scope discovery escapes work limit",
        path=_BASE + "WebLint.swift",
        old="try budget.charge() // Scope discovery shares the same fail-closed work budget.",
        new="try budget.charge(0) // Scope discovery shares the same fail-closed work budget.",
        test=_TEST
        + "WebPaintSemanticsTests/testOverlapScopeDiscoveryAndReachableCopiesShareWorkBudget",
    ),
]
