"""`scripts/land-tap-formula.sh` lands the tap formula through a PR, never a push to main.

DIR-045: the tap's main is PR-only. Real git with a local bare origin; `gh` is a
stub on PATH that simulates GitHub's PR states, so nothing here reaches GitHub.
"""

from __future__ import annotations

import os
import subprocess
from pathlib import Path

import pytest

pytestmark = pytest.mark.quick

SCRIPT = Path(__file__).resolve().parent.parent / "scripts" / "land-tap-formula.sh"

STUB_GH = r"""#!/bin/bash
set -euo pipefail
echo "$*" >> "$STUB_DIR/calls"
branch_file="$STUB_DIR/branch"
case "$1 $2" in
  "pr view")
    if [ "${3#https://}" = "$3" ]; then
      [ -f "$STUB_DIR/url" ] && [ "$(cat "$STUB_DIR/state")" = OPEN ] && { cat "$STUB_DIR/url"; exit 0; }
      echo "no pull requests found for branch \"$3\"" >&2; exit 1
    fi
    polls=$(( $(cat "$STUB_DIR/polls" 2>/dev/null || echo 0) + 1 )); echo "$polls" > "$STUB_DIR/polls"
    if [ "$STUB_MODE" = merge ] && [ "$(cat "$STUB_DIR/state")" = ARMED ] && [ "$polls" -ge 2 ]; then
      git --git-dir="$STUB_ORIGIN" update-ref refs/heads/main "refs/heads/$(cat "$branch_file")"
      git --git-dir="$STUB_ORIGIN" update-ref -d "refs/heads/$(cat "$branch_file")"
      echo MERGED > "$STUB_DIR/state"
    fi
    [ "$STUB_MODE" = close ] && echo CLOSED > "$STUB_DIR/state"
    s="$(cat "$STUB_DIR/state")"; [ "$s" = ARMED ] && s=OPEN; echo "$s" ;;
  "pr create")
    while [ $# -gt 0 ]; do [ "$1" = --head ] && echo "$2" > "$branch_file"; shift; done
    echo "https://example.invalid/pr/1" | tee "$STUB_DIR/url"; echo OPEN > "$STUB_DIR/state" ;;
  "pr merge")
    case "$*" in *--auto*) echo ARMED > "$STUB_DIR/state" ;; *) exit 1 ;; esac ;;
  *) echo "unexpected gh $*" >&2; exit 2 ;;
esac
"""


def _git(cwd: Path, *args: str) -> str:
    return subprocess.run(
        ["git", *args], cwd=cwd, check=True, capture_output=True, text=True, timeout=60
    ).stdout.strip()


@pytest.fixture
def tap(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> tuple[Path, Path, Path]:
    monkeypatch.setenv("GIT_CONFIG_GLOBAL", os.devnull)
    monkeypatch.setenv("GIT_CONFIG_NOSYSTEM", "1")
    origin = tmp_path / "tap.git"
    work = tmp_path / "tap"
    _git(tmp_path, "init", "-q", "--bare", "-b", "main", str(origin))
    _git(tmp_path, "init", "-q", "-b", "main", str(work))
    _git(work, "config", "user.email", "t@example.com")
    _git(work, "config", "user.name", "t")
    (work / "Formula").mkdir()
    (work / "Formula" / "verdictui.rb").write_text('url "v1.2.2"\n')
    _git(work, "add", "--", "Formula/verdictui.rb")
    _git(work, "commit", "-q", "-m", "seed")
    _git(work, "remote", "add", "origin", str(origin))
    _git(work, "push", "-q", "origin", "main")
    (work / "Formula" / "verdictui.rb").write_text('url "v1.2.3"\n')
    _git(work, "commit", "-q", "-am", "verdictui 1.2.3")
    stub = tmp_path / "stub"
    stub.mkdir()
    (stub / "gh").write_text(STUB_GH)
    (stub / "gh").chmod(0o755)
    monkeypatch.setenv("PATH", f"{stub}{os.pathsep}{os.environ['PATH']}")
    monkeypatch.setenv("STUB_DIR", str(stub))
    monkeypatch.setenv("STUB_ORIGIN", str(origin))
    monkeypatch.setenv("LAND_TAP_POLL", "0")
    return work, origin, stub


def _land(work: Path, mode: str, timeout: str = "30") -> subprocess.CompletedProcess[str]:
    env = {**os.environ, "STUB_MODE": mode, "LAND_TAP_TIMEOUT": timeout}
    return subprocess.run(
        ["bash", str(SCRIPT), str(work), "1.2.3"],
        capture_output=True,
        text=True,
        timeout=60,
        env=env,
    )


def test_formula_lands_through_an_auto_merge_pr(tap: tuple[Path, Path, Path]) -> None:
    work, origin, stub = tap
    before = _git(origin, "rev-parse", "main")
    proc = _land(work, "merge")
    assert proc.returncode == 0, proc.stderr
    assert proc.stdout.strip() == "https://example.invalid/pr/1"
    assert _git(origin, "show", "main:Formula/verdictui.rb") == 'url "v1.2.3"'
    assert _git(origin, "rev-parse", "main^") == before
    assert _git(origin, "branch", "--list", "release/*") == ""
    calls = (stub / "calls").read_text()
    assert "pr merge https://example.invalid/pr/1 --auto --squash --delete-branch" in calls


def test_an_open_pr_is_reused_not_duplicated(tap: tuple[Path, Path, Path]) -> None:
    work, _, stub = tap
    (stub / "url").write_text("https://example.invalid/pr/1\n")
    (stub / "state").write_text("OPEN\n")
    (stub / "branch").write_text("release/verdictui-1.2.3\n")
    proc = _land(work, "merge")
    assert proc.returncode == 0, proc.stderr
    assert "pr create" not in (stub / "calls").read_text()


def test_a_closed_pr_fails_the_release(tap: tuple[Path, Path, Path]) -> None:
    work, origin, _ = tap
    before = _git(origin, "rev-parse", "main")
    proc = _land(work, "close")
    assert proc.returncode == 1
    assert "closed without merging" in proc.stderr
    assert _git(origin, "rev-parse", "main") == before


def test_an_unmerged_pr_fails_at_the_deadline(tap: tuple[Path, Path, Path]) -> None:
    work, origin, _ = tap
    before = _git(origin, "rev-parse", "main")
    proc = _land(work, "never", timeout="0")
    assert proc.returncode == 1
    assert "not merged before the deadline" in proc.stderr
    assert _git(origin, "rev-parse", "main") == before
    assert _git(origin, "rev-parse", "release/verdictui-1.2.3") == _git(work, "rev-parse", "HEAD")


def test_the_script_never_pushes_main() -> None:
    text = SCRIPT.read_text()
    assert "HEAD:main" not in text
    assert "refs/heads/main" not in text
