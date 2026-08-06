# ADR 2026-003 — The settle quiet floor is charged in `settle()` only, never in `pump()`

**Date:** 2026-08-06
**Status:** Active
**Author:** Wave 1–3 audit (owner-approved trade-off)

## Context

The Wave 1–3 audit found `settle()` reporting quiet after ~5.6 ms while a mutation
scheduled 40 ms out had not yet landed — reproduced directly, not argued. The cause is
that `LayoutSettle.requiredAgreeingChecks` is a **count** with no time dimension: two
checks are separated by exactly one `pumpInterval` (5 ms), so "the token agreed twice"
meant "nothing changed for 5 ms", which is not a claim worth making about a UI.

The harness would therefore capture and lint a pre-mutation tree while telling the
caller the UI was still — the precise lie the product's "never lie" claim rules out,
and it bites hardest in the primary use case (asserting on a post-action tree).

## Decision

`LayoutSettle.pump` gained a `minimumQuiet: TimeInterval` parameter (default `0`), and
the quiet token must hold for that wall-clock span **in addition to** agreeing across
`requiredAgreeingChecks`. A changed token resets the clock as well as the count.

`Quiescence.settle` passes `LayoutSettle.minimumQuietInterval` (30 ms). **No other
call site passes it** — in particular `OracleHost.currentTree()` does not.

## Alternatives considered

1. **Apply the floor unconditionally inside `pump`.** Rejected on measurement:
   `Harness.perform` calls `currentTree()` twice around one `settle()`, and
   `currentTree` pumps too, so the floor is paid three times per cycle. Measured
   **p95 109.9 ms against a 100 ms SLO — a breach**. A correctness fix applied one
   layer too low becomes a performance regression.
2. **Raise `requiredAgreeingChecks` 2 → 6.** Rejected: it couples the honesty
   guarantee to `pumpInterval`, so anyone tuning that constant silently changes the
   guarantee. That coupling is exactly what caused the flaky-oscillation bug fixed
   earlier the same day.
3. **Document the ~5 ms limit and change nothing.** Rejected by the owner: it leaves
   the product's central claim resting on a 5 ms window.
4. **Drain the concurrency pool before the census.** Rejected as insufficient — it
   closes only work already *scheduled*; a timer firing 40 ms out still slips through.

## Consequences

- SLO 1 moved from p95 20.9 ms to **p50 ~49.6 ms / p95 ~56.7 ms** (isolated), still
  well inside the 100 ms budget. The honesty costs ~34 ms and is the reason.
- `currentTree` is a **capture** — it waits for layout it already has to stop moving.
  `settle` is the call that **asserts quiet**. The claim is paid for where it is made.
- The floor is a floor, not a guarantee. Work landing after it remains the timeout's
  job and Wave 8's independent witness's; `Quiescence`'s residual-risk note says so.
- The pinning test asserts **both directions** (see ADR 2026-004's sibling reasoning):
  the engine must honour the floor it declares, AND that declared floor must not drop
  below what the scenario needs. Deriving the assertion from the constant alone made
  the test move *with* the defect — measured: weakening to 5 ms passed.

## Rollback

Pass `minimumQuiet: 0` at the `Quiescence.settle` call site (one line). The suite will
fail `testSettleWaitsOutAMutationScheduledBeyondOnePumpInterval`, which is the intended
signal — that mutation is catalogued in `scripts/mutation-check.py` and verified NOTICED.
