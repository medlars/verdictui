# ADR 2026-007 — The mutation catalog lives outside the harness it drives

**Date:** 2026-08-10
**Status:** Active
**Author:** backlog-clearing session (CTS-47AA0547, closing `no.md` #16)

## Context

`scripts/mutation-check.py` held both the harness (apply a mutation, run its witness,
restore, classify) and the `MUTATIONS` catalog — 67 rows naming the source text each
guard is broken at. That co-location created a constraint nobody had questioned.

A `Mutation.old` must quote the exact source text it replaces, and `--verify-targets`
requires that text to resolve to **exactly one** site. So any row targeting the harness
itself matched **twice**: once at the real call site, once inside its own quoting of
that call site in the catalog below. `--verify-targets` refused it — correctly, since
the harness could not say which of the two it had broken.

`no.md` #16 recorded the consequence and accepted it: the `-B` flag on the pytest
witness argv — which makes the witness compile the source the harness just wrote
instead of reading a stale `__pycache__` — was declared **unrowable**. Three
progressively narrower one-line anchors were tried and all self-matched; a line-spanning
anchor worked only against a wrapped call that `ruff format` immediately collapses. The
guard was left with a hand-run control instead of a row.

That guard is not decorative. Measured 2026-08-07: CPython validates its bytecode cache
on mtime **plus size** at one-second granularity, six pytest rows target
`verdictui-pm.py` in sequence, and two landing in the same second make the witness judge
the *previous* row's compile. Exactly one of six went UNNOTICED in a full sweep and
NOTICED when re-run alone.

Separately, the file had reached 1105 lines against an 800-line advisory (CTS-47AA0547),
and the ticket framed the catalog-inside-the-harness arrangement as a constraint the
split would have to **work around**.

## Decision

Split into three modules:

| Module | Holds |
|---|---|
| `scripts/mutation-check.py` (300 lines) | The harness: apply, run, classify, restore, verify-targets |
| `scripts/mutation_catalog.py` (878 lines) | `MUTATIONS` — the rows |
| `scripts/mutation_catalog_types.py` (37 lines) | `Mutation` and `Runner` |

The types are a **third** module rather than living in the harness, because the catalog
imports them and the harness imports the catalog — putting them in the harness makes
that a cycle.

The split does not work around the constraint; it **removes** it. Two files that do not
contain each other's text can quote each other freely, so
`old='return run([sys.executable, "-B", "-m", "pytest"'` now matches exactly one site.
The row `no.md` #16 declared impossible was added and hand-verified NOTICED (exit 1 on
`test_a_mutated_module_is_not_served_from_stale_bytecode`) with a byte-identical restore.

The narrower rule that replaces #16: **a row may not quote text from
`mutation_catalog.py` itself** — rows targeting the catalog would self-match there for
exactly the same reason. That is a small, clearly-bounded exclusion rather than a hole
over the whole harness.

## Alternatives considered

**Leave it as one file and keep the hand-run control.** This was the standing position
(`no.md` #16) and it was defensible: a hand-run control proves the same thing a row
does, minus the automation. Rejected because the automation is the point — a hand-run
control is re-run only by whoever remembers it exists, and the guard it protects had
already produced a false UNNOTICED once.

**Anchor the row on a wrapped multi-line call.** Works, and it is the technique the
other `mutation-check.py` rows use (indentation plus `\n` make the target unquotable).
Rejected because `ruff format` collapses the wrap on the next format run, so the row
would rot silently rather than fail loudly — a guard that degrades quietly is worse than
one that is absent.

**Split by row count** (catalog A / catalog B, to also satisfy the 800-line advisory).
Rejected: `mutation_catalog.py` is a flat list with no internal subject seam, so any cut
falls at an arbitrary row number and the two halves have no independent meaning. The
800 figure is a fleet CEO-audit heuristic, not enforced by this project's PM (verified:
neither `verdictui-pm.py` nor `floor-check.py` reads it), and it is a proxy for
readability rather than a contract — see `no.md` #22.

## Consequences

- The `-B` guard is now mutation-verified; targets went 63 → 64 at the split and 67 by
  session end.
- A new class of row becomes writable: anything guarding the harness itself. Two were
  added the same day (the mid-run tree-ownership abort, and the stale-buffer detector's
  discrimination).
- The harness dropped to 300 lines and is now readable end-to-end.
- `pyproject.toml` gained `scripts` in pyright's `extraPaths`: `mutation-check.py`
  reaches its siblings through a runtime `sys.path.insert` (the directory holds
  hyphenated filenames, so it cannot be a package), and pyright does not replicate that.
- One new failure mode to watch: a row quoting `mutation_catalog.py` will self-match.
  `--verify-targets` catches it at write time, which is where it should be caught.

## Rollback

Concatenate `mutation_catalog_types.py` and `mutation_catalog.py` back into
`mutation-check.py`, drop the three-line `sys.path` shim and its two imports, and delete
the `-B` row plus any other row quoting harness source (they will self-match again).
`python3.14 scripts/mutation-check.py --verify-targets` must report every remaining
target resolving to exactly one site; `pytest Tests/test_mutation_check.py -q` must be
green. Nothing outside `scripts/` imports these modules, so the blast radius is the
directory.
