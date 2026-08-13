# 2026-017 — A pixel baseline is refused to any scenario that does not render identically twice

**Status**: Accepted (2026-08-13)
**Wave**: 9, Task 2

## Context

A pixel baseline is a promise that a screen renders these exact bytes every
time. Task 1 shipped the capture; nothing checked that promise before making it.

A baseline written for a scenario that is NOT byte-stable is worse than no
baseline at all: it fails at random on some later, unrelated commit, and the
reader spends the afternoon hunting a regression in code that never changed.
That failure is also self-discrediting — once a channel cries wolf, its real
findings get discounted.

## Decision

1. **`DeterminismCheck.verify` renders the scenario TWICE and compares bytes.**
   A scenario that disagrees with itself is refused a baseline.
2. **Each render constructs its own `OracleHost`.** A host evaluates
   `body(state:)` on construction, so this is what makes a re-evaluated `Date()`,
   `UUID()` or counter observable.
3. **Both renders settle before capture, through one shared helper**, so a
   difference in settling can never be misreported as a difference in
   determinism.
4. **A capture that cannot be produced throws** rather than reporting
   nondeterminism — "the screen is unstable" and "the harness could not look"
   are different findings.
5. **The refusal is actionable**: it names the scenario, both hashes, both byte
   counts, the backend, the usual unpinned inputs, and the alternative (semantic
   rules need no byte stability).

## Alternatives considered

- **Capture one host twice.** Rejected, and this is the load-bearing choice: the
  layout is already fixed after construction, so re-encoding it reports EVERY
  scenario as deterministic. The check would pass universally and could not fail
  for its own reason.
- **Warn instead of refuse.** Rejected: a warning that still writes the baseline
  leaves the random failure in place, having merely announced it once.
- **Render three or more times.** Rejected for now — two renders caught the
  drift in every fixture measured, and each render costs a full host
  construction plus settle. Revisit if a real scenario proves intermittently
  unstable rather than consistently so.
- **Report "nondeterministic" when a capture throws.** Rejected: it would send
  the reader to fix the screen when the harness is what failed.

## Consequences

- Pixel baselines (Task 4) can only be written through a verified capture.
- All six demo scenarios are verified deterministic on this machine, iterating
  the catalog rather than a hand-written list, with a vacuity guard so an empty
  catalog fails instead of passing.
- A scenario legitimately unable to be byte-stable (an embedded clock) is
  steered to semantic rules rather than left to fail intermittently.
- The `makeHost`-factory overload exists because `DemoScenarioEntry` hides its
  scenario type behind a closure; the factory contract is that it returns a
  FRESH host per call.

## Rollback

Revert `Sources/VerdictUIProbe/PixelDeterminism.swift`, its tests,
`DemoScenarioDeterminismTests.swift`, and the mutation row. Task 1's capture is
independent and keeps working; only the refusal disappears.

## See also

- `no.md` #47 — a fixture built to trigger a check is itself an untested claim
  (two fixtures here could not fail, for two different reasons)
- ADR 2026-016 — the capture this check consumes
