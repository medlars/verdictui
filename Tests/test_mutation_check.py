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

import hashlib
import importlib.util
import re
import subprocess
import sys
from pathlib import Path
from typing import Any

import pytest

pytestmark = pytest.mark.quick

_PROJECT_ROOT = Path(__file__).resolve().parents[1]


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

    def test_no_swift_mutation_carries_a_pytest_node_id(self) -> None:
        # The mirror of the check below. `swift test --filter` treats a node id
        # as a regex that matches nothing and still exits 0, so getting the
        # runner wrong in one direction is caught only by the baseline check
        # and in the other only by this.
        mod = _load()
        for mutation in mod.MUTATIONS:
            if mutation.runner is mod.Runner.SWIFT:
                assert "::" not in mutation.test, f"node id on a swift runner: {mutation.test}"

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
