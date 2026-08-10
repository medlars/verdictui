"""Tests for VerdictUIPM stages, floor-check, and validate-contracts."""

import contextlib
import importlib.util
import io
import json
import os
import re
import shutil
import subprocess
import sys
import types
from pathlib import Path

import pytest

# Quick gate: pure-python, sub-second — belongs in the pre-merge gate.
# Without a marker the quick gate selects ZERO tests and reports success (lesson 183).
pytestmark = pytest.mark.quick

_PROJECT_ROOT = Path(__file__).resolve().parents[1]
_PM_PATH = str(_PROJECT_ROOT / "scripts" / "verdictui-pm.py")
_PYTHON = sys.executable

# floor-check asserts dev-machine surfaces (~/.claude skills, iTerm2 profile)
# that do not exist on a CI runner. Tests whose SUBJECT is the full floor must
# skip there rather than fail for "the environment lacks the thing" (lesson 221).
_ON_DEV_MACHINE = (Path.home() / ".claude" / "skills" / "verdictui" / "SKILL.md").exists()
_needs_dev_machine = pytest.mark.skipif(
    not _ON_DEV_MACHINE,
    reason="floor-check asserts dev-machine surfaces absent on CI runners",
)

# Load verdictui-pm.py (hyphenated filename) without package machinery.
_spec = importlib.util.spec_from_file_location("verdictui_pm", _PM_PATH)
_mod = importlib.util.module_from_spec(_spec)  # type: ignore[arg-type]
_spec.loader.exec_module(_mod)  # type: ignore[union-attr]
VerdictUIPM = _mod.VerdictUIPM


class TestLoadsWithoutSharedLibs:
    """The PM must stay importable where shared-libs is absent (a CI runner).

    shared-libs is a SIBLING repo, absent on any clone — an unguarded
    `from pm_base import PmBase` raises at collection time and takes down the
    whole test run, not just the PM tests (lesson 168). Must run in a
    subprocess: in-process, pm_base is already importable from this checkout,
    so the assertion could never fail for the reason the test exists (lesson 224).
    """

    def test_module_imports_when_pm_base_is_absent(self) -> None:
        probe = (
            "import sys, importlib.util, importlib.abc\n"
            "class _Block(importlib.abc.MetaPathFinder):\n"
            "    def find_spec(self, name, path=None, target=None):\n"
            "        if name == 'pm_base' or name.startswith('pm_base.'):\n"
            "            raise ImportError('blocked for test')\n"
            "        return None\n"
            "sys.meta_path.insert(0, _Block())\n"
            f"spec = importlib.util.spec_from_file_location('vupm', {_PM_PATH!r})\n"
            "mod = importlib.util.module_from_spec(spec)\n"
            "spec.loader.exec_module(mod)\n"
            "print('LOADED_OK', mod.VerdictUIPM.__name__)\n"
        )
        result = subprocess.run([_PYTHON, "-c", probe], capture_output=True, text=True, timeout=60)
        assert result.returncode == 0, f"PM must import without shared-libs; got:\n{result.stderr}"
        assert "LOADED_OK VerdictUIPM" in result.stdout

    def test_fallback_pmbase_fails_closed(self) -> None:
        """Without shared-libs, run_pipeline must exit loudly — never report a pass."""
        probe = (
            "import sys, importlib.util, importlib.abc\n"
            "class _Block(importlib.abc.MetaPathFinder):\n"
            "    def find_spec(self, name, path=None, target=None):\n"
            "        if name == 'pm_base' or name.startswith('pm_base.'):\n"
            "            raise ImportError('blocked for test')\n"
            "        return None\n"
            "sys.meta_path.insert(0, _Block())\n"
            f"spec = importlib.util.spec_from_file_location('vupm', {_PM_PATH!r})\n"
            "mod = importlib.util.module_from_spec(spec)\n"
            "spec.loader.exec_module(mod)\n"
            "mod.VerdictUIPM.__init__ = lambda self: None\n"
            "mod.VerdictUIPM().run_pipeline(mode='quick')\n"
        )
        result = subprocess.run([_PYTHON, "-c", probe], capture_output=True, text=True, timeout=60)
        assert result.returncode != 0, "fallback PmBase must fail closed, not pass"
        assert "shared-libs pm-base unavailable" in result.stderr


class TestPMCLI:
    def test_main_dispatches_query_without_running_pipeline(self, monkeypatch, capsys) -> None:
        def fail_run_pipeline(*_args, **_kwargs):
            raise AssertionError("query must not run the PM pipeline")

        monkeypatch.setattr(VerdictUIPM, "run_pipeline", fail_run_pipeline)

        assert (
            _mod.main(
                [
                    "query",
                    "risk",
                    "--file",
                    "Tests/VerdictUIProbeTests/HarnessPerformanceTests.swift",
                ]
            )
            == 0
        )

        payload = json.loads(capsys.readouterr().out)
        assert payload["query"] == "risk"
        assert payload["risk"] == "high"
        assert payload["file"] == "Tests/VerdictUIProbeTests/HarnessPerformanceTests.swift"

    def test_unknown_cli_argument_fails_instead_of_running_quick(self, monkeypatch) -> None:
        def fail_run_pipeline(*_args, **_kwargs):
            raise AssertionError("unknown CLI args must not run the PM pipeline")

        monkeypatch.setattr(VerdictUIPM, "run_pipeline", fail_run_pipeline)

        with pytest.raises(SystemExit) as exc:
            _mod.main(["--definitely-not-a-mode"])

        assert exc.value.code == 2

    def test_query_coverage_lists_python_and_swift_tests(self, capsys) -> None:
        pm = VerdictUIPM.__new__(VerdictUIPM)

        assert pm.run_query("coverage", file_path="scripts/verdictui-pm.py") == 0

        payload = json.loads(capsys.readouterr().out)
        assert payload["query"] == "coverage"
        assert "Tests/test_verdictui_pm.py" in payload["tests"]
        assert "Tests/VerdictUIProbeTests/HarnessPerformanceTests.swift" in payload["tests"]

    def test_query_why_failed_reads_cached_status(self, tmp_path, capsys) -> None:
        status_file = tmp_path / "pm-last-status.json"
        status_file.write_text(
            json.dumps(
                {
                    "failed_stages": ["stage_runtime_bench"],
                    "stages": {
                        "stage_runtime_bench": {
                            "passed": False,
                            "detail": "p50 over budget",
                        }
                    },
                }
            )
        )
        pm = VerdictUIPM.__new__(VerdictUIPM)
        pm.status_file = status_file

        assert pm.run_query("why-failed", stage="stage_runtime_bench") == 0

        payload = json.loads(capsys.readouterr().out)
        assert payload["failed_stages"] == ["stage_runtime_bench"]
        assert payload["detail"]["detail"] == "p50 over budget"

    def test_query_why_failed_derives_failed_stages_from_cached_stage_map(
        self, tmp_path, capsys
    ) -> None:
        status_file = tmp_path / "pm-last-status.json"
        status_file.write_text(
            json.dumps(
                {
                    "stages": {
                        "stage_build": {"passed": True, "detail": "ok"},
                        "stage_runtime_bench": {
                            "passed": False,
                            "detail": "p50 over budget",
                        },
                    },
                }
            )
        )
        pm = VerdictUIPM.__new__(VerdictUIPM)
        pm.status_file = status_file

        assert pm.run_query("why-failed", stage="stage_runtime_bench") == 0

        payload = json.loads(capsys.readouterr().out)
        assert payload["failed_stages"] == ["stage_runtime_bench"]
        assert payload["detail"]["detail"] == "p50 over budget"


class TestDeploymentFloor:
    """The floor a CONSUMER collides with, not one this repo can see alone.

    SwiftPM refuses a dependency whose minimum platform is higher than the
    consuming package's, and the error names the product rather than the one
    API responsible — so a floor raised past the fleet's apps makes VerdictUI
    unusable by them for a reason nothing here would ever report. LaunchGate
    targets macOS 13; a v14 floor locked it out entirely.
    """

    def test_the_package_floor_stays_at_the_lowest_fleet_target(self) -> None:
        manifest = (_PROJECT_ROOT / "Package.swift").read_text()
        assert ".macOS(.v13)" in manifest, (
            "the deployment floor moved above macOS 13 — that silently locks out "
            "every consumer pinned lower (LaunchGate is .v13). Raising it needs a "
            "no.md entry naming the API that forced it."
        )

    def test_no_source_file_hard_codes_a_macos_14_only_api(self) -> None:
        # `.coordinateSpace(.named(_:))` is the macOS 14 spelling; the deprecated
        # `.coordinateSpace(name:)` is the 13-compatible one. Either is fine
        # BEHIND an availability check -- what breaks a v13 consumer is calling
        # the new form unguarded, which is exactly what this file used to do.
        probe = (_PROJECT_ROOT / "Sources/VerdictUIProbe/VerdictProbe.swift").read_text()
        if ".coordinateSpace(.named(" in probe:
            assert "if #available(macOS 14" in probe, (
                "VerdictProbe.swift calls the macOS 14 .coordinateSpace(.named:) "
                "overload without an #available guard — this is the single line "
                "that has historically forced the whole package to macOS 14"
            )


class TestStageArchitecture:
    """Kernel purity: VerdictUIKernel must never import SwiftUI/AppKit/CG/UIKit."""

    @staticmethod
    def _pm():
        # skip PmBase.__init__ (needs shared-libs state)
        return VerdictUIPM.__new__(VerdictUIPM)

    def test_real_kernel_is_pure(self) -> None:
        result = self._pm().stage_architecture()
        assert result["passed"], result["detail"]

    def test_ui_import_in_kernel_fails(self, tmp_path, monkeypatch) -> None:
        kernel = tmp_path / "Sources" / "VerdictUIKernel"
        kernel.mkdir(parents=True)
        (kernel / "Bad.swift").write_text("import SwiftUI\nstruct X {}\n")
        monkeypatch.setattr(_mod, "PROJECT_ROOT", tmp_path)
        result = self._pm().stage_architecture()
        assert not result["passed"]
        assert "kernel purity violated" in result["detail"]
        assert "Bad.swift" in result["detail"]

    def test_missing_kernel_dir_fails(self, tmp_path, monkeypatch) -> None:
        monkeypatch.setattr(_mod, "PROJECT_ROOT", tmp_path)
        result = self._pm().stage_architecture()
        assert not result["passed"]

    def test_all_banned_tokens_detected(self, tmp_path, monkeypatch) -> None:
        for token in ("import AppKit", "import CoreGraphics", "import UIKit"):
            kernel = tmp_path / "Sources" / "VerdictUIKernel"
            kernel.mkdir(parents=True, exist_ok=True)
            (kernel / "Bad.swift").write_text(f"{token}\n")
            monkeypatch.setattr(_mod, "PROJECT_ROOT", tmp_path)
            result = self._pm().stage_architecture()
            assert not result["passed"], f"{token} must be rejected"


class TestStageContracts:
    """The PM's contract gate: it must report the validator's verdict, not its own."""

    @staticmethod
    def _pm():
        return VerdictUIPM.__new__(VerdictUIPM)

    def test_real_contracts_pass_and_the_check_count_is_reported(self) -> None:
        result = self._pm().stage_contracts()
        assert result["passed"], result["detail"]
        # 1 schema + 1 version + one per fixture: a count of 0 would mean the
        # stage passed without the validator having checked anything.
        fixtures = len(list((_PROJECT_ROOT / "contracts" / "fixtures").glob("*.json")))
        assert f"({2 + fixtures} checks)" in result["detail"], result["detail"]

    def test_missing_validator_fails(self, tmp_path, monkeypatch) -> None:
        monkeypatch.setattr(_mod, "PROJECT_ROOT", tmp_path)
        result = self._pm().stage_contracts()
        assert not result["passed"]
        assert "validate-contracts.py not found" in result["detail"]

    def test_validator_failure_is_surfaced_not_swallowed(self, tmp_path, monkeypatch) -> None:
        """A broken contract must fail the stage and name the reason in the detail."""
        contracts = tmp_path / "contracts"
        contracts.mkdir()
        (contracts / "validate-contracts.py").write_text(
            "import sys\nprint('FAIL: staged contract breakage')\nsys.exit(1)\n"
        )
        monkeypatch.setattr(_mod, "PROJECT_ROOT", tmp_path)
        result = self._pm().stage_contracts()
        assert not result["passed"]
        assert "staged contract breakage" in result["detail"]


class TestStageBuild:
    def test_swift_module_cache_is_project_local(self) -> None:
        cache_path = Path(os.environ["CLANG_MODULE_CACHE_PATH"])
        assert cache_path.is_relative_to(_PROJECT_ROOT / ".build")

    def test_stage_build_uses_project_local_swiftpm_caches(self, monkeypatch) -> None:
        calls = []

        def run_swift_build(*_args, **kwargs):
            calls.append(kwargs)
            return {"passed": True, "detail": "swift build PASS", "output": ""}

        monkeypatch.setattr(_mod.shutil, "which", lambda _: "/usr/bin/swift")
        monkeypatch.setattr(
            _mod, "_swift_runner", lambda: (lambda _root: [], run_swift_build, None)
        )

        result = VerdictUIPM.__new__(VerdictUIPM).stage_build()

        assert result["passed"], result["detail"]
        flags = calls[0]["extra_flags"]
        assert "--cache-path" in flags
        assert "--config-path" in flags
        assert "--manifest-cache" in flags
        assert str(_PROJECT_ROOT / ".build" / "swiftpm-cache") in flags
        assert str(_PROJECT_ROOT / ".build" / "swiftpm-config") in flags
        assert "local" in flags

    def test_missing_package_swift_fails(self, tmp_path, monkeypatch) -> None:
        monkeypatch.setattr(_mod, "PROJECT_ROOT", tmp_path)
        pm = VerdictUIPM.__new__(VerdictUIPM)
        result = pm.stage_build()
        assert not result["passed"]
        assert "Package.swift" in result["detail"]

    def test_swift_runner_tolerates_timed_out_lock_sweep(self, monkeypatch) -> None:
        def raw_kill(_project_root: Path) -> list[int]:
            raise subprocess.TimeoutExpired(cmd="lsof", timeout=5)

        def run_swift_build() -> None:
            return None

        def run_swift_test() -> None:
            return None

        fake = types.SimpleNamespace(
            kill_zombie_swift_processes=raw_kill,
            run_swift_build=run_swift_build,
            run_swift_test=run_swift_test,
        )
        monkeypatch.setitem(sys.modules, "swift_runner", fake)

        safe_kill, build, test = _mod._swift_runner()

        assert safe_kill(_PROJECT_ROOT) == []
        assert build.__globals__["kill_zombie_swift_processes"] is safe_kill
        assert test.__globals__["kill_zombie_swift_processes"] is safe_kill
        assert getattr(fake, _mod._RAW_KILL_ATTR) is raw_kill

    def test_the_pm_script_is_pyright_clean(self) -> None:
        # The runtime tests above monkeypatch `swift_runner`, so they pass
        # whether or not the real module declares the names this script assigns
        # to it. Only a type check can see that, and CI runs one -- so without
        # this the PM script can go red on CI from a green local suite
        # (CIS-9EC205DF).
        if shutil.which("pyright") is None:
            pytest.skip("pyright not installed")
        proc = subprocess.run(
            ["pyright", "--outputjson", str(_PROJECT_ROOT / "scripts/verdictui-pm.py")],
            capture_output=True,
            text=True,
            cwd=_PROJECT_ROOT,
            check=False,
        )
        summary = json.loads(proc.stdout)["summary"]
        assert summary["errorCount"] == 0, proc.stdout

    def test_timed_out_lock_sweep_clears_project_lock_sentinels(
        self, tmp_path, monkeypatch
    ) -> None:
        project = tmp_path / "Project"
        project.mkdir()
        token = str(project / ".build").replace("/", "_")
        stale = tmp_path / f"{token}.lock"
        unrelated = tmp_path / "_other_project_.build.lock"
        stale.write_text("stale\n")
        unrelated.write_text("keep\n")
        monkeypatch.setattr(_mod.tempfile, "gettempdir", lambda: str(tmp_path))

        removed = _mod._clear_project_swiftpm_lock_files(project)

        assert removed == 1
        assert not stale.exists()
        assert unrelated.exists()


class TestSkipSentinel:
    def test_skipped_shared_libs_passes_with_reason(self) -> None:
        result = VerdictUIPM._skipped_shared_libs(ImportError("nope"))
        assert result["passed"]
        assert "skipped: shared-libs unavailable" in result["detail"]

    def test_external_store_unavailable_is_reported_as_skip(self) -> None:
        result = VerdictUIPM._skip_unavailable_external_store(
            {"passed": False, "detail": "IssueWatch skipped: unable to open database file"}
        )

        assert result["passed"]
        assert "external store unavailable" in result["detail"]

    def test_timing_record_only_honors_explicit_marker_environment(self, monkeypatch) -> None:
        for name in _mod.CONSTRAINED_TIMING_ENV_MARKERS:
            monkeypatch.delenv(name, raising=False)

        monkeypatch.setenv(_mod.TIMING_RECORD_ONLY_ENV, "1")

        assert _mod._timing_record_only_environment()

    def test_timing_record_only_detects_codex_repair_sandbox(self, monkeypatch) -> None:
        for name in _mod.CONSTRAINED_TIMING_ENV_MARKERS:
            monkeypatch.delenv(name, raising=False)

        monkeypatch.setenv("CODEX_CI", "1")

        assert _mod._timing_record_only_environment()

    def test_timing_record_only_treats_marker_presence_as_active(self, monkeypatch) -> None:
        for name in _mod.CONSTRAINED_TIMING_ENV_MARKERS:
            monkeypatch.delenv(name, raising=False)

        monkeypatch.setenv("CI", "")

        assert _mod._timing_record_only_environment()

    def test_unmarked_writable_host_still_asserts_its_timings(self, monkeypatch, tmp_path) -> None:
        """The negative control, and the only direction that can fail usefully.

        Every other test here asserts a marker turns record-only ON, and an
        implementation returning True unconditionally satisfies all of them --
        measured: it passed 199/199. That defect is silent in the expensive
        direction, because record-only means the p50 budget is enforced
        NOWHERE while every suite stays green (no.md #12, #15).
        """
        for name in _mod.CONSTRAINED_TIMING_ENV_MARKERS:
            monkeypatch.delenv(name, raising=False)
        # The other input the predicate reads: an unwritable SwiftPM cache also
        # means record-only, so a developer-hardware claim must pin both.
        monkeypatch.setattr(_mod.Path, "home", classmethod(lambda _cls: tmp_path))

        assert not _mod._timing_record_only_environment()

    def test_stage_test_exports_record_only_timing_only_during_swift_run(self, monkeypatch) -> None:
        observed = []

        def run_swift_test(**_kwargs):
            observed.append(os.environ.get(_mod.TIMING_RECORD_ONLY_ENV))
            return {
                "passed": True,
                "detail": "swift test passed",
                "output": "Executed 1 test, with 0 failures\n",
                "test_count": 1,
            }

        monkeypatch.delenv(_mod.TIMING_RECORD_ONLY_ENV, raising=False)
        monkeypatch.setattr(_mod.shutil, "which", lambda _: "/usr/bin/swift")
        monkeypatch.setattr(_mod, "_timing_record_only_environment", lambda: True)
        monkeypatch.setattr(_mod, "_run_streamed_swift_test", run_swift_test)

        result = VerdictUIPM.__new__(VerdictUIPM).stage_test()

        assert result["passed"], result["detail"]
        assert observed == ["1"]
        assert os.environ.get(_mod.TIMING_RECORD_ONLY_ENV) is None


class TestDefineStages:
    def test_quick_pipeline_contains_all_mandatory_stages(self) -> None:
        pm = VerdictUIPM.__new__(VerdictUIPM)
        names = [name for name, _fn in pm.define_stages("quick")]
        mandatory = [
            "stage_build",
            "stage_test",
            "stage_floor",
            "stage_contracts",
            "stage_architecture",
            "stage_ai_artifacts",
            "stage_todo_review",
            "stage_last20",
            "stage_test_alongside",
            "stage_lint",
            "stage_codewatch",
            "stage_issuewatch",
            "stage_capabilitywatch",
            "stage_cis_health",
        ]
        missing = [m for m in mandatory if m not in names]
        assert not missing, f"pipeline missing stages: {missing}"
        assert names[0] == "stage_build", "build must gate everything else"

    def test_every_stage_entry_is_callable(self) -> None:
        pm = VerdictUIPM.__new__(VerdictUIPM)
        for name, fn in pm.define_stages("quick"):
            assert callable(fn), f"{name} is not callable"


class TestStageWrappers:
    """Governance wrappers must return the {passed, detail} shape in all paths."""

    def test_stage_lint_fails_closed_when_ruff_is_missing(self, monkeypatch) -> None:
        """Was `assert result["passed"]` with "skipped" in the detail — this test
        pinned the fail-open as the intended contract, which is why the gap
        survived a review. A stage that cannot observe its subject must fail;
        "could not check" and "checked, clean" are different answers."""
        import shutil as _shutil

        monkeypatch.setattr(_shutil, "which", lambda _: None)
        pm = VerdictUIPM.__new__(VerdictUIPM)
        result = pm.stage_lint()
        assert not result["passed"]
        assert "cannot be verified" in result["detail"]

    def test_stage_lint_reports_a_real_lint_failure(self, tmp_path, monkeypatch) -> None:
        """The stage must FAIL on code ruff rejects, and name the reason.

        Every other lint test checks the tool-missing path, the clean-repo path,
        or greps the PM's own source for the argv it builds. None of them run
        the stage against BROKEN code, so `stage_lint` could stop reporting
        failures entirely and stay green — the gap was found by mutating the
        stage's `returncode != 0` branch and watching the whole suite pass.
        """
        (tmp_path / "bad.py").write_text("import os\nx = = 1\n")
        monkeypatch.setattr(_mod, "PROJECT_ROOT", tmp_path)
        result = VerdictUIPM.__new__(VerdictUIPM).stage_lint()
        assert not result["passed"], "ruff rejects this file; the stage must say so"
        assert "ruff check" in result["detail"], result["detail"]

    def test_stage_lint_reports_a_format_failure_distinctly(self, tmp_path, monkeypatch) -> None:
        """Format drift must fail too, and be distinguishable from a lint error.

        This is the half that was CI-only until this session: a locally-green PM
        pushed a red build because the stage ran `check` without
        `format --check`. A test that only proves SOME failure is caught would
        not have noticed which of the two halves was missing.
        """
        # Valid Python that ruff-check accepts and ruff-format would rewrite.
        (tmp_path / "ugly.py").write_text("x = {  'a':1,   'b':2 }\n")
        monkeypatch.setattr(_mod, "PROJECT_ROOT", tmp_path)
        result = VerdictUIPM.__new__(VerdictUIPM).stage_lint()
        assert not result["passed"], "unformatted code must fail the stage"
        assert "ruff format" in result["detail"], (
            f"the detail must name WHICH half failed, got: {result['detail']}"
        )

    def test_stage_lint_runs_clean_on_this_repo(self) -> None:
        pm = VerdictUIPM.__new__(VerdictUIPM)
        result = pm.stage_lint()
        assert result["passed"], result["detail"]

    @_needs_dev_machine
    def test_stage_floor_passes_on_this_repo(self) -> None:
        pm = VerdictUIPM.__new__(VerdictUIPM)
        result = pm.stage_floor()
        assert result["passed"], result["detail"]

    def test_stage_demo_runs_the_built_executable_not_swiftpm(self, tmp_path, monkeypatch) -> None:
        """The demo stage launches the product already built by `stage_build`.

        Re-entering `swift run` here re-plans the package, can wait on SwiftPM
        locks, and can hang in the repair sandbox. This stage's job is only to
        prove the demo executable launches and emits valid JSON.
        """
        seen: list[list[str]] = []
        demo = tmp_path / ".build" / "debug" / "VerdictUIDemo"
        demo.parent.mkdir(parents=True)
        demo.write_text("#!/bin/sh\n")
        monkeypatch.setattr(_mod, "PROJECT_ROOT", tmp_path)

        def _fake_run(argv, **_kwargs):
            seen.append(argv)
            return subprocess.CompletedProcess(argv, 0, stdout="[{}]", stderr="")

        monkeypatch.setattr(_mod.subprocess, "run", _fake_run)
        pm = VerdictUIPM.__new__(VerdictUIPM)
        assert pm.stage_demo()["passed"]

        assert seen == [[str(demo)]]

    def test_stage_demo_fails_when_the_built_executable_is_missing(
        self, tmp_path, monkeypatch
    ) -> None:
        monkeypatch.setattr(_mod, "PROJECT_ROOT", tmp_path)
        result = VerdictUIPM.__new__(VerdictUIPM).stage_demo()
        assert not result["passed"]
        assert "stage_build" in result["detail"]

    @staticmethod
    def _built_demo(tmp_path, monkeypatch) -> None:
        """Satisfy stage_demo's built-executable precondition.

        The stage returns early when `.build/debug/VerdictUIDemo` is absent, so
        the tests below — which mock `subprocess.run` to exercise the branches
        AFTER that check — never reached their subject on a runner where nothing
        is built. They passed locally purely because a previous `swift build`
        had left the binary there: green locally, red on CI, which is the worst
        shape a real gap can take because it reads as an environment fault.
        """
        monkeypatch.setattr(_mod, "PROJECT_ROOT", tmp_path)
        demo = tmp_path / ".build" / "debug" / "VerdictUIDemo"
        demo.parent.mkdir(parents=True, exist_ok=True)
        demo.touch()

    def test_stage_demo_fails_on_an_empty_verdict_array(self, tmp_path, monkeypatch) -> None:
        # `[]` is valid JSON and would otherwise read as success while
        # reporting a catalog of nothing.
        self._built_demo(tmp_path, monkeypatch)
        monkeypatch.setattr(
            _mod.subprocess,
            "run",
            lambda argv, **_k: subprocess.CompletedProcess(argv, 0, stdout="[]", stderr=""),
        )
        pm = VerdictUIPM.__new__(VerdictUIPM)
        result = pm.stage_demo()
        assert not result["passed"]
        assert "non-empty" in result["detail"]

    def test_stage_demo_fails_when_stdout_is_not_json(self, tmp_path, monkeypatch) -> None:
        self._built_demo(tmp_path, monkeypatch)
        monkeypatch.setattr(
            _mod.subprocess,
            "run",
            lambda argv, **_k: subprocess.CompletedProcess(argv, 0, stdout="not json", stderr=""),
        )
        pm = VerdictUIPM.__new__(VerdictUIPM)
        result = pm.stage_demo()
        assert not result["passed"]
        assert "not valid JSON" in result["detail"]

    def test_stage_demo_surfaces_a_nonzero_exit_with_its_stderr(
        self, tmp_path, monkeypatch
    ) -> None:
        self._built_demo(tmp_path, monkeypatch)
        monkeypatch.setattr(
            _mod.subprocess,
            "run",
            lambda argv, **_k: subprocess.CompletedProcess(
                argv, 1, stdout="", stderr="verdictui-demo: settle timed out\n"
            ),
        )
        pm = VerdictUIPM.__new__(VerdictUIPM)
        result = pm.stage_demo()
        assert not result["passed"]
        assert "settle timed out" in result["detail"]

    def test_stage_demo_hard_fails_when_swift_is_missing(self, monkeypatch) -> None:
        # Not a soft skip: the stage exists to run a Swift executable, and a
        # stage that cannot do its work must fail rather than print PASS.
        monkeypatch.setattr(_mod.shutil, "which", lambda _: None)
        pm = VerdictUIPM.__new__(VerdictUIPM)
        result = pm.stage_demo()
        assert not result["passed"]
        assert "swift not installed" in result["detail"]

    @_needs_dev_machine
    def test_stage_mutations_passes_on_this_repo(self) -> None:
        pm = VerdictUIPM.__new__(VerdictUIPM)
        result = pm.stage_mutations()
        assert result["passed"], result["detail"]
        assert "resolve to exactly one site" in result["detail"]

    def test_stage_mutations_fails_when_the_script_is_gone(self, monkeypatch) -> None:
        monkeypatch.setattr(_mod, "PROJECT_ROOT", Path("/nonexistent-verdictui-root"))
        pm = VerdictUIPM.__new__(VerdictUIPM)
        result = pm.stage_mutations()
        assert not result["passed"]
        assert "not found" in result["detail"]

    def test_pm_log_routes_through_logging(self, caplog) -> None:
        import logging

        with caplog.at_level(logging.INFO, logger="verdictui_pm"):
            _mod._pm_log("probe message", level="INFO")
        assert "probe message" in caplog.text


class TestFloorCheckFunction:
    """floor-check.py's check() helper appends to GAPS only for missing paths."""

    @staticmethod
    def _load_floor_check():
        fc_path = str(_PROJECT_ROOT / "scripts" / "floor-check.py")
        spec = importlib.util.spec_from_file_location("verdictui_floor_check", fc_path)
        mod = importlib.util.module_from_spec(spec)  # type: ignore[arg-type]
        # Script style: module body runs all checks then sys.exit()s.
        try:
            spec.loader.exec_module(mod)  # type: ignore[union-attr]
        except SystemExit:
            pass
        return mod

    def test_check_records_gap_for_missing_path(self) -> None:
        mod = self._load_floor_check()
        before = len(mod.GAPS)
        assert mod.check("does/not/exist.xyz", "phantom") is False
        assert len(mod.GAPS) == before + 1
        assert mod.GAPS[-1]["item"] == "phantom"

    def test_check_passes_for_existing_path(self) -> None:
        mod = self._load_floor_check()
        before = len(mod.GAPS)
        assert mod.check("README.md", "readme") is True
        assert len(mod.GAPS) == before


def _load_validator():  # noqa: ANN202 — module object, hyphenated filename
    """Import contracts/validate-contracts.py, whose filename is not an identifier."""
    vc_path = str(_PROJECT_ROOT / "contracts" / "validate-contracts.py")
    spec = importlib.util.spec_from_file_location("verdictui_validate_contracts", vc_path)
    mod = importlib.util.module_from_spec(spec)  # type: ignore[arg-type]
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    return mod


class TestValidateContractsMain:
    def test_main_returns_zero(self) -> None:
        assert _load_validator().main() == 0


class TestFloorCheck:
    @_needs_dev_machine
    def test_floor_check_reports_zero_gaps(self) -> None:
        r = subprocess.run(
            [_PYTHON, str(_PROJECT_ROOT / "scripts" / "floor-check.py"), "--json"],
            capture_output=True,
            text=True,
            timeout=120,
        )
        import json

        payload = json.loads(r.stdout)
        assert payload["total"] == 0, f"floor gaps: {payload['gaps']}"
        assert r.returncode == 0


class TestValidateContracts:
    def test_validate_contracts_validates_the_pinned_schema(self) -> None:
        """Asserted PASS, not SKIP: SKIP was only correct while no schema existed.

        Wave 1 Task 5 pinned contracts/verdict-schema.json, so the validator now
        takes its real branch. The old assertion described a transitional state
        and started failing the moment the file it was waiting for arrived.
        """
        schema = _PROJECT_ROOT / "contracts" / "verdict-schema.json"
        assert schema.exists(), "schema is pinned as of Wave 1 Task 5"
        r = subprocess.run(
            [_PYTHON, str(_PROJECT_ROOT / "contracts" / "validate-contracts.py")],
            capture_output=True,
            text=True,
            timeout=60,
        )
        assert r.returncode == 0, r.stdout + r.stderr
        assert "PASS" in r.stdout, r.stdout
        assert "verdict-schema.json" in r.stdout, r.stdout

    def test_real_fixtures_are_actually_round_tripped(self) -> None:
        """The happy path above would also pass if the validator checked nothing.

        This asserts the work was done: one PASS line per committed fixture, and
        at least one fixture exists to round-trip.
        """
        fixtures = sorted((_PROJECT_ROOT / "contracts" / "fixtures").glob("*.json"))
        assert fixtures, "contracts/fixtures/ is the round-trip corpus — it must not be empty"
        r = subprocess.run(  # noqa: S603 — fixed argv from constants
            [_PYTHON, str(_PROJECT_ROOT / "contracts" / "validate-contracts.py")],
            capture_output=True,
            text=True,
            timeout=60,
        )
        for fixture in fixtures:
            assert f"PASS: {fixture.name} round-trips" in r.stdout, r.stdout
        assert "PASS: schema and SchemaVersion.current agree" in r.stdout, r.stdout


class TestValidatorPrimitives:
    """Unit-level coverage of the validator's own keyword implementations.

    The failure-branch tests below drive `main()` end to end; these pin the
    individual keywords, including the ones the real schema happens not to
    exercise in a failing direction, so a regression in `validate()` cannot hide
    behind a fixture that never triggers it.
    """

    def test_type_keyword_accepts_and_rejects_each_json_type(self) -> None:
        mod = _load_validator()
        for kind, good, bad in [
            ("string", "s", 1),
            ("number", 1.5, "1.5"),
            ("integer", 3, 3.5),
            ("boolean", True, "true"),
            ("object", {}, []),
            ("array", [], {}),
            ("null", None, 0),
        ]:
            assert mod.validate(good, {"type": kind}, {}) == [], kind
            assert mod.validate(bad, {"type": kind}, {}), f"{kind} accepted {bad!r}"

    def test_booleans_are_not_numbers(self) -> None:
        """Python's bool-is-an-int would silently let `true` satisfy `number`."""
        mod = _load_validator()
        assert mod.validate(True, {"type": "number"}, {})
        assert mod.validate(False, {"type": "integer"}, {})

    def test_union_type_accepts_any_member(self) -> None:
        mod = _load_validator()
        schema = {"type": ["string", "number", "boolean"]}
        for value in ("s", 1, 1.5, True):
            assert mod.validate(value, schema, {}) == [], value
        assert mod.validate(None, schema, {})

    def test_unknown_type_name_is_a_schema_error_not_a_pass(self) -> None:
        mod = _load_validator()
        with pytest.raises(mod.SchemaError, match="unknown type"):
            mod.validate("x", {"type": "text"}, {})

    def test_const_enum_minlength_pattern_and_minimum(self) -> None:
        mod = _load_validator()
        assert mod.validate("1.0", {"const": "1.0"}, {}) == []
        assert mod.validate("2.0", {"const": "1.0"}, {})
        assert mod.validate("PASS", {"enum": ["PASS", "FAIL"]}, {}) == []
        assert mod.validate("MAYBE", {"enum": ["PASS", "FAIL"]}, {})
        assert mod.validate("", {"minLength": 1}, {})
        assert mod.validate("2026-08-04T09:20:31Z", {"pattern": r"^\d{4}-"}, {}) == []
        assert mod.validate("today", {"pattern": r"^\d{4}-"}, {})
        assert mod.validate(-0.1, {"minimum": 0}, {})
        assert mod.validate(0, {"minimum": 0}, {}) == []

    def test_required_and_additional_properties(self) -> None:
        mod = _load_validator()
        schema = {
            "type": "object",
            "required": ["a"],
            "properties": {"a": {"type": "string"}},
            "additionalProperties": False,
        }
        assert mod.validate({"a": "x"}, schema, {}) == []
        assert "missing required property 'a'" in mod.validate({}, schema, {})[0]
        assert "unexpected property 'b'" in mod.validate({"a": "x", "b": 1}, schema, {})[0]

    def test_additional_properties_as_a_schema_is_applied(self) -> None:
        """How `attributes` is typed: any key, but the value must be a primitive."""
        mod = _load_validator()
        schema = {"type": "object", "additionalProperties": {"type": ["string", "number"]}}
        assert mod.validate({"anything": "x", "n": 2}, schema, {}) == []
        assert mod.validate({"bad": {}}, schema, {})

    def test_min_items_and_per_item_validation(self) -> None:
        mod = _load_validator()
        schema = {"type": "array", "minItems": 1, "items": {"type": "string"}}
        assert mod.validate(["a"], schema, {}) == []
        assert "at least 1 item" in mod.validate([], schema, {})[0]
        assert "[1]" in mod.validate(["a", 2], schema, {})[0]

    def test_every_violation_is_reported_not_just_the_first(self) -> None:
        mod = _load_validator()
        schema = {
            "type": "object",
            "required": ["a", "b"],
            "properties": {"c": {"type": "string"}},
        }
        errors = mod.validate({"c": 1}, schema, {})
        assert len(errors) == 3, errors

    def test_resolve_follows_local_refs(self) -> None:
        mod = _load_validator()
        root = {"$defs": {"rect": {"type": "object"}}}
        assert mod.resolve({"$ref": "#/$defs/rect"}, root) == {"type": "object"}
        assert mod.validate([], {"$ref": "#/$defs/rect"}, root)

    def test_unsupported_keywords_walks_nested_schemas(self) -> None:
        mod = _load_validator()
        assert mod.unsupported_keywords({"type": "object", "description": "fine"}) == []
        found = mod.unsupported_keywords(
            {
                "properties": {"a": {"oneOf": []}},
                "$defs": {"b": {"items": {"uniqueItems": True}}},
                "additionalProperties": {"maxProperties": 2},
            }
        )
        assert sorted(found) == [
            "#/$defs/b/items/uniqueItems",
            "#/additionalProperties/maxProperties",
            "#/properties/a/oneOf",
        ], found

    def test_the_real_schema_uses_only_implemented_keywords(self) -> None:
        """Guards the reverse direction: the gate must not have drifted behind the schema."""
        mod = _load_validator()
        schema = json.loads((_PROJECT_ROOT / "contracts" / "verdict-schema.json").read_text())
        assert mod.unsupported_keywords(schema) == []


class TestValidateContractsFailureBranches:
    """Each failure the validator promises to catch, proven by making it happen.

    A gate is only worth its PASS if its FAIL is reachable. Every case here builds
    a broken contracts/ directory in a tmp_path and asserts both the non-zero exit
    and the message that names the defect — otherwise a validator could return 1
    for an unrelated reason and look correct.
    """

    @staticmethod
    def _stage(tmp_path: Path) -> tuple[Path, Path]:
        """A copy of the real contracts/ plus a copy of SchemaVersion.swift."""
        source = _PROJECT_ROOT / "contracts"
        contracts = tmp_path / "contracts"
        (contracts / "fixtures").mkdir(parents=True)
        (contracts / "verdict-schema.json").write_text((source / "verdict-schema.json").read_text())
        for fixture in (source / "fixtures").glob("*.json"):
            (contracts / "fixtures" / fixture.name).write_text(fixture.read_text())
        kernel = tmp_path / "SchemaVersion.swift"
        kernel.write_text(
            (_PROJECT_ROOT / "Sources" / "VerdictUIKernel" / "SchemaVersion.swift").read_text()
        )
        return contracts, kernel

    def _run(self, contracts: Path, kernel: Path) -> tuple[int, str]:
        mod = _load_validator()
        buffer = io.StringIO()
        with contextlib.redirect_stdout(buffer):
            code = mod.main(["--contracts", str(contracts), "--kernel-source", str(kernel)])
        return code, buffer.getvalue()

    def test_staged_copy_passes_before_any_tampering(self, tmp_path: Path) -> None:
        """Control: without this, a later FAIL might just mean the copy was broken."""
        contracts, kernel = self._stage(tmp_path)
        code, output = self._run(contracts, kernel)
        assert code == 0, output

    def test_unparseable_schema_fails(self, tmp_path: Path) -> None:
        contracts, kernel = self._stage(tmp_path)
        (contracts / "verdict-schema.json").write_text('{"type": "object",}')
        code, output = self._run(contracts, kernel)
        assert code == 1
        assert "unreadable" in output, output

    def test_schema_that_is_not_an_object_fails(self, tmp_path: Path) -> None:
        contracts, kernel = self._stage(tmp_path)
        (contracts / "verdict-schema.json").write_text("[]")
        code, output = self._run(contracts, kernel)
        assert code == 1
        assert "not a schema object" in output, output

    def test_missing_schema_fails(self, tmp_path: Path) -> None:
        contracts, kernel = self._stage(tmp_path)
        (contracts / "verdict-schema.json").unlink()
        code, output = self._run(contracts, kernel)
        assert code == 1
        assert "not found" in output, output

    def test_version_drift_between_schema_and_kernel_fails(self, tmp_path: Path) -> None:
        """The behaviour SchemaVersion.swift's doc comment promises."""
        contracts, kernel = self._stage(tmp_path)
        kernel.write_text(kernel.read_text().replace('current = "1.0"', 'current = "2.0"'))
        assert 'current = "2.0"' in kernel.read_text(), "drift was not actually introduced"
        code, output = self._run(contracts, kernel)
        assert code == 1
        assert "version drift" in output, output
        assert "'2.0'" in output, output

    def test_stale_id_url_fails_even_when_const_agrees(self, tmp_path: Path) -> None:
        contracts, kernel = self._stage(tmp_path)
        schema = json.loads((contracts / "verdict-schema.json").read_text())
        schema["$id"] = "https://verdictui.dev/schemas/verdict/0.9.json"
        (contracts / "verdict-schema.json").write_text(json.dumps(schema))
        code, output = self._run(contracts, kernel)
        assert code == 1
        assert "$id" in output, output

    def test_kernel_source_without_a_version_declaration_fails(self, tmp_path: Path) -> None:
        contracts, kernel = self._stage(tmp_path)
        kernel.write_text("public enum SchemaVersion {}\n")
        code, output = self._run(contracts, kernel)
        assert code == 1
        assert "no 'static let current'" in output, output

    def test_fixture_violating_the_schema_fails(self, tmp_path: Path) -> None:
        contracts, kernel = self._stage(tmp_path)
        target = contracts / "fixtures" / "verdict-pass.json"
        payload = json.loads(target.read_text())
        del payload["timing"]  # required by the schema
        payload["status"] = "MAYBE"  # outside the enum
        payload["findings"] = "none"  # wrong type
        payload["surprise"] = 1  # additionalProperties: false
        target.write_text(json.dumps(payload))
        code, output = self._run(contracts, kernel)
        assert code == 1
        assert "violates the schema" in output, output
        for expected in (
            "missing required property 'timing'",
            "'MAYBE' is not one of",
            "expected type array",
            "unexpected property 'surprise'",
        ):
            assert expected in output, f"{expected!r} not reported:\n{output}"

    def test_fixture_violating_a_nested_ref_fails(self, tmp_path: Path) -> None:
        """Proves $ref resolution is real: the defect is three levels deep."""
        contracts, kernel = self._stage(tmp_path)
        target = contracts / "fixtures" / "verdict-fail.json"
        payload = json.loads(target.read_text())
        payload["tree"]["children"][0]["role"] = ""  # minLength: 1 via $defs/semanticNode
        payload["delta"]["removed"][0] = []  # minItems: 1 via $defs/nodePath
        target.write_text(json.dumps(payload))
        code, output = self._run(contracts, kernel)
        assert code == 1
        assert "shorter than minLength 1" in output, output
        assert "expected at least 1 item" in output, output

    def test_unreadable_fixture_fails(self, tmp_path: Path) -> None:
        contracts, kernel = self._stage(tmp_path)
        (contracts / "fixtures" / "broken.json").write_text("{not json")
        code, output = self._run(contracts, kernel)
        assert code == 1
        assert "broken.json unreadable" in output, output

    def test_empty_fixture_directory_fails(self, tmp_path: Path) -> None:
        """A round-trip check over zero fixtures proves nothing, so it must not pass."""
        contracts, kernel = self._stage(tmp_path)
        for fixture in (contracts / "fixtures").glob("*.json"):
            fixture.unlink()
        code, output = self._run(contracts, kernel)
        assert code == 1
        assert "nothing round-tripped" in output, output

    def test_absent_fixture_directory_fails(self, tmp_path: Path) -> None:
        contracts, kernel = self._stage(tmp_path)
        shutil.rmtree(contracts / "fixtures")
        code, output = self._run(contracts, kernel)
        assert code == 1
        assert "nothing round-tripped" in output, output

    def test_schema_keyword_the_validator_cannot_enforce_fails(self, tmp_path: Path) -> None:
        """The anti-soft-pass guard: an unimplemented keyword must never be ignored."""
        contracts, kernel = self._stage(tmp_path)
        schema = json.loads((contracts / "verdict-schema.json").read_text())
        schema["$defs"]["finding"]["properties"]["message"]["maxLength"] = 200
        (contracts / "verdict-schema.json").write_text(json.dumps(schema))
        code, output = self._run(contracts, kernel)
        assert code == 1
        assert "does not implement" in output, output
        assert "maxLength" in output, output

    def test_unresolvable_ref_fails(self, tmp_path: Path) -> None:
        contracts, kernel = self._stage(tmp_path)
        schema = json.loads((contracts / "verdict-schema.json").read_text())
        schema["properties"]["timing"] = {"$ref": "#/$defs/nowhere"}
        (contracts / "verdict-schema.json").write_text(json.dumps(schema))
        code, output = self._run(contracts, kernel)
        assert code == 1
        assert "does not resolve" in output, output

    def test_remote_ref_fails_rather_than_being_skipped(self, tmp_path: Path) -> None:
        contracts, kernel = self._stage(tmp_path)
        schema = json.loads((contracts / "verdict-schema.json").read_text())
        schema["properties"]["timing"] = {"$ref": "https://example.com/timing.json"}
        (contracts / "verdict-schema.json").write_text(json.dumps(schema))
        code, output = self._run(contracts, kernel)
        assert code == 1
        assert "unsupported $ref" in output, output


class TestStageRuntimeBench:
    """SLO 1's gate. Every test here targets a way it could report health it
    did not measure — which is the only failure mode that matters in a
    performance gate, because an over-budget run is loud and a gate that
    stopped measuring is silent."""

    @staticmethod
    def _pm():
        return VerdictUIPM.__new__(VerdictUIPM)

    @staticmethod
    def _fake_swift(monkeypatch, *, stdout: str, returncode: int = 0) -> None:
        """Replace the streaming Swift runner with a canned result."""

        def run_swift_test(**_kwargs):
            executed = [int(m) for m in re.findall(r"Executed (\d+) test", stdout)]
            return {
                "passed": returncode == 0,
                "detail": "swift test failed" if returncode else "swift test passed",
                "output": stdout,
                "test_count": max(executed, default=0),
            }

        monkeypatch.setattr(_mod.shutil, "which", lambda _: "/usr/bin/swift")
        monkeypatch.setattr(_mod, "_timing_record_only_environment", lambda: False)
        monkeypatch.setattr(_mod, "_run_streamed_swift_test", run_swift_test)

    def test_uses_the_streaming_serial_runner_with_the_benchmark_filter(self, monkeypatch) -> None:
        calls = []

        def run_swift_test(**kwargs):
            calls.append(kwargs)
            return {
                "passed": True,
                "detail": "swift test passed",
                "output": "SLO1-PERFORM p50=20.03ms p95=32.23ms n=3\n"
                "Executed 3 tests, with 0 failures\n",
                "test_count": 3,
            }

        monkeypatch.setattr(_mod.shutil, "which", lambda _: "/usr/bin/swift")
        monkeypatch.setattr(_mod, "_timing_record_only_environment", lambda: False)
        monkeypatch.setattr(_mod, "_run_streamed_swift_test", run_swift_test)

        result = self._pm().stage_runtime_bench()

        assert result["passed"], result["detail"]
        assert len(calls) == 1
        kwargs = calls[0]
        assert kwargs["timeout"] == _mod.TIMEOUT_SWIFT_TEST
        assert kwargs["min_test_count"] == 1
        assert kwargs["log_name"] == "swift-runtime-bench-latest.log"
        assert "--parallel" not in kwargs["extra_flags"]
        assert "--filter" in kwargs["extra_flags"]
        assert "HarnessPerformanceTests" in kwargs["extra_flags"]

    def test_over_budget_records_in_a_constrained_timing_environment(self, monkeypatch) -> None:
        self._fake_swift(
            monkeypatch,
            stdout="SLO1-PERFORM p50=118.00ms p95=160.50ms mean=120.00ms max=200.0ms n=150\n"
            "Executed 2 tests, with 0 failures\n",
        )
        monkeypatch.setattr(_mod, "_timing_record_only_environment", lambda: True)

        result = self._pm().stage_runtime_bench()

        assert result["passed"], result["detail"]
        assert "recorded in constrained timing environment" in result["detail"]

    def test_under_budget_passes_and_reports_the_figure(self, monkeypatch) -> None:
        self._fake_swift(
            monkeypatch,
            stdout="SLO1-PERFORM p50=20.03ms p95=32.23ms mean=22.97ms max=89.79ms n=60\n"
            "Executed 2 tests, with 0 failures\n",
        )
        result = self._pm().stage_runtime_bench()
        assert result["passed"], result["detail"]
        assert "32.23ms" in result["detail"]

    def test_over_budget_fails(self, monkeypatch) -> None:
        self._fake_swift(
            monkeypatch,
            stdout="SLO1-PERFORM p50=90.00ms p95=140.50ms mean=95.00ms max=200.0ms n=60\n"
            "Executed 2 tests, with 0 failures\n",
        )
        result = self._pm().stage_runtime_bench()
        assert not result["passed"]
        assert "90.00ms" in result["detail"]

    def test_a_contended_tail_does_not_fail_the_stage(self, monkeypatch) -> None:
        """The figures below are a REAL measurement, not an invented shape:
        the PM run of 2026-08-07 reported exactly this pair while two isolated
        runs of the same commit gave p95 58.43 and 77.01 ms on an unchanged
        p50. `HarnessPerformanceTests` already decided this — it records p95
        and asserts p50, because p95 moves 56.7 -> 106.7 ms purely with
        contention while p50 sits at 49.6-51.2 ms in every context observed.

        The stage re-imposed the tail gate one level up, so the decision held
        in the test and was reversed by its own consumer. A gate that fails
        for load teaches its reader to ignore it, which is the failure mode
        that makes a false positive worse than a missing check."""
        self._fake_swift(
            monkeypatch,
            stdout="SLO1-PERFORM p50=49.09ms p95=105.51ms mean=50.00ms max=140.0ms n=150\n"
            "Executed 2 tests, with 0 failures\n",
        )
        result = self._pm().stage_runtime_bench()
        assert result["passed"], result["detail"]
        # Recorded, so a human reading the log still sees the tail.
        assert "105.51" in result["detail"]

    def test_a_regressed_median_fails_even_with_a_healthy_tail(self, monkeypatch) -> None:
        """The other direction, which is the one that matters: the median is
        the load-stable statistic, so it is the one that can carry a claim
        about the CODE. A p50 over its budget is a regression even when the
        tail happens to look fine, and asserting only the tail would miss it.

        Paired with the test above so 'the stage stopped failing' cannot
        satisfy both — one demands PASS on a contended tail, the other demands
        FAIL on a moved median."""
        self._fake_swift(
            monkeypatch,
            stdout="SLO1-PERFORM p50=88.00ms p95=95.00ms mean=89.00ms max=99.0ms n=150\n"
            "Executed 2 tests, with 0 failures\n",
        )
        result = self._pm().stage_runtime_bench()
        assert not result["passed"]
        assert "88.00ms" in result["detail"]

    def test_a_missing_p50_fails_rather_than_falling_back_to_the_tail(self, monkeypatch) -> None:
        """The gated figure must be the one parsed. A line carrying p95 but no
        p50 means the reporting format moved under the stage, and reading
        whichever number is present would silently re-point the gate at the
        statistic this change exists to stop asserting."""
        self._fake_swift(
            monkeypatch,
            stdout="SLO1-PERFORM p95=32.00ms mean=22.0ms n=150\n"
            "Executed 2 tests, with 0 failures\n",
        )
        result = self._pm().stage_runtime_bench()
        assert not result["passed"]
        assert "did not report" in result["detail"]

    def test_a_missing_summary_line_fails_rather_than_passing_quietly(self, monkeypatch) -> None:
        """The benchmark ran tests but printed no figure. That is not health —
        it means the reporting line was renamed or removed, and a gate that
        treats 'no number' as 'no problem' is exactly the fail-open this
        stage exists to avoid."""
        self._fake_swift(monkeypatch, stdout="Executed 2 tests, with 0 failures\n")
        result = self._pm().stage_runtime_bench()
        assert not result["passed"]
        assert "did not report" in result["detail"]

    def test_zero_executed_tests_fails_even_though_swift_exits_zero(self, monkeypatch) -> None:
        """`swift test --filter` exits 0 when the filter matches nothing. A
        stale filter must read as a broken gate, not as a fast one."""
        self._fake_swift(monkeypatch, stdout="Executed 0 tests, with 0 failures\n")
        result = self._pm().stage_runtime_bench()
        assert not result["passed"]
        assert "no executed tests" in result["detail"]

    def test_no_executed_line_at_all_fails(self, monkeypatch) -> None:
        """Not even a summary line: the runner died or never started."""
        self._fake_swift(monkeypatch, stdout="")
        result = self._pm().stage_runtime_bench()
        assert not result["passed"]

    def test_budget_boundary_is_exclusive(self, monkeypatch) -> None:
        """p50 exactly at its budget fails. The budget reads '<', so a figure
        landing on it is over, and pinning it here stops a later refactor
        turning `>=` into `>` without anyone noticing.

        Asserted on the GATED statistic. It formerly fed the boundary through
        p95, which stopped testing the boundary the moment the gate moved --
        a boundary test aimed at a recorded-only number cannot fail for the
        reason it exists."""
        self._fake_swift(
            monkeypatch,
            stdout=f"SLO1-PERFORM p50={_mod.SLO1_P50_BUDGET_MS:.2f}ms p95=80.0ms n=150\n"
            "Executed 2 tests, with 0 failures\n",
        )
        result = self._pm().stage_runtime_bench()
        assert not result["passed"]

    def test_the_gated_budget_agrees_with_the_swift_test(self) -> None:
        """Two files hold this threshold and neither can see the other, so the
        agreement is only real if something compares them. The Swift test
        spells it `50 * 1.4`; the PM cannot import Swift, so the number is
        duplicated and this test is the joint.

        Without it, moving one and not the other gives a PM that passes a
        median the test rejects (or the reverse) -- and the disagreement is
        invisible from either side, which is exactly how the p95 gate survived
        being retired in the test while the PM kept asserting it."""
        source = (
            _PROJECT_ROOT / "Tests" / "VerdictUIProbeTests" / "HarnessPerformanceTests.swift"
        ).read_text()
        match = re.search(r"performP50BudgetMs:\s*Double\s*=\s*([0-9.]+)\s*\*\s*([0-9.]+)", source)
        assert match is not None, "performP50BudgetMs is no longer spelled as a product"
        swift_budget = float(match.group(1)) * float(match.group(2))
        assert swift_budget == _mod.SLO1_P50_BUDGET_MS, (
            f"the Swift test asserts p50 < {swift_budget} ms but the PM gates at "
            f"{_mod.SLO1_P50_BUDGET_MS} ms — one moved without the other"
        )

    def test_the_swift_and_python_timing_lanes_agree(self) -> None:
        """The same marker class is spelled in two languages that cannot read
        each other, so the agreement is only real if something compares them.

        A marker present on one side only is silent in the expensive direction:
        the forgetful side keeps ASSERTING a median the host cannot hold, which
        is the Codex-sandbox failure (`no.md` #17) -- p50 167.50 ms against a
        70 ms budget on source measuring ~49 ms, and three P1 tickets for a
        regression that did not exist. Same joint as
        ``test_the_gated_budget_agrees_with_the_swift_test``, one level up: that
        pins the number, this pins the set of hosts it applies to.
        """
        source = (
            _PROJECT_ROOT / "Tests" / "VerdictUIProbeTests" / "ConstrainedTimingEnvironment.swift"
        ).read_text()
        block = re.search(r"static let markers = \[(.*?)\]", source, re.DOTALL)
        assert block is not None, "ConstrainedTimingEnvironment.markers is no longer a list literal"
        swift_markers = set(re.findall(r'"([^"]+)"', block.group(1)))

        assert swift_markers == set(_mod.CONSTRAINED_TIMING_ENV_MARKERS), (
            f"Swift marks {sorted(swift_markers)} as timing-constrained but the PM marks "
            f"{sorted(_mod.CONSTRAINED_TIMING_ENV_MARKERS)} — a host in one set and not the "
            "other asserts a budget it cannot hold, or exempts one it can"
        )

    def test_swift_failure_is_surfaced_not_swallowed(self, monkeypatch) -> None:
        self._fake_swift(
            monkeypatch,
            stdout="HarnessPerformanceTests.swift:110: error: p95 over budget\n",
            returncode=1,
        )
        result = self._pm().stage_runtime_bench()
        assert not result["passed"]
        assert "error:" in result["detail"]

    def test_missing_swift_fails_closed(self, monkeypatch) -> None:
        monkeypatch.setattr(_mod.shutil, "which", lambda _: None)
        result = self._pm().stage_runtime_bench()
        assert not result["passed"]
        assert "swift not installed" in result["detail"]

    def test_the_stage_is_registered_in_the_pipeline(self) -> None:
        """A stage that exists but is never run is not a gate. Read the source
        rather than the stage list, which is built inside a method."""
        source = (_PROJECT_ROOT / "scripts" / "verdictui-pm.py").read_text()
        assert '("stage_runtime_bench", self.stage_runtime_bench)' in source

    def test_the_budget_matches_the_published_slo(self) -> None:
        """docs/slo.md is the SSoT for the number. The constant is duplicated
        into the PM deliberately (parsing a threshold out of prose fails open
        when the prose is reworded), so the two must be asserted equal."""
        slo = (_PROJECT_ROOT / "docs" / "slo.md").read_text()
        assert f"< {int(_mod.SLO1_P95_BUDGET_MS)} ms p95" in slo


class TestNoSleepsInHarnessSource:
    """Wave 3 exit gate: zero sleeps anywhere in the harness.

    The product's claim is that verification is deterministic — settle returns
    when the UI is quiet, not when a guessed interval elapses. A `sleep` in
    Sources/ would be that claim quietly abandoned, and it is the single
    easiest thing to add when a test is flaky, which is exactly when it is
    most tempting and most wrong.

    `VerdictClock` is the sanctioned exception: it IMPLEMENTS Swift's `Clock`
    protocol, whose requirement is literally named `sleep(until:tolerance:)`,
    and its whole purpose is to make waiting controllable rather than real.
    """

    _PATTERN = re.compile(r"\b(?:Thread\.sleep|usleep|nanosleep)\b|(?<![.\w])sleep\s*\(")

    def test_no_real_sleeps_outside_the_virtual_clock(self) -> None:
        offenders: list[str] = []
        for path in sorted((_PROJECT_ROOT / "Sources").rglob("*.swift")):
            if path.name == "VerdictClock.swift":
                continue  # implements Clock.sleep by design — see the class docstring
            for number, line in enumerate(path.read_text().splitlines(), start=1):
                code = line.split("//", 1)[0]
                if self._PATTERN.search(code):
                    rel = path.relative_to(_PROJECT_ROOT)
                    offenders.append(f"{rel}:{number}: {line.strip()}")
        assert not offenders, "sleeps found in harness source:\n" + "\n".join(offenders)

    def test_the_detector_actually_fires(self, tmp_path, monkeypatch) -> None:
        """The test above passes on an empty match set, so on its own it cannot
        tell 'no sleeps' from 'the pattern stopped matching'. This plants one."""
        fake = tmp_path / "Sources" / "VerdictUIProbe"
        fake.mkdir(parents=True)
        (fake / "Bad.swift").write_text("func wait() {\n    Thread.sleep(forTimeInterval: 1)\n}\n")
        monkeypatch.setattr(_mod, "PROJECT_ROOT", tmp_path)
        # Re-run the same scan against the planted tree.
        offenders = [
            line
            for path in (tmp_path / "Sources").rglob("*.swift")
            for number, line in enumerate(path.read_text().splitlines(), start=1)
            if self._PATTERN.search(line.split("//", 1)[0])
        ]
        assert offenders, "the sleep detector failed to notice a planted Thread.sleep"


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
