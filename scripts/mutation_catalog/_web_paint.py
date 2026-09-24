"""Web paint-semantics, frame-geometry and inline-geometry guards and their witnesses."""

from mutation_catalog_types import Mutation

_BASE = "Sources/VerdictUIWeb/"
_TEST = "VerdictUIWebTests."

MUTATIONS: list[Mutation] = [
    Mutation(
        name="web inline cancellation prevents remote object cleanup",
        path=_BASE + "WebInlineGeometry.swift",
        old='_ = try await Task.detached {\n            try await command("Runtime.releaseObjectGroup", ["objectGroup": .string(group)], .seconds(1))\n        }.value',
        new='try Task.checkCancellation()\n        _ = try await command("Runtime.releaseObjectGroup", ["objectGroup": .string(group)], .seconds(1))',
        test=_TEST
        + "WebInlineGeometryTests/testResolutionBatchesAreBoundedAndCancellationStillReleasesObjects",
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
        name="web paint text boxes remain in child coordinates",
        path=_BASE + "WebFrameGeometry.swift",
        old='rectangleKeys += (0..<count).map { "web.textFragment\\($0)" }',
        new='rectangleKeys += (0..<min(count, 0)).map { "web.textFragment\\($0)" }',
        test=_TEST
        + "DOMSnapshotAssemblyTests/testTextFragmentGeometryTracksScrollAndFrameTransforms",
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
        name="web paint followup font warning is emitted as a confirmed defect",
        path=_BASE + "WebPaintSemantics.swift",
        old="if fontPaintUnverified {",
        new="if fontPaintUnverified && node.role == .spacer {",
        test=_TEST
        + "WebPaintSemanticsTests/testNormalFlowFontIntersectionUsesActualFragmentsAndStaysUnverified",
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
        name="web paint positioning empty frame identity proves clip escape",
        path=_BASE + "WebPaintSemantics.swift",
        old='let frame, !frame.isEmpty, node.attributes["web.frame"]',
        new='let frame, frame.isEmpty || !frame.isEmpty, node.attributes["web.frame"]',
        test=_TEST
        + "WebPaintSemanticsTests/testPositioningProofRequiresFiniteOrderedSameFrameDepths",
    ),
]
