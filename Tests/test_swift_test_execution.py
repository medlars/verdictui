"""Prove runner selection and completed-test admission at their actual entry points."""

import contextlib
import importlib.util
import json
import os
import subprocess
import sys
import textwrap
from pathlib import Path
from types import SimpleNamespace

import pytest
from pm_test_support import load_pm

pytestmark = pytest.mark.quick
ROOT = Path(__file__).resolve().parents[1]


def load_script(name):
    spec = importlib.util.spec_from_file_location(
        name.replace("-", "_"), ROOT / "scripts" / f"{name}.py"
    )
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def xc(n=2, skipped=0, failed=0):
    skip = f"{skipped} tests skipped and " if skipped else ""
    return f"Executed {n} tests, with {skip}{failed} failures (0 unexpected) in 0.1 (0.1) seconds\n"


def st(n=2, status="passed"):
    return f"✔ Test run with {n} tests in 1 suite {status} after 0.1 seconds.\n"


@pytest.mark.parametrize(
    ("output", "code", "passed", "tests", "skips"),
    [
        ("Build complete!", 0, False, 0, 0),
        (xc(0) + st(0), 0, False, 0, 0),
        (xc(2, 2), 0, False, 2, 2),
        (xc(), 0, True, 2, 0),
        (xc(3, 1), 0, True, 3, 1),
        (xc(2, failed=1), 0, False, 2, 0),
        (xc(), 9, False, 2, 0),
        (xc() + st(0), 0, True, 2, 0),
        (xc() + st(), 0, True, 4, 0),
        (xc() + st(status="failed"), 0, False, 4, 0),
        (st(), 0, True, 2, 0),
        (
            '✘ Test first() skipped: "unavailable"\n↷ Test second() skipped.\n' + st(),
            0,
            False,
            2,
            2,
        ),
        ("↷ Suite suite skipped.\n↷ Test first() skipped.\n" + st(), 0, True, 2, 1),
        ("Test run with 2 tests passed", 0, False, 0, 0),
        (xc(1) + xc(3, 1) + xc(3, 1), 0, True, 3, 1),
        (xc(1, failed=1) + xc(3), 0, False, 3, 0),
        ("↷ Test first() skipped.\n" + st(0), 0, False, 0, 1),
    ],
)
def test_summary_admission(output, code, passed, tests, skips):
    result = load_script("verify-swift-test-output").verify(output, code)
    assert result["passed"] is passed
    assert result["tests"] == tests
    assert result["skipped"] == skips
    assert result["observed"] == tests - skips


def native(argv):
    assert argv.count("--build-system") == 1
    assert argv[argv.index("--build-system") + 1] == "native"


@pytest.mark.parametrize("stage", ["build", "test", "runtime_bench", "mcp_latency"])
def test_pm_stage_native(stage, monkeypatch, tmp_path):
    pm = load_pm()
    (tmp_path / "Package.swift").touch()
    binary = tmp_path / ".build/debug/verdictui"
    binary.parent.mkdir(parents=True)
    binary.touch()
    monkeypatch.setattr(pm.S, "PROJECT_ROOT", tmp_path)
    monkeypatch.setattr(pm.S, "_LOCK_DIR", tmp_path / "locks")
    monkeypatch.setattr(pm.shutil, "which", lambda _: "/usr/bin/swift")
    calls = []

    def capture(*args, **kwargs):
        calls.append((args, kwargs))
        return {"passed": False, "detail": "fixture stopped before execution"}

    monkeypatch.setattr(pm.SW, "_swift_runner", lambda: (None, capture, None))
    monkeypatch.setattr(pm.SW, "_run_streamed_swift_test", capture)
    result = getattr(pm.VerdictUIPM.__new__(pm.VerdictUIPM), f"stage_{stage}")()
    assert result["passed"] is False
    assert len(calls) == 1
    flags = calls[0][1]["extra_flags"]
    native(flags)
    assert "-warnings-as-errors" in flags
    assert "--disable-sandbox" in flags
    if stage in {"runtime_bench", "mcp_latency"}:
        assert "--filter" in flags


def test_pm_cli_native(monkeypatch, tmp_path):
    pm = load_pm()
    monkeypatch.setattr(pm.S, "_LOCK_DIR", tmp_path / "locks")
    monkeypatch.setattr(pm.S, "PROJECT_ROOT", tmp_path)
    calls = []
    locks = []

    def popen(argv, **kwargs):
        calls.append((argv, kwargs))
        return SimpleNamespace(communicate=lambda **_: ("built", ""), returncode=0)

    def lock(argv, **kwargs):
        locks.append(argv)
        return contextlib.nullcontext()

    monkeypatch.setitem(sys.modules, "swift_runner", SimpleNamespace(swiftpm_command_lock=lock))
    monkeypatch.setattr(pm.SW.subprocess, "Popen", popen)
    result = pm.SW._run_locked_swift_build_product(timeout=5)
    assert result.returncode == 0
    assert len(calls) == 1 and locks == [calls[0][0]]
    native(calls[0][0])
    assert calls[0][1]["cwd"] == tmp_path
    assert "-warnings-as-errors" in calls[0][0]


def test_mutation_native(monkeypatch):
    script = load_script("mutation-check")
    calls = []
    refreshes = []
    monkeypatch.setattr(script, "run", lambda argv: calls.append(argv))
    monkeypatch.setattr(script, "refresh_macro_expansions", lambda: refreshes.append(True))
    script.run_named_test("ActualTests/testReal", script.Runner.SWIFT)
    native(calls[0])
    assert refreshes == [True]
    assert calls[0][-4:] == ["--filter", "ActualTests/testReal", "-Xswiftc", "-warnings-as-errors"]
    script.run_named_test("Tests/test_real.py", script.Runner.PYTEST)
    assert "swift" not in calls[1]
    assert refreshes == [True]


def fake_swift(tmp_path, output, code):
    binary = tmp_path / "bin"
    binary.mkdir()
    swift = binary / "swift"
    swift.write_text(
        f"#!{sys.executable}\nimport json, os, sys\n"
        "with open(os.environ['ARGV_LOG'], 'a') as f: f.write(json.dumps(sys.argv[1:]) + '\\n')\n"
        f"print({output!r})\nraise SystemExit({code} if sys.argv[1] == 'test' else 0)\n"
    )
    swift.chmod(0o755)
    return {
        **os.environ,
        "PATH": str(binary) + os.pathsep + os.environ["PATH"],
        "ARGV_LOG": str(tmp_path / "argv.jsonl"),
        "RUNNER_TEMP": str(tmp_path),
    }


@pytest.mark.parametrize(
    ("output", "code", "passed"),
    [
        (xc(), 0, True),
        (xc() + st(0), 0, True),
        ("Build complete!", 0, False),
        (xc(), 7, False),
        (xc(2, 2), 0, False),
    ],
)
def test_ci_executes_and_admits(output, code, passed, tmp_path):
    source = (ROOT / ".github/workflows/ci.yml").read_text()

    def step_run(name):
        # Extract the literal run field from this named step, then execute it.
        # No YAML dependency is needed for these scalar shell blocks.
        step = source.split(f"      - name: {name}\n", 1)[1].split("      - name:", 1)[0]
        value = step.split("        run: ", 1)[1]
        if value.startswith("|\n"):
            lines = []
            for line in value.splitlines()[1:]:
                if line and not line.startswith("          "):
                    break
                lines.append(line)
            return textwrap.dedent("\n".join(lines))
        return value.splitlines()[0]

    test = step_run("Test (zero-warning)")
    build = step_run("Build (including test targets, zero-warning)")
    env = fake_swift(tmp_path, output, code)
    built = subprocess.run(
        ["bash", "-e", "-c", build], cwd=ROOT, env=env, capture_output=True, text=True, timeout=10
    )
    result = subprocess.run(
        ["bash", "-e", "-c", test], cwd=ROOT, env=env, capture_output=True, text=True, timeout=10
    )
    assert built.returncode == 0
    assert (result.returncode == 0) is passed, result.stdout + result.stderr
    summary = json.loads(result.stdout.splitlines()[-1])
    assert summary["exit_code"] == code
    assert summary["passed"] is passed
    for argv in map(json.loads, (tmp_path / "argv.jsonl").read_text().splitlines()):
        native(argv)
        assert "-warnings-as-errors" in argv


def test_dev_native(tmp_path):
    env = fake_swift(tmp_path, xc(), 0)
    result = subprocess.run(
        ["bash", str(ROOT / "scripts/dev.sh")], env=env, capture_output=True, text=True, timeout=10
    )
    assert result.returncode == 0, result.stderr
    calls = list(map(json.loads, (tmp_path / "argv.jsonl").read_text().splitlines()))
    assert [argv[0] for argv in calls] == ["build", "test"]
    for argv in calls:
        native(argv)


@pytest.mark.parametrize(
    ("output", "reason"),
    [
        ("Build complete!", "missing completed test summary"),
        (xc(0), "zero tests reported"),
        (xc(1, 2), "inconsistent skip accounting"),
    ],
)
def test_unavailable_reason(output, reason):
    result = load_script("verify-swift-test-output").verify(output, 0)
    assert result["passed"] is False
    assert result["detail"] == reason


def test_real_swift_64_mixed_symbols():
    # Captured from an actual native Swift 6.4 fixture on 2026-09-24.
    # Apple emits private-use SF Symbols; disabled suites also emit child skips.
    output = 'Test Suite \'All tests\' started at 2026-09-24 13:21:59.142.\nTest Suite \'All tests\' passed at 2026-09-24 13:21:59.144.\n\t Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.002) seconds\n\U001007c8  Test run started.\n\U0010065f  Suite DisabledSuite skipped: "whole suite skip"\n\U0010065f  Test individualDisabled() skipped: "individual skip"\n\U001007c8  Test actualPass() started.\n\U0010065f  Test childDisabled() skipped: "whole suite skip"\n\U0010105b  Test actualPass() passed after 0.001 seconds.\n\U0010105b  Test run with 3 tests in 1 suite passed after 0.001 seconds.\n'
    result = load_script("verify-swift-test-output").verify(output, 0)
    assert result["passed"] is True
    assert result["tests"] == 3
    assert result["skipped"] == 2
    assert result["observed"] == 1


def test_real_swift_64_all_skipped_symbols():
    # Captured from an actual native Swift 6.4 fixture on 2026-09-24.
    # Apple emits private-use SF Symbols; disabled suites also emit child skips.
    output = '\U001007c8  Test run started.\n\U0010065f  Suite DisabledSuite skipped: "whole suite skip"\n\U0010065f  Test individualDisabled() skipped: "individual skip"\n\U0010065f  Test childDisabled() skipped: "whole suite skip"\n\U0010105b  Test run with 2 tests in 1 suite passed after 0.001 seconds.\n'
    result = load_script("verify-swift-test-output").verify(output, 0)
    assert result["passed"] is False
    assert result["tests"] == 2
    assert result["skipped"] == 2
    assert result["observed"] == 0
