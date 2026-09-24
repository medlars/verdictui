"""Web lint guards (overlap, tap target, clipping, font boxes) and their witnesses."""

from mutation_catalog_types import Mutation

_BASE = "Sources/VerdictUIWeb/"
_TEST = "VerdictUIWebTests."

MUTATIONS: list[Mutation] = [
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
        name="web paint scrollable descendant inherits outer clipping axis",
        path=_BASE + "WebLint.swift",
        old="y: $0.y && !scrollY)",
        new="y: $0.y && (scrollY || $0.y))",
        test=_TEST + "WebLintTests/testScrollPanelInsideHiddenCardDoesNotClipReachableContent",
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
