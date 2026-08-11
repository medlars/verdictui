#!/usr/bin/env python3.14
"""Mutation-verify guards: break one thing, watch a named test fail, restore exactly.

A guard nothing can break is a guard nothing is testing. For each mutation below
this applies the change, runs the single test that is supposed to notice, and
requires that test to FAIL. Then it restores the file and re-checks the sha256,
so a mutation run cannot leave the tree altered.

Three ways a naive version of this lies, all guarded against here:

- **The test was already red.** Then it fails with the mutation applied too, and
  the run reports coverage that does not exist. Every mutation is preceded by a
  baseline run of the same test on unmutated source, which must pass.
- **The filter matched nothing.** `swift test --filter` exits 0 having executed
  zero tests, so a renamed or misspelled test reads as "the guard is uncovered"
  rather than "this harness is out of date". Both runs assert a nonzero count.
- **The mutation did not compile, or trapped.** Neither is a test noticing
  anything; both are reported as INCONCLUSIVE, not as coverage.

Run `--verify-targets` for the cheap half: that every mutation still points at
source text that exists exactly once. That is what CI and PM run, because it
catches the harness rotting without paying for a rebuild per mutation.

Recovery: mutations are written in place and restored in a `finally`, and the
tree must be clean to start, so `git checkout -- <path>` undoes any mutation
left behind by a kill -9.
"""

from __future__ import annotations

import argparse
import hashlib
import re
import subprocess
import sys
from enum import Enum
from pathlib import Path

# `sys.path` rather than a package: this directory holds hyphenated scripts, so
# it is not importable as a package, and the harness is run as a script.
sys.path.insert(0, str(Path(__file__).resolve().parent))

from mutation_catalog import MUTATIONS  # noqa: E402 — needs the sys.path line above
from mutation_catalog_types import Mutation, Runner  # noqa: E402 — same

SUMMARY = "Mutation-verify guards: break one thing, watch a named test fail, restore exactly."

REPO = Path(__file__).resolve().parent.parent

# A `swift test --filter` that rebuilds from cold takes minutes; one that hangs
# would otherwise hang this script forever, and it edits source files while it
# waits.
TEST_TIMEOUT_SECONDS = 900


class Outcome(Enum):
    """What one mutation run proved, if anything."""

    NOTICED = "NOTICED"
    UNNOTICED = "UNNOTICED"
    INCONCLUSIVE = "INCONCLUSIVE"


# XCTest prints this once per suite plus once for the total; the largest count is
# the outermost total. swift-testing's parallel summary is not counted — every
# Swift mutation here names an XCTest method.
_EXECUTED = re.compile(r"Executed (\d+) test")
# pytest's terminal summary: "3 passed", "1 failed, 2 passed". Both counts are
# tests that ran, so both are summed — a run that fails is still a run.
_PYTEST_RAN = re.compile(r"(\d+) (?:passed|failed)")


def executed_test_count(output: str, runner: Runner = Runner.SWIFT) -> int:
    """How many tests the runner reported running, or 0 if it never said."""
    if runner is Runner.PYTEST:
        return sum(int(match) for match in _PYTEST_RAN.findall(output))
    counts = [int(match) for match in _EXECUTED.findall(output)]
    return max(counts) if counts else 0


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def resolve_in_repo(relative: str) -> Path:
    """`relative` under `REPO`, refusing anything that climbs out of it."""
    candidate = (REPO / relative).resolve()
    if not candidate.is_relative_to(REPO):
        raise SystemExit(f"mutation path escapes the repository: {relative}")
    return candidate


def run(args: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(  # noqa: S603 — fixed argv, no shell, literals only
        args,
        cwd=REPO,
        capture_output=True,
        text=True,
        check=False,
        timeout=TEST_TIMEOUT_SECONDS,
    )


MACRO_PLUGIN_DIR = "Sources/VerdictUIMacros/"

# Test targets whose sources must be re-stamped before a macro-plugin row runs.
# Spelled as a list so a new macro-consuming target is one row rather than a
# rediscovery of the trap below.
MACRO_CONSUMING_TEST_DIRS = (
    "Tests/VerdictUIMacroTests",
    "Tests/VerdictUIMacroRuntimeTests",
)


def refresh_macro_expansions() -> None:
    """Re-stamp macro-consuming test sources so SwiftPM re-expands the plugin.

    SwiftPM rebuilds a `.macro` plugin when its source changes but does NOT
    re-expand macros in a consuming target whose own sources are unchanged, so a
    RUNTIME witness executes the PREVIOUS expansion and passes against a broken
    plugin. That is `no.md` #23/#26, and it defeats this harness in the
    expensive direction: a working guard reports UNNOTICED, which reads as
    "untested" and invites rewriting correct code.

    Measured 2026-08-11: the `the two macros stop composing over a custom view`
    row went UNNOTICED in a full sweep and NOTICED (exit 1, 1 test executed,
    naming `vacuous-verdict`) when the same mutation was applied by hand with
    the consuming test files touched first. The row's own note recorded a
    hand-verification that the harness could not reproduce, because the hand
    check followed the touch discipline and the harness did not.

    The pytest path solves the same class of problem with `-B`; `swift test` has
    no equivalent, so the mtime is bumped directly.
    """
    for directory in MACRO_CONSUMING_TEST_DIRS:
        # Resolved against REPO, not the process cwd: every other path in this
        # harness is, and a helper that silently read a different root would
        # touch nothing while reporting nothing — the failure mode being closed
        # here, one layer down.
        root = resolve_in_repo(directory)
        if not root.is_dir():
            continue
        for source in root.rglob("*.swift"):
            source.touch()


def run_named_test(test: str, runner: Runner = Runner.SWIFT) -> subprocess.CompletedProcess[str]:
    """The one test invocation this script makes, spelled once per runner.

    Baseline and mutated runs must differ only in the state of the source, so
    they go through the same argv rather than two copies of it — and the runner
    must read that source fresh. Each runner defeats a different cache to get
    there: `-B` on the pytest path (no `__pycache__`), and
    ``refresh_macro_expansions`` on the Swift path (no stale macro expansion).
    """
    if runner is Runner.PYTEST:
        # `-p no:cacheprovider` so a mutation run leaves no `.pytest_cache`
        # behind for the final clean-tree check to trip over.
        #
        # `-B` because the witness must judge the source this harness just
        # wrote. Six pytest rows target `scripts/verdictui-pm.py` in sequence,
        # and the tests load it via `spec_from_file_location`, which honours
        # `__pycache__`. CPython validates that cache on mtime PLUS SIZE at
        # one-second granularity, so two rows landing in the same second serve
        # the previous row's bytecode — the mutation sits on disk while the
        # test reads the unmutated constant, and the row reports UNNOTICED for
        # a guard that works. That is the expensive direction: it reads as
        # "untested" and invites rewriting correct code. Measured 2026-08-07,
        # when exactly one of the six went UNNOTICED and re-running that row
        # alone said NOTICED — a race, so it moves between runs.
        return run([sys.executable, "-B", "-m", "pytest", test, "-q", "-p", "no:cacheprovider"])
    # Unconditional, and deliberately not narrowed to macro-plugin rows: the
    # baseline and mutated runs must differ ONLY in the state of the source, so
    # a refresh that happened on one and not the other would reintroduce the
    # very asymmetry this closes. Touching a handful of files costs a rebuild of
    # one test target and buys a witness that judges the code on disk.
    refresh_macro_expansions()
    return run(["swift", "test", "--filter", test, "-Xswiftc", "-warnings-as-errors"])


def git_is_clean() -> bool:
    """True when nothing is modified, staged, or untracked.

    `git diff --quiet` alone would miss staged and untracked changes, which
    would make the "restored byte-identically" claim at the end weaker than it
    reads.
    """
    return not run(["git", "status", "--porcelain"]).stdout.strip()


def classify(
    result: subprocess.CompletedProcess[str], runner: Runner = Runner.SWIFT
) -> tuple[Outcome, str]:
    """Read one mutated test run. Returns the outcome and a one-line reason."""
    combined = result.stdout + result.stderr
    ran = executed_test_count(combined, runner)
    # A mutation that stops the build compiles nothing and proves nothing, so a
    # compile failure is not an acceptable "the test noticed" signal. Under
    # pytest the equivalent is a collection error, which also runs no tests.
    if ran == 0 and ("error:" in combined or "errors during collection" in combined):
        return Outcome.INCONCLUSIVE, "the mutation did not compile"
    # A trap is a nonzero exit for a reason that is not the assertion: the test
    # never got to judge anything, so it says nothing about coverage.
    if "unexpected signal code" in combined:
        return Outcome.INCONCLUSIVE, "the mutation trapped instead of failing an assertion"
    # Zero tests run exits 0 under `swift test --filter`, which would otherwise
    # read as an uncovered guard when the truth is that this harness names a
    # test that no longer exists.
    if ran == 0:
        return Outcome.INCONCLUSIVE, "the filter matched no tests — has the test been renamed?"
    if result.returncode != 0:
        return Outcome.NOTICED, f"exit {result.returncode}"
    return Outcome.UNNOTICED, "the test passed with the guard broken"


def baseline_problem(mutation: Mutation) -> str | None:
    """Why the named test cannot serve as a witness, or `None` if it can.

    Without this a test that is *already* failing reports NOTICED for every
    mutation aimed at it — coverage claimed on the strength of a red test.
    """
    result = run_named_test(mutation.test, mutation.runner)
    combined = result.stdout + result.stderr
    if executed_test_count(combined, mutation.runner) == 0:
        # "Matched no tests" and "the tree does not build" both show zero
        # executed tests, and sending someone to hunt a renamed test when the
        # real fault is a broken build wastes the diagnosis this exists to give.
        if "error:" in combined:
            return "unmutated source does not build — fix the tree before mutation testing"
        return "the filter matched no tests before mutating — has the test been renamed?"
    if result.returncode != 0:
        return f"the test is already failing on unmutated source (exit {result.returncode})"
    return None


def target_problem(mutation: Mutation) -> str | None:
    """Why the mutation cannot be applied, or `None` if it can."""
    path = resolve_in_repo(mutation.path)
    if not path.is_file():
        return f"{mutation.path} does not exist"
    occurrences = path.read_text().count(mutation.old)
    if occurrences != 1:
        return f"target appears {occurrences} times in {mutation.path}, expected exactly 1"
    return None


def check(mutation: Mutation) -> bool:
    """Baseline, apply, run, require failure, restore. True when verified.

    Also aborts if anything but this harness wrote to the file while the witness
    was running — the verdict would otherwise describe a tree nobody intended.
    """
    if problem := target_problem(mutation):
        print(f"  SETUP FAILED: {problem}")
        return False
    if problem := baseline_problem(mutation):
        print(f"  SETUP FAILED: {problem}")
        return False

    path = resolve_in_repo(mutation.path)
    original = path.read_text()
    before = sha256(path)

    mutated = original.replace(mutation.old, mutation.new)
    path.write_text(mutated)
    expected_mutated = hashlib.sha256(mutated.encode()).hexdigest()
    try:
        result = run_named_test(mutation.test, mutation.runner)

        # The tree is not ours for the length of the run. An editor save, a
        # concurrent pytest, a sibling agent's `git checkout` -- any write to
        # THIS file while the witness ran means the witness judged something
        # other than the mutation, and the harness cannot tell which. Reporting
        # that as UNNOTICED is the expensive direction: it reads as "your guard
        # is untested" and invites rewriting correct code, which cost about an
        # hour on 2026-08-07 (`no.md` #14). A verdict we cannot stand behind is
        # not a verdict, so this aborts rather than scoring the row.
        if sha256(path) != expected_mutated:
            print("  ABORTED: the file changed while its witness was running")
            print(f"  {mutation.path} was written by something other than this harness")
            print("  re-run in the foreground with an exclusive tree (no.md #14)")
            raise SystemExit(3)

        outcome, reason = classify(result, mutation.runner)
        print(f"  {outcome.value} ({reason})")
        return outcome is Outcome.NOTICED
    finally:
        path.write_text(original)
        after = sha256(path)
        if after != before:
            print(f"  RESTORE FAILED: {before} -> {after}")
            print(f"  recover with: git checkout -- {mutation.path}")
            raise SystemExit(2)


def verify_targets() -> int:
    """Cheap rot check: every mutation still points at text that exists once.

    No build, so it costs milliseconds and can run on every PM pass. It cannot
    tell whether a guard is covered — only that this file has not drifted away
    from the source it claims to mutate.
    """
    # An empty catalog would otherwise print "all 0 targets resolve" and exit 0,
    # turning PM's stage green by deleting the thing it checks.
    if not MUTATIONS:
        print("the mutation catalog is empty — nothing was verified")
        return 1
    problems = [
        (mutation.name, problem) for mutation in MUTATIONS if (problem := target_problem(mutation))
    ]
    for name, problem in problems:
        print(f"STALE: {name}\n  {problem}")
    if problems:
        print(f"\n{len(problems)} of {len(MUTATIONS)} mutation targets are stale")
        return 1
    print(f"all {len(MUTATIONS)} mutation targets resolve to exactly one site")
    return 0


def main(argv: list[str] | None = None) -> int:
    # Not `__doc__.splitlines()[0]`: under `python -OO` docstrings are stripped
    # and `__doc__` is None, which would turn `--help` into an AttributeError.
    parser = argparse.ArgumentParser(description=SUMMARY)
    parser.add_argument(
        "--verify-targets",
        action="store_true",
        help="only check that each mutation's target text still exists exactly once",
    )
    args = parser.parse_args(argv)

    if args.verify_targets:
        return verify_targets()

    if not MUTATIONS:
        print("the mutation catalog is empty — nothing was verified")
        return 1
    if not git_is_clean():
        print("working tree is dirty; commit or stash before mutation testing")
        return 2

    failures = []
    for mutation in MUTATIONS:
        print(f"\n[{mutation.name}]")
        print(f"  {mutation.path} :: {mutation.test}")
        # Re-checked per mutation, not just once at the top. A full sweep runs
        # for ~30 minutes, and an edit landing mid-run makes every case after it
        # measure a tree nobody intended: the baseline stops building and the
        # harness reports SETUP FAILED, which reads as a broken guard rather
        # than as a dirty tree. Measured twice this session on concurrent doc
        # edits. Aborting names the real cause instead of filing false gaps.
        if not git_is_clean():
            print("  ABORTED: the working tree changed mid-run")
            print("mutation results are only valid on a tree that stays clean")
            return 2
        if not check(mutation):
            failures.append(mutation.name)

    print(f"\n{'=' * 68}")
    if failures:
        print(f"{len(failures)} of {len(MUTATIONS)} mutations went unverified:")
        for name in failures:
            print(f"  - {name}")
        return 1
    print(f"all {len(MUTATIONS)} mutations were noticed by their named test")
    if not git_is_clean():
        print("but the working tree was left dirty")
        return 2
    print("working tree restored byte-identically")
    return 0


if __name__ == "__main__":
    sys.exit(main())
