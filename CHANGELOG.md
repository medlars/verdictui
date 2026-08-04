# Changelog

## [Unreleased]

### 2026-08-04

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
