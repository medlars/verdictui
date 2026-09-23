"""Artifact gates must require affirmative measured output, not just exit zero."""

import json
import subprocess

import pytest
from pm_test_support import load_pm

_mod = load_pm()


@pytest.mark.parametrize(
    ("code", "output", "passed"),
    [
        (0, "", False),
        (0, "{}", False),
        (0, '{"status":"PASS","checks":[],"sha256":"abc"}', False),
        (0, '{"status":"unavailable","checks":["native"],"sha256":"abc"}', False),
        (1, '{"status":"PASS","checks":["native"],"sha256":"abc"}', False),
        (0, '{"status":"PASS","checks":["native"],"sha256":"abc"}', True),
    ],
)
def test_real_product_stage_requires_measured_acceptance(monkeypatch, code, output, passed):
    def run(arguments, **kwargs):
        assert "product-smoke.py" in arguments[1]
        assert kwargs["timeout"] > 0
        return subprocess.CompletedProcess(arguments, code, output, "")

    monkeypatch.setattr(subprocess, "run", run)
    pm = _mod.VerdictUIPM.__new__(_mod.VerdictUIPM)
    assert pm.stage_real_products()["passed"] is passed


@pytest.mark.parametrize("output", ["", "no tests matched", json.dumps({"status": "PASS"})])
def test_cold_consumer_requires_its_actual_summary(monkeypatch, output):
    monkeypatch.setattr(
        subprocess, "run", lambda args, **_: subprocess.CompletedProcess(args, 0, output, "")
    )
    pm = _mod.VerdictUIPM.__new__(_mod.VerdictUIPM)
    assert not pm.stage_consumer_runner()["passed"]


@pytest.mark.parametrize(
    ("code", "output", "passed"),
    [
        (0, "", False),
        (0, "WORKBENCH SMOKE PASS: 0 passed, 0 failed, 2/2 browser flows complete", False),
        (0, "WORKBENCH SMOKE PASS: 4 passed, 0 failed, 1/2 browser flows complete", False),
        (0, "WORKBENCH SMOKE PASS: 4 passed, 1 failed, 2/2 browser flows complete", False),
        (1, "WORKBENCH SMOKE PASS: 4 passed, 0 failed, 2/2 browser flows complete", False),
        (0, "WORKBENCH SMOKE PASS: 4 passed, 0 failed, 2/2 browser flows complete", True),
    ],
)
def test_workbench_stage_requires_complete_measured_flows(monkeypatch, code, output, passed):
    monkeypatch.setattr(
        subprocess, "run", lambda args, **_: subprocess.CompletedProcess(args, code, output, "")
    )
    pm = _mod.VerdictUIPM.__new__(_mod.VerdictUIPM)
    assert pm.stage_workbench()["passed"] is passed
