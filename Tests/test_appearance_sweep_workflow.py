"""Behavioural tests for the `appearance` job in `.github/workflows/appearance-sweep.yml`.

The job only runs on a manual dispatch on a hosted macOS runner, so nothing
exercises its shell locally. These tests pull each step's real `run:` body out of
the parsed YAML and run it under `bash -e` (GitHub's default shell) against stub
`swift`, `osascript` and `python3.14` commands on PATH. The product-sweep steps
run the REAL `scripts/appearance-sweep.py` against a stub verdictui binary; the
measurement steps, whose script sleeps through two app launches, are judged on
how the step treats each exit code the script can return.

Every step is shown both passing and failing, so a check that cannot fail would
show up as a test that cannot pass.
"""

from __future__ import annotations

import json
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any

import pytest

yaml = pytest.importorskip("yaml")

REPO = Path(__file__).resolve().parents[1]
WORKFLOW = REPO / ".github" / "workflows" / "appearance-sweep.yml"
JOB = "appearance"
APP = "/System/Applications/Dictionary.app"
BASH = shutil.which("bash") or "/bin/bash"
ON_KEYS = (True, "on")  # YAML 1.1 parses a bare `on:` as boolean True

_STUB = """#!/bin/bash
printf '%s\\n' "$(basename "$0") $*" >> "$STEP_CALLS"
case "$(basename "$0")" in
  swift)
    case "$*" in
      *--show-bin-path*) echo /fake/.build/debug ;;
      *) exit "${STUB_SWIFT_EXIT:-0}" ;;
    esac ;;
  osascript)
    case "$*" in
      *"get dark mode"*) echo "${STUB_DARK:-false}" ;;
    esac ;;
  python3.14)
    [ -n "$STUB_PY_EXIT" ] && exit "$STUB_PY_EXIT"
    exec "$REAL_PYTHON" "$@" ;;
  verdictui)
    printf '{"app":"%s","cells":[{"colorScheme":"dark","status":"%s"}]}\\n' \\
      "$4" "$STUB_STATUS" ;;
esac
exit 0
"""


def _load() -> dict[str, Any]:
    doc = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
    assert isinstance(doc, dict), f"{WORKFLOW.name} did not parse to a mapping"
    return doc


def _job() -> dict[str, Any]:
    jobs = _load()["jobs"]
    assert JOB in jobs, f"job {JOB!r} is gone; jobs={list(jobs)}"
    return jobs[JOB]


def _step_names() -> list[str]:
    return [str(step.get("name", "")) for step in _job()["steps"]]


def _step_run(name_part: str) -> str:
    matches = [
        step["run"]
        for step in _job()["steps"]
        if name_part.lower() in str(step.get("name", "")).lower() and "run" in step
    ]
    assert len(matches) == 1, f"{JOB} has {len(matches)} steps named like {name_part!r}"
    assert "${{" not in matches[0], "a GitHub expression would run here as a literal"
    return matches[0]


class StepResult:
    def __init__(
        self, proc: subprocess.CompletedProcess[str], tmp: Path, env: dict[str, str]
    ) -> None:
        self.env = env
        self.returncode = proc.returncode
        self.output = proc.stdout + proc.stderr
        self.calls = (tmp / "calls").read_text().splitlines()
        self.github_env = (tmp / "github_env").read_text()


@pytest.fixture
def run_step(tmp_path: Path):
    bindir = tmp_path / "bin"
    bindir.mkdir()
    for name in ("swift", "osascript", "python3.14", "verdictui"):
        (bindir / name).write_text(_STUB)
        (bindir / name).chmod(0o755)
    (tmp_path / "calls").write_text("")
    (tmp_path / "github_env").write_text("")

    def run(name_part: str, **env: str) -> StepResult:
        script = tmp_path / "step.sh"
        script.write_text(_step_run(name_part))
        step_env = {
            "PATH": f"{bindir}:/usr/bin:/bin",
            "HOME": str(tmp_path),
            "STEP_CALLS": str(tmp_path / "calls"),
            "GITHUB_ENV": str(tmp_path / "github_env"),
            "REAL_PYTHON": sys.executable,
            "VERDICTUI_BIN": str(bindir / "verdictui"),
            **env,
        }
        proc = subprocess.run(
            [BASH, "-e", str(script)],
            cwd=REPO,
            env=step_env,
            capture_output=True,
            text=True,
            check=False,
            timeout=120,
        )
        return StepResult(proc, tmp_path, step_env)

    return run


def test_appearance_job_runs_only_on_manual_dispatch_with_read_only_contents():
    doc = _load()
    trigger = next(doc[key] for key in ON_KEYS if key in doc)
    assert set(trigger) == {"workflow_dispatch"}, "a GUI-session sweep must never gate a merge"
    assert doc["permissions"] == {"contents": "read"}
    job = _job()
    assert job["runs-on"] == "xcode-27", "the sweep needs a macOS runner with a GUI session"
    assert 0 < job["timeout-minutes"] <= 30


def test_appearance_job_measures_the_light_host_before_switching_it_to_dark():
    names = [n.lower() for n in _step_names()]

    def index(part: str) -> int:
        found = [i for i, n in enumerate(names) if part in n]
        assert len(found) == 1, f"expected one step like {part!r}, got {found}"
        return found[0]

    switch = index("switch the ephemeral runner")
    assert index("build verdictui") < switch
    assert index("light host - the product sweep") < switch
    assert index("light host - a dark launch") < switch
    assert switch < index("dark host - the product sweep")
    assert switch < index("dark host - forced-aqua")


def test_build_step_exports_the_built_binary_path(run_step):
    result = run_step("Build verdictui")
    assert result.returncode == 0, result.output
    assert result.github_env == "VERDICTUI_BIN=/fake/.build/debug/verdictui\n"
    assert "swift build --build-system native --product verdictui" in result.calls


def test_build_step_fails_when_the_build_fails(run_step):
    result = run_step("Build verdictui", STUB_SWIFT_EXIT="1")
    assert result.returncode != 0
    assert result.github_env == ""


@pytest.mark.parametrize(
    ("status", "passes"), [("unavailable", True), ("pass", False), ("fail", False)]
)
def test_light_host_product_sweep_requires_the_dark_cell_unavailable(run_step, status, passes):
    result = run_step("Light host - the product sweep", STUB_STATUS=status)
    assert (result.returncode == 0) is passes, result.output
    assert f"verdictui sweep --app {APP} --color-schemes dark" in result.calls
    assert "expected unavailable" in result.output or passes


@pytest.mark.parametrize(
    ("status", "passes"), [("pass", True), ("fail", True), ("unavailable", False)]
)
def test_dark_host_product_sweep_requires_the_dark_cell_realised(run_step, status, passes):
    result = run_step("Dark host - the product sweep", STUB_STATUS=status, STUB_DARK="true")
    assert (result.returncode == 0) is passes, result.output
    assert f"verdictui sweep --app {APP} --color-schemes dark" in result.calls


@pytest.mark.parametrize(("code", "passes"), [("2", True), ("0", False), ("1", False)])
def test_light_host_measurement_passes_only_when_unavailable(run_step, code, passes):
    result = run_step("Light host - a dark launch", STUB_PY_EXIT=code)
    assert (result.returncode == 0) is passes, result.output
    assert f"measurement exit {code} (expected 2)" in result.output
    binary = result.env["VERDICTUI_BIN"]
    assert result.calls == [f"python3.14 scripts/appearance-sweep.py --binary {binary} --app {APP}"]


@pytest.mark.parametrize(("code", "passes"), [("0", True), ("1", False), ("2", False)])
def test_dark_host_measurement_passes_only_when_dark_measures_darker(run_step, code, passes):
    result = run_step("Dark host - forced-Aqua", STUB_PY_EXIT=code)
    assert (result.returncode == 0) is passes, result.output
    assert "--product-sweep" not in " ".join(result.calls)


@pytest.mark.parametrize(("observed", "passes"), [("true", True), ("false", False)])
def test_switch_step_fails_unless_the_runner_reads_back_dark(run_step, observed, passes):
    result = run_step("Switch the ephemeral runner", STUB_DARK=observed)
    assert (result.returncode == 0) is passes, result.output
    assert any("set dark mode to true" in c for c in result.calls)


def test_stub_sweep_report_is_the_shape_the_script_parses(run_step, tmp_path):
    """Guards the harness: a stub the script cannot parse would make every sweep 'unavailable'."""
    proc = subprocess.run(
        [str(tmp_path / "bin" / "verdictui"), "sweep", "--app", APP, "--color-schemes", "dark"],
        env={"STEP_CALLS": str(tmp_path / "calls"), "STUB_STATUS": "pass", "PATH": "/usr/bin:/bin"},
        capture_output=True,
        text=True,
        check=True,
    )
    assert json.loads(proc.stdout)["cells"] == [{"colorScheme": "dark", "status": "pass"}]
