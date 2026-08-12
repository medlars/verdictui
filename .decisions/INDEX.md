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
| [2026-010](2026-010-one-environment-chain-shape-for-pinned-and-swept-hosts.md) | The host's environment chain has ONE shape; a sweep varies values, never structure | 2026-08-11 | Active | sweeps, environment, host, determinism |
| [2026-011](2026-011-three-valued-exit-and-no-destructive-verb-over-a-socket.md) | Three-valued exit codes, and no destructive verb over a socket | 2026-08-11 | Active | cli, daemon, mcp, sd4, honesty |
| [2026-012](2026-012-transports-frame-bytes-and-never-dispatch.md) | Transports frame bytes and never dispatch, and blocking I/O stays off the render actor | 2026-08-12 | Active | daemon, mcp, transport, concurrency, one-implementation |
| [2026-013](2026-013-slo3-measures-the-wire-and-gates-the-median.md) | SLO 3 measures the artifact's wire latency, and gates the median because the tail is not load-stable | 2026-08-12 | Active | slo, latency, mcp, measurement, one-implementation |

> Use the `/adr` skill to create new entries. Each ADR is `YYYY-NNN-slug.md`.
> ProbeLayout.measure's optional-vs-reduce choice is recorded in `no.md` entry 10
> (not an ADR — it is a rejected rewrite of an unreachable branch).
