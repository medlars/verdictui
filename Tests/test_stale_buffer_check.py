"""`scripts/stale-buffer-check.py` — the stale-editor-buffer detector.

Untested until 2026-08-20 (TODO.md testwatch P1). The script guards
`stage_stale_buffer`, which THIS session leaned on while judging whether a
contended tree could be trusted — so an unverified detector here silently
weakens every measurement taken downstream of it.

The subject is a TIME COMPARISON, not a diff: an ordinary uncommitted edit and
a stale overwrite look identical to `git status`, and only the mtime-vs-commit
ordering separates them. Both directions are therefore load-bearing, and they
fail differently. Missing a stale buffer lets a measurement describe bytes
nobody chose; flagging ordinary work-in-progress makes the check ignored within
a day, which is the worse outcome because it is silent.

Every test drives a REAL git repository rather than a mocked `_git`. A mock
would assert this module's beliefs about git's output format back at itself —
the shape lesson 339 names, where a suite built only on fixtures tests the
belief and passes.
"""

from __future__ import annotations

import importlib.util
import subprocess
import sys
from pathlib import Path

import pytest

_SCRIPT = Path(__file__).resolve().parent.parent / "scripts" / "stale-buffer-check.py"


def _load():
    spec = importlib.util.spec_from_file_location("stale_buffer_check", _SCRIPT)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules["stale_buffer_check"] = module
    spec.loader.exec_module(module)
    return module


_mod = _load()


def _git(repo: Path, *args: str) -> str:
    proc = subprocess.run(
        ["git", *args],
        cwd=repo,
        capture_output=True,
        text=True,
        check=True,
        env={
            "PATH": "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin",
            "GIT_AUTHOR_NAME": "t",
            "GIT_AUTHOR_EMAIL": "t@example.com",
            "GIT_COMMITTER_NAME": "t",
            "GIT_COMMITTER_EMAIL": "t@example.com",
            "HOME": str(repo),
        },
    )
    return proc.stdout


@pytest.fixture
def repo(tmp_path: Path) -> Path:
    """A real repository with one committed file."""
    _git(tmp_path, "init", "-q", "-b", "main")
    (tmp_path / "tracked.txt").write_text("committed content\n")
    _git(tmp_path, "add", "tracked.txt")
    _git(tmp_path, "commit", "-q", "-m", "initial")
    return tmp_path


class TestModifiedTrackedFiles:
    def test_a_clean_repo_reports_nothing(self, repo: Path) -> None:
        assert _mod.modified_tracked_files(repo) == []

    def test_a_modified_file_is_listed(self, repo: Path) -> None:
        (repo / "tracked.txt").write_text("edited\n")
        assert _mod.modified_tracked_files(repo) == ["tracked.txt"]

    def test_an_untracked_file_is_not_listed(self, repo: Path) -> None:
        """`git diff --name-only` covers TRACKED files only, and that is
        correct here: an untracked file has no commit to compare against, so it
        cannot exhibit the defect this detects."""
        (repo / "stray.txt").write_text("new\n")
        assert _mod.modified_tracked_files(repo) == []


class TestLastCommitTime:
    def test_a_committed_path_has_a_timestamp(self, repo: Path) -> None:
        assert isinstance(_mod.last_commit_time(repo, "tracked.txt"), int)

    def test_an_unknown_path_is_None_rather_than_zero(self, repo: Path) -> None:
        """None and 0 are different answers. 0 would compare as older than every
        mtime and flag the file as stale — a false accusation from a path git
        simply does not know."""
        assert _mod.last_commit_time(repo, "never-existed.txt") is None


class TestStaleOverwrites:
    def test_a_clean_repo_finds_nothing(self, repo: Path) -> None:
        assert _mod.stale_overwrites(repo) == []

    def test_a_stale_buffer_is_caught_with_both_timestamps(self, repo: Path) -> None:
        """The defect this exists for: an editor re-saves a buffer it loaded
        BEFORE the commit, so the file differs from HEAD with an mtime that
        predates it."""
        target = repo / "tracked.txt"
        target.write_text("older buffer content\n")
        committed = _mod.last_commit_time(repo, "tracked.txt")
        assert committed is not None
        import os

        stale = committed - 3600
        os.utime(target, (stale, stale))

        found = _mod.stale_overwrites(repo)
        assert len(found) == 1, found
        path, mtime, commit_time = found[0]
        assert path == "tracked.txt"
        assert mtime < commit_time, "the report must carry BOTH numbers so a reader can check it"

    def test_ordinary_work_in_progress_is_NOT_reported(self, repo: Path) -> None:
        """The negative control, and the more important direction. A freshly
        edited file is dirty with a NEWER mtime — normal work. Flagging it
        would make the detector noise, and a noisy detector is ignored, which
        fails silently (`no.md` #53)."""
        (repo / "tracked.txt").write_text("edited just now\n")
        assert _mod.stale_overwrites(repo) == []

    def test_a_deleted_file_is_skipped_rather_than_crashing(self, repo: Path) -> None:
        """`stat` raises for a deleted path. That is a different problem, and a
        detector that crashes on it reports nothing about the files it COULD
        have judged."""
        (repo / "tracked.txt").unlink()
        assert _mod.stale_overwrites(repo) == []


class TestMain:
    def test_a_clean_tree_exits_zero_and_says_so(self, repo: Path, capsys) -> None:
        assert _mod.main(["--repo", str(repo)]) == 0
        assert "PASS" in capsys.readouterr().out

    def test_a_stale_overwrite_exits_one_and_names_the_file(self, repo: Path, capsys) -> None:
        import os

        target = repo / "tracked.txt"
        target.write_text("older\n")
        committed = _mod.last_commit_time(repo, "tracked.txt")
        assert committed is not None
        os.utime(target, (committed - 3600, committed - 3600))

        assert _mod.main(["--repo", str(repo)]) == 1
        out = capsys.readouterr().out
        assert "tracked.txt" in out
        assert "git checkout" in out, "must tell the reader how to recover the committed bytes"


class TestGitHelperFailsClosedTowardSilence:
    def test_a_failing_git_call_yields_empty_not_a_crash(self, tmp_path: Path) -> None:
        """A path where git cannot answer must read as 'no information', never
        as a finding: `_git` returns "" on a non-zero exit, so an unanswerable
        question produces no accusation (the script's own docstring rule)."""
        assert _mod._git(["log", "-1"], tmp_path) == ""
