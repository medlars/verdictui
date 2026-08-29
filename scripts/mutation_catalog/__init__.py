"""The mutation catalog: every guard in this repo, and the test that must notice it.

Split out of `mutation-check.py` (CTS-47AA0547), and the split does more than
cut a long file in half — it removes a constraint the harness could not escape.

A `Mutation.old` must quote the source text it replaces. While the catalog lived
INSIDE `mutation-check.py`, any row targeting the harness itself matched twice:
once at the real site, once in its own quoting of it, and `--verify-targets`
refused it (correctly — the harness could not say which site it broke). That is
`no.md` #16, which records a guard left with a hand-run control because no row
could be written for it. With the catalog in a separate module, a row may quote
harness code freely: the two files do not contain each other's text.

The rule that replaces it is narrower and easier to keep: a row must not quote
text from THIS file. Rows targeting the catalog itself would self-match here for
exactly the same reason.

SPLIT INTO A PACKAGE 2026-08-28 (CTS-49EE72D4). The single module reached 2231
lines against an 800-line limit. It is DATA, not logic, so the split is by the
area each row targets rather than by behaviour, and `MUTATIONS` is reassembled
here in a fixed order so the corpus a run sees is unchanged.

The rule above still holds, and the split does not widen it: a row must not
quote text from any file in THIS package, because such a row would self-match
where it is written.
"""

from mutation_catalog_types import Mutation, Runner

from mutation_catalog._cli import MUTATIONS as _CLI
from mutation_catalog._kernel import MUTATIONS as _KERNEL
from mutation_catalog._macros import MUTATIONS as _MACROS
from mutation_catalog._misc import MUTATIONS as _MISC
from mutation_catalog._probe import MUTATIONS as _PROBE
from mutation_catalog._scripts import MUTATIONS as _SCRIPTS

__all__ = ["MUTATIONS", "Mutation", "Runner"]

# Concatenated in a FIXED order. mutation-check.py reports rows by name rather
# than by index, so order is not load-bearing for correctness — but a stable
# order keeps a run's output diffable against the previous one.
MUTATIONS: list[Mutation] = _PROBE + _KERNEL + _MACROS + _CLI + _SCRIPTS + _MISC
