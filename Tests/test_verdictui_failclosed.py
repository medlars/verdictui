"""Tests that PM stages fail CLOSED when they cannot observe their subject.

Split out of `test_verdictui_pm.py` (CTS-E51CBEEB). The subject here is one
question asked of several stages: what does a stage report when the thing it
checks is UNAVAILABLE — the tool is not installed, the suite did not run?

The answer must never be PASS. A check that cannot observe its subject and
returns green is indistinguishable from one that observed a healthy subject,
and it is green precisely when the environment is broken (lessons 202/206/305).
The repo has been bitten by this: `stage_lint` once failed OPEN with `ruff`
absent, and the test that pinned that behaviour asserted it was CORRECT, which
is why the gap survived review.
"""

import pytest
from pm_test_support import _PROJECT_ROOT, load_pm

# Quick gate: pure-python, sub-second — belongs in the pre-merge gate.
# Without a marker the quick gate selects ZERO tests and reports success (lesson 183).
pytestmark = pytest.mark.quick

_mod = load_pm()
VerdictUIPM = _mod.VerdictUIPM


class TestStagePytest:
    """The stage that closes the CI/PM inversion. Its failure paths matter more
    than its happy one: it exists because a local Grade A used to be weaker
    than a CI pass, and a version of it that silently passes would restore that
    gap while looking like it had closed it."""

    @staticmethod
    def _pm():
        return VerdictUIPM.__new__(VerdictUIPM)

    @staticmethod
    def _fake(monkeypatch, *, stdout: str, returncode: int = 0) -> None:
        class _Result:
            def __init__(self) -> None:
                self.stdout = stdout
                self.stderr = ""
                self.returncode = returncode

        monkeypatch.setattr(_mod.subprocess, "run", lambda *a, **k: _Result())

    def test_the_real_suite_passes_and_the_count_is_reported(self) -> None:
        """Runs the REAL stage against a subset, not the whole suite.

        The unrestricted stage runs `Tests/`, which contains this file, which
        contains this test — so calling it here re-enters the whole suite and
        blows the stage's own timeout (measured: 120s, then a fail). Pointing it
        at one leaf file keeps the subprocess, the summary parse, and the count
        assertion real while removing only the recursion.
        """
        pm = self._pm()
        real_run = _mod.subprocess.run

        def _subset(argv, **kwargs):
            # Replace the "Tests" target with a file that cannot re-enter.
            argv = [("Tests/test_file_registry.py" if a == "Tests" else a) for a in argv]
            return real_run(argv, **kwargs)

        _mod.subprocess.run = _subset
        try:
            result = pm.stage_pytest()
        finally:
            _mod.subprocess.run = real_run
        assert result["passed"], result["detail"]
        assert "Python tests PASS" in result["detail"]

    def test_the_real_suite_uses_the_pytest_timeout_not_the_standard_timeout(
        self, monkeypatch
    ) -> None:
        calls = []

        class _Result:
            stdout = "1 passed in 0.01s\n"
            stderr = ""
            returncode = 0

        def _run(*args, **kwargs):
            calls.append((args, kwargs))
            return _Result()

        monkeypatch.setattr(_mod.subprocess, "run", _run)

        result = self._pm().stage_pytest()

        assert result["passed"], result["detail"]
        assert calls
        assert calls[0][1]["timeout"] == _mod.TIMEOUT_PYTEST
        assert _mod.TIMEOUT_PYTEST > _mod.TIMEOUT_STANDARD

    def test_zero_collected_fails_even_though_pytest_exits_zero(self, monkeypatch) -> None:
        """`pytest` exits 0 when it collects nothing, so a broken marker or a
        moved test directory would otherwise read as a fast, clean suite."""
        self._fake(monkeypatch, stdout="0 passed in 0.01s\n")
        result = self._pm().stage_pytest()
        assert not result["passed"]
        assert "0 tests" in result["detail"]

    def test_a_missing_summary_line_fails_rather_than_passing(self, monkeypatch) -> None:
        self._fake(monkeypatch, stdout="no tests ran in 0.01s\n")
        result = self._pm().stage_pytest()
        assert not result["passed"]
        assert "no pytest summary" in result["detail"]

    def test_a_failing_test_is_surfaced_by_name(self, monkeypatch) -> None:
        self._fake(
            monkeypatch,
            stdout="FAILED Tests/test_x.py::TestY::test_z - AssertionError\n1 failed, 3 passed\n",
            returncode=1,
        )
        result = self._pm().stage_pytest()
        assert not result["passed"]
        assert "test_z" in result["detail"]

    def test_the_stage_is_registered_in_the_pipeline(self) -> None:
        source = (_PROJECT_ROOT / "scripts" / "verdictui-pm.py").read_text()
        assert '("stage_pytest", self.stage_pytest)' in source

    def test_the_stage_runs_what_ci_runs(self) -> None:
        """CI and the PM must not drift apart on WHICH suite they run — that
        divergence is the whole reason this stage exists."""
        workflow = (_PROJECT_ROOT / ".github" / "workflows" / "ci.yml").read_text()
        assert "pytest Tests/" in workflow, "CI no longer runs Tests/ — update this stage with it"

    def test_ci_python_meets_pm_base_requires(self) -> None:
        """Lint PM scripts installs pm-base (Requires-Python >=3.14). A 3.13
        runner fails at `pip install` before any assertion can run — measured
        on main run 31317809175 after aa6c39c."""
        workflow = (_PROJECT_ROOT / ".github" / "workflows" / "ci.yml").read_text()
        assert 'python-version: "3.14"' in workflow or "python-version: '3.14'" in workflow, (
            "python-scripts job must use Python >=3.14 so pm-base installs"
        )
        assert "Install pm_base" in workflow, "CI must still install pm_base for PM tests"


class TestStagesFailClosedWithoutTheirTool:
    """A stage whose tool is missing must FAIL, never pass with "skipped".

    `stage_build` and `stage_test` returned `passed: True` when `swift` was
    absent, so on any host without a toolchain the PM reported Grade A having
    compiled and run nothing — and `stage_lint` did the same for ruff. The two
    newest stages (`stage_demo`, `stage_runtime_bench`) were written to fail
    closed and carry their own tests for it; the oldest and most important ones
    were never brought forward. This pins all of them together so the next
    stage cannot be added with the old shape.
    """

    @staticmethod
    def _pm():
        return VerdictUIPM.__new__(VerdictUIPM)

    @pytest.mark.parametrize(
        ("stage_name", "tool"),
        [
            ("stage_build", "swift"),
            ("stage_test", "swift"),
            ("stage_demo", "swift"),
            ("stage_runtime_bench", "swift"),
            ("stage_lint", "ruff"),
        ],
    )
    def test_stage_fails_when_its_tool_is_missing(self, stage_name, tool, monkeypatch) -> None:
        monkeypatch.setattr(_mod.shutil, "which", lambda _: None)
        result = getattr(self._pm(), stage_name)()
        assert not result["passed"], (
            f"{stage_name} passed with {tool} absent -- it verified nothing and said so was fine"
        )

    def test_lint_runs_both_check_and_format(self) -> None:
        """CI runs `ruff format --check .`; a stage running only `check` lets
        format drift through to a red CI on a locally-green tree. Measured
        2026-08-06 -- that is exactly what happened."""
        source = (_PROJECT_ROOT / "scripts" / "verdictui-pm.py").read_text()
        assert '[ruff, "check", "."]' in source
        assert '[ruff, "format", "--check", "."]' in source

    def test_lint_scope_matches_ci_scope(self) -> None:
        """Both must cover the whole repo. A stage scoped narrower than CI
        reproduces the same gap in miniature."""
        workflow = (_PROJECT_ROOT / ".github" / "workflows" / "ci.yml").read_text()
        assert "ruff format --check ." in workflow, (
            "CI changed its format scope -- stage_lint must move with it"
        )
