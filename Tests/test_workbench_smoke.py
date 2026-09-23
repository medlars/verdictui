"""The rendered smoke gate cannot claim success from skips or empty runs."""

from __future__ import annotations

import importlib.util
import json
import sys
from pathlib import Path

import pytest

pytestmark = pytest.mark.quick
SCRIPT = Path(__file__).resolve().parent.parent / "scripts/workbench-smoke.py"
SPEC = importlib.util.spec_from_file_location("workbench_smoke", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
smoke = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = smoke
SPEC.loader.exec_module(smoke)


def test_empty_execution_never_prints_a_pass(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    run = smoke.SmokeRun()
    assert smoke.report(run, tmp_path) == 1
    output = capsys.readouterr().out
    assert "WORKBENCH SMOKE FAIL: 0 passed, 0 failed, 0/2" in output
    assert "WORKBENCH SMOKE PASS" not in output


def test_both_browsers_must_run_assertions_not_just_start() -> None:
    run = smoke.SmokeRun(completed_browsers=["chromium", "webkit"])
    run.assertion("chromium visible check", True)
    assert run.summary()["status"] == "FAIL"
    run.assertion("webkit visible check", True)
    assert run.summary()["status"] == "PASS"


def test_a_failed_assertion_is_counted_once_and_preserves_passes(tmp_path: Path) -> None:
    run = smoke.SmokeRun(completed_browsers=["chromium", "webkit"])
    run.assertion("chromium passing check", True)
    run.assertion("webkit passing check", True)
    with pytest.raises(smoke.SmokeFailure, match="actual regression"):
        run.assertion("webkit actual regression", False)
    assert smoke.report(run, tmp_path) == 1
    output = json.loads((tmp_path / "verification.json").read_text())
    assert output["passed"] == 2
    assert output["failed"] == 1
    assert output["failures"] == [
        {"name": "webkit actual regression", "message": "assertion failed"}
    ]


def test_missing_browser_is_failure_not_a_passing_result() -> None:
    run = smoke.SmokeRun(completed_browsers=["chromium"])
    run.assertion("chromium complete check", True)
    run.unavailable("webkit browser flow", "runtime missing")
    assert run.summary()["passed"] == 1
    assert run.summary()["failed"] == 1
    assert run.summary()["status"] == "FAIL"


def test_partial_browser_flow_is_not_complete_even_with_measured_assertions() -> None:
    run = smoke.SmokeRun(completed_browsers=["chromium"])
    run.assertion("chromium finished check", True)
    run.assertion("webkit intermediate check", True)
    assert run.summary()["status"] == "FAIL"
    run.completed_browsers.append("webkit")
    assert run.summary()["status"] == "PASS"


def test_complete_measured_run_prints_nonzero_summary(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    run = smoke.SmokeRun(completed_browsers=["chromium", "webkit"])
    run.assertion("chromium measured check", True)
    run.assertion("webkit measured check", True)
    assert smoke.report(run, tmp_path) == 0
    assert "WORKBENCH SMOKE PASS: 2 passed, 0 failed, 2/2" in capsys.readouterr().out


def test_missing_resources_emit_structured_failure(tmp_path: Path) -> None:
    artifacts = tmp_path / "artifacts"
    assert smoke.main([str(tmp_path), "--artifact-dir", str(artifacts)]) == 1
    output = json.loads((artifacts / "verification.json").read_text())
    assert output["passed"] == 0
    assert output["failed"] == 1
    assert output["status"] == "FAIL"
