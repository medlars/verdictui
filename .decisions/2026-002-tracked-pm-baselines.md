# ADR 2026-002 — Track `pm-baselines.json` (do not gitignore it)

**Date:** 2026-08-05
**Status:** Active
**Author:** Wave 2 third review (end-of-session)

## Context

`scripts/floor-check.py` requires `pm-baselines.json` as a floor item (project-forge
template). VerdictUI had the file in `.gitignore`, so a clean clone failed
`stage_floor` / `test_stage_floor_passes_on_this_repo` even when every other gate
was green. Peer projects (e.g. Archivist) track a seed baselines file; shared
`pm_base` documents a tracked `pm-baselines.json` as a human-committed floor file.

## Decision

Remove `pm-baselines.json` from `.gitignore` and commit a seed file with version
`1.0` and the current test-count / health-score snapshot. Floor and PM may refresh
metrics in place; the file stays tracked.

## Alternatives considered

1. **Drop the floor check for baselines.** Rejected — floor is the clone-readiness
   contract; carving exceptions for gitignored runtime files hides real gaps.
2. **Keep gitignore; write the file in `stage_floor` if missing.** Rejected —
   floor would then create what it claims to verify, and CI runners without a
   prior PM run would still look different from local.

## Consequences

- Fresh clones pass floor without a prior PM run.
- Metric refreshes may dirty the tree; commit them when they change meaningfully,
  or accept a dirty baselines file as non-blocking for mutation-check only when
  intentional (mutation-check still requires a clean tree).

## Rollback

Re-add the gitignore line and delete the tracked file only if floor-check is also
changed to stop requiring it — never leave the contradiction in place.
