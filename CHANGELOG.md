# Changelog

## [Unreleased]

### 2026-08-12 (Wave 7 dogfood — the loop closes, and the first real bytes found a defect no test could)

**Fixed**

- **No MCP client could complete a handshake.** `MCPRequest.params` was typed as
  the `tools/call`-specific `MCPCallParams`, whose `name` is non-optional — but
  `params` is free-form per JSON-RPC method, and `initialize`, the first message
  of every real session, fills it with `protocolVersion`/`capabilities`/
  `clientInfo`. A strict decode rejected the whole ENVELOPE, so the message never
  reached the correct `initialize` handler sitting four lines below, and every
  real client's opening message was answered with `-32700 parse error`.

  Three layers were blind for one reason: the suite's handshake test sends
  `initialize` with **no `params` key at all** — the one spelling that decodes
  either way; `stage_transport_smoke` sent that same payload and asserted only
  the reply COUNT, which cannot see this, **because a parse error IS a reply**;
  and the contract documented the tools but not the handshake. Now: `params`
  decodes leniently (`callTool` still rejects a missing one as a tool-level
  error, so a malformed `tools/call` fails as that call rather than as the
  connection), pinned by `testTheHandshakeARealClientSendsIsAnswered` with a
  paramless `tools/list` control, by a mutation row, and by the gate asserting
  the handshake SUCCEEDED. Recorded as `no.md` #37.

**Added**

- **`docs/dogfood-session.md`** — Wave 7's exit-gate transcript, run against the
  shipped binary and pasted verbatim: `demo-clean-settings` PASS → a Save button
  shrunk to 24 pt → **FAIL, exit 1**, citing `tap-target` on `save-button` with
  both measurements and the fix → the same failure over MCP at `isError: false`
  → fix → **PASS, exit 0**, with `git diff --stat` empty. No screenshots, no
  window server, 0.32 ms of engine time.

- **Warm MCP latency, measured through the real stdio transport** (30 samples,
  one long-lived process): `verify` **p50 9.61 ms / p95 10.25 ms**,
  `list_scenarios` p50 0.08 ms — against the gate's 100 ms.

**Known gap**

- The plan's `act` tool and its 300 B delta budget are **unbuilt** — `tools/list`
  returns `list_scenarios`, `render`, `verify`, `sweep`, `baseline_diff`, and the
  contract documents no `act` either, so only the plan names it. The delta budget
  therefore has no subject to measure. Tracked as **CTS-D47CCD1D**. The tree half
  IS enforced (362–839 B against 2048).

### 2026-08-11 (Waves 5–7 — the engine leaves the test target, and three green signals that proved nothing)

**Added**

- **`verdictui` CLI** (`Sources/verdictui`, `Sources/VerdictUICLICore`) — `list`,
  `render`, `verify`, `baseline`, `sweep`. The first time anything outside a test
  target can run a verdict.

  Exit codes are **three-valued** and the third is the point: `0` passed, `1` a
  verdict was produced and FAILED (the UI is wrong), `2` no verdict could be
  produced (says nothing about any UI). A tool that reports "not passing" for
  both an incorrect layout and an unreadable scenario forces every caller to
  treat an infrastructure fault as a product defect.

  All command logic lives in the LIBRARY, not the executable: nothing inside an
  `executableTarget` is reachable from a test in the same package, so logic
  living there would be verified by nothing.

- **`BaselineStore`** (kernel) — the storage half of baselines, and the one
  destructive operation in the product. Replacing a baseline requires `--accept`,
  prints the delta BEFORE the write, and appends the SUPERSEDED content's SHA-256
  to `logs/baseline-audit.log` (after the fact the question is *what did I
  destroy*; the replacement is still on disk for anyone who wants its hash).
  Creating a FIRST baseline needs no flag — a gate that fires on both branches
  teaches users to pass it reflexively. SHA-256 is hand-rolled because the kernel
  may not import CryptoKit, and is pinned to the published FIPS vectors rather
  than to its own output.

- **`VerdictDaemon` + `DaemonTransport` — the warm daemon, now reachable.**
  `verdictui daemon start|stop|status` binds `~/.verdictui/daemon.sock` and
  answers newline-delimited JSON-RPC, pipelining several frames per connection.
  `ok` reports whether the daemon could LOOK, never what it saw (a FAILING
  verdict is an ANSWERED request), and it deliberately serves no baseline
  update. `status` probes by CONNECTING, so a crashed daemon's leftover socket
  file reads as not-running rather than as a live server; the same probe lets a
  restart replace stale debris while refusing a genuine `addressInUse`.

- **`CompactTree`** — the token-frugal wire format: parallel arrays, a parent
  index, interned strings. 362–839 B against the plan's 2 KB budget.

- **`Expectation.onscreen`** — the predicate the DSL dogfood proved was missing.

- **`MCPServer` + `MCPTransport` — the MCP surface, now reachable.**
  `verdictui mcp` speaks MCP over stdio: `initialize`, `tools/list`,
  `tools/call`, `ping`. Every tool routes into `VerdictDaemon.handle`, so the
  CLI, the socket and MCP cannot drift into three answers. `isError` reports
  whether the tool COULD ANSWER, never what the answer was — a failing verdict
  arrives `isError: false`. A NOTIFICATION (no `id`) is answered with silence,
  as the protocol requires; replying to `notifications/initialized` is how a
  server presents as "never finished starting".

- **`stage_transport_smoke`** — drives the built binary as a subprocess over the
  MCP wire, asserting the catalog arrives and a failing verdict is not an error.
  A library test cannot see a process that will not start (`no.md` #32).

**Fixed**

- **A daemon and an MCP server with no transport, behind 14 green tests.**
  `handle()` and the tool catalog were correct and fully covered while nothing
  bound a socket or read stdin — and the docs described a live wire protocol,
  including a literal `nc -U` example against a path nothing created. The method
  surface without its transport is a library, not a service (`no.md` #34).

- **The published wire shape was never the shape that shipped.** Swift's
  synthesized encoding for an enum with associated values wraps the payload in a
  positional key, so the daemon sent `{"scenarios":{"_0":[…]}}` while
  `contracts/mcp-tools.md` documented `{"scenarios":[…]}`. Every test agreed with
  it, because they all round-tripped through the same `Codable`. `DaemonResult`
  now codes by hand and two tests assert on RAW JSON.

- **A blocking accept on the main actor.** `serve` ran `accept`/`read` on the
  main actor, which is also where SwiftUI renders — so the daemon could not
  render the scenario a request asked for, and deadlocked outright when a client
  shared the process (measured: a ten-minute hang with no output). The syscalls
  now run off-actor and only `handle` hops onto the main actor.

- **A binary that could not start, behind a green suite.** `main.swift` calling
  `VerdictUITool.main()` selects the synchronous overload on an async root
  command: it compiles, links, and fails at RUN time. 8/8 library tests passed
  against it. Fixed with `@main` in a file NOT named `main.swift`, and covered by
  a suite that runs the built artifact (`no.md` #32).

- **A DSL that could not express its own demo scenario.** An offscreen button
  satisfied `.visible`, `.role(.button)` and `.below(...)` at `x: 420` in a 320 pt
  viewport, because `isVisible` is always `true` from the layout pass and the
  viewport had no name in the vocabulary.

- **A lossy wire format.** `CompactTree` first dropped `textMetrics` and
  `structuralPath`; all six demo trees failed to round-trip. `TruncationRule`
  reads `textMetrics`, so a verdict computed from the far side would have
  reported a clean screen for a clipped label.

- **`ScenarioEntry` could not forward a `Variant`** — the stored closure dropped
  it, so `verdictui sweep` over a registered scenario would have rendered the
  baseline environment for every cell while labelling each with its variant name.

- **A SIGKILLed test runner reported as a test failure** (CIS-B3CE1A2C). A
  negative return code is a signal, not a verdict, and is now INCONCLUSIVE —
  checked before the count and failure branches, because a killed run leaves a
  partial log that routinely contains real-looking failures. A failure count with
  no runner summary is likewise inferred rather than reported.

- **Nine unverified mutation rows, not the seven the ticket claimed**, across two
  causes it collapsed into one: 5 non-compiling and 4 whose test filter matched
  nothing — those had been proving nothing before any mutation was applied, and
  two went stale in this session when a file split moved the tests they named.
  Sweep after: 90 NOTICED, 0 UNNOTICED, 2 unverified (`no.md` #33).

- **A guard that judged by spelling.** The macro-witness rule asserted
  `suite.endswith("MacroTests")`; it now asks whether the suite CALLS
  `assertMacroExpansion`.


### 2026-08-11 (Wave 5 Task 5 — state-machine scenarios, and a mutation row that proved nothing)

**Added**

- **`ScenarioStateMachine` + `Harness.walk`** (`Sources/VerdictUIProbe/StateMachine.swift`)
  — a screen described as named states plus the transitions between them, walked
  one path at a time with a verdict per step.

  The load-bearing decision is that a state carries an `ExpectationSet` and
  **arrival is checked, not assumed**. A machine whose states are only names
  produces a walk that applies every action, settles every time, and reports PASS
  while the UI never left the first screen — "walked login → dashboard →
  settings" as a clean path table, with no layer anywhere able to notice. So a
  state with no expectations is **rejected at construction**, along with three
  other structural defects that each yield a walk which *runs and reports*
  rather than one that can fail: a transition to an undefined state, a duplicate
  state name, and two edges leaving one state on the same action.

  The entry state is checked **before** any action, because a scenario that does
  not start where the machine claims would otherwise blame its first
  *transition* — sending debugging at an innocent action while the real defect
  goes unnamed. Multi-path walks build a fresh harness per path, since a path
  beginning where the previous one ended is not the path the caller asked for.

- `ProbeAction.description` — hand-spelled rather than derived from the enum,
  because it is both the transition label in evidence and the ambiguity key a
  machine validates on, and an interpolated case is a compiler detail that would
  not survive a toolchain upgrade. The *value* is part of it, so typing two
  different strings into one field is two edges rather than one collision.

**Fixed**

- A mutation row added in this same session scored **INCONCLUSIVE — the mutation
  did not compile**: deleting the `findings.append(contentsOf:)` statement left
  `tree`, `context` and `machineState` unused, which is an *error* under
  `-warnings-as-errors`. The row therefore executed zero tests while looking like
  a row. This is the fourth occurrence of the shape `no.md` #25 records. The `new`
  now calls `evaluate` and discards its result, keeping every binding live while
  breaking exactly the behaviour under test; hand-verified red (1 test, 3
  failures, citing zero findings) and green (21 tests, 0 failures) with a
  byte-identical restore.

**Found by the engine, in its own fixture**

- The first `PanelScenario` probed a bare `Text` as `role: .button`, which
  measured 28×16 pt, and `TapTargetRule` failed the transition step against the
  28×28 pt macOS minimum. The walk was right and the fixture was wrong — which is
  also the proof that a walk step carries its **lint** findings alongside its
  arrival check rather than only the latter.

**Measured**

- 552 Swift + 220 Python tests, 0 failures, zero warnings under
  `-warnings-as-errors`; PM quick **Grade A (100.0)**.
- Full mutation sweep on a clean exclusive tree: **92 rows, 84 NOTICED,
  0 UNNOTICED, 8 INCONCLUSIVE**, exit 0, byte-identical restore. One
  INCONCLUSIVE was this session's and is fixed; the other **seven are
  pre-existing and unproven** — tracked as CTS-D0942526 rather than left
  implicit behind a "0 UNNOTICED" headline.

### 2026-08-11 (Wave 5 Task 1 — rule library v2, and a harness that was lying about coverage)

**Added**

- Four kernel lint rules, taking the standard set from 8 to 12 and meeting Wave
  5's ">= 12 rules, each with false-positive tests" exit criterion:

  - **`empty-container`** (warning) — a container reserving visible area whose
    children all fail to paint. The blank box a `ForEach` over an empty array or
    a `nil`-bound detail pane leaves behind; no other rule can see it, because
    the frame is not zero and every rule iterates children that never arrived.
    Reports the **outermost** empty node per branch, so a blank
    `VStack { HStack { } }` is one finding rather than two, and keeps descending
    through a *suppressed* node so suppressing a wrapper reveals the empty child
    instead of blindfolding a subtree.
  - **`misalignment`** (warning) — the "2 px off" class, inside a measured
    0.5–4 pt window. Below it is float noise, at or above it is a deliberate
    indent; only the gap between can be a mistake. One finding per **node**
    naming its worst edge, because a box nudged sideways misses on `leading` and
    `trailing` simultaneously.
  - **`inconsistent-spacing`** (warning) — one gap breaking a single-axis
    stack's rhythm. Keyed on the **mode**, never the mean: with gaps
    `12, 12, 12, 12, 20` the mean is 13.6, so a mean-based rule reports all five
    including the four that are correct. Silent unless the modal gap holds a
    strict majority, so deliberately varied layouts produce nothing.
  - **`clipped-content`** (error) — content extending past an **ancestor's**
    frame, not merely its parent. The case that reaches a user is a label inside
    an `HStack` inside a card: the `HStack` grew to fit its child and pushed the
    overflow up a level, so a parent-only check passes every simple test and
    misses it.

**Fixed**

- `empty-container`'s first draft fired on `CleanSettingsScenario` — the
  reference *correct* UI whose entire job is producing zero findings — reporting
  `card-surface` and `card-pill`. From the layout pass a probed leaf that paints
  itself (a filled shape, a capsule background, a divider) is
  **indistinguishable** from a container whose content never arrived: both have
  zero children, and no attribute records whether a node draws. The rule now
  declines childless containers entirely and reports only the unambiguous nested
  case, pinned by its own test so nobody widens it back.

- The mutation harness was reporting **UNNOTICED for a guard that works**. A
  sweep row (`the two macros stop composing over a custom view`) failed to
  notice its mutation because `run_named_test` never re-stamped
  macro-consuming test sources: SwiftPM rebuilds a `.macro` plugin but does not
  re-expand macros in an unchanged consuming target, so the runtime witness
  executed the *previous* expansion. Applied by hand with the consuming tests
  touched first, the same mutation is NOTICED at exit 1 with 1 test executed,
  failing on `vacuous-verdict`.

  The row's own note asserted the trap "does not apply" here, reasoning from
  where `verdictProbing` lives rather than where the **mutated symbol** lives —
  true about the hand check, false about the harness, and unfalsifiable because
  it lived in a comment. Recorded as `no.md` #28. `refresh_macro_expansions()`
  now runs unconditionally on the Swift path, since baseline and mutated runs
  must differ only in the source; guarded by its own mutation row and a
  pytest-path negative control.

**Verification** — 478 Swift + 220 Python tests, 0 failures, zero warnings under
`-warnings-as-errors`, 84/84 mutation targets resolve to exactly one site.

### 2026-08-10 (cold-read: the passthrough overload had no runtime coverage)

**Added**

- `testANonVerifiableViewStillRendersThroughTheProbingOverload` — the
  `verdictProbing(_:)` **passthrough** overload, exercised at runtime for the
  first time. Until now it appeared only inside expansion snapshots, which
  compare generated *text* and cannot show that the resolved overload renders
  anything. That left the branch a consumer hits most often — most views in a
  real app are not `@Verifiable`, and the walk wraps every one of them —
  completely unexercised.

  Two drafts of this test were wrong before it was right, and both corrections
  are recorded at the call site. The fixtures had to move to **file scope**: a
  `#VerdictScenario` body referencing `TwoTokenAdoptionTests.X` rendered an
  empty tree (measured — *both* views missing, not just the plain one), because
  the macro lifts the closure into a generated struct at enum scope. And the
  assertion was inverted: the first version demanded the plain view's text
  appear in the tree, conflating **rendering** with **being measured**. The
  passthrough returns the view unchanged, so an unprobed view contributes no
  node. Asserting its *absence* — beside a `@Verifiable` sibling that must be
  present — is what makes the test discriminate, and it was negative-controlled
  by making the plain view `@Verifiable` and watching it fail.

### 2026-08-10 (Wave 4 complete — and the wave's headline claim was false until today)

**Fixed**

- **The two macros now compose.** Writing the test for the exit gate's claim —
  "a previously unprobed view gains full verification by adding exactly two
  tokens" — falsified it. A `@Verifiable` view rendered through a
  `#VerdictScenario` produced a tree with **no probed node at all** and a verdict
  of `vacuous-verdict`: the generated `verdictProbedBody` was never called by
  anything, and the scenario walk correctly declines to probe an opaque custom
  view. Fixed by ADR 2026-009 — `@Verifiable` also generates
  `verdictProbedContent` (no root) and conforms the type to `VerifiableView`;
  the walk wraps opaque view constructions in `verdictProbing(_:)`, whose two
  overloads resolve at compile time. No reflection, and a non-verifiable view
  costs nothing.

**Added**

- `docs/adoption.md` — three tiers (macro / manual / hybrid), composition,
  compile-time diagnostics, a limitations table, migration steps, and the
  measured build cost. It **leads with probe placement**, because a probe
  outside a `.frame(width:)` measures the frame and makes truncation invisible
  — verified both ways on a real consumer view.
- `TwoTokenAdoptionTests` — the exit-gate claim asserted rather than described,
  including a source-level guard that the fixture view stays unadorned. Without
  it, "exactly two tokens" is unenforced.
- A vocabulary-scale differential: macro tree ≡ hand-probed tree across all five
  recognised element kinds, with a node-count control so two empty trees cannot
  pass it.
- `runtime_witness_reason` on `Mutation` — a declared, length-checked per-row
  opt-out from the snapshot-witness rule (`no.md` #23), plus a tripwire test
  asserting how many rows use it. An undeclared escape hatch would let that rule
  decay to nothing while the suite stayed green.

**Measured**

- Build cost, cold and back to back: probe alone **24.03 s**, macro support
  alone **20.71 s**, whole package **29.44 s**. Macros cost a probe consumer
  **~5.4 s (+22%)** — not the tripling the plan assumed. SwiftSyntax is not the
  heaviest thing in this package; SwiftUI/AppKit is.

**Documented**

- `no.md` #26 — a stale macro expansion after a byte-identical RESTORE reads as
  a regression in correct code, which is the most expensive of the three
  costumes this trap wears.
- `no.md` #27 — `VerdictPreviewAdapter` is not built and cannot be: `#Preview`
  content is only reachable through underscored SwiftUI SPI.

### 2026-08-10 (compile-time lint — and the plan's second diagnostic described a defect that does not exist)

**Added**

- **Duplicate explicit probe id → error.** Two elements in one view sharing an
  author-written id are reported at the second occurrence. Every layer
  downstream matches on the id — `TreeDiff` pairs nodes by it, a baseline keys
  on it — so a collision silently merges two elements into one. The kernel
  already caught this at runtime; the compiler sees every `@Verifiable` view on
  every build, where a runtime rule needs the view rendered in a scenario
  somebody remembered to write.

- **Interactive element with no label → warning, with a fix-it.** Measured
  rather than taken from the plan, which calls this "no derivable ID": the id
  derives fine. What is missing is `text:` — the accessible label — because a
  `Button(action:) { Image(…) }` has no literal of its own. The element can be
  located but not *named*, so `TruncationRule` has nothing to read and a human
  reading the verdict sees an anonymous control. A warning, not an error: this
  is ordinary correct SwiftUI, and refusing to compile it would make
  `@Verifiable` reject working code. The fix-it inserts a probe with an EMPTY
  label for the author to fill — a guessed one would write a plausible wrong
  name into the one field a human reads to identify the control.

- Both diagnostics travel with `BodyProbeWalk`, so `#VerdictScenario` emits them
  too. A defect reported through one macro and silent through the other would be
  a difference with no reason an author could see.

**Fixed**

- **Conditional content in a `#VerdictScenario` body was unprobed.** The
  scenario macro had its own local map over expression items — a second
  implementation of the walk — so it carried the `@ViewBuilder`-statement defect
  independently, and fixing the view macro left it broken and green. Both macros
  now enter through `rewriteStatements`.

**Changed**

- Statement lists lifted into a generated template are re-indented
  (`reindentedForTemplate`). Statement trivia is load-bearing inside a closure
  (it separates `in` from the first statement) and is doubled indentation at the
  top of a re-templated list.

### 2026-08-10 (the edge shapes Task 4 names — two of four were broken, not merely uncovered)

**Fixed**

- **`@ViewBuilder` conditional content is probed.** An `if` or `switch` inside a
  view builder is a *statement*, not an expression, and `BodyProbeWalk` rewrote
  only statements that were expressions — so every element in every branch went
  uninstrumented. The container's other probed children keep the tree looking
  observed, so `vacuous-verdict` (which fires only when no probed node exists)
  could not see it and every rule reported PASS about content nobody measured.
  `if`, `else`, `else if` chains and `switch` cases are now walked.

- **`ForEach` expands to source that compiles.** A probed statement is
  re-inserted `.trimmed`, and the statement's own leading trivia is the only
  thing separating a closure's `in` from its first statement — so `{ row in` +
  `Text(…)` became `{ row inText(…)`, and `@Verifiable` was unusable on any view
  containing a `ForEach`. Trivia is now carried across. No existing test used a
  closure *with a signature*, which is why this shipped green.

**Added**

- Expansion snapshots for the four shapes the wave plan names and this repo had
  not pinned: `ForEach`, `@ViewBuilder` conditional, `switch` case, and a nested
  custom view (a negative assertion — `MyRow()` stays opaque by design — paired
  with a probed sibling so the test can fail for its own reason).
- Compilation tests for the `ForEach` and conditional shapes, which read the
  rendered tree rather than generated text; the `ForEach` one is also the guard
  that the expansion builds at all.
- Two mutation rows, both witnessed by expansion snapshots per `no.md` #23 and
  hand-verified NOTICED in both directions with byte-identical restores.

**Changed**

- Four existing expansion snapshots re-pinned: preserving statement trivia
  changes the *indentation* of generated multi-line bodies (probes, ids, roles
  and text are byte-identical). The lifted-body indentation note now records
  trivia preservation as the operative cause.

### 2026-08-10 (scenarios declare themselves, and an explicit probe stops swallowing its subtree)

**Added**

- **`#VerdictScenario("name") { … }`** — a freestanding macro expanding to a
  `VerdictScenario`-conforming struct whose `body(state:)` is the trailing
  closure, probed by the same `BodyProbeWalk` `@Verifiable` uses. Together the
  two macros are the wave's adoption claim: an unverified view becomes fully
  verifiable by adding two tokens.

  It must be written at **type** scope, and that is a language constraint rather
  than a style choice: the generated type name derives from an author-written
  string, so the macro declares `names: arbitrary`, and the compiler rejects
  arbitrary names at global scope outright.

- **`ScenarioEntry` / `ScenarioRegistry`** — static registration for scenario
  discovery (Wave 6's `verdictui list`). The entry erases *construction*, not
  the scenario, because `OracleHost` is generic over `Scenario: VerdictScenario`
  so the `Body` type survives into the hosted tree and `any VerdictScenario`
  cannot satisfy that constraint. Registration is a list you write, never a
  runtime scan: Swift has no load-time hook a value type can register from, and
  reflection breaks under dead-code stripping and makes the scenario set depend
  on link order. A test pins the cost — an unregistered scenario is absent — so
  the tradeoff cannot be quietly "fixed" into reflection.

**Fixed**

- **An explicit `.verdictProbe` on a container no longer swallows everything
  inside it.** `BodyProbeWalk.rewrite` returned the un-recursed expression when
  an element already carried a probe, so a hand-probed container produced a tree
  of exactly one node with no content — measured as
  `["outer-container|container|"]`. This is worse than the empty tree the
  `vacuous-verdict` guard exists for: that guard fires only when no probed node
  exists, and the container's own probe makes the tree look observed, so every
  rule reports PASS about content nobody instrumented. Suppression is now
  positional — recurse first, then decline to probe this position.

  The finding that outlives the bug is about the **witness**: SwiftPM rebuilds
  the plugin but does not re-expand macros in a consuming target whose own
  sources are unchanged, so a render test executes the previous expansion and
  passes against a broken plugin. A macro mutation row must name an expansion
  snapshot. Recorded as `no.md` #23.

### 2026-08-10 (text that wraps past intent is now reported, and the timing gate stops failing for the machine)

**Added**

- **`excessive-wrap` — text wrapping far past the width it was designed for.**
  `truncation` fires only when characters are LOST, and SwiftUI wraps rather
  than clips, so a label spilling onto five lines in a header produced no
  finding at all. Measured on a real screen: `intrinsicWidth 335.0` inside an
  82 pt frame across five lines, `findings: []`. Narrow windows, long localized
  strings and accessibility text sizes all produce this and none of them clip.

  The threshold is **measured, not chosen**, and the measurement changed the
  design. Hosting one 13 pt string at seven widths gave ordinary two-line wraps
  at intrinsic/frame ratios 1.54, 1.88 and 2.00, while the defect sits at 3.88 —
  and `Internationalization` at 58 pt is ratio 2.00 on two lines, *higher* than
  a normal case. A ratio threshold cannot separate normal from defect; line
  count can. The rule gates on `LintContext.maximumWrappedLines` (default 3)
  and reports the ratio only as evidence. Severity is `warning`, not `error`:
  a paragraph is allowed to wrap and the rule cannot know intent.

- **`stage_stale_buffer`** — detects a tracked file overwritten by a stale
  editor buffer, a failure that had struck four times and left the working tree
  silently different from HEAD. `git status` cannot separate it from ordinary
  work in progress; an mtime *older* than the commit that touched the file can.

**Fixed**

- **The SLO 1 gate no longer fails for the environment.** A Codex repair
  sandbox was not recognised as timing-constrained, so it asserted a 70 ms
  median and measured 167 ms, then 394 ms, on source that runs at ~49 ms —
  three P1 tickets describing a regression that did not exist. The marker class
  had also drifted across three test suites and is now spelled once, with a
  cross-language test pinning the Swift and Python halves together.

- **The mutation harness aborts instead of guessing.** A write landing while a
  row's witness ran was previously classified anyway; with the guard removed it
  prints `NOTICED` for a row whose subject something else had rewritten. It now
  exits 3 and names the file.

- **`.github/scripts/create-actions-update-issue.cjs`** — the pinned-actions
  workflow had always ended by calling this file, and it had never existed. The
  weekly check failed with `MODULE_NOT_FOUND` at precisely the moment it had
  something to report.

### 2026-08-08 (usable by other packages, and it can no longer pass on nothing)

**Added**

- **`vacuous-verdict` — a verdict may only report PASS about a tree it could
  actually observe.** Every rule iterates children, so a view carrying no
  `.verdictProbe` produced zero findings and derived to `PASS` — the engine
  announcing a screen is fine on the strength of having looked at nothing.
  Measured against a real app view hosted without probes: squeezed to an eighth
  of its intended width, visibly broken, `PASS` with an empty findings array.
  `RuleEngine.run` now emits an `error` finding when no probed node is present.

  It is deliberately **not** a `LintRule`: `LintContext.disabledRules` could
  switch it off, and the one check whose absence is invisible must not be
  opt-out. The root does not count as a probe (it is synthesized and always
  present), and the search is depth-first, so a probe nested under unprobed
  containers still counts as an observation.

**Fixed**

- **The package can be consumed by apps targeting macOS 13.** A single call to
  the macOS 14 `.coordinateSpace(.named(_:))` overload forced the whole manifest
  to `.v14`, and SwiftPM refuses any consumer pinned lower — naming the *product*
  rather than the API, so nothing in this repo could report it. Split by
  availability in `verdictNamedCoordinateSpace()`; floor lowered to `.macOS(.v13)`.

### 2026-08-08 (correctness pass — every open P1 closed)

**Fixed**

- **The settle engine's waiter census is now one observation, not two.**
  `Quiescence.progressToken` read `clock.pendingWaiterCount` for its
  early-return guard and again to hash it, with a `CATransaction.flush()`
  between — so a virtual-clock waiter registering in that window produced a
  token hashing a count the guard had never seen. Never a wrong verdict (the
  next check self-corrects), but an incoherent one.
- **`HostileSettleTests` no longer races its own fixture.** The test scheduled
  its mutation 20 ms out against a 30 ms quiet floor, leaving 10 ms of slack; on
  a loaded CI runner the timer fired after `settle()` returned but before
  `currentTree()`, reddening `main`. The engine was never at fault — a
  starved-timer control fails *both* assertions, while CI showed only the phase
  one. The mutation is now scheduled 5 ms out instead of 20 ms — still well
  inside the floor, so the test's claim is unchanged, but jitter can no longer
  push the fire past `settle` — and the tree is captured before `phase` is read.
- **The PM script type-checks again.** `_swift_runner` stashes the unwrapped
  zombie sweep under a runtime-injected attribute; assigning it with attribute
  syntax is a type error pyright cannot see past, and CI type-checks that file —
  so a green local suite went red remotely. Now assigned via `setattr`, with the
  name spelled once.
- **The `stage_demo` branch tests establish their own preconditions.** Three
  tests mocked `subprocess.run` but never created the built executable whose
  absence short-circuits the stage, so they passed only on a machine where
  `swift build` had already run.

**Internal**

- Swift `--disable-sandbox` on PM-owned invocations, a `TimeoutExpired` guard
  around the `lsof` lock sweep (shared-libs catches only `OSError`), a
  project-local clang module cache, and `stage_demo` invoking the built binary
  instead of re-entering SwiftPM.

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
