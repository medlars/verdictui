"""Tests for VerdictUIPM stages, floor-check, and validate-contracts."""

import importlib.util
import subprocess
import sys
from pathlib import Path

import pytest

# Quick gate: pure-python, sub-second — belongs in the pre-merge gate.
# Without a marker the quick gate selects ZERO tests and reports success (lesson 183).
pytestmark = pytest.mark.quick

_PROJECT_ROOT = Path(__file__).resolve().parents[1]
_PM_PATH = str(_PROJECT_ROOT / "scripts" / "verdictui-pm.py")
_PYTHON = sys.executable

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


class TestStageBuild:
    def test_missing_package_swift_fails(self, tmp_path, monkeypatch) -> None:
        monkeypatch.setattr(_mod, "PROJECT_ROOT", tmp_path)
        pm = VerdictUIPM.__new__(VerdictUIPM)
        result = pm.stage_build()
        assert not result["passed"]
        assert "Package.swift" in result["detail"]


class TestSkipSentinel:
    def test_skipped_shared_libs_passes_with_reason(self) -> None:
        result = VerdictUIPM._skipped_shared_libs(ImportError("nope"))
        assert result["passed"]
        assert "skipped: shared-libs unavailable" in result["detail"]


class TestDefineStages:
    def test_quick_pipeline_contains_all_mandatory_stages(self) -> None:
        pm = VerdictUIPM.__new__(VerdictUIPM)
        names = [name for name, _fn in pm.define_stages("quick")]
        mandatory = [
            "stage_build",
            "stage_test",
            "stage_floor",
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

    def test_stage_lint_skips_when_ruff_missing(self, monkeypatch) -> None:
        import shutil as _shutil

        monkeypatch.setattr(_shutil, "which", lambda _: None)
        pm = VerdictUIPM.__new__(VerdictUIPM)
        result = pm.stage_lint()
        assert result["passed"]
        assert "skipped" in result["detail"]

    def test_stage_lint_runs_clean_on_this_repo(self) -> None:
        pm = VerdictUIPM.__new__(VerdictUIPM)
        result = pm.stage_lint()
        assert result["passed"], result["detail"]

    def test_stage_floor_passes_on_this_repo(self) -> None:
        pm = VerdictUIPM.__new__(VerdictUIPM)
        result = pm.stage_floor()
        assert result["passed"], result["detail"]

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


class TestValidateContractsMain:
    def test_main_returns_zero(self) -> None:
        vc_path = str(_PROJECT_ROOT / "contracts" / "validate-contracts.py")
        spec = importlib.util.spec_from_file_location("verdictui_validate_contracts", vc_path)
        mod = importlib.util.module_from_spec(spec)  # type: ignore[arg-type]
        spec.loader.exec_module(mod)  # type: ignore[union-attr]
        assert mod.main() == 0


class TestFloorCheck:
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
    def test_validate_contracts_stub_exits_zero(self) -> None:
        r = subprocess.run(
            [_PYTHON, str(_PROJECT_ROOT / "contracts" / "validate-contracts.py")],
            capture_output=True,
            text=True,
            timeout=60,
        )
        assert r.returncode == 0
        assert "SKIP" in r.stdout
