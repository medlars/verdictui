"""Tests for VerdictUIPM's stages.

`floor-check.py` and `contracts/validate-contracts.py` are standalone gate
SCRIPTS the PM shells out to rather than stages of it, and their tests live in
`test_verdictui_gates.py` (split out under CTS-E51CBEEB). The loader preamble
both files need is `pm_test_support.py`.
"""

import importlib.util
import json
import os
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

    def test_module_imports_when_default_ceo_lock_dir_rejects_chmod(self) -> None:
        """A repair sandbox can block HOME CEO locks while shared-libs exists.

        This is not the same case as missing shared-libs: the import got as far
        as reporter.py, then `ceo_lock_path()` raised `PermissionError` before
        the local `query` command could run. The PM should redirect only the
        import-time CEO paths into VerdictUI-local writable directories.
        """
        probe = (
            "import importlib.util, json, os\n"
            "from pathlib import Path\n"
            "original_home = os.environ.get('HOME')\n"
            "default_lock = str(Path.home() / '.cache' / 'vohux-ceo' / 'locks')\n"
            "_real_chmod = os.chmod\n"
            "def _blocked_default_ceo_chmod(path, mode, *args, **kwargs):\n"
            "    if str(path).startswith(default_lock):\n"
            "        raise PermissionError('blocked default CEO lock for test')\n"
            "    return _real_chmod(path, mode, *args, **kwargs)\n"
            "os.chmod = _blocked_default_ceo_chmod\n"
            f"spec = importlib.util.spec_from_file_location('vupm', {_PM_PATH!r})\n"
            "mod = importlib.util.module_from_spec(spec)\n"
            "spec.loader.exec_module(mod)\n"
            "assert os.environ.get('HOME') == original_home, 'PM import leaked HOME override'\n"
            "import pm_constants\n"
            "assert pm_constants.DASHBOARD_FILE == "
            "Path('logs/ceo-dashboard.json').resolve(), pm_constants.DASHBOARD_FILE\n"
            "code = mod.main(['query', 'risk', '--file', "
            "'Tests/VerdictUICLICoreTests/MCPLatencyTests.swift'])\n"
            "print('EXIT', code)\n"
        )
        result = subprocess.run([_PYTHON, "-c", probe], capture_output=True, text=True, timeout=60)
        assert result.returncode == 0, result.stderr
        assert '"query": "risk"' in result.stdout
        assert "EXIT 0" in result.stdout


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


class TestKilledRunnerIsInconclusive:
    """A runner terminated by a signal is UNMEASURED, never a test failure.

    Measured 2026-08-10 at load 163: `stage_test` printed "Tests: FAIL
    (exit -9)" and "1 failure(s) in 3 tests" for a run the OS had killed, which
    is indistinguishable in the report from a real regression and sends the next
    session hunting a bug that does not exist (CIS-B3CE1A2C).
    """

    @staticmethod
    def _fake_run(monkeypatch, tmp_path, returncode: int, log_text: str):
        """Drive the REAL `_run_streamed_swift_test` with a process that exits
        `returncode` after writing `log_text`.

        The runner itself is under test, so it is not stubbed — only the
        subprocess and the lock it takes are.
        """
        monkeypatch.setattr(_mod, "PROJECT_ROOT", tmp_path)
        monkeypatch.setattr(_mod, "_LOCK_DIR", tmp_path / ".lock")
        monkeypatch.setattr(_mod, "_swift_runner", lambda: (lambda _root: [], None, None))

        class _FakeProc:
            pid = 4242

            def wait(self, timeout=None):  # noqa: ARG002 — signature parity
                return returncode

        def _popen(_cmd, **kwargs):
            kwargs["stdout"].write(log_text)
            kwargs["stdout"].flush()
            return _FakeProc()

        monkeypatch.setattr(_mod.subprocess, "Popen", _popen)

        import contextlib

        fake_swift_runner = types.SimpleNamespace(
            swiftpm_command_lock=lambda *_a, **_k: contextlib.nullcontext()
        )
        monkeypatch.setitem(sys.modules, "swift_runner", fake_swift_runner)

        return _mod._run_streamed_swift_test(
            extra_flags=[], timeout=60, min_test_count=1, log_name="probe.log"
        )

    def test_a_sigkilled_runner_is_reported_as_inconclusive(self, monkeypatch, tmp_path) -> None:
        result = self._fake_run(
            monkeypatch,
            tmp_path,
            returncode=-9,
            log_text="Executed 3 tests, with 1 failures\n",
        )

        assert result.get("inconclusive") is True, result
        assert "SIGKILL" in result["detail"], result["detail"]
        # The distinction that matters: the detail must NOT read as a test
        # failure, because the run was terminated rather than failed.
        assert "test failure" not in result["detail"], result["detail"]

    def test_a_genuine_test_failure_is_still_a_failure_not_inconclusive(
        self, monkeypatch, tmp_path
    ) -> None:
        """The control. Without it, "reports inconclusive" is satisfied by a
        runner that calls every nonzero exit inconclusive — which would hide
        every real regression behind "the machine was busy"."""
        result = self._fake_run(
            monkeypatch,
            tmp_path,
            returncode=1,
            log_text="Executed 3 tests, with 1 failures\n",
        )

        assert not result["passed"]
        assert not result.get("inconclusive"), result
        assert "1 test failure(s)" in result["detail"], result["detail"]

    def test_a_summaryless_log_never_reports_a_failure_count(self, monkeypatch, tmp_path) -> None:
        """The issue's OTHER half: "require a summary line before claiming any
        failure count". A log of test STARTS with no `Executed N tests` line
        must not produce the "1 failure(s) in 3 tests" the report quoted for a
        run that was killed — a count derived from what never completed
        describes the truncation, not the code.
        """
        result = self._fake_run(
            monkeypatch,
            tmp_path,
            returncode=1,
            # A `Test run with N tests failed` line WITHOUT any matching
            # `Executed N tests` summary: the swift-testing half of the parser
            # counts the failure, the XCTest half sees no completion, and the
            # count then describes the truncation rather than the code.
            log_text=(
                "Test Suite 'All tests' started\n"
                "Test Case '-[A testOne]' started.\n"
                "Test Case '-[A testTwo]' star"
            ),
        )

        # The failure count here comes from neither regex, so the run is short
        # rather than failing — assert on the branch that ACTUALLY governs a
        # summary-less log, which is that no failure is claimed at all.
        assert not result["passed"]
        assert "failure" not in result["detail"], (
            "a log with no runner summary must not report a failure COUNT — the number "
            f"would describe the truncation, not the code. Got: {result['detail']}"
        )

    def test_a_clean_run_is_unaffected(self, monkeypatch, tmp_path) -> None:
        result = self._fake_run(
            monkeypatch,
            tmp_path,
            returncode=0,
            log_text="Executed 5 tests, with 0 failures\n",
        )

        assert result["passed"], result
        assert not result.get("inconclusive")
        assert result["test_count"] == 5


class TestPmBaseImportEnvironment:
    """The sandbox fallback that lets the PM import shared pm-base at all.

    `reporter` computes CEO lock and dashboard paths at IMPORT time, so a
    sandbox where the private lock dir exists but rejects `chmod` raises before
    this PM can dispatch even a local `query`. These three helpers detect that
    and redirect the paths into the repo just long enough for the import.

    Untested until 2026-08-14 (CIS-E9A52349 / CIS-987186EE / CIS-AAA88402).
    They are the reason the PM runs in a repair sandbox at all, and a silent
    regression here would look like "shared-libs is broken" from inside one.
    """

    def test_available_paths_mean_no_overrides(self, monkeypatch, tmp_path) -> None:
        """A normal owner shell keeps the GLOBAL paths untouched.

        The empty dict is the load-bearing half: it is what
        `_restore_pm_base_import_environment` later replays, so an override
        applied here would silently persist past the import it was for.
        """
        monkeypatch.setattr(_mod.Path, "home", staticmethod(lambda: tmp_path))
        assert _mod._ceo_paths_are_available() is True
        assert _mod._prepare_pm_base_import_environment() == {}

    def test_an_unwritable_lock_dir_is_reported_unavailable(self, monkeypatch) -> None:
        """The detector must key on the ACTUAL failure, not on a guess.

        `mkdir` raising OSError is exactly what a restricted sandbox does, and
        it must read as "unavailable" rather than propagating — a raised
        exception here aborts the PM before any stage runs.
        """

        def _refuse(*_args, **_kwargs):
            raise OSError(1, "Operation not permitted")

        monkeypatch.setattr(_mod.Path, "mkdir", _refuse)
        assert _mod._ceo_paths_are_available() is False

    def test_unavailable_paths_redirect_into_the_repo_and_restore(self, monkeypatch) -> None:
        """The whole round trip: override, then put every key back as found.

        Restoration is checked for BOTH shapes — a key that existed before
        (must return to its old value) and one that did not (must be REMOVED,
        not set to empty string). Leaving `HOME` pointing into `.build/` would
        redirect every later subprocess in the session.
        """
        monkeypatch.setattr(_mod, "_ceo_paths_are_available", lambda: False)
        monkeypatch.setenv("HOME", "/original/home")
        monkeypatch.delenv("PROJECTS_HUB", raising=False)

        previous = _mod._prepare_pm_base_import_environment()

        assert previous, "an unavailable sandbox must produce overrides"
        assert previous["HOME"] == "/original/home"
        assert previous["PROJECTS_HUB"] is None, "an absent key records None, not ''"
        assert os.environ["HOME"] != "/original/home", "HOME was not redirected"
        assert str(_mod.PROJECT_ROOT) in os.environ["PROJECTS_HUB"]

        _mod._restore_pm_base_import_environment(previous)

        assert os.environ["HOME"] == "/original/home"
        assert "PROJECTS_HUB" not in os.environ, (
            "a key absent before the override must be REMOVED, not left set"
        )
