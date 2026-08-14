# 2026-022 — What 1.0 promises, and what it deliberately does not

**Status**: Accepted (2026-08-14)
**Wave**: 10, Task 3 (API audit for 1.0 semver)

## Context

Wave 10 Task 3 asks for an "API audit for 1.0 semver". A version number is a
promise about what will not change, and the promise is worth nothing unless the
boundary is written down before the tag exists — afterwards, every argument
about whether something was covered is unfalsifiable.

The audit found nothing to fix, which is itself the finding worth recording:

- **No underscored public symbols.** `grep 'public (func|var|let|struct|enum|class) _'`
  over `Sources/` returns nothing, so there is no half-private surface being
  shipped as if it were API.
- **No `TODO`/`FIXME`/`HACK` anywhere in `Sources/`.** Nothing is marked as
  provisional and then exported.
- **No deprecations.** There is no legacy tier to explain, because nothing has
  been superseded yet.
- **`Role` already carries `.custom(String)`** — the escape hatch that lets new
  vocabulary arrive without a new enum case.

## Decision

**1.0 covers the wire, the CLI contract and the kernel's public types.
It does not cover the probe's internals or the demo catalog.**

### Covered — breaking these needs a major version

1. **The verdict wire format**, governed by `SchemaVersion.current` (now `1.1`)
   and pinned by `contracts/verdict-schema.json` plus its fixtures. Agents parse
   this; breaking it silently breaks every consumer. Any shape change bumps the
   schema version, the contract and the regenerated fixtures **in one commit**,
   and `contracts/validate-contracts.py` fails the drift.
2. **The CLI's verbs and its three-valued exit codes** — `0` passed, `1` a
   verdict was produced and FAILED, `2` no verdict could be produced. Scripts
   branch on these, and collapsing 1 and 2 would force callers to treat an
   infrastructure fault as a product defect.
3. **The MCP tool names and their argument shapes.** Seven tools; a rename is a
   breaking change for every registered client.
4. **The kernel's public types** — `SemanticNode`, `Rect`, `Size`, `Verdict`,
   `Finding`, `LintContext`, `LintRule`, `Baseline`, and the expectations DSL.
5. **Rule identifiers.** `tap-target`, `truncation`, … appear in
   `Finding.rule`, in `disabledRules`, and in per-node suppression attributes,
   so renaming one silently un-suppresses code that had opted out.

### Not covered — these may change in a minor release

1. **Rule THRESHOLDS.** Every numeric floor in this engine is a measurement, and
   a measurement that is wrong should be corrected rather than preserved. On
   2026-08-14 the macOS tap-target minimum moved 28 → 12 pt because no native
   macOS control could satisfy 28 (see ADR-adjacent notes on
   `LintContext.macOSMinimumTapTarget`); freezing it would have meant shipping a
   rule that fires on idiomatic SwiftUI forever. **A threshold change can make
   a previously-passing screen fail, and that is not a breaking API change — it
   is the rule becoming correct.** Consumers who need stability against this
   pin a baseline, which is exactly what baselines are for.
2. **The set of rules in `RuleEngine.standardRules`.** New rules will be added.
   A consumer wanting a frozen set passes their own array.
3. **Finding MESSAGES and SUGGESTIONS.** Human-readable prose, improved freely.
   Machine consumers key on `rule` and `nodeID`, which are covered above.
4. **`VerdictUIProbe` internals** — settle policy, quiescence heuristics, host
   construction. These are how the tree is produced, not what it means.
5. **The demo scenario catalog.** `demo-undersized-tap-target` and its siblings
   are fixtures for this project's own tests and documentation. Its planted
   defect shrank from 18 × 18 to 6 × 6 pt in the same commit as the threshold
   change, precisely because a demo whose bug is a legal size demonstrates
   nothing.

### `Role` stays non-frozen, and `.custom` is why that is safe

Adding a case to a public Swift enum breaks every exhaustive `switch` in every
consumer. `Role` is expected to grow — it mirrors SwiftUI's accessibility
vocabulary, which Apple extends — so a strict reading would freeze it at 1.0 and
force `.custom("disclosureGroup")` forever.

Instead: **new roles arrive as `.custom(String)` within a major version, and are
promoted to real cases only at a major bump.** That keeps the common path
typed while making the vocabulary extensible without a breaking release, and it
is why `.custom` exists rather than being an afterthought.

## Consequences

**Thresholds being explicitly out of scope is the load-bearing clause.** It is
also the one most likely to surprise, so it is stated first among the
exclusions and justified with the case that prompted it. Without it, this
project would have to choose between a correct engine and its own version
promise — and a verification tool that ships a rule it knows to be miscalibrated
has already lost the argument it exists to make.

**A consumer needing bit-stability across releases uses baselines.** That is a
better mechanism than a version promise anyway: it pins what *their* screens
looked like, rather than what our thresholds happened to be.

**No compatibility shims.** Per the project's code-shape rules there are no
`_`-prefixed aliases and no re-exports for removed types. When something is
removed at a major version it is removed.
