"""The CI pm_base install must survive a transient GitHub SSH denial (CIS-72CBC8B5).

On 2026-09-24 GitHub's SSH frontend refused valid deploy keys for minutes;
'Lint PM scripts' went red on a single-shot `pip install git+ssh://...pm-base`.
The step is executed here against a fake pip, so the test observes behaviour,
not wording.
"""

from __future__ import annotations

import os
import subprocess
import textwrap
from pathlib import Path

from pm_test_support import _PROJECT_ROOT

WORKFLOW = _PROJECT_ROOT / ".github" / "workflows" / "ci.yml"


def _install_script() -> str:
    lines = WORKFLOW.read_text().splitlines()
    start = next(i for i, line in enumerate(lines) if line.strip() == "- name: Install pm_base")
    run_line = lines[start + 1]
    assert run_line.strip().startswith("run:"), run_line
    if run_line.strip() != "run: |":
        return run_line.split("run:", 1)[1].strip()
    indent = len(lines[start + 2]) - len(lines[start + 2].lstrip())
    body: list[str] = []
    for line in lines[start + 2 :]:
        if line.strip() and len(line) - len(line.lstrip()) < indent:
            break
        body.append(line)
    return textwrap.dedent("\n".join(body))


def _run(script: str, failures: int, tmp: Path) -> tuple[int, int]:
    counter = tmp / "calls"
    counter.write_text("0")
    (tmp / "pip").write_text(
        f'#!/bin/bash\nn=$(cat {counter}); echo $((n+1)) > {counter}\n[ "$n" -ge {failures} ]\n'
    )
    (tmp / "sleep").write_text("#!/bin/bash\nexit 0\n")
    for name in ("pip", "sleep"):
        (tmp / name).chmod(0o755)
    env = {**os.environ, "PATH": f"{tmp}:{os.environ['PATH']}"}
    result = subprocess.run(
        ["bash", "-e", "-c", script], env=env, capture_output=True, text=True, check=False
    )
    return result.returncode, int(counter.read_text())


def test_transient_denial_is_retried(tmp_path: Path) -> None:
    assert _run(_install_script(), 2, tmp_path)[0] == 0, "two SSH denials then success must pass"


def test_healthy_install_runs_once(tmp_path: Path) -> None:
    assert _run(_install_script(), 0, tmp_path) == (0, 1)


def test_persistent_denial_still_fails_and_is_bounded(tmp_path: Path) -> None:
    code, calls = _run(_install_script(), 99, tmp_path)
    assert code != 0, "a persistent denial was masked as success"
    assert calls <= 5, f"unbounded retry: {calls} attempts"
