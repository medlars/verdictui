# ADR 2026-005 — The vacuity guard is structural, never a `LintRule`

**Date:** 2026-08-08
**Status:** Active
**Author:** first external-consumer trial (owner-directed: "build a proper structural guard")

## Context

`Verdict.Status` is derived from findings alone: `findings.contains { $0.severity == .error } ? .fail : .pass`.
Every `LintRule` iterates `root.children`. Those two facts compose into the worst
failure this product can have — a tree with **no probed nodes** produces zero findings,
and zero findings derives to `PASS`.

Measured 2026-08-08, not argued. A real app view (LaunchGate's `PageHeader`) hosted
through `OracleHost` with no `.verdictProbe` yielded
`SemanticNode(id: "", role: .container, children: [])` — the synthesized root and
nothing else. Squeezed from its real 720 pt width to 90 pt, visibly and grossly broken,
it returned `status: PASS` with `findings: []`.

The product's whole thesis is telling a coding agent whether a screen is broken. A
vacuous PASS is **indistinguishable at the call site from a real one**, so the agent
trusts a screen nobody verified. The demo catalog cannot observe this class at all:
all six scenarios are probed by construction, so no in-repo fixture can produce a
probeless tree. 359 passing tests said nothing about it, and the defect was only
findable by consuming the package from **outside** it.

## Decision

`RuleEngine.run` checks `containsProbedNode(root)` **before** the rule loop and appends
an `error` `Finding` under the id `vacuous-verdict` when it is false. The id is exported
as `RuleEngine.vacuousVerdictRule`.

Three properties are load-bearing and each is pinned by its own test:

- **It is not a `LintRule`.** Naming `vacuous-verdict` in `LintContext.disabledRules`
  does nothing (`testTheGuardCannotBeDisabled`).
- **It does not route through `LintContext.makeFinding`.** That helper consults
  per-node suppression; there is no offending node here, and a tree-level suppression
  key would reopen the hole from the other side.
- **The root never counts as a probe**, and the search is depth-first over the whole
  tree — a probe nested under unprobed containers is still an observation
  (`testAProbeNestedDeepCountsAsObservation`).

## Alternatives considered

1. **A new `VacuityRule` in `standardRules`.** Rejected: it is reachable through
   `disabledRules`, so the one check whose absence is invisible would have been
   opt-out. A caller silencing it gets back exactly the original defect, and nothing
   would report that they had.
2. **Severity `warning` instead of `error`.** Rejected on arithmetic: `Status.derived`
   only fails on `.error`, so a warning leaves the verdict reading `PASS` — which *is*
   the defect. The finding would be true and useless.
3. **A third `Verdict.Status` case (`vacuous`).** Rejected as disproportionate: it
   changes the schema shape, `Status.derived`, the decoder's contradiction check, and
   every consumer's exhaustive switch — a breaking contract change with a
   `SchemaVersion` bump, to express something an `error` finding already expresses
   inside the existing derivation. Reconsider only if a consumer needs to distinguish
   "vacuous" from "genuinely failed" programmatically.
4. **Refuse at `OracleHost.currentTree()` instead.** Rejected: the kernel is the
   choke point every verification path terminates at, and `OracleHost` is one
   producer of trees. Guarding the producer leaves hand-built trees and any future
   producer unguarded.

## Consequences

- A probeless scenario now FAILS loudly with a finding naming the fix, instead of
  passing silently. Verified end-to-end on the original external reproduction.
- Correctly probed screens are unaffected: the demo catalog still emits 4 FAIL / 2 PASS
  with **zero** `vacuous-verdict` findings.
- The contract is unchanged — `verdict-schema.json` types `rule` as a free string, so
  no shape change and no `SchemaVersion` bump (`validate-contracts.py` 4 PASS).
- Cost is one depth-first walk per verdict, short-circuiting on the first probed node.
- Wave 4's `@Verifiable` reduces how often a scenario is probeless but does not replace
  this: a hand-written `VerdictScenario` stays the documented escape hatch.

## Rollback

Delete the `containsProbedNode` block from `RuleEngine.run`, the
`vacuousVerdictRule`/`containsProbedNode` members, `VacuousVerdictTests.swift`, its
`FILE_REGISTRY` row, the two mutation rows, and the `docs/kernel.md` §2 subsection.
Nothing else depends on it — the contract never changed, so no consumer breaks.
Rolling back restores the false-PASS behaviour, so do it only alongside a replacement.
