"""`Mutation` and `Runner` — shared by the harness and the catalog.

A third module rather than either of the other two, because the catalog imports
these types and the harness imports the catalog; putting them in the harness
would make that a cycle.
"""

from __future__ import annotations

from dataclasses import dataclass
from enum import Enum


class Runner(Enum):
    """Which test runner owns the witness.

    The guards worth mutating stopped being Swift-only once PM grew stages with
    their own preconditions. A Python guard that no mutation can reach is
    exactly the unverified guard this script exists to rule out, so the runner
    travels with the mutation instead of being assumed.
    """

    SWIFT = "swift"
    PYTEST = "pytest"


@dataclass(frozen=True)
class Mutation:
    """One deliberate break, and the test that must notice it."""

    name: str
    path: str
    old: str
    new: str
    # `swift test --filter` pattern, or a pytest node id when `runner` is PYTEST.
    test: str
    runner: Runner = Runner.SWIFT
    # Why this macro row may be witnessed by a RUNTIME test instead of an
    # expansion snapshot. Empty for every other row.
    #
    # `no.md` #23: SwiftPM rebuilds a `.macro` target but does NOT re-expand
    # macros in a consuming target whose own sources are unchanged, so a render
    # test executes the PREVIOUS expansion and passes against a broken plugin.
    # A macro row must therefore name a snapshot — unless the mutated behaviour
    # is not in the expansion at all, which is a real case and needs saying out
    # loud rather than being argued in a comment nothing checks.
    runtime_witness_reason: str = ""
    # Why this row's witness may SKIP, stated as the condition. Empty for every
    # other row, and a row that sets it is refused as a witness rather than
    # scored.
    #
    # A skipped XCTest is INDISTINGUISHABLE from a passing one: it prints
    # `Test Case '-[...]' passed` and `Executed 1 test, with 0 failures`, exits
    # 0, and emits no skip marker at any verbosity (`--xunit-output` does not
    # help — the file written here covers only the swift-testing lane). So
    # `classify` reads ran=1 + exit 0 and reports `UNNOTICED — the test passed
    # with the guard broken`, which is false in the expensive direction: the
    # guard is fine, the test never ran, and the sweep accuses working code.
    #
    # Measured 2026-08-15 on the AX bounded-walk row, the only UNNOTICED in a
    # 121-row sweep. Its witness opens with `XCTSkipIf(isHeadless)`,
    # `XCTSkipUnless(AXReader.isTrusted)` and a skip when no third-party app is
    # running. There is nothing in stdout to parse, so the declaration has to
    # live on the row — the same discipline as `runtime_witness_reason`.
    skips_when: str = ""
