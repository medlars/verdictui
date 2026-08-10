# Decisions Index — VerdictUI

| ADR | Title | Date | Status | Tags |
|-----|-------|------|--------|------|
| [2026-001](2026-001-mutation-harness-multi-runner.md) | Mutation harness runs both `swift test` and `pytest` | 2026-08-05 | Active | mutation, testing, pm |
| [2026-002](2026-002-tracked-pm-baselines.md) | Track `pm-baselines.json` (do not gitignore it) | 2026-08-05 | Active | floor, pm |
| [2026-003](2026-003-settle-quiet-floor-scoped-to-settle.md) | The settle quiet floor is charged in `settle()` only, never in `pump()` | 2026-08-06 | Active | settle, honesty, slo |
| [2026-004](2026-004-slo-gates-median-everywhere-tail-in-isolation.md) | SLO 1 gates the median everywhere; the tail is recorded, never asserted | 2026-08-06 | Active | slo, benchmark, flake |
| [2026-005](2026-005-vacuity-guard-is-structural-not-a-rule.md) | The vacuity guard is structural, never a `LintRule` | 2026-08-08 | Active | kernel, honesty, false-pass |
| [2026-006](2026-006-deployment-floor-tracks-the-lowest-fleet-target.md) | The deployment floor tracks the lowest fleet target, not the newest API | 2026-08-08 | Active | packaging, adoption, consumers |
| [2026-007](2026-007-mutation-catalog-lives-outside-the-harness.md) | The mutation catalog lives outside the harness it drives | 2026-08-10 | Active | mutations, tooling, self-reference |
| [2026-008](2026-008-scenario-registration-is-a-static-list.md) | Scenario registration is a static list, not a runtime scan | 2026-08-10 | Active | macros, registry, adoption |
| [2026-009](2026-009-macro-composition-via-compile-time-overload.md) | Macros compose through a compile-time overload, not reflection | 2026-08-10 | Active | macros, adoption, composition |

> Use the `/adr` skill to create new entries. Each ADR is `YYYY-NNN-slug.md`.
> ProbeLayout.measure's optional-vs-reduce choice is recorded in `no.md` entry 10
> (not an ADR — it is a rejected rewrite of an unreachable branch).
