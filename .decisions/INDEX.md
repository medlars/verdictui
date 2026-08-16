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
| [2026-014](2026-014-the-act-delta-shares-one-node-table-and-its-budget-is-measured.md) | The act delta shares one node table across additions, and its budget is a measurement rather than the plan's unreachable 300 B | 2026-08-12 | Active | wire-format, act, budget, measurement, untrusted-input |
| [2026-015](2026-015-the-witness-mirrors-the-probe-channels-layout.md) | The witness mirrors the probe channel's layout, and frames on the SwiftUI side | 2026-08-12 | Active | wave8, cross-validation, witness, layout, measurement, one-implementation |
| [2026-016](2026-016-pixel-capture-pins-1x-and-names-its-backend.md) | The pixel capture pins 1x itself rather than inheriting the device scale, and every capture names its backend | 2026-08-12 | Active | wave9, pixel, capture, measurement, portability |
| [2026-017](2026-017-a-pixel-baseline-is-refused-to-any-scenario-that-drifts.md) | A pixel baseline is refused to any scenario that does not render identically twice | 2026-08-13 | Active | wave9, pixel, determinism, baseline, falsifiability |
| [2026-018](2026-018-the-pixel-diff-gates-on-channel-magnitude-not-pixel-count.md) | The pixel diff gates on channel magnitude, not on the differing-pixel count — a real regression and an invisible one touch the same 196 pixels | 2026-08-13 | Active | wave9, pixel, diff, tolerance, measurement, negative-control |
| [2026-019](2026-019-the-pixel-cache-keys-on-the-tree-and-accepts-a-lower-speedup.md) | The pixel cache keys on the semantic tree, and accepts a 3x gate rather than weaken the key that makes a stale hit impossible | 2026-08-13 | Active | wave9, pixel, cache, sd4, budget, measurement |
| [2026-020](2026-020-the-witness-window-is-readable-without-being-visible.md) | The witness window is readable without being visible — alpha 0 keeps it AX-published while compositing nothing; an offscreen origin is impossible because NSWindow clamps to the screen | 2026-08-14 | Active | wave8, witness, ax, visibility, measurement, negative-control |
| [2026-021](2026-021-the-open-core-boundary-is-the-machine-not-the-feature.md) | The open-core boundary is the MACHINE, not the feature — everything running on one developer's machine is MIT, including BaselineStore; only second-party layers are reserved | 2026-08-14 | Active | wave10, licensing, open-core, mit, release, boundary |
| [2026-022](2026-022-what-1-0-promises-and-what-it-does-not.md) | What 1.0 promises and what it does not — the wire, CLI exit codes, MCP tool names and kernel types are covered; rule THRESHOLDS deliberately are not, because a measurement that is wrong should be corrected | 2026-08-14 | Active | wave10, semver, api, release, thresholds |
| [2026-023](2026-023-quiescence-hashes-the-tree-not-the-counters.md) | Quiescence hashes the TREE, not the counters that describe it — a layout alternating 10/40 pt kept every count identical, so the token went constant while the screen moved | 2026-08-14 | Active | wave10, settle, quiescence, false-green, measurement |
| [2026-024](2026-024-a-witness-declares-what-the-runner-cannot-report.md) | A witness declares what the runner cannot report — a skipped XCTest is byte-identical to a passing one, so a working AX guard was scored UNNOTICED; where the runner emits no signal, the catalog carries the claim | 2026-08-15 | Active | mutation-harness, false-green, apparatus, measurement |

> Use the `/adr` skill to create new entries. Each ADR is `YYYY-NNN-slug.md`.
> ProbeLayout.measure's optional-vs-reduce choice is recorded in `no.md` entry 10
> (not an ADR — it is a rejected rewrite of an unreachable branch).
