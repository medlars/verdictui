# ADR 2026-004 — SLO 1 gates the median everywhere, the tail only where it means something

**Date:** 2026-08-06
**Status:** Active
**Author:** Wave 1–3 audit, second sweep

## Context

After ADR 2026-003 moved SLO 1's p50 from ~20 ms to ~49 ms, the p95 assertion began
breaching intermittently — 102.6 ms and 120.6 ms on full-suite runs — while the
median never moved. Measured across runs:

| Context | p50 | p95 |
|---|---|---|
| Isolated (`--filter HarnessPerformanceTests`) | 49.6 ms | **56.7 ms** |
| Full suite (319 tests) | 49.8–51.2 ms | **64.1 → 102.6 ms** |

The median is load-stable; p95 is not. A benchmark competing with 318 other tests for
cores is measuring **the suite**, not the engine — the same reasoning already applied
to shared CI runners in this file (owner decision, same day).

An earlier attempt raised the sample count 60 → 150, which genuinely narrows the p95
band (50.6–87.8 ms → 53.5–58.1 ms) but does **not** fix it: a median at half the
budget leaves too little headroom for tail variance, and no amount of sampling
changes that. Treating a load problem as a measurement problem was the wrong
diagnosis, kept here because the sampling change is still an improvement on its own.

## Decision

- **p50 is asserted in every environment** at half the budget (70 ms).
- **p95 is asserted only in isolation**; under CI or a full-suite run it is *recorded*
  as `SLO1-PERFORM-LOADED` without failing.
- Both figures are printed everywhere, so a regression stays visible in the log even
  where it is not fatal.
- Everything that proves the benchmark actually **ran** — sample count, finiteness
  checks, per-cycle PASS with a non-empty delta — remains a hard failure in all
  environments. A benchmark that silently stopped running must never read as a fast one.

## Alternatives considered

1. **Assert p50 only, record p95 always.** Rejected: it stops gating the tail entirely,
   and the tail is what an agent actually waits on when the tool is slow.
2. **Raise SLO 1 to 150 ms.** Rejected: it weakens the published product claim to
   accommodate a build machine. 150 ms is still far better than a screenshot cycle,
   but the SLO stops being a forcing function.
3. **Accept the flake.** Rejected: a gate that flakes is one people learn to re-run
   rather than read — which is how the settle bug survived in the first place.
4. **Restructure `perform` so the floor is paid once.** Investigated and **abandoned on
   measurement**: a cost probe against the shipped engine reads `currentTree` at
   6.19 ms and `settle` at 35.03 ms, so ~49 ms is two cheap captures plus *one*
   floor-length settle. The floor was already charged once; the hypothesis was wrong.

## Consequences

- The gate no longer flakes: 3/3 consecutive full-suite runs green after the change.
- It still catches real regressions — tripling the settle floor to 90 ms fails the p50
  assertion in a **full-suite** run at 108 ms, naming the figure. Catalogued as a
  mutation row and verified NOTICED.
- `isUnderFullSuiteLoad` reads `CommandLine.arguments` for the XCTest filter argument,
  because this is a property of the **run**, not the machine — the same binary is both.

## Rollback

Delete the `p50` assertion and the `isUnderFullSuiteLoad` branch, restoring the
unconditional p95 gate. Expect intermittent red on full-suite runs; the mutation row
`the settle floor triples, tripling inner-loop latency` will still pass, so coverage of
real regressions is retained either way.
