"""Tests for scripts/mutation-check.py.

This script is the evidence behind every "mutation-verified" claim in the
changelog. If it reports NOTICED when nothing was noticed, the guards it blesses
are unproven and nothing downstream would say so — so its three lying modes get
pinned here by hand:

- a test that was already red must not be accepted as a witness;
- a filter that matches no tests must not read as an uncovered guard;
- a mutation that fails to compile, or traps, must not read as coverage.

The outcome tests drive the pure decision functions with synthetic
`CompletedProcess` values. Nothing shells out to `swift`; the one subprocess
here is a pytest collection pass, which runs no test bodies.
"""

import contextlib
import hashlib
import importlib.util
import os
import re
import subprocess
import sys
import time
from pathlib import Path
from types import SimpleNamespace
from typing import Any

import pytest

pytestmark = pytest.mark.quick

_PROJECT_ROOT = Path(__file__).resolve().parents[1]


def _load_named(name: str, path: Path) -> Any:
    """Import a hyphen-named script as a module under `name`.

    Generalised from `_load` rather than copied: two loaders would be two places
    for the `sys.modules` registration below to go wrong, and the failure is a
    confusing one (`@dataclass` raises on the decorator, not on anything the
    test is about).
    """
    # Purge the bytecode cache for THIS file before loading. CPython validates a
    # `.pyc` on mtime PLUS SIZE at one-second granularity, so two edits to one
    # file inside the same second — which an edit-then-restore control is, by
    # construction — leave a cache the loader honours over the bytes on disk.
    # Measured 2026-08-12 while adding this very test: the file read 3600 to
    # `grep` and 1800 to the loader, and the test failed against source that was
    # already correct. That is `no.md` #16 one layer up: the harness fixed its
    # own pytest witness with `-B`, but a loader inside a test is a second cache
    # consumer nobody had covered.
    cache = path.parent / "__pycache__"
    if cache.is_dir():
        for stale in cache.glob(f"{path.stem}.*.pyc"):
            stale.unlink(missing_ok=True)
    spec = importlib.util.spec_from_file_location(name, str(path))
    mod = importlib.util.module_from_spec(spec)  # type: ignore[arg-type]
    sys.modules[name] = mod
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    return mod


def _load() -> Any:
    """Import the hyphen-named script as a module. `Any`, because tests rebind
    its `REPO` constant — a `ModuleType` annotation would reject that."""
    name = "verdictui_mutation_check"
    path = str(_PROJECT_ROOT / "scripts" / "mutation-check.py")
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)  # type: ignore[arg-type]
    # `@dataclass` resolves its own annotations through `sys.modules[__module__]`,
    # so a module executed without being registered there raises on the
    # decorator rather than on anything this file is testing. Re-registering per
    # load is deliberate: tests rebind `REPO` and `MUTATIONS`, and each needs its
    # own copy.
    sys.modules[name] = mod
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    return mod


def _result(
    returncode: int = 0, stdout: str = "", stderr: str = ""
) -> subprocess.CompletedProcess[str]:
    return subprocess.CompletedProcess(
        args=["swift", "test"], returncode=returncode, stdout=stdout, stderr=stderr
    )


# One passing XCTest method, as `swift test --filter` prints it.
_ONE_PASSED = "Test Suite 'Selected tests' passed\n\t Executed 1 test, with 0 failures\n"
# The same method failing an assertion.
_ONE_FAILED = (
    "<unknown>:0: error: -[SubjectTests testThing] : XCTAssertEqual failed\n"
    "\t Executed 1 test, with 1 failure (0 unexpected)\n"
)
# What a filter that matches nothing prints — note the exit code is 0.
_NONE_MATCHED = "\t Executed 0 tests, with 0 failures (0 unexpected) in 0.000 seconds\n"


class TestExecutedTestCount:
    """`swift test` reports a count per suite; the total is the largest."""

    def test_a_run_that_executed_nothing_counts_zero(self) -> None:
        assert _load().executed_test_count(_NONE_MATCHED) == 0

    def test_output_with_no_count_line_at_all_counts_zero(self) -> None:
        assert _load().executed_test_count("error: could not build\n") == 0

    def test_the_outermost_suite_total_wins_over_per_suite_lines(self) -> None:
        # Nested suites each print their own tally. Summing would double-count;
        # taking the first would under-count when the inner suite prints first.
        output = (
            "\t Executed 1 test, with 0 failures\n"
            "\t Executed 4 tests, with 0 failures\n"
            "\t Executed 1 test, with 0 failures\n"
        )
        assert _load().executed_test_count(output) == 4


class TestPytestRunner:
    """Guards in PM stages are Python, and must be mutable like the Swift ones."""

    def test_a_pytest_run_counts_passed_and_failed_as_tests_that_ran(self) -> None:
        mod = _load()
        assert mod.executed_test_count("3 passed in 0.1s", mod.Runner.PYTEST) == 3
        assert mod.executed_test_count("1 failed, 2 passed in 0.1s", mod.Runner.PYTEST) == 3

    def test_a_pytest_run_that_collected_nothing_counts_zero(self) -> None:
        # `pytest <nodeid>` on a renamed test exits nonzero with no tally, which
        # must read as a stale catalog, not as a noticed mutation.
        mod = _load()
        assert mod.executed_test_count("no tests ran in 0.01s", mod.Runner.PYTEST) == 0

    def test_the_swift_tally_is_not_read_as_a_pytest_one(self) -> None:
        # "Executed 4 tests" contains no "passed"/"failed" count, so reading it
        # with the wrong runner must yield zero rather than a wrong number.
        mod = _load()
        assert (
            mod.executed_test_count("\t Executed 4 tests, with 0 failures", mod.Runner.PYTEST) == 0
        )

    def test_a_pytest_collection_error_is_inconclusive_not_coverage(self) -> None:
        mod = _load()
        outcome, reason = mod.classify(
            _result(2, stdout="!!! 1 errors during collection !!!\n"), mod.Runner.PYTEST
        )
        assert outcome is mod.Outcome.INCONCLUSIVE
        assert "did not compile" in reason

    def test_a_failing_pytest_witness_is_the_guard_being_noticed(self) -> None:
        mod = _load()
        outcome, _ = mod.classify(_result(1, stdout="1 failed in 0.1s"), mod.Runner.PYTEST)
        assert outcome is mod.Outcome.NOTICED

    def test_the_pytest_invocation_targets_the_node_id_and_leaves_no_cache(self) -> None:
        # A `.pytest_cache` written mid-run would make the final clean-tree
        # check report the harness as having dirtied the repository.
        mod = _load()
        seen: list[list[str]] = []

        def _capture(argv: list[str]) -> subprocess.CompletedProcess[str]:
            seen.append(argv)
            return _result(0)

        mod.run = _capture
        mod.run_named_test("Tests/test_x.py::TestY::test_z", mod.Runner.PYTEST)
        argv = seen[0]
        assert "pytest" in argv
        assert "Tests/test_x.py::TestY::test_z" in argv
        assert argv[argv.index("-p") + 1] == "no:cacheprovider"

    def test_a_mutated_module_is_not_served_from_stale_bytecode(self, tmp_path) -> None:
        """A pytest witness must judge the source the harness just wrote, not a
        cached compile of what was there a moment ago.

        Six pytest mutations target `scripts/verdictui-pm.py` in sequence, and
        each one writes the file, runs pytest, and restores it. Tests load that
        module with `spec_from_file_location`, which honours `__pycache__`, and
        CPython validates that cache on **mtime plus size** at one-second
        granularity. Two rows landing in the same second therefore serve the
        PREVIOUS row's bytecode: the mutation is on disk, the test judges the
        unmutated constant, and the row reports UNNOTICED.

        That is the expensive direction. UNNOTICED reads as "this guard is not
        covered" and invites someone to rewrite a guard that works — the same
        class of wasted hour `no.md` #14 records, where a sweep verdict
        contradicted a direct measurement and the apparatus was at fault. It is
        also a RACE, so it moves between runs: exactly one of the six went
        UNNOTICED on 2026-08-07 and re-running that row alone said NOTICED.

        This test reproduces the race deterministically by writing two versions
        of a module inside one second and asserting the second read sees the
        second version.
        """
        mod = _load()
        module = tmp_path / "subject.py"
        reader = tmp_path / "test_reader.py"
        reader.write_text(
            "import importlib.util, sys\n"
            f"spec = importlib.util.spec_from_file_location('subject', {str(module)!r})\n"
            "m = importlib.util.module_from_spec(spec)\n"
            "sys.modules['subject'] = m\n"
            "spec.loader.exec_module(m)\n"
            "def test_budget():\n"
            "    assert m.BUDGET == 70.0, f'read {m.BUDGET}'\n"
        )

        # Through `run_named_test`, NOT a hand-written argv: the flag under test
        # lives in that function, so a test spelling its own command line would
        # stay red however the harness is fixed — it would be measuring itself.
        # `REPO` is rebound because the harness runs every command with
        # `cwd=REPO`, and the subject module lives in the tmp tree.
        mod.REPO = tmp_path

        # Both versions are 14 bytes, so SIZE cannot separate them, and both are
        # stamped with the SAME mtime so the second cannot either. That stamp is
        # what makes this deterministic instead of a coin flip: pytest's ~0.9 s
        # startup pushes two natural writes into different seconds most of the
        # time, which would let the test pass against the unfixed harness — and
        # a control that passes either way is not a test (`no.md` #12). The
        # sweep hits the same collision by running six rows back-to-back against
        # one file; measured on 2026-08-07 as mtimes ...352.32 and ...352.78,
        # identical to the second, with the mutated module read as unmutated.
        stamp = (1_700_000_000, 1_700_000_000)

        module.write_text("BUDGET = 70.0\n")
        os.utime(module, stamp)
        first = mod.run_named_test(str(reader), mod.Runner.PYTEST)
        assert first.returncode == 0, f"the unmutated baseline must pass: {first.stdout}"

        module.write_text("BUDGET = 85.0\n")
        os.utime(module, stamp)
        second = mod.run_named_test(str(reader), mod.Runner.PYTEST)
        assert second.returncode != 0, (
            "the mutated module was judged as unmutated — pytest served a stale "
            "__pycache__ compile, so this row would report UNNOTICED for a guard "
            f"that works. stdout: {second.stdout}"
        )

    def test_no_swift_mutation_carries_a_pytest_node_id(self) -> None:
        # The mirror of the check below. `swift test --filter` treats a node id
        # as a regex that matches nothing and still exits 0, so getting the
        # runner wrong in one direction is caught only by the baseline check
        # and in the other only by this.
        mod = _load()
        for mutation in mod.MUTATIONS:
            if mutation.runner is mod.Runner.SWIFT:
                assert "::" not in mutation.test, f"node id on a swift runner: {mutation.test}"

    def test_the_bench_stage_gate_conditions_are_all_mutated(self) -> None:
        """Every threshold comparison in `stage_runtime_bench` needs a row.

        This stage decides SLO 1, the product thesis in one number, and it
        shipped on 2026-08-07 asserting a statistic its own Swift test had
        already retired — failing at p95 105.51 ms on a healthy p50 of
        49.09 ms. Nothing caught that, because the catalog had no row for
        WHICH figure the stage gates on: a guard can be wrong in both
        directions (never failing, or failing for load) and the existing
        rows see neither.

        Asserts coverage of the CONDITIONS rather than a fixed count, so
        adding a threshold to the stage fails this until it is mutated —
        a count would merely need to be bumped."""
        mod = _load()
        pm_source = (_PROJECT_ROOT / "scripts" / "verdictui-pm.py").read_text()
        stage = pm_source.split("def stage_runtime_bench")[1].split("\n    def ")[0]

        conditions = [
            line.strip()
            for line in stage.splitlines()
            if line.strip().startswith("if ") and "BUDGET_MS" in line
        ]
        assert conditions, "stage_runtime_bench compares against no budget at all"

        mutated = {m.old for m in mod.MUTATIONS if m.path == "scripts/verdictui-pm.py"}
        for condition in conditions:
            assert condition in mutated, (
                f"stage_runtime_bench gates on `{condition}` and no mutation breaks it — "
                "an unmutated threshold is a gate nobody has shown can fail"
            )

    def test_both_timing_lane_consumers_are_mutated(self) -> None:
        """The two SITES that read the timing predicates each need a row.

        `ConstrainedTimingEnvironment` splits one question into two:
        `isActive` answers "is my wall clock comparable to a developer's?",
        and `canEvaluateElapsedInvariants` answers "can I order two durations
        I measured myself?". Splitting the DEFINITION is only half the fix —
        the catalog already rows that — because the defect recurs at either
        CONSUMER, and from outside the two are indistinguishable:

        * `HarnessTests` naming the clock lane for the overshoot invariant
          retires `no.md` #18's discriminator on any read-only-cache host.
        * `stage_test` wrapping the FULL suite in the explicit human override
          suppresses that same invariant on EVERY host.

        Both leave a gate inert while the suite reads green, which is the
        `no.md` #58 shape. Measured 2026-08-15: forcing the record-only lane
        runs the whole suite to 0 failures, so no existing test can see it.

        Asserts coverage of the two decisive SOURCE LINES rather than a row
        count — a count would merely need bumping when a row is deleted."""
        mod = _load()
        rowed = {(m.path, m.old) for m in mod.MUTATIONS}

        overshoot_lane = "        !ConstrainedTimingEnvironment.canEvaluateElapsedInvariants"
        harness_tests = _PROJECT_ROOT / "Tests" / "VerdictUIProbeTests" / "HarnessTests.swift"
        assert overshoot_lane in harness_tests.read_text(), (
            "HarnessTests no longer assigns the overshoot lane from the "
            "elapsed-invariant predicate — the guard moved or was retired"
        )
        assert ("Tests/VerdictUIProbeTests/HarnessTests.swift", overshoot_lane) in rowed, (
            "the overshoot lane assignment has no mutation row — nothing shows "
            "that re-coupling it to the clock lane would be noticed"
        )

        full_suite_call = (
            "        return _run_streamed_swift_test(\n            timeout=TIMEOUT_SWIFT_TEST,"
        )
        pm_source = (_PROJECT_ROOT / "scripts" / "verdictui-pm.py").read_text()
        assert full_suite_call in pm_source, (
            "stage_test no longer calls the streamed runner unwrapped — either "
            "the override came back or the call was reshaped"
        )
        assert ("scripts/verdictui-pm.py", full_suite_call) in rowed, (
            "stage_test's unwrapped full-suite call has no mutation row — "
            "nothing shows that re-wrapping it in the record-only override "
            "would be noticed"
        )

    def test_every_macro_mutation_is_witnessed_by_an_expansion_snapshot(self) -> None:
        # A macro row whose witness is a RENDER test cannot fail for the defect
        # it exists to catch. SwiftPM rebuilds the `.macro` target but does NOT
        # re-expand macros in a consuming target whose own sources are
        # unchanged, so the test binary keeps the PREVIOUS expansion and passes
        # against a broken plugin.
        #
        # Measured 2026-08-10 in four quadrants (no.md #23): mutated plugin +
        # untouched test file PASSES; mutated + `touch`ed fails naming both
        # swallowed elements; restored is green with a byte-identical restore.
        # The render test is the layer that LOOKS like the strongest evidence,
        # which is exactly why a row must not rest on it.
        mod = _load()
        macro_rows = [m for m in mod.MUTATIONS if m.path.startswith("Sources/VerdictUIMacros/")]
        assert macro_rows, "the macro guards lost their mutations"
        for mutation in macro_rows:
            suite = mutation.test.split("/")[0]
            if mutation.runtime_witness_reason:
                # An explicit, per-row opt-out. Legitimate when the mutated
                # behaviour is not IN the expansion — a change to the support
                # library the expansion merely calls into is rebuilt normally,
                # so the stale-expansion trap does not apply. Required to be
                # stated on the row rather than argued in a comment, so the
                # exception is data the guard can see rather than prose it
                # cannot.
                assert len(mutation.runtime_witness_reason) >= 40, (
                    f"macro row {mutation.name!r} opts out of the snapshot-witness rule with a "
                    "reason too short to be one; say what makes the runtime test able to fail here"
                )
                continue
            # Judged by the PROPERTY, not by the class NAME. This assertion
            # used to read `suite.endswith("MacroTests")`, which is a claim
            # about spelling: splitting VerifiableMacroTests into a
            # ...DiagnosticsTests class (CTS-E1A2E56A) made four correct rows
            # fail a guard that had not changed meaning. A suite is an
            # expansion-snapshot suite when it CALLS assertMacroExpansion, and
            # that is what the file says.
            klass = suite.split(".")[-1]
            witness_files = [
                path
                for path in (_PROJECT_ROOT / "Tests" / "VerdictUIMacroTests").glob("*.swift")
                if f"class {klass}" in path.read_text(encoding="utf-8")
            ]
            assert witness_files, (
                f"macro row {mutation.name!r} names suite {klass!r}, which no file in "
                "Tests/VerdictUIMacroTests declares — the row is witnessed by nothing"
            )
            assert any(
                "assertMacroExpansion" in path.read_text(encoding="utf-8") for path in witness_files
            ), (
                f"macro row {mutation.name!r} is witnessed by {mutation.test!r}, whose suite "
                "never calls assertMacroExpansion — a render test executes the previous "
                "expansion and passes against a broken plugin (no.md #23). If the mutated "
                "behaviour is not in the expansion, set `runtime_witness_reason` saying why."
            )

    def test_a_runtime_witness_opt_out_is_rare_and_declared(self) -> None:
        # The control for the opt-out above. Without it, `runtime_witness_reason`
        # is an escape hatch that can be pasted onto every macro row until the
        # snapshot-witness rule protects nothing and the suite still reads green
        # — the always-true predicate shape of no.md #17.
        #
        # TWO is the count today, raised from one on 2026-08-14 (Wave 10). This
        # is a tripwire, not a budget: a further legitimate opt-out should raise
        # it deliberately, with the reasoning written down, rather than arriving
        # unnoticed.
        #
        # The second opt-out is "generated members stop matching the host type's
        # access level", and it is admitted on a MEASUREMENT rather than an
        # argument. The mutation was hand-applied and its witness run WITHOUT
        # touching any consuming source; it still failed, with the compiler's
        # "must be declared public because it matches a requirement in public
        # protocol" error. The no.md #23 trap therefore cannot apply: the defect
        # IS a compile failure in the consuming target, so a stale expansion is
        # the BROKEN expansion and re-running against it fails identically
        # instead of passing. An assertMacroExpansion snapshot could not witness
        # it at all — the generated text differs by one access keyword and is
        # syntactically valid either way, so only a real build separates them.
        mod = _load()
        opted_out = [
            m
            for m in mod.MUTATIONS
            if m.path.startswith("Sources/VerdictUIMacros/") and m.runtime_witness_reason
        ]
        assert len(opted_out) == 2, (
            "the number of macro rows witnessed by a runtime test changed; each one weakens "
            f"the no.md #23 rule, so raise this deliberately. Opted out: "
            f"{[m.name for m in opted_out]}"
        )

    def test_every_pytest_mutation_names_a_node_id_that_exists(self) -> None:
        # A `--filter`-style name would silently select nothing under pytest.
        mod = _load()
        pytest_mutations = [m for m in mod.MUTATIONS if m.runner is mod.Runner.PYTEST]
        assert pytest_mutations, "the Python guards lost their mutations"
        for mutation in pytest_mutations:
            file_part = mutation.test.split("::")[0]
            assert (_PROJECT_ROOT / file_part).is_file(), mutation.test
            assert mutation.test.count("::") == 2, f"not a node id: {mutation.test}"
        # Shape is not existence. A wrong class name or a renamed method keeps
        # the shape, selects nothing, and scores INCONCLUSIVE forever — which
        # reads as "not proven yet" rather than "this entry is broken". Only
        # collection can tell the two apart, so ask pytest itself. Collection
        # runs no test bodies, so this cannot recurse.
        collected = subprocess.run(
            [
                sys.executable,
                "-m",
                "pytest",
                "--collect-only",
                "-q",
                "-p",
                "no:cacheprovider",
                *[m.test for m in pytest_mutations],
            ],
            cwd=_PROJECT_ROOT,
            capture_output=True,
            text=True,
            check=False,
        )
        assert collected.returncode == 0, (
            "a mutation names a node id pytest cannot collect:\n"
            f"{collected.stdout}{collected.stderr}"
        )


class TestClassify:
    """The verdict on one mutated run.

    Each test loads the module once and holds it: `_load()` builds a fresh
    module object every call, so `_load().classify(...) is _load().Outcome.X`
    compares members of two distinct enum classes and is never true.
    """

    def test_a_failing_assertion_is_the_guard_being_noticed(self) -> None:
        mod = _load()
        outcome, _ = mod.classify(_result(returncode=1, stdout=_ONE_FAILED))
        assert outcome is mod.Outcome.NOTICED

    def test_a_passing_test_means_the_guard_is_uncovered(self) -> None:
        mod = _load()
        outcome, reason = mod.classify(_result(returncode=0, stdout=_ONE_PASSED))
        assert outcome is mod.Outcome.UNNOTICED
        assert "passed with the guard broken" in reason

    def test_a_mutation_that_will_not_compile_proves_nothing(self) -> None:
        # Nonzero exit, but no test ever ran. Counting this as NOTICED is the
        # single easiest way to fake a fully mutation-covered codebase.
        mod = _load()
        outcome, reason = mod.classify(
            _result(returncode=1, stderr="Subject.swift:9:5: error: cannot find 'x'\n")
        )
        assert outcome is mod.Outcome.INCONCLUSIVE
        assert "did not compile" in reason

    def test_a_trap_is_not_an_assertion_noticing_anything(self) -> None:
        mod = _load()
        outcome, reason = mod.classify(
            _result(
                returncode=4,
                stdout=_ONE_FAILED + "Fatal error: unexpected signal code 4\n",
            )
        )
        assert outcome is mod.Outcome.INCONCLUSIVE
        assert "trapped" in reason

    def test_every_swift_mutation_names_a_test_that_still_exists(self) -> None:
        """A row whose test filter matches nothing is proving nothing, and says
        so only after a 35-minute sweep.

        Measured 2026-08-11 (no.md #33): a full sweep reported 9 unverified rows
        against a ticket claiming 7, and FOUR of them had failed with
        "the filter matched no tests before mutating" — they had been dead
        before any mutation was applied. Two went stale in that same session,
        when splitting `VerifiableMacroTests` into a `...DiagnosticsTests` class
        moved the tests their filters named.

        `--verify-targets` structurally cannot catch this: it checks that the
        SOURCE anchor resolves to exactly one site and never reads the test
        filter at all. So this is a static check of the other half — cheap,
        run in the quick gate, and failing at the moment a rename or a split
        breaks a row rather than an hour into the next sweep.
        """
        mod = _load()
        swift_rows = [m for m in mod.MUTATIONS if m.runner is mod.Runner.SWIFT]
        assert swift_rows, "the Swift mutations vanished"

        sources = {
            path: path.read_text(encoding="utf-8")
            for path in (_PROJECT_ROOT / "Tests").rglob("*.swift")
        }
        assert sources, "no Swift test sources found — this check would pass vacuously"

        stale: list[str] = []
        for mutation in swift_rows:
            suite_part, _, method = mutation.test.rpartition("/")
            klass = suite_part.split(".")[-1]

            # The METHOD must exist, and it must exist in the class the filter
            # names — a method that moved to a sibling class is exactly the
            # failure this catches, and searching for the method alone would
            # miss it.
            homes = [text for text in sources.values() if f"func {method}(" in text]
            if not homes:
                stale.append(f"{mutation.name!r}: no test named {method!r} exists")
                continue
            if klass and not any(f"class {klass}" in text for text in homes):
                stale.append(
                    f"{mutation.name!r}: {method!r} exists but not in {klass!r} — "
                    "the filter names a class that does not declare it"
                )

        assert not stale, (
            "mutation rows name tests that cannot be selected, so they verify nothing:\n  "
            + "\n  ".join(stale)
        )

    def test_a_filter_matching_no_tests_is_stale_not_uncovered(self) -> None:
        # Exit 0 with zero tests run. Without the count check this reads as
        # UNNOTICED, sending a reader to audit a guard that is fine while the
        # real fault — a renamed test — goes unmentioned.
        mod = _load()
        outcome, reason = mod.classify(_result(returncode=0, stdout=_NONE_MATCHED))
        assert outcome is mod.Outcome.INCONCLUSIVE
        assert "renamed" in reason


class TestBaselineProblem:
    """A witness must be green before it is asked to testify."""

    def test_a_green_test_is_accepted_as_a_witness(self, monkeypatch: Any) -> None:
        mod = _load()
        monkeypatch.setattr(
            mod, "run_named_test", lambda _test, _runner=None: _result(0, stdout=_ONE_PASSED)
        )
        assert mod.baseline_problem(mod.MUTATIONS[0]) is None

    def test_an_already_failing_test_is_refused(self, monkeypatch: Any) -> None:
        # The lie this exists to stop: a red test fails with the mutation too,
        # so every mutation aimed at it reports NOTICED.
        mod = _load()
        monkeypatch.setattr(
            mod, "run_named_test", lambda _test, _runner=None: _result(1, stdout=_ONE_FAILED)
        )
        problem = mod.baseline_problem(mod.MUTATIONS[0])
        assert problem is not None
        assert "already failing" in problem

    def test_a_filter_matching_nothing_is_refused_before_mutating(self, monkeypatch: Any) -> None:
        mod = _load()
        monkeypatch.setattr(
            mod, "run_named_test", lambda _test, _runner=None: _result(0, stdout=_NONE_MATCHED)
        )
        problem = mod.baseline_problem(mod.MUTATIONS[0])
        assert problem is not None
        assert "renamed" in problem

    def test_a_tree_that_does_not_build_says_so_instead_of_blaming_the_name(
        self, monkeypatch: Any
    ) -> None:
        # A broken build also executes zero tests. Reporting it as a renamed
        # test sends the reader to the wrong file.
        mod = _load()
        monkeypatch.setattr(
            mod,
            "run_named_test",
            lambda _test, _runner=None: _result(
                1, stderr="Subject.swift:3:1: error: expected '}'\n"
            ),
        )
        problem = mod.baseline_problem(mod.MUTATIONS[0])
        assert problem is not None
        assert "does not build" in problem
        assert "renamed" not in problem


class TestSkippableWitness:
    """A test that SKIPS is not a witness, and XCTest will not say it skipped.

    Measured 2026-08-15 on `ThirdPartyAuditTests/testTheReaderIsBoundedAgainst
    AHostileTree`, whose first three statements are `XCTSkipIf(isHeadless)`,
    `XCTSkipUnless(AXReader.isTrusted)` and a skip when no third-party app is
    running. On a host where any of those fires, XCTest prints

        Test Case '-[...]' passed (0.062 seconds)
        Executed 1 test, with 0 failures (0 unexpected)

    and exits 0 — **byte-identical to a real pass**, with no skip marker
    anywhere in the output at any verbosity. `--xunit-output` does not rescue
    it either: the file emitted here covers only the swift-testing lane (0
    tests), not the XCTest lane.

    So `classify` sees `ran == 1`, `returncode == 0`, and reports
    `UNNOTICED — the test passed with the guard broken`. That sentence is
    false in the most expensive direction available: the guard is fine and the
    test never executed a line of it, yet the sweep accuses working code.
    It is the `no.md` #58 shape (a gate that stopped gating reads exactly like
    a gate that passed) arriving through the environment rather than a flag.

    The fix cannot be a stdout parse, because there is nothing to parse. A row
    whose witness has environmental preconditions must SAY SO on the row —
    the same discipline as `runtime_witness_reason`, where a claim about the
    apparatus is stated and checked rather than argued in a comment.
    """

    def _skippable(self, mod: Any, reason: str) -> Any:
        return mod.Mutation(
            name="synthetic",
            path="Sources/Subject.swift",
            old="a",
            new="b",
            test="T/t",
            skips_when=reason,
        )

    def test_a_row_declaring_it_can_skip_is_not_scored_as_a_witness(self, monkeypatch: Any) -> None:
        # The whole point: a green-looking run from a skippable witness must be
        # refused BEFORE it can be read as UNNOTICED.
        mod = _load()
        monkeypatch.setattr(
            mod, "run_named_test", lambda _test, _runner=None: _result(0, stdout=_ONE_PASSED)
        )
        problem = mod.baseline_problem(self._skippable(mod, "needs a window server"))
        assert problem is not None
        assert "skip" in problem.lower()
        assert "needs a window server" in problem, (
            "the row's stated reason must reach the operator — a bare 'it can skip' "
            "gives them nothing to act on"
        )

    def test_a_row_without_the_declaration_is_still_scored(self, monkeypatch: Any) -> None:
        # The negative control. Without it, "skippable rows are refused" is
        # satisfied by an implementation that refuses EVERY row, which would
        # silently retire the whole sweep while reporting a clean summary
        # (`no.md` #17 — a predicate whose only exercised branch is the
        # permissive one cannot be told from one that is always true).
        mod = _load()
        monkeypatch.setattr(
            mod, "run_named_test", lambda _test, _runner=None: _result(0, stdout=_ONE_PASSED)
        )
        assert mod.baseline_problem(mod.MUTATIONS[0]) is None

    def test_the_ax_bounded_row_declares_its_preconditions(self) -> None:
        """The row this defect was found on must carry the declaration.

        Pinned by NAME rather than by a count, so deleting the declaration
        fails here instead of quietly restoring the false UNNOTICED. Measured
        2026-08-15: this row was the ONLY UNNOTICED in a 121-row sweep, and it
        was not a coverage gap at all — the witness had skipped.
        """
        mod = _load()
        row = next(
            (
                m
                for m in mod.MUTATIONS
                if m.test.startswith("ThirdPartyAuditTests/testTheReaderIsBounded")
            ),
            None,
        )
        assert row is not None, "the AX bounded-walk row has been renamed or removed"
        assert row.skips_when, (
            "this witness skips on a headless host, without Accessibility trust, or when no "
            "third-party app is running — and XCTest reports every one of those as 'passed', "
            "so without the declaration the sweep reports the guard as unverified"
        )


class TestTargetProblem:
    """The text a mutation replaces must exist exactly once."""

    def _mutation(self, mod: Any, old: str) -> Any:
        return mod.Mutation(
            name="synthetic", path="Sources/Subject.swift", old=old, new="x", test="T/t"
        )

    def _stage(self, mod: Any, tmp_path: Path, body: str) -> None:
        (tmp_path / "Sources").mkdir(parents=True)
        (tmp_path / "Sources" / "Subject.swift").write_text(body)
        mod.REPO = tmp_path

    def test_a_target_present_once_has_no_problem(self, tmp_path: Path) -> None:
        mod = _load()
        self._stage(mod, tmp_path, "let a = 1\nlet b = 2\n")
        assert mod.target_problem(self._mutation(mod, "let a = 1")) is None

    def test_a_target_present_twice_is_refused(self, tmp_path: Path) -> None:
        # Replacing both sites mutates more than the guard under test, so the
        # named test failing would not localise to anything.
        mod = _load()
        self._stage(mod, tmp_path, "let a = 1\nlet a = 1\n")
        problem = mod.target_problem(self._mutation(mod, "let a = 1"))
        assert problem is not None
        assert "appears 2 times" in problem

    def test_a_target_that_has_vanished_is_refused(self, tmp_path: Path) -> None:
        mod = _load()
        self._stage(mod, tmp_path, "let a = 1\n")
        problem = mod.target_problem(self._mutation(mod, "let gone = 1"))
        assert problem is not None
        assert "appears 0 times" in problem

    def test_a_missing_file_is_named_rather_than_raising(self, tmp_path: Path) -> None:
        mod = _load()
        mod.REPO = tmp_path
        problem = mod.target_problem(self._mutation(mod, "anything"))
        assert problem is not None
        assert "does not exist" in problem


class TestResolveInRepo:
    """Mutation paths are literals, but they are still joined onto a root."""

    def test_a_path_inside_the_repo_resolves(self, tmp_path: Path) -> None:
        mod = _load()
        mod.REPO = tmp_path
        assert mod.resolve_in_repo("Sources/Subject.swift") == (
            tmp_path / "Sources" / "Subject.swift"
        )

    def test_a_path_climbing_out_of_the_repo_is_refused(self, tmp_path: Path) -> None:
        mod = _load()
        mod.REPO = tmp_path / "repo"
        (tmp_path / "repo").mkdir()
        with pytest.raises(SystemExit):
            mod.resolve_in_repo("../outside.swift")


class TestGitIsClean:
    """`git diff --quiet` would miss staged and untracked changes."""

    def test_no_porcelain_output_means_clean(self, monkeypatch: Any) -> None:
        mod = _load()
        monkeypatch.setattr(mod, "run", lambda _args: _result(0, stdout=""))
        assert mod.git_is_clean() is True

    def test_an_untracked_file_counts_as_dirty(self, monkeypatch: Any) -> None:
        mod = _load()
        monkeypatch.setattr(mod, "run", lambda _args: _result(0, stdout="?? stray.swift\n"))
        assert mod.git_is_clean() is False

    def test_a_staged_change_counts_as_dirty(self, monkeypatch: Any) -> None:
        # This is the case `git diff --quiet` returned 0 for.
        mod = _load()
        monkeypatch.setattr(mod, "run", lambda _args: _result(0, stdout="M  Subject.swift\n"))
        assert mod.git_is_clean() is False


class TestCheckRestoresTheFile:
    """A mutation run must not be able to leave the tree altered."""

    def _stage(self, mod: Any, tmp_path: Path) -> tuple[Any, Path]:
        (tmp_path / "Sources").mkdir(parents=True)
        source = tmp_path / "Sources" / "Subject.swift"
        source.write_text("let guarded = true\n")
        mod.REPO = tmp_path
        mutation = mod.Mutation(
            name="synthetic",
            path="Sources/Subject.swift",
            old="let guarded = true",
            new="let guarded = false",
            test="T/t",
        )
        return mutation, source

    def test_a_refused_baseline_never_writes_the_mutation_at_all(
        self, tmp_path: Path, monkeypatch: Any
    ) -> None:
        # When the witness is already red the source must not be touched: there
        # is nothing to learn, and a mutation written and restored is a window
        # in which a kill leaves the tree broken for no benefit.
        mod = _load()
        mutation, source = self._stage(mod, tmp_path)
        calls: list[str] = []

        def _run(_test: str, _runner: Any = None) -> subprocess.CompletedProcess[str]:
            calls.append(source.read_text())
            return _result(1, stdout=_ONE_FAILED)

        monkeypatch.setattr(mod, "run_named_test", _run)
        assert mod.check(mutation) is False
        assert calls == ["let guarded = true\n"], "only the baseline should have run"
        assert source.read_text() == "let guarded = true\n"

    def test_the_file_is_restored_even_when_the_mutation_goes_unnoticed(
        self, tmp_path: Path, monkeypatch: Any
    ) -> None:
        mod = _load()
        mutation, source = self._stage(mod, tmp_path)
        calls: list[str] = []

        def _run(_test: str, _runner: Any = None) -> subprocess.CompletedProcess[str]:
            calls.append(source.read_text())
            # Green baseline, then a green mutated run: UNNOTICED.
            return _result(0, stdout=_ONE_PASSED)

        monkeypatch.setattr(mod, "run_named_test", _run)
        assert mod.check(mutation) is False
        assert calls[0] == "let guarded = true\n", "baseline must run unmutated"
        assert calls[1] == "let guarded = false\n", "the second run must be mutated"
        assert source.read_text() == "let guarded = true\n"

    def test_a_verified_guard_reports_true_and_restores(
        self, tmp_path: Path, monkeypatch: Any
    ) -> None:
        mod = _load()
        mutation, source = self._stage(mod, tmp_path)
        outcomes = iter([_result(0, stdout=_ONE_PASSED), _result(1, stdout=_ONE_FAILED)])
        monkeypatch.setattr(mod, "run_named_test", lambda _t, _runner=None: next(outcomes))
        assert mod.check(mutation) is True
        assert source.read_text() == "let guarded = true\n"


class TestSha256:
    """The restore check's only evidence that a file came back unchanged."""

    def test_the_digest_matches_hashlib_over_the_same_bytes(self, tmp_path: Path) -> None:
        target = tmp_path / "Subject.swift"
        target.write_bytes(b"let guarded = true\n")
        expected = hashlib.sha256(b"let guarded = true\n").hexdigest()
        assert _load().sha256(target) == expected

    def test_a_one_byte_change_changes_the_digest(self, tmp_path: Path) -> None:
        # The property `check` relies on: restoring "close enough" is caught.
        mod = _load()
        target = tmp_path / "Subject.swift"
        target.write_bytes(b"let guarded = true\n")
        before = mod.sha256(target)
        target.write_bytes(b"let guarded = true \n")
        assert mod.sha256(target) != before

    def test_it_reads_bytes_rather_than_decoded_text(self, tmp_path: Path) -> None:
        # A text-mode read would normalise CRLF on some platforms and report two
        # different files as identical.
        mod = _load()
        unix, dos = tmp_path / "a.swift", tmp_path / "b.swift"
        unix.write_bytes(b"a\nb\n")
        dos.write_bytes(b"a\r\nb\r\n")
        assert mod.sha256(unix) != mod.sha256(dos)


class TestRun:
    """The subprocess wrapper every other call goes through."""

    def test_it_reports_the_real_exit_code_rather_than_raising(self) -> None:
        # `check=False` on purpose: a nonzero exit is the signal this whole
        # script reads, not an error condition.
        result = _load().run([sys.executable, "-c", "raise SystemExit(3)"])
        assert result.returncode == 3

    def test_it_captures_stdout_and_stderr_as_text(self) -> None:
        result = _load().run(
            [sys.executable, "-c", "import sys; print('out'); print('err', file=sys.stderr)"]
        )
        assert result.stdout.strip() == "out"
        assert result.stderr.strip() == "err"

    def test_it_runs_in_the_repository_not_the_caller_s_directory(self, tmp_path: Path) -> None:
        # Mutation paths are relative to REPO, and `git status` must describe the
        # repository rather than wherever pytest was invoked from.
        mod = _load()
        mod.REPO = tmp_path
        result = mod.run([sys.executable, "-c", "import os; print(os.getcwd())"])
        assert Path(result.stdout.strip()).resolve() == tmp_path.resolve()

    def test_a_hanging_command_is_cut_off_rather_than_hanging_forever(self) -> None:
        # The script edits source files while it waits, so an unbounded wait
        # leaves the tree mutated indefinitely.
        mod = _load()
        mod.TEST_TIMEOUT_SECONDS = 0.5
        with pytest.raises(subprocess.TimeoutExpired):
            mod.run([sys.executable, "-c", "import time; time.sleep(30)"])


class TestVerifyTargets:
    """The cheap rot check CI and PM run."""

    def test_every_swift_mutation_names_a_test_that_exists(self) -> None:
        """The Swift half of the catalog needs the same existence check pytest got.

        `--verify-targets` validates only that `mutation.old` appears once in
        `mutation.path`; the `test=` field is never checked for the Swift
        mutations. So a renamed or deleted witness leaves the catalog reporting
        "all N targets resolve" — measured: renaming
        `testRunStopsEarlyOnTheFirstFailure` and touching no source still exits 0
        with "all 31 mutation targets resolve to exactly one site".

        A full run then scores that mutation INCONCLUSIVE, which reads as "not
        proven yet" rather than "this entry is broken", and `main()` only fails
        on NOT-NOTICED, so an INCONCLUSIVE never fails the harness either. The
        guard the fourth review pass built for pytest (`--collect-only`) simply
        was not mirrored here — this is that mirror.

        Source text rather than `swift test --list-tests`: listing needs a build
        (~4 min under strict flags) and this suite is the sub-second quick gate.
        A declaration grep cannot confirm the test RUNS, but it does confirm the
        name in the catalog still exists, which is the drift being guarded.
        """
        mod = _load()
        swift_mutations = [m for m in mod.MUTATIONS if m.runner is mod.Runner.SWIFT]
        assert swift_mutations, "no swift mutations — this test would check nothing"

        declarations: set[str] = set()
        for path in (_PROJECT_ROOT / "Tests").rglob("*.swift"):
            for match in re.finditer(r"func\s+(test[A-Za-z0-9_]*)\s*\(", path.read_text()):
                declarations.add(match.group(1))
        assert declarations, "found no test declarations — the scan itself is broken"

        missing = []
        for mutation in swift_mutations:
            # "SuiteName/testMethod" or a bare method name.
            method = mutation.test.rsplit("/", maxsplit=1)[-1]
            if method not in declarations:
                missing.append(f"{mutation.name!r} names {mutation.test!r}")
        assert not missing, "swift mutations naming tests that do not exist:\n" + "\n".join(missing)

    def test_the_real_catalog_still_points_at_real_source(self) -> None:
        # Not synthetic: this is the assertion that keeps the shipped mutation
        # list from drifting away from the code it claims to cover.
        assert _load().verify_targets() == 0

    def test_an_empty_catalog_fails_rather_than_reporting_nothing_wrong(self) -> None:
        # "all 0 targets resolve" would exit 0 and turn PM's stage green by
        # deleting the thing it checks — a validator that skips its work must
        # fail, not pass.
        mod = _load()
        mod.MUTATIONS = []
        assert mod.verify_targets() == 1

    def test_a_stale_target_is_reported_nonzero(self, tmp_path: Path) -> None:
        mod = _load()
        (tmp_path / "Sources").mkdir(parents=True)
        (tmp_path / "Sources" / "Subject.swift").write_text("let a = 1\n")
        mod.REPO = tmp_path
        mod.MUTATIONS = [
            mod.Mutation(
                name="synthetic",
                path="Sources/Subject.swift",
                old="let vanished = 1",
                new="x",
                test="T/t",
            )
        ]
        assert mod.verify_targets() == 1


class TestMidRunTreeGuard:
    """A sweep runs for ~30 minutes; the tree must stay clean for ALL of it.

    `git_is_clean` was checked once at the top and then trusted. An edit landing
    mid-run makes every case after it measure a tree nobody intended: the
    baseline stops building and the harness prints SETUP FAILED, which reads as
    a broken guard rather than as a dirty tree. That happened twice in one
    session on concurrent doc edits, and the second time it filed a false
    coverage gap against a mutation that was fine.
    """

    def test_main_aborts_when_the_tree_goes_dirty_mid_run(self, monkeypatch) -> None:
        mod = _load()
        calls = {"n": 0}

        def _clean() -> bool:
            # Clean for the entry check, dirty once the loop starts.
            calls["n"] += 1
            return calls["n"] <= 1

        monkeypatch.setattr(mod, "git_is_clean", _clean)
        # `check` must never run: the abort precedes it.
        monkeypatch.setattr(
            mod, "check", lambda _: pytest.fail("check ran after the tree went dirty")
        )
        assert mod.main([]) == 2

    def test_a_clean_tree_still_reaches_the_mutations(self, monkeypatch) -> None:
        """The control: without this, the test above would pass on a `main`
        that aborted unconditionally."""
        mod = _load()
        monkeypatch.setattr(mod, "git_is_clean", lambda: True)
        seen: list[str] = []

        def _check(mutation) -> bool:
            seen.append(mutation.name)
            return True

        monkeypatch.setattr(mod, "check", _check)
        assert mod.main([]) == 0
        assert len(seen) == len(mod.MUTATIONS), "not every mutation was reached"


class TestPerRowTreeOwnership:
    """`main`'s clean-tree check is a PRECONDITION, not an invariant.

    It is evaluated between rows, so a write landing DURING a row's test run is
    invisible to it — and that is the window that matters, because a row's test
    run is where all the time goes. The harness then classifies a result
    produced against a file nobody intended and prints UNNOTICED, which reads as
    "your guard is untested" and invites rewriting correct code. That cost about
    an hour on 2026-08-07 (`no.md` #14, CTS-8795E0FE).
    """

    @staticmethod
    def _mutation(mod, tmp_path):
        target = tmp_path / "subject.swift"
        target.write_text("let guardValue = 1\n")
        return target, mod.Mutation(
            name="probe",
            path="subject.swift",
            old="let guardValue = 1",
            new="let guardValue = 2",
            test="Fake/testSomething",
        )

    def test_a_write_during_the_witness_run_aborts_rather_than_scoring(
        self, monkeypatch, tmp_path
    ) -> None:
        mod = _load()
        target, mutation = self._mutation(mod, tmp_path)
        monkeypatch.setattr(mod, "resolve_in_repo", lambda _: target)
        monkeypatch.setattr(mod, "target_problem", lambda _: None)
        monkeypatch.setattr(mod, "baseline_problem", lambda _: None)

        def _run_and_meddle(_test, _runner):
            # Exactly what a concurrent editor save or sibling agent does: write
            # to the file the harness is holding, while its witness runs.
            target.write_text("let guardValue = 99\n")
            return subprocess.CompletedProcess([], 1, "Executed 1 test", "")

        monkeypatch.setattr(mod, "run_named_test", _run_and_meddle)

        with pytest.raises(SystemExit) as exc:
            mod.check(mutation)

        assert exc.value.code == 3, "a tree we do not own must abort, not produce a verdict"

    def test_an_untouched_file_still_produces_its_verdict(self, monkeypatch, tmp_path) -> None:
        """The control. Without it, the test above is satisfied by a harness
        that aborts on every row — which would report the same exit code while
        verifying nothing at all."""
        mod = _load()
        target, mutation = self._mutation(mod, tmp_path)
        monkeypatch.setattr(mod, "resolve_in_repo", lambda _: target)
        monkeypatch.setattr(mod, "target_problem", lambda _: None)
        monkeypatch.setattr(mod, "baseline_problem", lambda _: None)
        monkeypatch.setattr(
            mod,
            "run_named_test",
            lambda _t, _r: subprocess.CompletedProcess([], 1, "Executed 1 test", ""),
        )

        assert mod.check(mutation) is True
        assert target.read_text() == "let guardValue = 1\n", "the file must be restored"


class TestMain:
    """Argument handling and the dirty-tree precondition."""

    def test_verify_targets_mode_skips_the_clean_tree_requirement(self, monkeypatch: Any) -> None:
        # PM runs this mid-edit, so requiring a clean tree would make it
        # unusable exactly when it is most useful.
        mod = _load()
        monkeypatch.setattr(mod, "git_is_clean", lambda: False)
        monkeypatch.setattr(mod, "verify_targets", lambda: 0)
        assert mod.main(["--verify-targets"]) == 0

    def test_a_dirty_tree_refuses_a_full_run(self, monkeypatch: Any) -> None:
        mod = _load()
        monkeypatch.setattr(mod, "git_is_clean", lambda: False)
        assert mod.main([]) == 2

    def test_an_unverified_mutation_exits_nonzero(self, monkeypatch: Any) -> None:
        mod = _load()
        monkeypatch.setattr(mod, "git_is_clean", lambda: True)
        monkeypatch.setattr(mod, "check", lambda _m: False)
        assert mod.main([]) == 1

    def test_an_empty_catalog_fails_a_full_run_too(self, monkeypatch: Any) -> None:
        mod = _load()
        mod.MUTATIONS = []
        monkeypatch.setattr(mod, "git_is_clean", lambda: True)
        assert mod.main([]) == 1

    def test_all_mutations_verified_exits_zero(self, monkeypatch: Any) -> None:
        mod = _load()
        monkeypatch.setattr(mod, "git_is_clean", lambda: True)
        monkeypatch.setattr(mod, "check", lambda _m: True)
        assert mod.main([]) == 0

    def test_a_run_that_dirtied_the_tree_exits_nonzero_despite_passing(
        self, monkeypatch: Any
    ) -> None:
        # Every mutation verified, but something was left behind: that is a
        # failure of the run, not a footnote to a success.
        mod = _load()
        states = iter([True, False])
        monkeypatch.setattr(mod, "git_is_clean", lambda: next(states))
        monkeypatch.setattr(mod, "check", lambda _m: True)
        assert mod.main([]) == 2


class TestMacroExpansionFreshness:
    """A Swift witness must judge the plugin the harness just wrote.

    SwiftPM rebuilds a `.macro` plugin when its source changes but does NOT
    re-expand macros in a consuming target whose own sources are unchanged, so a
    RUNTIME witness executes the PREVIOUS expansion and passes against a broken
    plugin. That is `no.md` #23/#26 — and it defeats this harness in the
    expensive direction, because a working guard then reports UNNOTICED, which
    reads as "not covered" and invites rewriting correct code.

    Measured 2026-08-11: `the two macros stop composing over a custom view` went
    UNNOTICED in a full sweep, and the SAME mutation applied by hand — with the
    consuming test files touched first — was NOTICED at exit 1 with one test
    executed, failing on `vacuous-verdict`. The row's own note already claimed a
    hand-verification the harness could not reproduce, because the hand check
    followed the touch discipline and the harness did not.
    """

    def test_every_declared_macro_dir_is_restamped_not_just_the_first(self, tmp_path: Any) -> None:
        """The helper's own contract, which its caller's test cannot observe.

        `test_the_swift_runner_restamps_macro_consuming_sources` asserts that the
        RUNNER calls this, and it is right to go through `run_named_test` — the
        defect it guards was the runner not calling it at all. But that test
        creates ONE directory, so it holds identically whether the loop covers
        every entry in `MACRO_CONSUMING_TEST_DIRS` or stops after the first.

        That distinction is not cosmetic. A stale expansion in ANY consuming
        target makes a runtime witness execute the previous plugin build, and
        the harness then prints UNNOTICED for a guard that works (`no.md`
        #23/#26/#28) — the expensive direction, because it reads as a coverage
        gap and invites rewriting correct code. A loop that silently covered
        only `VerdictUIMacroTests` would leave `VerdictUIMacroRuntimeTests`
        stale forever with every signal green.

        Asserted over the DECLARED tuple rather than a hard-coded list of two,
        so adding a third directory extends this test instead of leaving it
        quietly behind (lesson 219/240 — a rule keyed on a hand-copied subset is
        blind to everything the subset omits).
        """
        mod = _load()
        assert len(mod.MACRO_CONSUMING_TEST_DIRS) >= 2, (
            "this test discriminates 'covers all dirs' from 'covers the first'; "
            "with fewer than two declared dirs it cannot fail for its own reason"
        )

        stale = 1_700_000_000
        sources = []
        for directory in mod.MACRO_CONSUMING_TEST_DIRS:
            root = tmp_path / directory
            root.mkdir(parents=True)
            source = root / "SomeMacroTests.swift"
            source.write_text("// consuming test\n")
            os.utime(source, (stale, stale))
            sources.append(source)

        mod.REPO = tmp_path
        mod.refresh_macro_expansions()

        unstamped = [str(s) for s in sources if s.stat().st_mtime == stale]
        assert not unstamped, f"left stale (SwiftPM will reuse the old expansion): {unstamped}"

    def test_a_missing_macro_dir_is_skipped_rather_than_raising(self, tmp_path: Any) -> None:
        """A worktree need not contain every declared directory.

        The harness runs in detached verification worktrees and in trees where a
        target has not been created yet. If an absent directory raised, the
        Swift path would die before the runner ever started — turning a missing
        *optional* input into a hard failure of the whole sweep.

        The paired positive control is the point: without it, "does not raise"
        is satisfied by a helper that returns immediately and stamps NOTHING,
        which is the silent-no-op this guard exists to forbid (`no.md` #17 — a
        predicate whose tests only exercise one branch cannot tell a working
        rule from one that is always true).
        """
        mod = _load()
        present = tmp_path / mod.MACRO_CONSUMING_TEST_DIRS[0]
        present.mkdir(parents=True)
        source = present / "SomeMacroTests.swift"
        source.write_text("// consuming test\n")
        stale = 1_700_000_000
        os.utime(source, (stale, stale))

        # Every OTHER declared directory is deliberately absent.
        mod.REPO = tmp_path
        mod.refresh_macro_expansions()  # must not raise

        assert source.stat().st_mtime != stale, (
            "skipping absent directories must not stop the present one being "
            "stamped — a helper that no-ops entirely would also 'not raise'"
        )

    def test_the_stamp_resolves_against_repo_not_the_process_cwd(
        self, tmp_path: Any, monkeypatch: Any
    ) -> None:
        """The failure this closes is invisible: it touches nothing, silently.

        Every other path in this harness resolves against `REPO`. A helper that
        read the process cwd instead would find no directories in a detached
        worktree or under a different working directory, skip its loop, and
        return normally — reporting success while doing nothing at all, which is
        precisely the stale-expansion condition it exists to prevent.

        The cwd is pointed at a decoy tree holding an identically-named source,
        so a cwd-resolving implementation would stamp the WRONG file and leave
        the real one stale. Asserting both halves is what separates the two.
        """
        mod = _load()
        stale = 1_700_000_000

        real_root = tmp_path / "real"
        real = real_root / mod.MACRO_CONSUMING_TEST_DIRS[0] / "SomeMacroTests.swift"
        real.parent.mkdir(parents=True)
        real.write_text("// the real consuming test\n")
        os.utime(real, (stale, stale))

        decoy_root = tmp_path / "decoy"
        decoy = decoy_root / mod.MACRO_CONSUMING_TEST_DIRS[0] / "SomeMacroTests.swift"
        decoy.parent.mkdir(parents=True)
        decoy.write_text("// a same-named file under the cwd\n")
        os.utime(decoy, (stale, stale))

        mod.REPO = real_root
        monkeypatch.chdir(decoy_root)
        mod.refresh_macro_expansions()

        assert real.stat().st_mtime != stale, "the REPO-rooted source was not stamped"
        assert decoy.stat().st_mtime == stale, (
            "a file under the process cwd was stamped — the helper is resolving "
            "against the cwd, so in any worktree it would touch nothing"
        )

    def test_the_swift_runner_restamps_macro_consuming_sources(
        self, tmp_path: Any, monkeypatch: Any
    ) -> None:
        """The mechanism, asserted where it is cheap to observe.

        Running a real `swift test` here would cost minutes; what makes the
        harness honest is narrower and directly checkable — that the Swift path
        bumps the mtime of every macro-consuming test source before the runner
        reads it. Asserted through `run_named_test` rather than by calling
        `refresh_macro_expansions` directly, because the defect was the runner
        NOT CALLING it: a test that invoked the helper itself would pass against
        the unfixed harness and prove nothing (`no.md` #12).
        """
        mod = _load()
        consuming = tmp_path / "Tests" / "VerdictUIMacroTests"
        consuming.mkdir(parents=True)
        source = consuming / "SomeMacroTests.swift"
        source.write_text("// consuming test\n")

        stale = 1_700_000_000
        os.utime(source, (stale, stale))
        mod.REPO = tmp_path

        # The runner is stubbed: this asserts what happens BEFORE the subprocess,
        # so the real toolchain never has to run.
        monkeypatch.setattr(
            mod,
            "run",
            lambda *_a, **_k: SimpleNamespace(
                returncode=0, stdout="Executed 1 test, with 0 failures", stderr=""
            ),
        )
        mod.run_named_test("AnyTests/testAnything", mod.Runner.SWIFT)

        assert source.stat().st_mtime > stale, (
            "the Swift path left a macro-consuming source at its old mtime, so "
            "SwiftPM will serve the previous expansion and a broken plugin passes"
        )

    def test_the_pytest_path_does_not_restamp_swift_sources(
        self, tmp_path: Any, monkeypatch: Any
    ) -> None:
        """The negative control.

        Without it, "the runner restamps sources" is satisfied by a harness that
        restamps unconditionally on every path — including pytest rows, which
        have their own cache defeat in `-B` and no macro expansion to refresh.
        A rule that is always true cannot distinguish a working runner from a
        broken one.
        """
        mod = _load()
        consuming = tmp_path / "Tests" / "VerdictUIMacroTests"
        consuming.mkdir(parents=True)
        source = consuming / "SomeMacroTests.swift"
        source.write_text("// consuming test\n")

        stale = 1_700_000_000
        os.utime(source, (stale, stale))
        mod.REPO = tmp_path

        monkeypatch.setattr(
            mod,
            "run",
            lambda *_a, **_k: SimpleNamespace(returncode=0, stdout="1 passed", stderr=""),
        )
        mod.run_named_test("Tests/test_x.py::test_y", mod.Runner.PYTEST)

        assert source.stat().st_mtime == stale, (
            "the pytest path touched a Swift source it has no reason to rebuild"
        )


class TestSweepMarker:
    """A mutation sweep must announce itself to READERS, not only to writers.

    `no.md` #14/#21 close the concurrent-WRITER hole: a write during a sweep
    corrupts the verdict, and the per-row hash guard aborts on it. Neither can
    see a concurrent READER, because a reader writes nothing — yet a reader that
    FILES issues turns a deliberate red into a fabricated regression.

    Measured 2026-08-12: a background PM sampled this repo during a hand-applied
    mutation and filed two P1s (CTS-36AA316A, CTS-D69CD61A) citing exact
    file:line locations for a defect that did not exist. Both were falsified on
    a clean tree and closed.
    """

    def test_the_marker_is_absent_when_no_sweep_is_running(self):
        mod = _load()
        # The control. Without it, "the marker suppresses filing" is satisfied
        # by a marker that is ALWAYS present, which would silence issue filing
        # permanently — strictly worse than the noise it prevents.
        assert not mod.sweep_in_progress()

    def test_a_sweep_announces_itself_and_stops_when_it_ends(self, tmp_path, monkeypatch):
        mod = _load()
        monkeypatch.setattr(mod, "SWEEP_MARKER", tmp_path / ".mutation-in-progress")
        assert not mod.sweep_in_progress()
        with mod.sweep_marker():
            assert mod.sweep_in_progress(), "a live sweep did not announce itself"
        assert not mod.sweep_in_progress(), "the marker outlived the sweep"

    def test_the_marker_is_removed_even_when_the_sweep_raises(self, tmp_path, monkeypatch):
        mod = _load()
        # The half that matters most. A marker leaked by a crashed sweep would
        # suppress issue filing until its TTL expired — converting a
        # false-positive problem into a blind one.
        monkeypatch.setattr(mod, "SWEEP_MARKER", tmp_path / ".mutation-in-progress")
        with contextlib.suppress(mod.SweepAborted):
            with mod.sweep_marker():
                raise mod.SweepAborted
        assert not mod.sweep_in_progress(), "an aborted sweep leaked its marker"

    def test_a_stale_marker_does_not_suppress_forever(self, tmp_path, monkeypatch):
        mod = _load()
        # A sweep killed by SIGKILL cannot run its `finally`. Without a TTL its
        # marker would silence reporting for good, and nothing would ever notice
        # — the failure is that everything looks quiet.
        marker = tmp_path / ".mutation-in-progress"
        monkeypatch.setattr(mod, "SWEEP_MARKER", marker)
        stale = time.time() - mod.SWEEP_MARKER_TTL_SECONDS - 1
        marker.write_text(f"12345 {stale}\n")
        assert not mod.sweep_in_progress(), "a stale marker still suppressed filing"

    def test_a_malformed_marker_is_treated_as_absent(self, tmp_path, monkeypatch):
        mod = _load()
        # Fail OPEN here, deliberately and unusually: this guard suppresses
        # reporting, so an unreadable marker must not be able to silence it.
        # The usual fail-closed rule protects a check that ASSERTS something;
        # this one only ever excuses, and an excuse that cannot be verified
        # should not be honoured.
        marker = tmp_path / ".mutation-in-progress"
        monkeypatch.setattr(mod, "SWEEP_MARKER", marker)
        for content in ("", "garbage", "12345 not-a-timestamp", "only-one-field"):
            marker.write_text(content)
            assert not mod.sweep_in_progress(), (
                f"a malformed marker ({content!r}) suppressed filing"
            )

    def test_the_pm_and_the_harness_agree_on_the_marker_ttl(self):
        """The PM READS the marker the harness WRITES, so their TTLs are one rule.

        They cannot import each other — `mutation-check.py` is hyphen-named and
        so is not importable as a module — which means neither file can read the
        other's value and a drift is invisible from both sides. That is the
        two-implementations-of-one-rule shape (`no.md` #45's cousin): each copy's
        tests assert it against itself and agree.

        A disagreement is a real window, not a tidiness issue: for the interval
        between the two values, the harness believes a sweep is live while the PM
        believes it has expired, and the PM resumes filing issues against a tree
        that is still deliberately mutated — which is the exact defect the marker
        was built to prevent (CTS-36AA316A, CTS-D69CD61A).
        """
        mod = _load()
        pm = _load_named("verdictui_pm", _PROJECT_ROOT / "scripts" / "verdictui-pm.py")
        assert mod.SWEEP_MARKER_TTL_SECONDS == pm.MUTATION_SWEEP_TTL_SECONDS, (
            f"the harness writes a marker it considers valid for "
            f"{mod.SWEEP_MARKER_TTL_SECONDS}s while the PM reads it as valid for "
            f"{pm.MUTATION_SWEEP_TTL_SECONDS}s — for the difference, one believes a "
            f"sweep is live and the other files issues against the mutated tree"
        )


class TestSweep:
    """`sweep` — the loop that turns a catalog into a verdict.

    Untested until 2026-08-13 (CIS-902C382E), which mattered because the
    function owns the one behaviour that decides whether a whole run's results
    mean anything: it re-checks tree cleanliness BETWEEN rows, so a mid-run edit
    aborts instead of silently scoring every later row against a tree nobody
    intended (`no.md` #14/#21).
    """

    def test_it_returns_the_names_that_went_unverified(self, monkeypatch):
        mod = _load()
        monkeypatch.setattr(mod, "git_is_clean", lambda: True)
        # `check` is the per-row verdict; sweep's own job is only to collect the
        # rows that failed, so it is stubbed by NAME rather than by running any
        # real mutation.
        monkeypatch.setattr(mod, "check", lambda m: m.name != "bad")
        rows = [
            mod.Mutation(name="good", path="p", old="o", new="n", test="t"),
            mod.Mutation(name="bad", path="p", old="o", new="n", test="t"),
        ]

        assert mod.sweep(rows) == ["bad"]

    def test_a_clean_run_reports_no_failures(self, monkeypatch):
        mod = _load()
        monkeypatch.setattr(mod, "git_is_clean", lambda: True)
        monkeypatch.setattr(mod, "check", lambda m: True)
        rows = [mod.Mutation(name="a", path="p", old="o", new="n", test="t")]

        # The control. Without it, "returns the failures" is satisfied by a
        # sweep that reports every row as failing.
        assert mod.sweep(rows) == []

    def test_it_aborts_when_the_tree_changes_between_rows(self, monkeypatch):
        mod = _load()
        # Clean for the first row, dirty for the second — the exact shape of an
        # edit landing mid-run. Scoring the second row here would measure a tree
        # the author never intended and report SETUP FAILED, which reads as a
        # broken guard rather than as a dirty tree.
        clean = iter([True, False])
        monkeypatch.setattr(mod, "git_is_clean", lambda: next(clean))
        checked = []
        monkeypatch.setattr(mod, "check", lambda m: checked.append(m.name) or True)
        rows = [
            mod.Mutation(name="first", path="p", old="o", new="n", test="t"),
            mod.Mutation(name="second", path="p", old="o", new="n", test="t"),
        ]

        with pytest.raises(mod.SweepAborted):
            mod.sweep(rows)
        assert checked == ["first"], "the row after the tree went dirty was still scored"
