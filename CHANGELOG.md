# Changelog

## [Unreleased]

### 2026-08-07 (Wave 4 Task 2)

**The body walk — `@Verifiable` now buys a semantic tree, not just a root.**

- **`BodyProbeWalk`** rewrites a copy of the view's `body`, attaching
  `.verdictProbe(id:role:text:)` to every recognised element (`Text`, `Button`,
  `Toggle`, `TextField`, `SecureField`, `Image`, `List`). Ids come from source
  structure — `Row.text.0`, `Row.image.0` — so they are stable across runs and
  readable in a finding. An unprobed `Text("hello")` now reaches the kernel as a
  `.text` node instead of vanishing into a bare root.
- **Recognition is by callee identifier, through the modifier chain.**
  `Text("x").padding().foregroundStyle(.red)` is still a `Text`; nearly every
  real element carries modifiers, so a walk matching only bare calls would probe
  almost nothing while passing a suite written with bare elements. Matching on
  the parsed callee rather than on expression text is what keeps `myText(…)` from
  being probed as a `Text` (lesson 213).
- **An explicit probe always wins.** An element already carrying
  `.verdictProbe` is left exactly as written — re-probing would give one element
  two ids and make `DuplicateProbeIDRule` report the instrumentation itself as a
  defect.
- **A body the walk cannot rewrite is REPORTED, not silently passed through.**
  A multi-statement `body` gets a named error at the attachment site. The
  alternative — expanding to an unprobed passthrough — compiles, renders, and
  yields a tree with a root and nothing under it, so every rule reports PASS on a
  screen nobody instrumented. A false green is this product's worst failure.
- **Only literal text is forwarded as `text:`.** An interpolated string is not
  knowable at expansion time, and forwarding its source would put the literal
  `\(name)` where `TruncationRule` reads what the user sees. A false value is
  worse than an absent one, because the rule acts on it.
- **`RoleVocabularyTests` pins the walk's role strings against the kernel's
  `Role`.** The plugin cannot import `VerdictUIKernel` — it builds for the host
  toolchain — so the roles it emits are string literals, and an unknown one
  decodes to `Role.custom` rather than failing: silent loss of coverage, not a
  compile error. The test target can see both modules, so that is where the two
  spellings are made to meet (lesson 284).
- **Known cosmetic limitation, measured rather than assumed.** A multi-line body
  keeps the indentation it had inside `body`, because the expression is lifted
  out of it. `SwiftBasicFormat.formatted()` was tried and removed: it supplies
  trivia only where trivia is *absent*, so it indented the walk's new lines and
  left the original closing brace untouched; stripping trivia first makes it emit
  flat output. There is no re-indent facility in SwiftSyntax to reach for. The
  snapshot pins what the macro actually emits.
- **354 Swift + 178 Python tests, 50 mutation targets** (was 344 / 178 / 45).

### 2026-08-06 (Wave 4 Task 1)

**`@Verifiable` — the macro target, kept optional by construction.**

- **New targets.** `VerdictUIMacros` (a `.macro` compiler plugin) and
  `VerdictUIMacroSupport` (the library a consumer imports), plus a
  `VerdictUIMacroTests` target. `@Verifiable` attaches to a `View` struct and
  generates `verdictProbedBody(into:)` — the view's own `body` wrapped in
  `.verdictRoot(into:)`. The view's `body` is not rewritten, so a `@Verifiable`
  view renders identically in an app and in a preview.
- **Macros are an opt-in product, not a probe dependency.** SwiftSyntax is the
  heaviest thing in the graph: a clean probe-only build is **9.48 s** against
  **21.34 s** for the whole package. `VerdictUIMacroSupport` is therefore its own
  product, so a probe-only consumer never resolves SwiftSyntax at all.
  `Tests/test_macro_isolation.py` pins that structurally — no shipping target may
  reach SwiftSyntax, the plugin must stay `.macro` (a plain `.target` would link
  it in), and the dependency must stay pinned `exact`. None of those failures is
  visible to `swift test`, because none of them changes behaviour.
- **SwiftSyntax pinned `exact: "603.0.2"`**, verified building a plugin against
  the local Swift 6.3.3 toolchain before it was written into the manifest. Majors
  track the compiler, so a range would let a toolchain-coupled dependency move
  under CI without a commit saying so.
- **Misuse is diagnosed at the attachment site** — a non-struct or a type with no
  `body` gets a named error there, rather than a compile failure inside generated
  code the author cannot see. Each kind carries its own article, because two of
  the six begin with a vowel and a hardcoded "a" produced "this is a enum".
- Mutation catalog 42 → 45 rows, all three manifest-shaped and each verified
  NOTICED with a byte-identical restore.
- 332 → 344 Swift tests, 172 → 178 Python tests.

### 2026-08-06 (later)

**New rule `content-overlap` — the overflow no single container can be blamed for.**

- **`sibling-overlap` was blind by construction to the most common real VStack
  overflow.** It compares children of one parent, so a `Text` that outgrows its
  row and covers the *next* row's text — different parents — was never compared,
  and the engine returned PASS on a visibly broken screen. `ContentOverlapRule`
  compares leaf content across unrelated branches, leaving ancestors, direct
  siblings and containers themselves deliberately silent so ordinary nesting
  does not report. Layering (`zIndex`, a `zstack` ancestor) is honoured along
  the whole ancestor path. `RuleEngine.standardRules` is now **seven** rules.
- **The docs rule-count no longer pins a literal.** A hand-written count
  describes the moment someone last typed it, not the catalog; the test now
  counts the document's own catalog headings, which also catches the reverse
  drift a `contains` loop cannot see — a section for a rule that no longer
  exists in the standard set.
- Mutation catalog 38 → 42 rows. One of the four was UNNOTICED on the first
  sweep and correctly so: the ancestry guard is unreachable from `evaluate`
  (only leaves become subjects), so its witness was repointed to a direct seam
  assertion. Verifying that a target's TEXT resolves is not verifying that the
  named test can execute the branch.

### 2026-08-06

**Wave 1–3 audit — three P0s, each reproduced before it was fixed.**

- **A NaN frame passed all six lint rules.** Every comparison against NaN is
  false, so `Rect.isEmpty` answered "this renders" and `intersects` — a negated
  disjunction — answered "on screen". A button with a NaN frame produced
  `status=pass, findings=0`; it now produces a `zero-size` error naming the node.
  Fixed once in `Rect` (non-finite components, origin included, count as empty)
  rather than in six rules, because it was one arithmetic fact with six
  symptoms. NaN is what a broken layout actually produces, so the engine was
  silent on exactly the shapes it exists to catch.
- **`settle()` reported quiet 5.6 ms in, with a mutation pending 40 ms out.**
  `requiredAgreeingChecks` is a count with no time dimension, and two checks are
  one `pumpInterval` (5 ms) apart. `LayoutSettle.pump` now also requires the
  quiet token to hold for `minimumQuietInterval` (30 ms), charged in `settle()`
  alone — applying it inside `pump` unconditionally costs the floor three times
  per `perform()` and measured p95 109.9 ms against a 100 ms SLO. **SLO 1 moves
  from p95 20.9 ms to 53.8 ms**; the honesty is the reason.
- **The Swift half of the mutation catalog was unguarded.** `--verify-targets`
  checked only that the mutated text exists, never that the named witness test
  does, so a renamed test left it reporting "all 31 targets resolve". The pytest
  half had had a `--collect-only` existence check since Wave 2.

Governance, from the same audit:

- `stage_pytest` — CI ran the Python suite from Wave 0 and the PM never did, so
  a local Grade A was strictly weaker than a CI pass and the PM's own
  correctness tests were unreachable from the PM.
- `stage_lint` now runs `ruff format --check` as CI does (this session pushed a
  red build from a locally-green tree), and `stage_build`/`stage_test`/
  `stage_lint` now fail **closed** when their tool is missing. The test that
  pinned the lint fail-open as correct behaviour was rewritten.
- The demo catalog is checked against the filesystem instead of three
  hand-maintained counts that only ever agreed with each other.

Mutation catalog 31 → 34 rows, each verified by hand with a byte-identical
restore. 314 Swift + 168 Python tests.

- **Wave 3 complete.** Task 4 `Harness` (`perform` = tree → act → settle → tree →
  diff → lint in one call; `run` batches with early exit) gained the verification
  half it shipped without — 16 tests over every return path, including the act-
  failure and settle-timeout paths that build their own `Verdict`. `stoppedEarly`
  is pinned to mean *skipped work*, not failure.
- Wave 3 Task 5: hostile settle suite — perpetual motion, deferred async mutation,
  debounced input, rapid successive actions. Each carries a control, so "times out"
  cannot be satisfied by an engine that times out on everything.
- Wave 3 Task 6: **SLO 1 formally met and enforced.** `HarnessPerformanceTests`
  measures act→settle→verdict at p50 19.9 ms / p95 20.9 ms (n=60) against the
  100 ms budget, and PM `stage_runtime_bench` gates it. The stage fails on a
  missing `SLO1-PERFORM` line or a zero executed-test count, because
  `swift test --filter` exits 0 when it matches nothing.
- Fixed an order-dependent flake in `testOscillatingLayoutTimesOutWithDeltaEvidence`:
  its 4 ms mutation timer raced `LayoutSettle.pumpInterval` (5 ms), so a loaded run
  loop could fit two quiet checks between ticks and the test accused the engine of
  settling early. The interval now derives from `pumpInterval`.
- Registered `pm-baselines.json` in `docs/FILE_REGISTRY.md` — ADR 2026-002 tracked
  the file but never listed it, leaving the registry guard red on main.
- **Fixed a lost-cancellation race in `VerdictClock.sleep(until:)` that hung the
  entire test suite roughly one run in three.** `withTaskCancellationHandler`
  invokes `onCancel` immediately on the cancelling thread — it does not wait for
  the operation body to suspend. A `cancel()` landing between `sleep`'s
  `Task.checkCancellation()` and its continuation registering therefore found an
  empty `waiters` map, resumed nothing, and never fired again; the body then
  registered a waiter releasable only by a 60-second virtual advance that never
  came. The leaked continuation left `task.value` suspended forever, and because
  XCTest runs an `async` test by blocking the *main* thread in
  `invokeWithAsynchronousWait`, the whole `xctest` process wedged at 0 % CPU with
  no VerdictUI frame on the stack — which is why it read as an XCTest fault
  rather than ours. Cancellation is now recorded under the same lock that guards
  `waiters`, so whichever side runs second resumes the continuation exactly once.
  `testCancellationRacingRegistrationIsNeverLost` repeats the race 200 times
  under an independent per-attempt timeout: it fails in ~5 s against the old code
  and passes in 4 ms against the new, and it can never re-hang the suite.

### 2026-08-05

- Wave 3 Task 1 (settle engine foundations): `VerdictClock` (manual `Clock` with
  `advance(by:)`), `SettlePolicy` (`.skipAnimations` default / `.runAnimations`),
  `AnimationControl.apply`, and `OracleHost.applyStateChange` + `\.verdictClock`
  environment injection. Animation control uses `Transaction(animation: nil)` —
  not the unwritable `accessibilityReduceMotion` key.
- Wave 3 Task 2: `Quiescence` / `OracleHost.settle(timeout:)` composes main-queue
  drain, probe-recorder activity, tree stability, virtual-clock waiter census, and
  `CATransaction.flush` on top of `LayoutSettle`. Timeout returns
  `SettleResult.timedOut(lastDelta:)` and a FAIL `settle-timeout` verdict.
- SLO 1 warm `currentTree()` gate aligned to `docs/slo.md` (< 100 ms p95); the
  prior 50 ms Wave 2 stretch failed CI under load (~55 ms p95).
- Wave 3 Task 3: `ProbeAction` in-process injection via `ScenarioState` bindings
  and `.verdictProbe(..., action:)`; `OracleHost.apply(_:)`; `ToggleLayoutScenario`
  driven by a real binding. Trust levels (inner vs Wave 8 real events) documented
  in `docs/kernel.md`. Probe action registration runs during view evaluation (not
  `onAppear`); toggle/unknown-probe guards are mutation-catalogued.

### 2026-08-04

- `CLAUDE.md` is now pinned by `Tests/test_claude_md_ssot.py`. The page every session
  is told to read first had rotted unnoticed: its Single-Source-of-Truth table promised
  the Layout probe as future work after Wave 2 shipped it, and named `VerdictFramesKey`,
  which survives only in a historical comment. A table that sends the next session to the
  wrong file causes the second implementation it exists to prevent. The guard resolves
  every SSoT row to a real file and symbol and checks all 18 repo-relative paths the page
  names; two catalog rows in `scripts/mutation-check.py` prove it notices when they lie.
- Rules 5–7 added to `CLAUDE.md`: subagent scoping and worktree isolation, exit-code and
  mutation discipline, and the requirement that a schema shape change moves
  `SchemaVersion`, the JSON schema, and the fixtures together. These had been retyped into
  every session prompt instead of living in the repo.
- `docs/FILE_REGISTRY.md` is now enforced by `Tests/test_file_registry.py`. It calls itself
  the single source of truth for source files, but the only thing measuring that claim was
  `floor-check.py` asserting the file exists. Three files had reached `main` with no row —
  `Tests/test_mutation_check.py`, `Tests/test_claude_md_ssot.py`, and `scripts/mutation-check.py`
  itself, a peer of two scripts that were listed — and each was found by hand, one audit at a
  time. The guard runs both directions — every tracked source file has an **Active** row, every
  active row still names something real — and takes its file list from `git ls-files` rather
  than a fixed set of directories, so source added somewhere new is covered instead of quietly
  unscanned. Both scope lists that remain are self-policing: a tracked file whose type nobody has
  classified fails the run rather than dropping out of scope — by name for extensionless files,
  so a future `Makefile` cannot be waved through as `.gitignore` was — and the status cell is
  checked in both directions,
  because a row flipped out of `Active` would otherwise satisfy completeness while being skipped
  for existence. Follows `Agents/tests/test_file_registry_parity.py`, which solved the same drift.
- The mutation harness's node-id guard now asks pytest to collect the ids instead of checking
  that they look like ids. It only required the shape `file::Class::test`, so a wrong class
  name or a renamed method still selected nothing — which the harness scores INCONCLUSIVE,
  reading as "not proven yet" rather than "this entry is broken". Found because an external
  write dropped `TestClaudeMdSSoT::` from two entries after they were committed green.

- Wave 2: probe runtime + oracle harness. Any SwiftUI view wrapped in a probe scenario
  now renders **headless** — no window, no window server — and yields a `SemanticNode`
  tree with real layout-engine frames. Screenshots become optional here.
  - **Pre-wave spike** (recorded in `docs/implementation-plan.md`): windowless
    `NSHostingView` proven to need no window server, verified against a sandbox
    profile that denies every windowserver mach-lookup _and_ a positive control
    that fails under the same profile. The whole 248-test suite also passes under
    that denial.
  - **`ProbeLayout`**: byte-transparent `Layout` wrapper recording size negotiation
    (proposal, returned size, placement) plus unconstrained-intrinsic and
    width-constrained-ideal measurements into a `@MainActor ProbeRecorder`.
    Explicit alignment guides are forwarded (CIS-39FB61BC): declared
    `.alignmentGuide` values were silently dropped; an empirical 20-shape battery
    showed guide evaluation always happens in the layout's own unoffset space, so
    the forwarding is untranslated, with a canary test watching that assumption.
  - **Probe pipeline**: `.verdictProbe(id:role:text:attributes:)` emits
    `ProbeRecord`s in the named `verdict-root` coordinate space;
    `.verdictRoot(into: VerdictTreeSink)` assembles the `SemanticNode` tree —
    frame-containment nesting, layout-order siblings, probe ids winning over
    structural paths, and `TextMetrics` attached only where a real measurement
    matches the rendered frame (never guessed).
  - **`OracleHost`**: windowless harness with a pinned deterministic environment
    (displayScale 1, en_US, Gregorian/UTC, light scheme, medium type, LTR),
    `fittingSize` or explicit-viewport sizing behind a 4096 pt clamp exposed as
    `wasClamped`, and a reusable `LayoutSettle` pump (two agreeing checks, hard
    deadline) that throws `settleTimedOut` rather than fabricating an empty tree.
    `accessibilityReduceMotion` is documented as uninjectable (get-only key path).
  - **`VerdictScenario` + `ScenarioState`**: the scenario protocol; state is
    deliberately minimal until Wave 3 actions and Wave 5 sweeps land.
  - **Demo catalog** (`VerdictUIDemoScenarios` + `VerdictUIDemo` executable): five
    planted defects each caught by exactly the intended rule (`truncation`,
    `sibling-overlap`, `offscreen`, `tap-target`, plus a toggle-driven Wave 3
    fixture) and a non-trivial clean scenario guarding against false positives.
    The executable prints one verdict JSON per scenario.
  - **End-to-end proof**: integration tests pin every planted finding (rule,
    severity, node, count) from a table the tests own; 10 fresh hosts × 2
    scenarios produce byte-identical encoded trees; a staged-layout determinism
    arm fails if the settle logic weakens (found because the exit gate's own 10×
    test could not distinguish "identical" from "identically wrong").
  - **SLO 1 baseline recorded**: warm `OracleHost.currentTree()` on the demo app —
    p50 5.99 ms, p95 6.60 ms (n=120), ~7.6× inside the 50 ms exit-gate bar,
    enforced by `OraclePerformanceTests`.
  - Swift tests 157 → 248; every task implemented in an isolated git worktree with
    scope-checked diffs, and every guard mutation-verified with byte-identical
    restores.
  - **Post-wave review pass** (three reviewers reading the closed wave cold; 248 →
    261 tests):
    - `TextMetrics` withheld its derived line counts only for `\n`, so a bare CR,
      CRLF, NEL or U+2028/2029 slipped through and both counts came out silently
      wrong for multi-line text. Now keyed on `Character.isNewline`.
    - A thrown `OracleHostError` left the demo executable through the runtime's
      unhandled-error trap — SIGABRT, exit 134, nothing readable on stderr. Now
      exit 1 with the scenario named, and stdout is one complete JSON document or
      empty, never partial (`no.md` entry 9).
    - A probe id starting with `@` collided with the identity namespace reserved
      for unprobed nodes, silently degrading `TreeDiff` to positional matching
      with no finding to show for it. Refused up front.
    - Nesting `verdictRoot` hands the outer collector the inner root's viewport;
      documented as unsupported rather than left to look correct.
    - The environment pins moved to a shared `View.verdictPinnedEnvironment()`
      and are applied by the test hosts too, which had been measuring glyph
      widths against the machine's own locale and type size.
    - A measurement filter in `assembledTree` was deleted: mutation testing
      showed no test could see it, and the reason was that it changed no output.
      It read like a guard against stale data while guarding nothing.
    - CI now runs the demo executable, which it previously only compiled.
    - `scripts/mutation-check.py` records the 11 mutations behind these guards;
      a compile failure or a trap counts as inconclusive, never as coverage.
  - **Second review pass — the harness that judges the guards.** The findings
    above were verified by `scripts/mutation-check.py`, so an audit of the
    fixes had to audit it too. It was deciding "covered" from a nonzero exit
    code alone:
    - It never ran the named test on unmutated source first. A test that was
      already red fails with the mutation applied as well, so every mutation
      aimed at it reported NOTICED — coverage claimed on a red witness. A green
      baseline is now a precondition.
    - `swift test --filter` exits **0** having executed zero tests when the
      name matches nothing, so a renamed test read as "uncovered guard" rather
      than "this catalog is stale". Both runs assert a nonzero executed count,
      and stale names are reported as inconclusive.
    - Its own new tests caught a third: `check` still assembled its own
      `swift test` argv instead of calling the extracted helper, so the
      baseline and mutated runs went through different code paths.
    - `Tests/test_mutation_check.py` (42 tests) pins all three lying modes.
      `--verify-targets` is the cheap half — no build, just "does each target
      still resolve to exactly one site" — and PM runs it every pass.
  - **Pipeline parity.** PM never ran the demo executable that CI has run since
    the first pass, so a local Grade A meant strictly less than a CI pass;
    `stage_demo` and `stage_mutations` close that. Also: `__doc__.splitlines()`
    crashed under `python -OO` (CIS-3BA814D7), `git_is_clean()` used
    `git diff --quiet` and saw neither staged nor untracked files, and
    `renderJSON` did not forward the `deadline` seam, leaving the function
    `main.swift` actually calls unreachable on its failure branch.
  - **`ProbeLayout.measure` keeps its `union ?? .zero` fallback**, after an
    attempt to remove it was reverted. SwiftUI elides empty content before a
    custom `Layout` is instantiated — verified against both `EmptyView` and an
    empty `ForEach`, neither of which records a measurement at all — so the
    fallback is unreachable, and rewriting it as a reduction seeded with `.zero`
    looked like a clean way to delete a branch no test can enter. It is not:
    seeding puts a `max(0, _)` on the **single-subview** path, and `max(0, -5)`
    and `max(0, .nan)` are both `0` in Swift (measured). A wrapper documented as
    returning its subview's answer byte-for-byte would have silently rewritten
    negative and NaN dimensions. An unreachable `??` beats a reachable
    misstatement (`no.md` entry 10).
  - **Third review pass — the stage that was not running what it claimed.**
    `stage_demo` shipped as `swift run VerdictUIDemo -Xswiftc -warnings-as-errors`.
    Everything after the target name is the _executable's_ argv, so the strict
    flags were never applied — confirmed by appending a flag `swift` itself
    would reject and watching the run exit 0 — and, because the configuration
    then differed from `stage_build`'s, the stage rebuilt the package instead of
    reusing it. Flags now precede the target.
  - **The mutation harness learns a second runner.** Every guard added in the
    previous pass was Python, and the harness could only run `swift test`, so
    the rule that each new guard is mutation-verified had quietly stopped
    applying to exactly the code doing the verifying. `Mutation` now carries a
    `Runner`, `pytest` node ids are first-class, and the four Python guards
    (flag order, empty verdict array, empty mutation catalog, broken-build
    diagnosis) are mutated like the Swift ones — 17 mutations, both languages.
  - Also in this pass: an **empty `MUTATIONS` list** made both `--verify-targets`
    and a full run print success and exit 0, so emptying the catalog would have
    turned PM's stage green by deleting what it checks; and `baseline_problem`
    reported a **tree that does not build** as "has the test been renamed?",
    since both execute zero tests.
- Wave 1: the verdict engine. `VerdictUIKernel` now owns the whole path from a probed
  tree to a machine-readable verdict, and stays platform-pure while doing it.
  - **Semantic tree**: `Role` vocabulary mirroring SwiftUI's accessibility roles,
    `attributes` (three primitive cases), `isVisible`/`zIndex`, `TextMetrics`, and
    `structuralPath` for unprobed nodes.
  - **`TreeDiff`**: `TreeDelta` with added/removed/moved/changed, id-first O(n)
    matching, and an `apply` that replays a delta onto the before-tree exactly —
    property-tested against random mutations.
  - **Rule engine**: `LintRule`, `LintContext` (viewport, platform minimums,
    per-node suppression, severity overrides, disabled rules), `RuleEngine.run`
    producing byte-stable findings.
  - **Six rules**: `duplicate-probe-id`, `zero-size`, `sibling-overlap`,
    `offscreen`, `truncation`, `tap-target` — each with an explicit suppression
    path and a message that names the measurement that fired it.
  - **Verdict schema v1**: `SchemaVersion` with a major/minor compatibility
    contract the decoder enforces, the `Verdict` envelope
    (`schemaVersion`/`scenario`/`timestamp`/`status`/`findings`/`tree?`/`delta?`/`timing`),
    and `contracts/verdict-schema.json`. Absent fields are omitted, never `null`.
  - **Contract gate**: `contracts/validate-contracts.py` now checks schema
    integrity, agreement between the schema and `SchemaVersion.current`, and a
    round-trip of encoder-generated fixtures under `contracts/fixtures/`. Wired
    into the PM as `stage_contracts`.
  - **Docs**: `docs/kernel.md` — role vocabulary, rule catalog with a real failure
    example and suppression path per rule, diff and schema reference. Pinned to the
    source by `KernelDocumentationTests`.
  - 154 kernel tests, 75 Python tests, `scripts/kernel-symbol-audit.py` reporting
    zero doc or test gaps across 214 public kernel symbols.
- Wave 0: project scaffolded via /project-forge — buildable SPM package with seed kernel
  (`SemanticNode`, `Verdict`, sibling-overlap lint) and probe (`.verdictProbe(id:)`), full
  project floor, and the multi-wave implementation plan (`docs/implementation-plan.md`).
