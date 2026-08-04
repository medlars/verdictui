# VerdictUI — Wave Status (session continuity SSoT)

> **Purpose**: every new session resumes the build from this file — no re-planning,
> no asking "where were we". Read it at session start; update it before ending any
> session that changed code or completed a task. Keep entries terse and factual.
>
> Task numbers refer to `docs/implementation-plan.md` (the execution SSoT).

## Current position

| Field | Value |
|-------|-------|
| Current wave | **Wave 1 — Kernel: the verdict engine** |
| Wave task in progress | *(none — Wave 1 not yet started)* |
| Next action | Start Wave 1 Task 1: extend `SemanticNode` (Role enum, attributes, isVisible/zIndex, TextMetrics, structuralPath) |
| Last session ended | 2026-08-04 03:10 |
| Health at last session end | PM Grade A (100.0), floor 0 gaps, CI green, 0 open P0/P1 CIS |

## Wave 1 task checklist (from implementation-plan.md)

- [ ] Task 1 — Extend `SemanticNode`: Role enum, `attributes`, `isVisible`, `zIndex`, `TextMetrics`, `structuralPath`
- [ ] Task 2 — `TreeDiff.swift`: compute TreeDelta (added/removed/moved/changed), id-first matching, property test
- [ ] Task 3 — `RuleEngine.swift`: `LintRule` protocol, `LintContext`, `RuleEngine.run`
- [ ] Task 4 — Six rules under `Rules/`: SiblingOverlap, ZeroSize, Offscreen, Truncation, TapTarget, DuplicateProbeID
- [ ] Task 5 — Verdict schema v1: `contracts/verdict-schema.json`, `SchemaVersion.swift`, fixture round-trip in validate-contracts.py
- [ ] Task 6 — `docs/kernel.md`: role vocabulary, rule catalog, schema reference

### Wave 1 exit gate (all must pass before Wave 2)

- [ ] `swift test --filter VerdictUIKernelTests` green; ≥ 30 kernel tests incl. one property-style diff test
- [ ] Every public kernel symbol has a doc comment + at least one test
- [ ] `contracts/validate-contracts.py` → PASS (schema round-trip)
- [ ] PM `stage_architecture` green (kernel purity intact)
- [ ] PM quick Grade A; FILE_REGISTRY + CHANGELOG updated

## Completed waves

| Wave | Completed | Evidence |
|------|-----------|----------|
| Wave 0 — Scaffold | 2026-08-04 | Grade A PM, floor 0 gaps, CI green, 6 Swift + 19 Python tests, all scaffold CIS issues closed |

## Session log (newest first, keep last ~10)

- **2026-08-04 03:10** — Session continuity wiring: this file created; skill resume protocol added. All P0/P1 CIS closed; PM Grade A.
- **2026-08-04 02:00** — Scaffold debt cleared: pyright extraPaths fix, executables chmod'd, CodeWatch baseline seeded, 19-test PM suite added, CI green.
- **2026-08-04 00:30** — Project scaffolded via /project-forge; 10-wave implementation plan written; registrations complete.
