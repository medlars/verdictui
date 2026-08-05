# Changelog

## [Unreleased]

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

- Wave 2: probe runtime + oracle harness. Any SwiftUI view wrapped in a probe scenario
  now renders **headless** — no window, no window server — and yields a `SemanticNode`
  tree with real layout-engine frames. Screenshots become optional here.
  - **Pre-wave spike** (recorded in `docs/implementation-plan.md`): windowless
    `NSHostingView` proven to need no window server, verified against a sandbox
    profile that denies every windowserver mach-lookup *and* a positive control
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
    Everything after the target name is the *executable's* argv, so the strict
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
