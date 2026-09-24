"""Artifact gates must require affirmative measured output, not just exit zero."""

import json
import subprocess
import sys
from pathlib import Path

import pytest
from pm_test_support import load_pm

_mod = load_pm()


def test_workbench_pm_timeout_allows_native_cleanup(tmp_path, monkeypatch):
    import signal
    import time

    import verdictui_pm_smoke as smoke

    workbench_inputs(tmp_path, monkeypatch)
    (tmp_path / "scripts").mkdir()
    binary = tmp_path / "candidate.app/Contents/MacOS/VerdictUIWorkbench"
    binary.parent.mkdir(parents=True)
    marker = tmp_path / "native-stopped"
    ready = tmp_path / "native-ready"
    release = tmp_path / "release"
    binary.write_text(
        f"#!{sys.executable}\nimport pathlib,signal,time,sys,os\n"
        f"release=pathlib.Path({str(release)!r})\n"
        "def stop(sig,frame):\n"
        f" pathlib.Path({str(marker)!r}).write_text(str(sig));sys.exit(2)\n"
        "signal.signal(signal.SIGTERM,stop)\n"
        f"pathlib.Path({str(ready)!r}).write_text(str(os.getpid()))\n"
        "deadline=time.monotonic()+10\n"
        "while not release.exists() and time.monotonic()<deadline: time.sleep(.01)\n"
    )
    binary.chmod(0o700)
    implementation = Path(__file__).resolve().parents[1] / "scripts/workbench-acceptance.py"
    (tmp_path / "scripts/workbench-acceptance.py").write_text(
        "import argparse,importlib.util,pathlib,sys,types\n"
        f"spec=importlib.util.spec_from_file_location('actual',{str(implementation)!r})\n"
        "m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)\n"
        "m.load_identity=lambda _:types.SimpleNamespace(validate_app=lambda *a:{},validate_consumer=lambda *a:{})\n"
        f"root=pathlib.Path({str(tmp_path)!r});output=m.create_output(root/'native-run')\n"
        "try: m.run(argparse.Namespace(app=root/'candidate.app',consumer_runner=root/'consumer',consumer_build_receipt=root/'consumer.json',timeout_seconds=20),root,output)\n"
        "except ValueError: sys.exit(2)\n"
    )
    real_run = subprocess.run

    def run(args, **kwargs):
        if "workbench-acceptance.py" in args[1]:
            return real_run(args, **{**kwargs, "timeout": 1})
        return subprocess.CompletedProcess(
            args, 0, "WORKBENCH SMOKE PASS: 108 passed, 0 failed, 2/2 browser flows complete", ""
        )

    monkeypatch.setattr(subprocess, "run", run)
    monkeypatch.setattr(smoke, "WORKBENCH_NATIVE_TIMEOUT", 1, raising=False)
    try:
        pm = _mod.VerdictUIPM.__new__(_mod.VerdictUIPM)
        result = pm.stage_workbench()
        assert not result["passed"]
        assert ready.exists(), "stalled native fixture was never exercised"
        assert marker.exists(), "PM killed wrapper before its detached native cleanup"
        assert marker.read_text() == str(signal.SIGTERM)
        assert "tim" in result["detail"].lower()
    finally:
        release.touch()
        deadline = time.monotonic() + 2
        while ready.exists() and not marker.exists() and time.monotonic() < deadline:
            time.sleep(0.01)


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
        (0, "cold external consumer auto-build PASS", False),
        (1, "consumer reload PASS: same MCP/daemon PID", False),
        (0, "consumer reload PASS: same MCP/daemon PID", True),
    ],
)
def test_consumer_gate_requires_persistent_rebuild_recovery(monkeypatch, code, output, passed):
    modes = []

    def run(arguments, **kwargs):
        assert kwargs["timeout"] > 0
        modes.append(arguments[-1])
        if arguments[-1] == "--cold":
            return subprocess.CompletedProcess(
                arguments, 0, "cold external consumer auto-build PASS", ""
            )
        assert arguments[-1] == "--reload"
        return subprocess.CompletedProcess(arguments, code, output, "")

    monkeypatch.setattr(subprocess, "run", run)
    pm = _mod.VerdictUIPM.__new__(_mod.VerdictUIPM)
    assert pm.stage_consumer_runner()["passed"] is passed
    assert modes == ["--cold", "--reload"]


def workbench_inputs(tmp_path, monkeypatch):
    monkeypatch.setattr(_mod.S, "PROJECT_ROOT", tmp_path)
    (tmp_path / "dist").mkdir()
    (tmp_path / "dist/workbench-acceptance-inputs.json").write_text(
        json.dumps(
            {
                "app": str(tmp_path / "candidate.app"),
                "consumer_runner": str(tmp_path / "consumer"),
                "consumer_build_receipt": str(tmp_path / "consumer.json"),
            }
        )
    )


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
def test_workbench_stage_requires_complete_measured_flows(
    monkeypatch, tmp_path, code, output, passed
):
    workbench_inputs(tmp_path, monkeypatch)

    def run(args, **_):
        if "workbench-smoke.py" in args[1]:
            return subprocess.CompletedProcess(args, code, output, "")
        return subprocess.CompletedProcess(
            args, 0, "WORKBENCH ACCEPTANCE PASS: 40 assertions, 10/10 native phases complete", ""
        )

    monkeypatch.setattr(subprocess, "run", run)
    monkeypatch.setattr("verdictui_pm_smoke._run_workbench_native", run)
    pm = _mod.VerdictUIPM.__new__(_mod.VerdictUIPM)
    assert pm.stage_workbench()["passed"] is passed


@pytest.mark.parametrize(
    "native",
    [
        "",
        "PASS",
        "WORKBENCH ACCEPTANCE PASS: 0 assertions, 10/10 native phases complete",
        "WORKBENCH ACCEPTANCE PASS: 40 assertions, 9/10 native phases complete",
        "WORKBENCH ACCEPTANCE UNAVAILABLE: no paint",
    ],
)
def test_workbench_stage_refuses_missing_native_acceptance(monkeypatch, tmp_path, native):
    workbench_inputs(tmp_path, monkeypatch)

    def run(args, **_):
        output = (
            "WORKBENCH SMOKE PASS: 108 passed, 0 failed, 2/2 browser flows complete"
            if "workbench-smoke.py" in args[1]
            else native
        )
        return subprocess.CompletedProcess(args, 0, output, "")

    monkeypatch.setattr(subprocess, "run", run)
    monkeypatch.setattr("verdictui_pm_smoke._run_workbench_native", run)
    pm = _mod.VerdictUIPM.__new__(_mod.VerdictUIPM)
    assert not pm.stage_workbench()["passed"]
