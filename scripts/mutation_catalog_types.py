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
