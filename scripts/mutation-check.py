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
from dataclasses import dataclass
from enum import Enum
from pathlib import Path

SUMMARY = "Mutation-verify guards: break one thing, watch a named test fail, restore exactly."

REPO = Path(__file__).resolve().parent.parent

# A `swift test --filter` that rebuilds from cold takes minutes; one that hangs
# would otherwise hang this script forever, and it edits source files while it
# waits.
TEST_TIMEOUT_SECONDS = 900


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


class Outcome(Enum):
    """What one mutation run proved, if anything."""

    NOTICED = "NOTICED"
    UNNOTICED = "UNNOTICED"
    INCONCLUSIVE = "INCONCLUSIVE"


MUTATIONS = [
    Mutation(
        name="hard line breaks other than \\n stop withholding TextMetrics",
        path="Sources/VerdictUIProbe/TreeAssembly.swift",
        old="!text.contains(where: \\.isNewline)",
        new='!text.contains("\\n")',
        test="TreeAssemblyTests/testTextMetricsAreWithheldWhereTheDerivationHasNoHonestBasis",
    ),
    Mutation(
        name="'@'-prefixed probe ids stop being refused",
        path="Sources/VerdictUIProbe/VerdictProbe.swift",
        old='if candidate.hasPrefix("@") {',
        new="if false {",
        test="VerdictUIProbeTests/testAnEmptyOrStructuralPathShapedProbeIDIsRefused",
    ),
    Mutation(
        name="empty probe ids stop being refused",
        path="Sources/VerdictUIProbe/VerdictProbe.swift",
        old="if candidate.isEmpty {",
        new="if false {",
        test="VerdictUIProbeTests/testAnEmptyOrStructuralPathShapedProbeIDIsRefused",
    ),
    Mutation(
        name="a pass with no viewport invents one instead of not delivering",
        path="Sources/VerdictUIProbe/VerdictProbe.swift",
        old="guard let viewport = snapshot.viewport else { return nil }",
        new="let viewport = snapshot.viewport ?? Rect(x: 0, y: 0, width: 1, height: 1)",
        test="VerdictUIProbeTests/testAPassWithNoViewportDeliversNoTree",
    ),
    Mutation(
        # This replaced a mutation on a `recorded.filter { ids.contains(...) }`
        # line in `assembledTree`, which went unnoticed for a good reason: the
        # filter changed no output, because `TreeAssembly` reads only
        # `measurements[record.id]`. The line was deleted rather than papered over
        # with a test, and the guard that *is* load-bearing — that a node's
        # metrics come from its own probe id — is mutated instead.
        name="a node's text metrics stop being keyed by its own probe id",
        path="Sources/VerdictUIProbe/TreeAssembly.swift",
        old="measurements: measurements[record.id] ?? []",
        # Sorted so the wrong answer is deterministic: dictionary order is not.
        new="measurements: measurements.sorted { $0.key < $1.key }.last?.value ?? []",
        test="VerdictUIProbeTests/testAMeasurementWithoutARecordNeitherBecomesNorAltersANode",
    ),
    Mutation(
        name="a multi-subview probe forwards its first subview's explicit guide",
        path="Sources/VerdictUIProbe/ProbeLayout.swift",
        old="guard subviews.count == 1, let subview = subviews.first else { return nil }",
        new="guard let subview = subviews.first else { return nil }",
        test="ProbeLayoutTests/testAProbeWrappingSeveralSubviewsForwardsNoExplicitGuide",
    ),
    Mutation(
        # The reuse-the-intrinsic-answer shortcut in `sizeThatFits`. Inverting the
        # ternary keeps the width-unconstrained case correct by coincidence (both
        # arms measure `.unspecified` there) and breaks the constrained one, which
        # is exactly the asymmetry the named test pins.
        name="the ideal-at-width measurement is reused when a width WAS proposed",
        path="Sources/VerdictUIProbe/ProbeLayout.swift",
        old="                proposal.width == nil\n                ? intrinsic",
        new="                proposal.width != nil\n                ? intrinsic",
        test="ProbeLayoutTests/testWidthConstrainedMeasurementReportsTheHeightWrappingWouldNeed",
    ),
    Mutation(
        name="a non-integral host size is rounded in the error message",
        path="Sources/VerdictUIProbe/OracleHost.swift",
        old="guard value.isFinite, value == value.rounded(), value.magnitude < 1e15 else {",
        # Only the integrality clause is dropped. Dropping the finiteness clause
        # instead would trap in `Int64(Double.nan)` and the run would report a
        # signal rather than a failed assertion — noticed, but for the wrong
        # reason, and unreadable as evidence.
        new="guard value.isFinite, value.magnitude < 1e15 else {",
        test="OracleHostTests/testANonIntegralHostSizeIsReportedWithoutBeingRounded",
    ),
    Mutation(
        name="the demo swallows a scenario that cannot settle",
        path="Sources/VerdictUIDemoScenarios/DemoReport.swift",
        old="let tree = try await host.currentTree()",
        new="guard let tree = try? await host.currentTree() else { continue }",
        test="DemoReportTests/testAScenarioThatCannotSettleFailsTheRunAndNamesItself",
    ),
    Mutation(
        # `renderJSON` is what `main.swift` calls, so its failure branch gets its
        # own mutation rather than riding on `verdicts`'.
        name="renderJSON turns an unsettleable run into an empty document",
        path="Sources/VerdictUIDemoScenarios/DemoReport.swift",
        old="let data = try encoder.encode(try await verdicts(deadline: deadline))",
        new="let data = try encoder.encode((try? await verdicts(deadline: deadline)) ?? [])",
        test=(
            "DemoReportTests/testRenderJSONPropagatesTheFailureRatherThanEmittingAnEmptyDocument"
        ),
    ),
    Mutation(
        name="an entry ignores an explicit viewport override",
        path="Sources/VerdictUIDemoScenarios/DemoScenarios.swift",
        old="host(viewport ?? recommendedViewport, deadline)",
        new="host(recommendedViewport, deadline)",
        test=(
            "DemoScenarioCatalogTests/"
            "testAnEntryHostsAtAnExplicitViewportOrFallsBackToItsRecommendation"
        ),
    ),
    Mutation(
        name="each body evaluation gets a fresh ScenarioState",
        path="Sources/VerdictUIProbe/OracleHost.swift",
        # Enough context to miss the identical string in `ScenarioRoot`'s own doc
        # comment, which explains why this line reads the stored state.
        old="    var body: some View {\n        scenario.body(state: state)\n    }",
        new="    var body: some View {\n        scenario.body(state: ScenarioState())\n    }",
        test="ScenarioTests/testOneHostHandsEveryReEvaluationTheSameScenarioState",
    ),
    Mutation(
        name="the demo stage puts its build flags after the target name",
        path="scripts/verdictui-pm.py",
        old='["swift", "run", *SWIFT_STRICT_FLAGS, "VerdictUIDemo"]',
        new='["swift", "run", "VerdictUIDemo", *SWIFT_STRICT_FLAGS]',
        test=(
            "Tests/test_verdictui_pm.py::TestStageWrappers::"
            "test_stage_demo_puts_build_flags_before_the_target_name"
        ),
        runner=Runner.PYTEST,
    ),
    Mutation(
        name="the demo stage accepts an empty verdict array",
        path="scripts/verdictui-pm.py",
        old="if not isinstance(verdicts, list) or not verdicts:",
        new="if not isinstance(verdicts, list):",
        test=(
            "Tests/test_verdictui_pm.py::TestStageWrappers::"
            "test_stage_demo_fails_on_an_empty_verdict_array"
        ),
        runner=Runner.PYTEST,
    ),
    Mutation(
        name="an empty mutation catalog reports success",
        path="scripts/mutation-check.py",
        old='        print("the mutation catalog is empty — nothing was verified")\n        return 1\n    problems = [',
        new="        pass\n    problems = [",
        test=(
            "Tests/test_mutation_check.py::TestVerifyTargets::"
            "test_an_empty_catalog_fails_rather_than_reporting_nothing_wrong"
        ),
        runner=Runner.PYTEST,
    ),
    Mutation(
        name="a broken build is blamed on a renamed test",
        path="scripts/mutation-check.py",
        old='        if "error:" in combined:\n            return "unmutated source does not build',
        new='        if False:\n            return "unmutated source does not build',
        test=(
            "Tests/test_mutation_check.py::TestBaselineProblem::"
            "test_a_tree_that_does_not_build_says_so_instead_of_blaming_the_name"
        ),
        runner=Runner.PYTEST,
    ),
    Mutation(
        name="the ZStack layering exemption becomes case-sensitive",
        path="Sources/VerdictUIKernel/Rules/SiblingOverlapRule.swift",
        old='node.role.identifier.lowercased() == "zstack"',
        new='node.role.identifier == "ZStack"',
        test="SiblingOverlapRuleTests/testZStackParentRoleReadsAsIntentionalLayering",
    ),
    Mutation(
        name="CLAUDE.md's SSoT table points at a file that does not exist",
        path="CLAUDE.md",
        old="Sources/VerdictUIProbe/OracleHost.swift",
        new="Sources/VerdictUIProbe/OracleHostRenamed.swift",
        test=("Tests/test_claude_md_ssot.py::TestClaudeMdSSoT::test_every_ssot_location_exists"),
        runner=Runner.PYTEST,
    ),
    Mutation(
        name="CLAUDE.md's SSoT table names a symbol that moved",
        path="CLAUDE.md",
        old="`VerdictScenario`",
        new="`VerdictScenarioProtocol`",
        test=(
            "Tests/test_claude_md_ssot.py::TestClaudeMdSSoT::"
            "test_every_ssot_symbol_lives_where_the_table_says"
        ),
        runner=Runner.PYTEST,
    ),
    Mutation(
        # Retargeting a row rather than deleting one: this leaves every row
        # pointing at a real file, so only the completeness direction can catch it.
        name="a source file loses its FILE_REGISTRY row",
        path="docs/FILE_REGISTRY.md",
        old="| `scripts/dev.sh`",
        new="| `scripts/floor-check.py`",
        test=(
            "Tests/test_file_registry.py::TestFileRegistry::"
            "test_every_authored_source_file_has_an_active_row"
        ),
        runner=Runner.PYTEST,
    ),
    Mutation(
        # The one guard here whose subject is a policy constant rather than a
        # file: it fails when a tracked file's type is in neither classification
        # set, and no edit to a *document* can produce that. Dropping `.swift`
        # from the source set is the honest equivalent of adding an unclassified
        # file type, and proves the canary reads the tree instead of itself.
        name="a file type drops out of both classification sets",
        path="Tests/test_file_registry.py",
        old='".swift", ',
        new="",
        test=(
            "Tests/test_file_registry.py::TestFileRegistry::test_every_tracked_suffix_is_classified"
        ),
        runner=Runner.PYTEST,
    ),
    Mutation(
        # Anchored on the widest Purpose cell, the one row the markdown formatter
        # leaves unpadded, so this target does not depend on column alignment. If
        # a longer purpose is ever written, --verify-targets reports this STALE.
        name="a source file's registry row is flipped out of Active",
        path="docs/FILE_REGISTRY.md",
        old="tree delivery | Active |",
        new="tree delivery | Removed |",
        test=(
            "Tests/test_file_registry.py::TestFileRegistry::"
            "test_every_authored_source_file_has_an_active_row"
        ),
        runner=Runner.PYTEST,
    ),
    Mutation(
        name="a FILE_REGISTRY row is left behind by a rename",
        path="docs/FILE_REGISTRY.md",
        old="| `scripts/floor-check.py`",
        new="| `scripts/floor-check-renamed.py`",
        test=(
            "Tests/test_file_registry.py::TestFileRegistry::"
            "test_every_active_row_points_at_a_path_that_exists"
        ),
        runner=Runner.PYTEST,
    ),
]

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


def run_named_test(test: str, runner: Runner = Runner.SWIFT) -> subprocess.CompletedProcess[str]:
    """The one test invocation this script makes, spelled once per runner.

    Baseline and mutated runs must differ only in the state of the source, so
    they go through the same argv rather than two copies of it.
    """
    if runner is Runner.PYTEST:
        # `-p no:cacheprovider` so a mutation run leaves no `.pytest_cache`
        # behind for the final clean-tree check to trip over.
        return run([sys.executable, "-m", "pytest", test, "-q", "-p", "no:cacheprovider"])
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
    """Baseline, apply, run, require failure, restore. True when verified."""
    if problem := target_problem(mutation):
        print(f"  SETUP FAILED: {problem}")
        return False
    if problem := baseline_problem(mutation):
        print(f"  SETUP FAILED: {problem}")
        return False

    path = resolve_in_repo(mutation.path)
    original = path.read_text()
    before = sha256(path)

    path.write_text(original.replace(mutation.old, mutation.new))
    try:
        outcome, reason = classify(run_named_test(mutation.test, mutation.runner), mutation.runner)
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
