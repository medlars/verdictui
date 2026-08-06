# ADR 2026-001 — Mutation harness runs both `swift test` and `pytest`

**Date:** 2026-08-05
**Status:** Active
**Author:** Wave 2 third review (end-of-session)

## Context

`scripts/mutation-check.py` existed to enforce "every new guard is mutation-verified."
Wave 2's second review pass added Python guards inside PM (`stage_demo`,
`stage_mutations`) and inside the harness itself (empty catalog, baseline
diagnosis). The harness could only invoke `swift test --filter`, so the standing
rule stopped applying to precisely the code doing the verifying.

## Decision

`Mutation` carries a `Runner` enum (`SWIFT` | `PYTEST`). Baseline and mutated runs
go through one `run_named_test(test, runner)` helper. Pytest node ids are
first-class; `-p no:cacheprovider` keeps mutation runs from dirtying the tree with
`.pytest_cache`. An empty `MUTATIONS` list hard-fails both `--verify-targets` and
a full run.

## Alternatives considered

1. **Keep Swift-only; "trust" Python tests.** Rejected — the session's own history
   shows Python guards can look covered while being unmutated.
2. **Separate `mutation-check-py.py`.** Rejected — doubles the catalog and the
   restore/clean-tree contract.
3. **Shell out to PM stages as the witness.** Rejected — too slow and couples
   mutation to the whole PM graph.

## Consequences

- Adding a Python guard requires a `Runner.PYTEST` mutation with a real node id.
- Catalog tests assert: every pytest mutation names an existing `::`-form node id;
  no Swift mutation carries a node id (because `swift test --filter` would match
  nothing and exit 0).
- Full run is now 17 mutations across both languages.

## Rollback

Remove `Runner`, drop the four pytest mutations, and restore
`run_named_test`/`executed_test_count` to Swift-only. The empty-catalog hard-fail
should stay regardless.
