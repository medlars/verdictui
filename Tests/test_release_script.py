"""`scripts/release.sh` must refuse every unsafe release BEFORE its first mutation.

CIS-730A9D76 (REL-006). The script tags, publishes a release and edits a PUBLIC tap,
none of which can be quietly undone, so each guard is asserted against a throwaway
repository with a local bare origin. Nothing here reaches GitHub.
"""

from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

import pytest

pytestmark = pytest.mark.quick

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts" / "release.sh"
VERSION_FILE = "Sources/VerdictUICLICore/ReleaseVersion.swift"


def _git(cwd: Path, *args: str) -> str:
    return subprocess.run(
        ["git", *args], cwd=cwd, check=True, capture_output=True, text=True, timeout=60
    ).stdout.strip()


@pytest.fixture
def repo(tmp_path: Path) -> Path:
    origin = tmp_path / "origin.git"
    work = tmp_path / "work"
    _git(tmp_path, "init", "-q", "--bare", "-b", "main", str(origin))
    _git(tmp_path, "init", "-q", "-b", "main", str(work))
    _git(work, "config", "user.email", "t@example.com")
    _git(work, "config", "user.name", "t")
    (work / "scripts").mkdir()
    shutil.copy(SCRIPT, work / "scripts" / "release.sh")
    (work / VERSION_FILE).parent.mkdir(parents=True)
    (work / VERSION_FILE).write_text('    public static let current = "1.2.3"\n')
    _git(work, "add", "-A")
    _git(work, "commit", "-q", "-m", "seed")
    _git(work, "remote", "add", "origin", str(origin))
    _git(work, "push", "-q", "origin", "main")
    return work


def _run(repo: Path, *args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["bash", str(repo / "scripts" / "release.sh"), *args],
        cwd=repo,
        capture_output=True,
        text=True,
        timeout=60,
    )


def test_clean_matching_dry_run_passes_and_creates_no_tag(repo: Path) -> None:
    proc = _run(repo, "1.2.3", "--dry-run")
    assert proc.returncode == 0, proc.stderr
    assert "no tag, release or formula change made" in proc.stdout
    assert _git(repo, "tag", "--list") == ""


def test_the_burned_version_is_refused(repo: Path) -> None:
    proc = _run(repo, "1.0.0", "--dry-run")
    assert proc.returncode == 1
    assert "v1.0.0 is burned" in proc.stderr


def test_a_malformed_version_is_refused(repo: Path) -> None:
    proc = _run(repo, "v1.2", "--dry-run")
    assert proc.returncode == 1
    assert "usage" in proc.stderr


def test_a_tag_that_disagrees_with_the_source_version_is_refused(repo: Path) -> None:
    proc = _run(repo, "1.2.4", "--dry-run")
    assert proc.returncode == 1
    assert "ReleaseVersion.current is '1.2.3'" in proc.stderr


def test_a_dirty_tree_is_refused(repo: Path) -> None:
    (repo / "stray.txt").write_text("x")
    proc = _run(repo, "1.2.3", "--dry-run")
    assert proc.returncode == 1
    assert "working tree is dirty" in proc.stderr


def test_an_existing_tag_is_refused(repo: Path) -> None:
    _git(repo, "tag", "v1.2.3")
    proc = _run(repo, "1.2.3", "--dry-run")
    assert proc.returncode == 1
    assert "tag v1.2.3 already exists" in proc.stderr


def test_a_head_that_is_not_origin_main_is_refused(repo: Path) -> None:
    (repo / "extra.txt").write_text("x")
    _git(repo, "add", "-A")
    _git(repo, "commit", "-q", "-m", "unpushed")
    proc = _run(repo, "1.2.3", "--dry-run")
    assert proc.returncode == 1
    assert "HEAD is not origin/main" in proc.stderr
