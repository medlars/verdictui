"""DOMSnapshot assembly and accessible-name guards and their witnesses."""

from mutation_catalog_types import Mutation

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
        name="web inline border union consistency is ignored",
        path=_BASE + "DOMSnapshotAssembly.swift",
        old="abs(measuredUnion.height - frame.height) <= 0.1",
        new="abs(measuredUnion.height - frame.height) <= 1000",
        test=_TEST
        + "DOMSnapshotAssemblyTests/testInlineBorderFragmentsPreserveUnionAndRejectIncompleteOrChangedGeometry",
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
        name="web scroll empty paint proof is not applied",
        path=_BASE + "DOMSnapshotAssembly.swift",
        old="&& !WebLint.emptyPaint(position: style[4], clip: style[5], clipPath: style[6], frame: frame)",
        new='&& (!WebLint.emptyPaint(position: style[4], clip: style[5], clipPath: style[6], frame: frame) || style[0] != "none")',
        test=_TEST
        + "DOMSnapshotAssemblyTests/testMeasuredEmptyPaintClipHidesDescendantsAndFocusRestoresThem",
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
        name="web paint text boxes ignore document scroll",
        path=_BASE + "DOMSnapshotAssembly.swift",
        old="y: box.y - scrollY,",
        new="y: box.y - scrollY * 0,",
        test=_TEST
        + "DOMSnapshotAssemblyTests/testTextFragmentGeometryTracksScrollAndFrameTransforms",
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
        name="web custom roles expose reflected credentials",
        path=_BASE + "DOMSnapshotAssembly.swift",
        old="role = .custom(WebRedaction.clean(raw, secrets: secrets))",
        new="role = .custom(raw)",
        test=_TEST + "DOMSnapshotAssemblyTests/testCredentialReflectedIntoCustomRoleIsRedacted",
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
]
