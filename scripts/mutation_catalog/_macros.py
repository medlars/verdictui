"""Mutation rows for the @Verifiable macro and its expansion (Sources/VerdictUIMacros).

Part of the `mutation_catalog` package; see its `__init__` for why the
catalog is split and for the rule about quoting text from these files.
"""

from mutation_catalog_types import Mutation, Runner  # noqa: F401

MUTATIONS: list[Mutation] = [
    Mutation(
        # The walk stops honouring an existing probe, so a hand-probed element
        # gets a second, generated id. `DuplicateProbeIDRule` then reports the
        # instrumentation itself as a defect.
        name="body walk re-probes an already-probed element",
        path="Sources/VerdictUIMacros/BodyProbeWalk.swift",
        old="        if Self.carriesExplicitProbe(recursed) {",
        new="        if false {",
        test="VerdictUIMacroTests.VerifiableMacroTests/testAnElementThatAlreadyHasAProbeIsNotProbedAgain",
        runner=Runner.SWIFT,
    ),
    Mutation(
        # Suppression stops being POSITIONAL and swallows the subtree: an
        # explicit probe on a container makes everything nested inside it
        # invisible, so the tree is one node with no content. `vacuous-verdict`
        # cannot catch that — the container's own probe makes the tree look
        # observed — so every rule reports PASS about uninstrumented content.
        #
        # The witness is the EXPANSION SNAPSHOT, not the runtime render test
        # that also covers this behaviour. SwiftPM rebuilds the plugin but does
        # not re-expand macros in a consuming target whose own sources are
        # unchanged, so a render test keeps the PREVIOUS expansion and passes
        # under this mutation (measured: passes mutated, fails once the test
        # file is touched). A macro row must therefore name a test in the
        # module that expands the macro at build time.
        name="explicit probe on a container swallows its children",
        path="Sources/VerdictUIMacros/BodyProbeWalk.swift",
        old="            return recursed\n        }\n\n        guard let role",
        new="            return expression\n        }\n\n        guard let role",
        test=(
            "VerdictUIMacroTests.VerifiableMacroTests/"
            "testAnExplicitProbeOnAContainerDoesNotSwallowItsChildren"
        ),
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
        # The statement leading trivia is dropped, so a probed statement is
        # glued to whatever precedes it. In a closure WITH A SIGNATURE that is
        # the `in` keyword — `{ row in` + `Text(…)` becomes `{ row inText(…)`,
        # which is not Swift, so `@Verifiable` on any view containing a
        # `ForEach` expands to source that cannot compile.
        #
        # Witnessed by the expansion snapshot rather than by the ForEach RENDER
        # test, for the reason recorded in no.md #23 AND for a second one that
        # is specific to this mutation: a non-compiling expansion in the
        # consuming target scores INCONCLUSIVE, which measures nothing. The
        # snapshot test expands the macro in-process, so it observes the broken
        # source as a text mismatch instead of as a build failure.
        # UNPROVABLE BY CONSTRUCTION, and the reason is the defect itself: this
        # guard exists because the macro emitted `{ row inText(…)`, which by
        # definition does not compile. A mutation reinstating that bug therefore
        # cannot produce a building test target, so the row scores INCONCLUSIVE
        # however it is written. The snapshot witness WOULD see it (measured:
        # "cannot find 'item' in scope" / "cannot find 'inText' in scope"), but
        # sibling COMPILATION tests in the same target fail to build first.
        # Kept rather than deleted: --verify-targets still pins the anchor, so a
        # refactor that moves the line is caught even though the mutation is not.
        name="body walk drops the trivia separating a statement from its closure signature",
        path="Sources/VerdictUIMacros/BodyProbeWalk.swift",
        old="                        rewritten.with(\\.leadingTrivia, expression.leadingTrivia)",
        new="                        rewritten",
        test=(
            "VerdictUIMacroTests.VerifiableMacroTests/"
            "testElementsInsideAForEachAreProbedAndTheClosureSurvives"
        ),
        runner=Runner.SWIFT,
    ),
    Mutation(
        # `@ViewBuilder` conditional content stops being walked, so every element
        # in every `if`/`switch` branch goes unprobed. The container's other
        # probed children keep the tree looking observed, so `vacuous-verdict`
        # (which fires only when NO probed node exists) cannot see it and every
        # rule reports PASS about content nobody instrumented.
        #
        # `case .stmt` is kept and made a no-op rather than deleted, so the
        # switch stays exhaustive and the mutation compiles — a mutation that
        # cannot build scores on the compiler's verdict instead of the suite's.
        name="body walk leaves ViewBuilder conditional content unprobed",
        path="Sources/VerdictUIMacros/BodyProbeWalk.swift",
        old="                    copy.item = .stmt(rewriteStatement(statement))",
        new="                    copy.item = .stmt(statement)",
        test=(
            "VerdictUIMacroTests.VerifiableMacroTests/testElementsInsideAConditionalBranchAreProbed"
        ),
        runner=Runner.SWIFT,
    ),
    Mutation(
        # The two macros stop composing. With the wrap removed, an opaque custom
        # view renders its ORDINARY body inside a scenario, so a `@Verifiable`
        # view reached through `#VerdictScenario` produces a tree with no probed
        # node — `vacuous-verdict`, which is the wave's headline claim failing in
        # its worst form. Measured before the fix existed.
        #
        # Witnessed by the RUNTIME test rather than an expansion snapshot, which
        # is the exception to no.md #23 and is deliberate: the defect is about
        # what the compiler RESOLVES `verdictProbing` to, and a snapshot cannot
        # see an overload choice. Both the macro plugin AND the consuming test
        # file are rebuilt here because `verdictProbing` lives in the support
        # library, not the plugin, so the stale-expansion trap does not apply.
        name="the two macros stop composing over a custom view",
        path="Sources/VerdictUIMacros/BodyProbeWalk.swift",
        old='                return "verdictProbing(\\(recursed.trimmed))"',
        new="                return recursed",
        test=(
            "VerdictUIMacroTests.TwoTokenAdoptionTests/"
            "testTheTwoTokensBuyAVerdictThatCanSeeTheContent"
        ),
        runtime_witness_reason=(
            "The defect is which OVERLOAD of verdictProbing the compiler resolves, and a "
            "snapshot compares generated text, so it cannot observe an overload choice. "
            "no.md #23's stale-expansion trap DOES apply -- this note previously claimed "
            "it did not, reasoning that verdictProbing lives in the support library rather "
            "than the plugin. That reasoning was wrong: the MUTATED symbol is in the "
            "plugin (BodyProbeWalk), so the consuming target must be re-expanded no matter "
            "where the overloads live. Measured 2026-08-11: this row reported UNNOTICED in "
            "a full sweep while the same mutation applied by hand -- with the consuming "
            "tests touched first -- was NOTICED at exit 1, 1 test executed, failing on "
            "vacuous-verdict. The harness now calls refresh_macro_expansions() on the "
            "Swift path, so the hand discipline and the automated path agree (no.md #28)."
        ),
        runner=Runner.SWIFT,
    ),
    Mutation(
        # The duplicate-id check stops reporting, so two elements sharing an
        # author-written id compile clean. Every layer downstream matches on the
        # id — TreeDiff pairs nodes by it, a baseline keys on it — so the two
        # elements silently merge into one node.
        #
        # `insert` still runs so the set is still populated; only the REPORT is
        # suppressed, which is the honest mutation: deleting the insert would
        # also break the walk's own bookkeeping and could fail for a second,
        # unrelated reason.
        name="two elements sharing an explicit probe id stop being reported",
        path="Sources/VerdictUIMacros/BodyProbeWalk.swift",
        old="        if !explicitIDs.insert(id).inserted {",
        new="        if false, !explicitIDs.insert(id).inserted {",
        test=(
            "VerdictUIMacroTests.VerifiableMacroDiagnosticsTests/testTwoElementsSharingAnExplicitIdIsAnError"
        ),
        runner=Runner.SWIFT,
    ),
    Mutation(
        # The unlabelled-interactive warning stops firing, so a button the
        # verdict can locate but cannot NAME passes review silently. Nothing
        # downstream can recover the label: it lives inside a closure the macro
        # never evaluates, so the node reaches the kernel with no text at all.
        name="an interactive element with no label stops being warned about",
        path="Sources/VerdictUIMacros/BodyProbeWalk.swift",
        old="        if Self.rolesRequiringALabel.contains(role), Self.literalTextArgument(of: recursed) == nil {",
        new="        if false, Self.literalTextArgument(of: recursed) == nil {",
        test=(
            "VerdictUIMacroTests.VerifiableMacroDiagnosticsTests/"
            "testAnInteractiveElementWithNoLabelIsAWarningCarryingAFixIt"
        ),
        runner=Runner.SWIFT,
    ),
    Mutation(
        # An interpolated string is forwarded as `text:`, putting the literal
        # source `\\(name)` where TruncationRule reads what the user sees. A
        # false value is worse than an absent one — the rule acts on it.
        name="body walk forwards an interpolated string as literal text",
        path="Sources/VerdictUIMacros/BodyProbeWalk.swift",
        # Two lines, because Task 5's `explicitProbeID` extractor introduced a
        # second `literal.segments.count == 1,` in this file and a one-line
        # anchor began self-matching. The following line differs between the two
        # sites (`literal.segments.first?…!= nil` here, `let segment = …` there),
        # so the pair is unique. Safe as a multi-line anchor where `no.md` #16's
        # was not: that one relied on a wrap `ruff format` collapses, and ruff
        # does not touch Swift.
        old=(
            "                literal.segments.count == 1,\n"
            "                literal.segments.first?.as(StringSegmentSyntax.self) != nil"
        ),
        new=(
            "                literal.segments.count >= 1,\n"
            "                literal.segments.first?.as(StringSegmentSyntax.self) != nil"
        ),
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
        # The generated members stop mirroring the host type's access level, so
        # `verdictProbedContent` is internal again and cannot satisfy the PUBLIC
        # `VerifiableView` requirement. Every `public` view carrying
        # `@Verifiable` then fails to compile — which is every view a library
        # module exports, and is how this shipped for four waves: no fixture in
        # the macro test target was public, most being nested in an XCTestCase
        # where `public` is not expressible.
        #
        # The `new` returns "" rather than deleting the property, keeping the
        # plugin itself compilable (no.md #31) — the failure must be the
        # CONSUMER's build, which is exactly what the witness observes. The
        # witness is in the module that EXPANDS the macro (no.md #23), and the
        # harness restamps macro-consuming sources before running it (no.md #28).
        name="generated members stop matching the host type's access level",
        path="Sources/VerdictUIMacros/VerifiableMacro.swift",
        old='        return isPublic ? "public " : ""',
        new='        return isPublic ? "" : ""',
        test="VerdictUIMacroTests.PublicVerifiableViewTests/testAPublicViewIsProbedThroughItsPublicConformance",
        runtime_witness_reason=(
            "MEASURED, not argued: the mutation was hand-applied and the witness run WITHOUT "
            "touching any consuming source, and it still failed with the compiler's "
            "'must be declared public because it matches a requirement in public protocol' "
            "error. The stale-expansion trap of no.md #23 cannot apply here because the defect "
            "IS a compile failure in the consuming target — a stale expansion is the BROKEN "
            "expansion, so re-running against it fails for exactly the same reason rather than "
            "passing. An assertMacroExpansion snapshot could not witness this at all: the "
            "generated text differs by one access keyword and is syntactically valid either "
            "way, so only a real build can tell the two apart. Restored byte-identically "
            "(sha256 d20d3a26...) and the green control re-ran 2 tests, 0 failures."
        ),
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
        # `#VerdictScenario` declares the conformance but stops PROBING the
        # body, so a macro-declared scenario renders to a root with nothing
        # under it and every rule reports PASS on an uninstrumented screen.
        #
        # `_ = walk.rewrite(...)` is kept so the mutation still COMPILES: the
        # obvious deletion leaves `walk` unused, which is an error under
        # `-warnings-as-errors`, and a mutation that fails to build never runs
        # a test — it would score on the compiler's verdict, not the suite's.
        #
        # Witness is the expansion snapshot, not the render test that also
        # covers this: SwiftPM does not re-expand macros in a consuming target
        # whose own sources are unchanged (`no.md` #23).
        # Re-anchored in Task 5. This row targeted the scenario macro's own
        # local map over expression items; that map was DELETED because it was
        # a second implementation of the walk and carried the Task 4 conditional
        # defect independently. The guard it protects is unchanged — a scenario
        # that declares a conformance but probes nothing — so the row now points
        # at the shared entry both macros use.
        name="scenario macro declares a conformance without probing its body",
        path="Sources/VerdictUIMacros/VerdictScenarioMacro.swift",
        # `walk` is still driven, and discarded. The obvious mutation — dropping
        # the call entirely — leaves `var walk` never mutated, which is an ERROR
        # under -warnings-as-errors, so the build fails and the row scores on the
        # compiler's verdict instead of the suite's. Measured: it reported
        # NOTICED having executed zero tests. Same trap as the Task 3 row; a
        # mutation that cannot compile is not a witness.
        old="        let probedStatements = walk.rewriteStatements(closure.statements).reindentedForTemplate",
        new=(
            "        _ = walk.rewriteStatements(closure.statements)\n"
            "        let probedStatements = closure.statements.reindentedForTemplate"
        ),
        test=(
            "VerdictUIMacroTests.VerdictScenarioMacroTests/"
            "testTheScenarioBodyIsProbedByTheSameWalkAsAView"
        ),
        runner=Runner.SWIFT,
    ),
    Mutation(
        # The `Scenario` suffix stops being appended, so a scenario named
        # "Text" generates `struct Text` — which shadows SwiftUI's `Text`
        # inside its own expansion, making every element in the body resolve
        # to the scenario itself.
        # UNPROVABLE BY CONSTRUCTION. Its own witness is a PURE-FUNCTION test
        # (`typeName(forScenarioNamed: "Text")`) that needs no expansion, but a
        # sibling file hard-codes the generated name
        # (`VerdictScenarioCompilationTests` -> `MacroScenarios.MacroCheckoutScenario`),
        # so dropping the suffix breaks the TARGET build before any test runs.
        # Measured: "'MacroCheckoutScenario' is not a member type of enum".
        name="generated scenario type name drops its suffix",
        path="Sources/VerdictUIMacros/VerdictScenarioMacro.swift",
        old='        return out + "Scenario"',
        new="        return out",
        test=(
            "VerdictUIMacroTests.VerdictScenarioMacroTests/testTheScenarioSuffixIsAlwaysAppended"
        ),
        runner=Runner.SWIFT,
    ),
]
