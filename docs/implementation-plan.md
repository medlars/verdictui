# VerdictUI — Implementation Plan (Opus 5 Execution Spec)

> **Status**: Waves 0–2 complete (2026-08-04). Current wave: **Wave 3 — settle engine**.
> **How to execute**: one wave per Opus 5 session (`/verdictui` at session start). A wave is
> DONE only when every item in its **Exit gate** passes with runner-sourced evidence
> (`swift test` output, PM Grade A, benchmark numbers). Do not begin wave N+1 with wave N
> gates open. Within a wave, tasks are ordered — respect dependencies. Record deviations
> in `no.md` (deliberate) or ADRs (architectural).
> **Research basis**: 5-agent deep research 2026-08-03 (CTS-5BABC171): SwiftUI internals,
> ecosystem tooling, agent-native protocols, cross-platform verification, web-tooling gaps.

---

## Product thesis (context for every wave)

The screenshot→wait→click→wait→confirm cycle exists because SwiftUI is a closed box: the
framework knows every frame, every animation's progress, and every pending state change,
but exposes none of it. VerdictUI opens the box **from the inside**, using only public
API, and sells the result as three concentric loops:

| Loop | Channel | Latency | Trust model |
|------|---------|---------|-------------|
| Inner (every agent edit) | In-process: Layout probes + preference-key streams → semantic tree → kernel verdict | ~ms | Self-reported by the layout engine — fast but must be kept honest |
| Middle (per scenario) | External: AX tree + real CGEvents + windowless pixel capture, reconciled against inner stream | ~s | Independent witness — divergence IS the bug detector |
| Outer (release smoke) | Thin orchestrated XCUITest | ~min | OS-level truths only (launch, permission dialogs, real keyboard) |

Non-negotiables (from CLAUDE.md / no.md): kernel platform-purity; public API only in the
core; verdicts always carry evidence; no web implementation before Wave 10 exits (contract
stays platform-agnostic from day one).

---

## Wave 1 — Kernel: the verdict engine

**Objective**: `VerdictUIKernel` is complete, platform-pure, and worth trusting: full
semantic tree model, tree diffing, the first six lint rules, and a versioned JSON verdict
schema. Everything headless-testable — no SwiftUI in sight.

**Why first**: every later wave (probe, settle, CLI, MCP, cross-validation) terminates in
this engine. Schema mistakes here propagate into the agent-facing wire format, so the
kernel must stabilize before anything consumes it.

### Tasks (ordered)

1. **Extend `SemanticNode`** (`Sources/VerdictUIKernel/SemanticNode.swift`):
   - `role` becomes `Role` enum: `container, text, button, toggle, slider, textField, image, list, listRow, navigation, tabBar, menu, spacer, custom(String)` — mirror SwiftUI's accessibility role vocabulary so Wave 8 reconciliation maps 1:1 to AX roles.
   - Add `attributes: [String: AttributeValue]` (string/number/bool enum, Codable) for role-specific data (toggle state, slider value, text truncation metrics).
   - Add `isVisible: Bool` (opacity > 0, not clipped to zero) and `zIndex: Double?`.
   - Add `textMetrics: TextMetrics?` — `intrinsicWidth`, `renderedLineCount`, `idealLineCount` (probe supplies these in Wave 2; kernel defines the contract now).
   - Stable identity: `id` remains the probe-supplied string; add `structuralPath: String` (parent-chain fallback for unprobed nodes, e.g. `root/VStack[0]/Text[2]`).
2. **`TreeDiff`** (new file `TreeDiff.swift`):
   - `TreeDiff.compute(before: SemanticNode, after: SemanticNode) -> TreeDelta` where `TreeDelta` has `added: [NodePath]`, `removed: [NodePath]`, `moved: [(NodePath, from: Rect, to: Rect)]`, `changed: [(NodePath, [AttributeChange])]`.
   - Match nodes by `id` first, `structuralPath` second. O(n) via dictionary index; property-test with random tree mutations (insert/delete/move/mutate) asserting the delta reconstructs the mutation.
3. **Rule engine** (new file `RuleEngine.swift`):
   - `protocol LintRule: Sendable { static var id: String { get }; func evaluate(_ root: SemanticNode, context: LintContext) -> [Finding] }`
   - `LintContext` carries viewport `Rect`, platform minimums (tap target 44×44 pt macOS-adjusted), and rule configuration (severity overrides, per-node suppressions via `attributes["verdict.suppress"]`).
   - `RuleEngine.run(rules: [any LintRule], on: SemanticNode, context: LintContext) -> Verdict`.
4. **Six rules** (one file each under `Rules/`), each with edge-case tests:
   - `SiblingOverlapRule` (port + generalize the Wave 0 seed; ignore intentional ZStack layering via `zIndex`/container role).
   - `ZeroSizeRule` — visible node with empty frame (spacers and probes exempt by role).
   - `OffscreenRule` — node fully outside viewport while `isVisible`.
   - `TruncationRule` — `renderedLineCount < idealLineCount` or `frame.width < intrinsicWidth` for text nodes.
   - `TapTargetRule` — interactive roles below minimum hit size.
   - `DuplicateProbeIDRule` — same probe `id` twice in one tree (breaks diffing and act-targeting; must be an error).
5. **Verdict schema v1** (`contracts/verdict-schema.json` + `SchemaVersion.swift`):
   - Envelope: `{schemaVersion: "1.0", scenario, timestamp, status, findings[], tree?, delta?, timing: {settleMs, evaluateMs}}`.
   - Findings gain `suggestion: String?` (machine-actionable hint, e.g. "increase frame width to ≥ intrinsicWidth 212pt").
   - `contracts/validate-contracts.py` upgraded: round-trip a fixture verdict from the Swift encoder through the JSON schema (store fixture under `contracts/fixtures/`).
6. **Docs**: `docs/kernel.md` — role vocabulary table, rule catalog with failure examples, schema reference.

### Exit gate

- [ ] `swift test --filter VerdictUIKernelTests` green; ≥ 30 kernel tests including one property-style diff test
- [ ] Every public kernel symbol has a doc comment and at least one test exercising it
- [ ] `contracts/validate-contracts.py` → PASS (schema round-trip)
- [ ] PM `stage_architecture` still green (no UI imports crept in)
- [ ] PM quick Grade A; FILE_REGISTRY + CHANGELOG updated

### Risks

- **Over-modeling**: keep `AttributeValue` to 3 primitive cases; resist nested structures until a rule needs them.
- **Rule false positives** kill adoption faster than false negatives — each rule ships with an explicit suppression path and a "why this fired" message template.

---

## Wave 2 — Probe runtime + oracle harness

**Objective**: any SwiftUI view, wrapped in a probe scenario, renders **headless** and
yields a `SemanticNode` tree with real layout-engine frames. The "offscreen geometry
oracle" from the research becomes a supported library API.

**Why**: this is the moment screenshots become optional — ground truth starts flowing from
the layout pass itself.

### Spike finding (2026-08-04, pre-wave, /tmp — the assumption the wave rests on)

**Question**: does a windowless `NSHostingView` yield real layout-engine frames with no
window-server dependency? **Answer: yes — verified with a positive control, not just a
green run.** A throwaway package (`/tmp/verdictui-spike`) hosted a probed SwiftUI view in
an `NSHostingView` with no `NSWindow`, no `NSApplication.run`; GeometryReader/preference
frames came back glyph-real (20-char 13 pt text measured 120 pt wide, `VStack` spacing
exact at 10 pt, `.frame(width: 120)` honored to the point). Re-run under a `sandbox-exec`
profile denying every `com.apple.windowserver*`/`CARenderServer` mach-lookup: byte-identical
frames, exit 0. The profile itself was proven non-vacuous by a control program that orders
a real `NSWindow` on screen — it succeeds normally (window server allocates windowNumber)
and fails under the same profile (windowNumber 0, exit 1). Two operational facts for
Task 3: (a) preference values are delivered only after pumping the main run loop —
a single `layoutSubtreeIfNeeded` is not sufficient, confirming risk #3's
loop-until-stable design; (b) `fittingSize` works headless.

### Tasks (ordered)

1. **Transparent Layout probe** (`Sources/VerdictUIProbe/ProbeLayout.swift`):
   - `struct ProbeLayout: Layout` that forwards `sizeThatFits`/`placeSubviews` unchanged while recording proposed sizes, returned sizes, and placements into a `ProbeRecorder` (a `@MainActor` reference sink injected via `LayoutValueKey` or environment).
   - This is the layer that sees layout *negotiation* (proposals vs results), which GeometryReader cannot; it powers `TruncationRule` inputs (`intrinsicWidth` via an unconstrained proposal probe on text).
2. **Full preference pipeline** (`VerdictProbe.swift` rewrite):
   - `.verdictProbe(_ id:, role:, attributes:)` — keep the Wave 0 GeometryReader/preference spine but emit a `ProbeRecord` (id, role, frame in a named root coordinate space, text, attributes) instead of bare `Rect`.
   - Root modifier `.verdictRoot()` — establishes `coordinateSpace(name: "verdict-root")`, collects `VerdictFramesKey`, merges with `ProbeRecorder` layout data, assembles the `SemanticNode` tree (parent/child by frame containment + layout order; probe IDs win over structural paths).
3. **Oracle harness** (`Sources/VerdictUIProbe/OracleHost.swift`):
   - `@MainActor final class OracleHost { init(scenario:); func currentTree() async -> SemanticNode }`
   - Backed by windowless `NSHostingView` sized by `fittingSize` or explicit viewport; **never** attached to a visible window (CI-safe — runbook failure mode #2).
   - Deterministic environment injection: `displayScale = 1`, fixed locale/calendar/timeZone, `colorScheme` pinned, dynamic type pinned, `accessibilityReduceMotion = true`.
4. **Scenario protocol** (`Scenario.swift`):
   - `protocol VerdictScenario { associatedtype Body: View; var name: String { get }; @MainActor @ViewBuilder func body(state: ScenarioState) -> Body }` — `ScenarioState` is the injection point for variant sweeps (Wave 3 uses it for actions; Wave 5 for state matrices).
5. **Demo app target** (`Sources/VerdictUIDemo/` executable + `DemoScenarios/`):
   - A deliberately bug-rich set: truncating label, overlapping badges, offscreen button, undersized tap target, a toggle-driven layout change. Used by tests, benchmarks (SLO 1), and eventually the README GIF.
6. **Integration tests** (`Tests/VerdictUIProbeTests/`):
   - Render each demo scenario through `OracleHost`, assert exact expected frames (deterministic env makes exact assertion safe), run kernel rules, assert the known-planted bugs are each caught by the right rule — **the tool catching a planted bug is the product's first end-to-end proof**.
   - Determinism test: render the same scenario 10×, assert byte-identical encoded trees.

### Exit gate

- [ ] All demo-scenario planted bugs caught by the correct rule (integration test green)
- [ ] Determinism test green (10× identical trees)
- [ ] Harness runs with **no** window server dependency (verify: tests pass under `swift test` in a non-GUI login shell / CI-style env)
- [ ] `OracleHost.currentTree()` p95 < 50 ms on the demo app (XCTest `measure`; records baseline for SLO 1)
- [ ] PM quick Grade A; registry/changelog updated

### Risks

- **Frame containment tree-building is ambiguous** for overlapping siblings — layout-order tiebreak; document in kernel.md.
- **`fittingSize` loops** on unbounded content (infinite ScrollView) — cap by explicit viewport, emit a `warning` finding when clamped.
- **AppKit hosting quirks** (first layout pass empty): loop `layoutSubtreeIfNeeded` until stable or deadline; this is a preview of Wave 3's settle problem — keep the primitive reusable.

---

## Wave 3 — Settle engine: `pumpAndSettle` for SwiftUI

**Objective**: the missing synchronization primitive. `await harness.settle()` returns
exactly when the UI is quiescent — animations done, main-queue drained, layout stable —
or FAILs with a timeout verdict. Plus in-process action injection, making the inner loop
**act → settle → verdict** atomic.

**Why**: Flutter's `pumpAndSettle` is the single most-cited reason its agent loop feels
solid; XCUITest's `waitForQuiescence` is broken enough that teams patch it out. Shipping
this alone would justify the project.

### Tasks (ordered)

1. **Virtual clock** (`Sources/VerdictUIProbe/VerdictClock.swift`):
   - `final class VerdictClock: Clock` (Swift `Clock` protocol, `Instant`/`Duration`) with manual `advance(by:)`; scenarios receive it via environment so `Task.sleep`/`clock.timer` in app code under test becomes controllable.
   - Animation control: harness applies `Transaction(animation: nil)` / `withTransaction` around injected state changes by default (`settlePolicy: .skipAnimations`); `.runAnimations` mode drives them via `CATransaction.flush` + display-link pump for animation-correctness scenarios.
2. **Quiescence detector** (`Settle.swift`):
   - Signals composed (all must be true across two consecutive checks): main queue drained (async barrier probe), no in-flight `ProbeRecorder` layout activity since last check, tree hash unchanged, no pending virtual-clock timers, `CATransaction` commit cycle idle.
   - `func settle(timeout: Duration = .seconds(2)) async -> SettleResult` — `.settled(after: Duration)` or `.timedOut(lastDelta: TreeDelta)`; timeout produces a FAIL verdict with the still-changing subtree named (SD2 audit requirement: never hang, never lie).
3. **Action injection** (`Actions.swift`):
   - `enum ProbeAction { case tap(String), setText(String, String), toggle(String), setSlider(String, Double), custom(String, (ScenarioState) -> Void) }`
   - Implementation: actions mutate `ScenarioState` bindings registered at probe sites (`.verdictProbe(id, action: binding)`) — in-process, no event synthesis, no permissions. Real-event injection stays in Wave 8 (middle loop) by design; document the trust difference in kernel.md.
4. **Atomic act-and-observe** (`Harness.swift`):
   - `func perform(_ action: ProbeAction) async -> StepResult` = capture tree → act → `settle()` → capture tree → `TreeDiff` → rules on new tree → `Verdict` + `TreeDelta` in one call. **One call, complete evidence — this is the API agents live on.**
   - `func run(_ flow: [ProbeAction]) async -> FlowResult` — batched steps, early-exit on FAIL, per-step timing.
5. **Hostile test suite** (the settle engine's own verification, SD2):
   - Infinite `repeatForever` animation → settle must time out with FAIL naming the animating node.
   - Delayed `Task { sleep; mutate }` → virtual clock advance surfaces the mutation before settle reports quiet.
   - Debounced text field (0.3 s) → `setText` + settle sees the post-debounce tree, not the intermediate.
   - Rapid double-tap → two atomic steps produce two clean deltas, no interleaving.
6. **Benchmark harness** (~~`Tests/VerdictUIBenchTests/`~~ → shipped as
   `Tests/VerdictUIProbeTests/HarnessPerformanceTests.swift`, see `no.md` #11 —
   `--filter` gives the isolation a separate target was wanted for; PM `stage_runtime_bench`):
   - Measure act→settle→verdict p50/p95 on demo scenarios; PM stage compares to `docs/slo.md` SLO 1 (<100 ms p95) and fails on regression >20%. Update pm-baselines.json.

### Exit gate

- [ ] Hostile suite green (all four adversarial scenarios behave as specified)
- [ ] `perform()` p95 < 100 ms on demo app — **SLO 1 formally met and enforced by PM stage**
- [ ] Settle never hangs: every test path has deadline coverage (verified by suite-level timeout margin)
- [ ] Zero screenshots, zero sleeps anywhere in harness source (`rg "sleep\(|usleep|Thread.sleep" Sources/` clean, virtual-clock internals exempted by comment)
- [ ] PM quick Grade A

### Risks

- **False quiescence** (async work scheduled off-main): detector requires two consecutive quiet checks + virtual-clock timer census; document residual risk honestly in kernel.md (SD1/SD2).
- **`Clock` injection requires app cooperation** (code must take a `Clock` parameter or read environment) — acceptable: instrumented-app is the product model; uninstrumented async work is what the timeout verdict is for.

---

## Wave 4 — Macros: zero-boilerplate adoption

**Objective**: `@Verifiable` attached macro auto-probes a view's semantic elements;
`#VerdictScenario` registers scenarios discoverable-by-name; a compile-time pass catches
verifiability defects before render. Manual `.verdictProbe()` becomes the escape hatch,
not the norm.

**Why**: research verdict — instrumentation products die from boilerplate (SwiftLens
dormant). Embrace proved macro injection works in production. Adoption cost decides
open-source traction.

### Tasks (ordered)

1. **`VerdictUIMacros` target** (SwiftSyntax dependency; isolate — this triples compile
   time, so macros are an *optional* product: `.library(name: "VerdictUIMacroSupport")`).
2. **`@Verifiable` attached member macro** on a `View` struct:
   - Wraps `body` result with `.verdictRoot()`; walks the body syntax tree; attaches `.verdictProbe(id:role:)` to recognized element expressions (`Text`, `Button`, `Toggle`, `TextField`, `Image`, `List`, …) with IDs derived from source structure (`SaveButton.button.0`) unless an explicit `.verdictProbe` already present.
   - Explicit ID override: `@Verifiable(ids: ["title": "screen-title"])`.
3. **`#VerdictScenario("name", state: ...)` freestanding macro** — expands to a `VerdictScenario` conformance + registration into a runtime `ScenarioRegistry` (static registration list; no runtime reflection). ~~`#Preview` bridging: `VerdictPreviewAdapter` re-exposes existing previews as scenarios where possible.~~ **Not built — see `no.md` #27.** `#Preview` content is only reachable through `PreviewRegistry`, underscored SwiftUI SPI, which `no.md` #1 forbids on the core path; the task's own "where possible" is the answer. Writing `#VerdictScenario("x") { MyView() }` beside the `#Preview` costs one line and renders the probed content since ADR 2026-009.
4. **Expansion snapshot tests** (`Tests/VerdictUIMacroTests/`, SD5):
   - `assertMacroExpansion` fixtures for: simple view, generic view, `@ViewBuilder` conditional content, `ForEach`, nested custom views, view with existing probes (no double-probe).
   - Compile-and-run test: macro-probed demo scenario produces the same tree as its hand-probed twin (differential test — the macro's correctness oracle).
5. **Compile-time lint diagnostics**: duplicate explicit IDs → error; interactive element with no derivable ID (unlabeled closure-only Button) → warning with fix-it inserting `.verdictProbe`.
6. **Docs**: `docs/adoption.md` — three tiers (macro / manual probes / hybrid), migration guide, macro limitations table.

### Exit gate

- [x] Differential test green — `testTheMacroMatchesHandProbingAcrossEveryRecognisedElement` compares macro against hand-probed twin across all five recognised element kinds in one view (ids, roles and forwarded text identical), with a node-count control so two empty trees cannot pass it. **Not run against the six demo scenarios, and that is a design property rather than a gap**: they use author-chosen semantic ids (`save-button`) that rule assertions and Wave 5 baselines key on, where the macro mints positional ones, and `CleanSettingsScenario` declares layering as `.custom("zstack")`, a role the walk cannot emit. Pinned by `testTheDemoCatalogIsOutOfTheMacrosReachByDesign`, which fails if the walk ever gains a custom or container role
- [x] All expansion snapshots green including the generic/conditional edge shapes — 64 tests in `VerdictUIMacroTests`, covering generic view, `@ViewBuilder` conditional, `switch` case, `ForEach`, nested custom view, and existing-probe (no double-probe)
- [x] Two tokens suffice — `TwoTokenAdoptionTests`, 3 tests: the verdict is non-vacuous, both elements' text reaches the kernel, and a source-level guard that the fixture view carries no VerdictUI spelling but the attribute. **This gate item was FALSE when first tested** and is what ADR 2026-009 fixes: nothing ever called the generated `verdictProbedBody`, so the composition produced an empty tree and `vacuous-verdict`
- [x] Build-time impact measured and documented — cold (`rm -rf .build`), back to back on one machine: probe alone **24.03 s**, macro support alone **20.71 s**, whole package **29.44 s**. Marginal cost of macros to a probe consumer is **~5.4 s (+22%)**, not the tripling this plan assumed; SwiftSyntax is not the heaviest thing here, SwiftUI/AppKit is. Recorded in `docs/adoption.md`
- [x] PM quick Grade A — **Grade A (100.0)**, all stages PASS, `SLO 1 p50 49.97ms < 70.0ms`

### Risks

- **SwiftSyntax version churn** — pin exact version; CI matrix against the two latest Swift toolchains.
- **Macro cannot see through opaque custom subviews** — by design: it probes the layer it can see; nested `@Verifiable` types compose. Document, don't fight.

---

## Wave 5 — Verdict layer completion: rules, baselines, semantic assertions

**Objective**: the full judgment vocabulary — rule library expanded, expected-state
assertions, baseline trees with review workflow, variant sweeps. The verdict becomes
expressive enough to replace "look at the screenshot and tell me if it's right".

### Tasks (ordered)

1. **Rule library v2** (kernel, each with tests + suppression + suggestion strings):
   - `ContrastRule` (probe supplies resolved fg/bg colors as attributes; WCAG AA math in kernel), `ClippedContentRule` (child extends beyond clipping ancestor), `SafeAreaViolationRule`, `MisalignmentRule` (near-miss edge alignment within tolerance ε — catches the "2 px off" class), `InconsistentSpacingRule` (sibling gaps deviate from modal gap), `EmptyContainerRule`.
2. **Expected-state assertions** (`Expectations.swift`, kernel):
   - Declarative: `expect("save-button", .visible, .enabled, .text("Save"), .rightOf("cancel-button"), .width(.atLeast(80)))` — compiled to findings; relational predicates (`rightOf`, `alignedWith`, `contains`) work on tree geometry.
3. **Baselines** (`Baselines.swift`, kernel + storage):
   - `verdict-baselines/<scenario>.tree.json` — canonical-form semantic tree (sorted keys, quantized floats to 0.5 pt).
   - Compare = `TreeDiff` + significance filter (sub-ε moves ignored); verdict cites the delta.
   - **Update is destructive → SD4 requirements**: update command must show the diff, require `--accept`, and log the pre-update tree hash to `logs/baseline-audit.log`.
4. **Variant sweeps** (`Sweep.swift`, probe):
   - `Sweep(scenario:).over(locales: [en, de, ar], dynamicType: [.medium, .accessibility3], colorSchemes: [.light, .dark], viewports: [.compact, .regular])` → cartesian render matrix, one verdict per cell, aggregated `SweepReport` (rule × variant grid). The "German string truncates at AX3 type" class of bug becomes a table cell, not a support ticket.
5. **State-machine scenarios** (foundation for model-based testing later):
   - `ScenarioState` gains named states + transitions; `Sweep.walk(paths:)` drives transition paths, verdict per step. Icebox note: full property-based UI exploration deferred (record decision in no.md when closing the wave).

### Exit gate

- [ ] ≥ 12 total lint rules, each with false-positive tests (a correct UI passes all rules — run on a "clean" demo scenario)
- [ ] Baseline round-trip: create → mutate view → FAIL with cited delta → `--accept` → PASS; audit log entry present
- [ ] Sweep across 3 locales × 2 type sizes × 2 schemes on demo app < 5 s total (render caching groundwork: reuse `OracleHost` per variant)
- [ ] Expectation DSL covers every demo scenario's semantics (dogfood: replace all hand-written frame assertions in integration tests with the DSL)
- [ ] PM quick Grade A

---

## Wave 6 — CLI + warm daemon

**Objective**: `verdictui` command-line tool + long-lived daemon. The engine leaves the
test target and becomes a service an agent (or human) can call against a scenario bundle
without recompiling per verify.

### Tasks (ordered)

1. **`verdictui` CLI target** (swift-argument-parser):
   - `verdictui list` (scenarios via registry), `verdictui render <scenario> [--variant ...] [--tree|--verdict]`, `verdictui verify <scenario> [--baseline] [--rules ...]`, `verdictui act <scenario> --do 'tap:save-button' [--flow file.json]`, `verdictui baseline update <scenario> --accept`, `verdictui sweep <scenario> --locales ... --report json|md`.
   - All output = verdict-schema JSON on stdout (agents parse it; humans get `--pretty`).
2. **Warm daemon** (`verdictui daemon start|stop|status`):
   - Hosts compiled scenario bundles; JSON-RPC over unix socket at `~/.verdictui/daemon.sock`; per-scenario `OracleHost` pool (LRU, cap N) so repeat verifies skip setup — target < 20 ms marginal verify.
   - **Rebuild loop**: watch the consumer package's build products; on change, reload scenario bundle (relaunch child "scenario host" process holding the dylib — avoids in-process dylib unload unsafety). Architecture: daemon (broker, long-lived) ⇄ scenario-host (per-build child, disposable). Crash of a host = structured error verdict, never daemon death.
3. **Consumer integration story** (`docs/integration.md`):
   - Consumer adds a `VerdictScenarios` target (their scenarios + demo pattern); `verdictui` builds it via `swift build --product` and loads the host against it. Validate the whole flow on a fresh sample project outside this repo (`examples/ConsumerApp/`).
4. **Signing/notarization** (docs/signing.md executed): Developer ID, hardened runtime, notarized zip; `stage_auto_release` remains off until Wave 10, but the release script (`scripts/build-release.sh`) lands now and is exercised manually once.
5. **PM additions**: `stage_cli_smoke` — daemon start → verify demo scenario → assert PASS JSON → stop; runs in quick mode.

### Exit gate

- [ ] Cold `verdictui verify` (incl. daemon autostart + scenario build) < 30 s; warm verify < 500 ms end-to-end, < 20 ms marginal in-daemon (measured, recorded in pm-baselines.json)
- [ ] Kill -9 a scenario host mid-verify → CLI receives structured error verdict; daemon survives (test scripted)
- [ ] `examples/ConsumerApp` (separate package) fully verifiable through the CLI with zero changes to VerdictUI source
- [ ] Binary signed + notarized (spot-check `spctl -a -vv`)
- [ ] PM quick Grade A including new `stage_cli_smoke`

### Risks

- **Dylib/host lifecycle** is the hard part — the child-process-per-build design dodges unload bugs at the cost of one process spawn per rebuild (~100 ms, acceptable). Do not attempt in-process reload "optimization" without an ADR.

---

## Wave 7 — MCP server: the agent-native surface

**Objective**: agents stop shelling out — `verdictui mcp` exposes the engine as MCP tools
with token-frugal responses. This is where the product plugs into Claude Code / Cursor
and the loop the whole project exists for closes.

### Tasks (ordered)

1. **MCP server** (stdio transport; reuse daemon broker internally):
   - Tools: `list_scenarios`, `render(scenario, variant?) → semantic tree`, `verify(scenario, rules?, baseline?) → verdict`, `act(scenario, action|flow) → step/flow result with delta`, `sweep(scenario, matrix) → report`, `baseline_diff(scenario)`, `baseline_accept(scenario, confirm: true)` (destructive-action confirmation per SD4).
2. **Token-frugal wire format** (this is a product feature, per web-gap research):
   - Trees serialize as compact node-table + parent-index arrays (not nested JSON); repeated strings interned; response caps with `truncated: true` + `focus(nodePath)` follow-up tool.
   - Deltas-by-default: `act` returns `TreeDelta`, never the full tree unless `include_tree: true`.
   - Measure: full demo-app tree ≤ 2 KB serialized; typical act delta ≤ 300 bytes.
3. **Contract pinning**: `contracts/mcp-tools.md` (tool signatures + examples) + fixture-based contract tests (`validate-contracts.py` extended).
4. **Live dogfood**: register the MCP server in this machine's Claude Code config; run an agent session that (a) breaks a demo view, (b) sees FAIL verdict with suggestion, (c) fixes it, (d) sees PASS — capture the transcript into `docs/dogfood-session.md`. **The product's first real usage is its own acceptance test.**

### Exit gate

- [ ] End-to-end agent session documented: edit → verify FAIL (evidence cited) → fix → verify PASS, no screenshots involved
- [ ] Wire-size budgets met (tree ≤ 2 KB, delta ≤ 300 B on demo app; enforced by contract test)
- [ ] Destructive baseline-accept requires explicit `confirm` (contract test)
- [ ] MCP tools respond < 100 ms warm (measured through the actual stdio transport)
- [ ] PM quick Grade A

---

## Wave 8 — Cross-validation: the honest middle loop

**Objective**: keep the fast channel honest. External witness (AX tree + real event
injection + windowless capture) reconciles against the in-process stream; divergence
becomes a finding. Answers "how do we know the probes aren't lying?" with machinery, not
promises.

### Tasks (ordered)

1. **`VerdictUIWitness` target** (separate library — Accessibility deps stay out of the core):
   - AX reader: `AXUIElement` tree of the scenario-host window (the ONE component that runs windowed, and only in middle-loop mode), normalized into `SemanticNode` via the shared role vocabulary (Wave 1 payoff).
   - Real actions: `CGEventPostToPid`-targeted clicks/keys at probe-frame coordinates, plus `AXUIElementPerformAction` fallback.
   - `AXObserver` push notifications (layout-changed, value-changed) as the settle signal for the external channel — no polling.
2. **Reconciler** (kernel):
   - `Reconcile.compare(internal: SemanticNode, external: SemanticNode) -> [Finding]` — role/frame/text agreement within tolerance; probed-but-AX-invisible nodes → `axVisibilityGap` finding (doubles as a free **accessibility audit**: unlabeled controls surface here — note as marketing point).
3. **Permission handling (SD6)**: `AXIsProcessTrusted` check up front; without permission the middle loop returns a verdict whose findings include `warning: cross-validation skipped (no Accessibility permission)` — never a silently weaker PASS. Grant flow documented in runbook.
4. **Deliberate-lie fixtures (SD1)**: demo scenarios that misreport (probe with hardcoded wrong frame; view that renders differently than its probe claims via clipping trick) — reconciler MUST catch every planted lie (this suite is the honesty proof; wire into PM full mode).
5. **CLI/MCP integration**: `verify --cross-validate` / `verify(cross_validate: true)`; verdict `timing` gains `crossValidateMs`; document trust levels (`inner-only` vs `cross-validated`) in the schema (`schemaVersion 1.1`).

### Exit gate

- [ ] Every deliberate-lie fixture caught (100% — this number is non-negotiable)
- [ ] Cross-validated verify on demo app < 5 s per scenario (new SLO 3 added to docs/slo.md)
- [ ] Permission-absent path returns explicit warning finding (SD6 test)
- [ ] AX-gap findings verified useful: run against SagaMail's main window once, file findings as CIS issues (dogfood + fleet value)
- [ ] PM quick Grade A (lie fixtures in full mode)

---

## Wave 9 — Pixel channel: the deterministic exception path

**Objective**: for the questions geometry can't answer (gradients, shadows, image
content, font rendering), a screenshot-class channel that is deterministic, cached, and
diffed structurally — pixels as evidence of last resort, never the default.

### Tasks (ordered)

1. **Capture** (`VerdictUIProbe/PixelCapture.swift`): windowless `NSHostingView.cacheDisplay` (matches Wave 2 host, scale pinned 1.0) + `ImageRenderer` alternate backend (flag) — document divergence between the two backends honestly.
2. **Determinism hardening**: font smoothing/hinting pinned via context flags; assert stability by double-render byte-compare before any baseline is written (auto-detect nondeterministic scenarios and refuse pixel baselines for them with a clear error).
3. **Structural diff** (kernel-adjacent `PixelDiff.swift`): ODiff-style perceptual compare (per-channel tolerance + anti-aliasing awareness); diff artifacts (before/after/heat) written to `logs/pixel-diffs/` and referenced by path in findings.
4. **Region-scoped pixels**: `expectPixels("hero-image", matches: baseline)` — capture cropped to a probe's frame; keeps baselines small and failures attributable to a node.
5. **Render cache**: subtree-hash (semantic tree + relevant state) keyed pixel cache in `~/.verdictui/cache`; SD4 invalidation test — any input change (locale, scheme, state, source rebuild id) must miss.
6. **CLI/MCP**: `render --pixels`, findings carry artifact paths; MCP returns paths not image payloads (token frugality).

### Exit gate

- [ ] Double-render determinism check green across all demo scenarios on this machine
- [ ] Pixel diff catches a planted 1-px border-color regression that all semantic rules miss (the channel's existence proof)
- [ ] Cache: warm pixel verify ≥ 10× faster than cold; invalidation test green
- [ ] Nondeterministic scenario (embedded `Date()`) correctly refused with actionable error
- [ ] PM quick Grade A

---

## Wave 10 — Proof, hardening, release

**Objective**: dogfood at fleet scale, benchmark against the thesis, and ship: MIT
engine on GitHub public, Homebrew tap, docs site, launch collateral.

### Tasks (ordered)

1. **Fleet dogfood**: adopt in SagaMail and PanoMac (KastDrive optional third) — one real screen each through macro adoption; file every friction point as a CIS issue against VerdictUI; fix P0/P1 before release. Success = an Opus session on SagaMail using VerdictUI MCP instead of screenshots for a real UI task.
2. **Benchmark report** (`docs/benchmarks.md`): VerdictUI inner loop vs screenshot cycle vs XCUITest on the same 5 verification tasks — wall-clock, token cost, flake rate over 100 runs. Honest numbers including where XCUITest still wins (outer-loop truths).
3. **Hardening**: `/verdictui-audit` full run (all 10 phases + SD1–SD6); fuzz the MCP input surface; API audit for 1.0 semver.
4. **Release engineering**: LICENSE (MIT), CONTRIBUTING, public repo flip (or mirror), Homebrew tap (`medlars/homebrew-tap`), `stage_auto_release` flipped True in CEO PROPAGATION_PATTERNS + PM wiring, appcast/release-data for CLI updates.
5. **Docs site** (verdictui.com — register domain first, TODO P1): quickstart, the three-loops explainer, rule catalog, MCP setup for Claude Code/Cursor, benchmark page. Astro on Cloudflare Pages as a `surfaces` entry in pm-registry (hub rule #8 — NOT a separate project); `stage_live_smoke` added to PM per fleet rule F-051.
6. **Launch**: README with the dogfood GIF, Show HN / Swift forums post drafts in `docs/launch/`, open-core boundary ADR (engine free; hosted baseline/team layer reserved) recorded in `.decisions/`.

### Exit gate

- [ ] SagaMail + PanoMac sessions verified working through VerdictUI MCP (transcripts saved)
- [ ] Benchmark report complete with honest loss-column
- [ ] `/verdictui-audit` full: zero P0/P1 open
- [ ] Public repo + Homebrew install path verified from a clean machine account
- [ ] verdictui.com live, `stage_live_smoke` green, PM Grade A
- [ ] CHANGELOG 1.0.0 entry; goals.md + roadmap.md milestones updated

---

## Cross-wave engineering rules

1. **Session protocol**: start with `/verdictui`; end with PM Grade A + updated FILE_REGISTRY/CHANGELOG/roadmap + CTS ticket closure with evidence.
2. **Never weaken a gate to pass it** — if an exit criterion is wrong, change it via ADR, not by deletion.
3. **Test-alongside** every source file (PM `stage_test_alongside` enforces).
4. **Determinism debt is P0** — any nondeterministic test output is fixed before new features.
5. **Evidence in tickets**: CIS/CTS closures carry runner-sourced output, not narratives.
6. **Schema changes** bump `schemaVersion` + fixture + migration note in contracts/ — agents parse this wire format; breaking it silently breaks every consumer.
