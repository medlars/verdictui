#!/usr/bin/env python3.14
"""Mutation-verify guards: break one thing, watch a named test fail, restore exactly.

A guard nothing can break is a guard nothing is testing. For each mutation below
this applies the change, runs the single test that is supposed to notice, and
requires that test to FAIL. Then it restores the file and re-checks the sha256,
so a mutation run cannot leave the tree altered.

Not a permanent part of the build: run it by hand when adding a guard. Exits
non-zero on the first mutation that goes unnoticed.
"""

from __future__ import annotations

import hashlib
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent


@dataclass(frozen=True)
class Mutation:
    """One deliberate break, and the test that must notice it."""

    name: str
    path: str
    old: str
    new: str
    test: str  # `swift test --filter` pattern


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
        name="delivery stops filtering measurements to reporting probes",
        path="Sources/VerdictUIProbe/VerdictProbe.swift",
        old="grouping: recorded.filter { ids.contains($0.probeID) },",
        new="grouping: recorded,",
        test="VerdictUIProbeTests/testDeliveryDropsMeasurementsForProbesThatDidNotReport",
    ),
    Mutation(
        name="a multi-subview probe forwards its first subview's explicit guide",
        path="Sources/VerdictUIProbe/ProbeLayout.swift",
        old="guard subviews.count == 1, let subview = subviews.first else { return nil }",
        new="guard let subview = subviews.first else { return nil }",
        test="ProbeLayoutTests/testAProbeWrappingSeveralSubviewsForwardsNoExplicitGuide",
    ),
    Mutation(
        name="a non-integral host size is rounded in the error message",
        path="Sources/VerdictUIProbe/OracleHost.swift",
        old="guard value.isFinite, value == value.rounded(), value.magnitude < 1e15 else {",
        new="guard !value.isFinite else {",
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
        old="scenario.body(state: state)",
        new="scenario.body(state: ScenarioState())",
        test="ScenarioTests/testOneHostHandsEveryReEvaluationTheSameScenarioState",
    ),
    Mutation(
        name="the ZStack layering exemption becomes case-sensitive",
        path="Sources/VerdictUIKernel/Rules/SiblingOverlapRule.swift",
        old='node.role.identifier.lowercased() == "zstack"',
        new='node.role.identifier == "ZStack"',
        test="SiblingOverlapRuleTests/testZStackParentRoleReadsAsIntentionalLayering",
    ),
]


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(args: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        args, cwd=REPO, capture_output=True, text=True, check=False
    )


def git_is_clean() -> bool:
    return run(["git", "diff", "--quiet"]).returncode == 0


def check(mutation: Mutation) -> bool:
    """Apply, run the named test, require failure, restore. True when verified."""
    path = REPO / mutation.path
    original = path.read_text()
    before = sha256(path)

    occurrences = original.count(mutation.old)
    if occurrences != 1:
        print(
            f"  SETUP FAILED: target appears {occurrences} times, expected exactly 1"
        )
        return False

    path.write_text(original.replace(mutation.old, mutation.new))
    try:
        result = run(
            [
                "swift", "test",
                "--filter", mutation.test,
                "-Xswiftc", "-warnings-as-errors",
            ]
        )
        # A mutation that stops the build compiles nothing and proves nothing, so
        # a compile failure is not an acceptable "the test noticed" signal.
        combined = result.stdout + result.stderr
        if "error:" in combined and "Executed" not in combined:
            print("  INCONCLUSIVE: the mutation did not compile")
            print("  " + "\n  ".join(combined.strip().splitlines()[-6:]))
            return False
        noticed = result.returncode != 0
        print(f"  {'NOTICED' if noticed else 'UNNOTICED'} (exit {result.returncode})")
        if not noticed:
            print("  the guard is not covered: the test passed with it broken")
        return noticed
    finally:
        path.write_text(original)
        after = sha256(path)
        if after != before:
            print(f"  RESTORE FAILED: {before} -> {after}")
            raise SystemExit(2)


def main() -> int:
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
        print(f"{len(failures)} of {len(MUTATIONS)} mutations went unnoticed:")
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
