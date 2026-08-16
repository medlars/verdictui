# ADR 2026-024 — A witness declares what the runner cannot report

**Date:** 2026-08-15
**Status:** Active
**Author:** session 15 (`no.md` #62)

## Context

`scripts/mutation-check.py` classifies one mutated test run into NOTICED,
UNNOTICED or INCONCLUSIVE. Its four cases — compile failure, trap, zero tests
executed, nonzero exit — were derived from what `swift test` and `pytest` *print*.

A full 121-row sweep returned exactly one UNNOTICED: `the AX walk keeps its depth
bound but loses its node budget`, witnessed by
`ThirdPartyAuditTests/testTheReaderIsBoundedAgainstAHostileTree`. That reads as a
coverage gap in a real safety bound — the one added after an unbounded AX walk
segfaulted the runner at test 15 of 669 (`no.md` #44).

It was not a gap. **The witness had skipped.** Its first three statements are
`XCTSkipIf(isHeadless)`, `XCTSkipUnless(AXReader.isTrusted)` and a skip when no
third-party app publishes a readable window. Measured 2026-08-15, it completed in
**0.062 s** against the ~2 s a real AX read costs.

The decisive fact is that **XCTest emits no skip marker**. The output is:

```
Test Case '-[…testTheReaderIsBoundedAgainstAHostileTree]' passed (0.062 seconds).
	 Executed 1 test, with 0 failures (0 unexpected)
```

exit 0 — byte-identical to a real pass. So `classify` saw `ran == 1` and
`returncode == 0`, fell through all four cases, and printed **"UNNOTICED — the
test passed with the guard broken."** Every clause is false: it did not pass, it
did not run, and the guard is fine.

The direction is what makes this expensive. A *missing* NOTICED reads as *your
code is unprotected* and sends the next session to rewrite a correct bound —
`no.md` #26's false-red shape, and `no.md` #14's rule (suspect the apparatus
before the subject) arriving through an environmental precondition.

## Decision

A `Mutation` row may declare `skips_when: str` — the condition under which its
witness will skip. `baseline_problem()` refuses such a row **before running
anything**, alongside the two unusable-witness cases already there (already-red,
matches-nothing), and the refusal names the condition:

> the witness can skip (the host is headless, lacks Accessibility trust, or is
> running no third-party app with a readable window) and a skipped XCTest is
> indistinguishable from a passing one — run it on a host where it executes

This is the same discipline as `runtime_witness_reason` (ADR-adjacent, `no.md`
#23): **a claim about the APPARATUS is stated on the row and checked, never argued
in a comment nothing reads.**

The general rule it encodes: *a harness that scores a test's OUTCOME must first
establish the test was CAPABLE of running, and where the runner cannot say so, the
catalog must.*

## Alternatives considered

**Parse stdout for a skip marker.** Rejected on measurement, not preference —
there is nothing to parse. Searched at default verbosity and with `-v`: no skip
token appears anywhere in a skipped run's output.

**Use `--xunit-output`, whose XML has a `<skipped/>` element.** Tested directly.
SwiftPM wrote `/tmp/ax-swift-testing.xml` covering only the **swift-testing** lane
(`tests="0"`) and did **not** emit the XCTest lane's XML at all. The signal that
would have worked does not reach us.

**Infer a skip from suspiciously fast execution** (0.062 s vs ~2 s). Rejected: a
threshold on wall-clock is a claim about a host, which is precisely the class of
guess `no.md` #15/#17 exist to forbid. It would also be wrong the first time a
fast machine ran the real read.

**Delete the row.** Rejected — it guards a real safety bound whose absence
segfaulted the runner once already. Deleting the row to silence a false verdict is
the silencer this project forbids (SE Principle 11).

**Leave it UNNOTICED and explain in a comment.** Rejected as the actual defect:
the sweep's summary line is what people read, and a comment does not travel with
it. That is the `no.md` #28 shape, where a row's own note asserted a
hand-verification the harness could not reproduce.

## Consequences

- Mutation targets 121 → 122. The new row (`a witness that can skip is scored as
  if it had run`) mutates the check itself with `if False`, keeping every binding
  live so it still compiles (`no.md` #31).
- A row carrying `skips_when` is **never scored** on a host where it skips. That
  is honest but it is not free: the guard is unproven there. `SETUP FAILED` names
  the condition so an operator can re-run somewhere it executes.
- Over-application would silently retire the sweep — a declaration on every row
  refuses every row while reporting a clean summary. Guarded two ways: the
  negative control `test_a_row_without_the_declaration_is_still_scored`, and
  `test_the_ax_bounded_row_declares_its_preconditions`, which pins the affected
  row **by name** rather than by a count so deleting the declaration fails loudly.
  Measured: exactly 1 of 122 rows carries it, and the other 121 still score.
- The check runs *before* the witness, so it saves a test run rather than costing
  one.

## Rollback

Delete the `skips_when` field from `mutation_catalog_types.py`, its branch in
`baseline_problem()`, its declaration on the AX row, the three tests in
`TestSkippableWitness`, and the `a witness that can skip is scored as if it had
run` row. `python3.14 scripts/mutation-check.py --verify-targets` must then report
121 targets resolving to exactly one site, and
`pytest Tests/test_mutation_check.py -q` must be green. The sweep returns to
reporting a false UNNOTICED whenever that witness skips — which is the state this
ADR exists to leave behind, so roll back only if the declaration proves to be
over-applied.
