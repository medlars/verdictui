"""Tests for `scripts/stale-buffer-check.py`.

The detector's whole value is DISCRIMINATION, so most of these are controls. A
check that fires on any dirty file would be true whenever `git status` is, add
nothing, and be switched off within a day (CIS-638133AE, CTS-AB38005C).
"""

import importlib.util
import os
import subprocess
from pathlib import Path

import pytest
from pm_test_support import _PROJECT_ROOT

pytestmark = pytest.mark.quick


def _load():
    """Load the hyphenated script as a module."""
    path = str(_PROJECT_ROOT / "scripts" / "stale-buffer-check.py")
    spec = importlib.util.spec_from_file_location("verdictui_stale_buffer", path)
    module = importlib.util.module_from_spec(spec)  # type: ignore[arg-type]
    spec.loader.exec_module(module)  # type: ignore[union-attr]
    return module


def _git(repo: Path, *args: str) -> None:
    subprocess.run(  # noqa: S603 — fixed argv, no shell
        ["git", *args], cwd=repo, check=True, capture_output=True, text=True
    )


@pytest.fixture
def repo(tmp_path: Path) -> Path:
    """A real git repo with one committed file.

    Real rather than mocked: the detector's subject is the relationship between
    a file's mtime and `git log`, and a mock of git would be a second
    implementation of the thing under test (AP-005).
    """
    _git(tmp_path, "init", "-q", ".")
    _git(tmp_path, "config", "user.email", "t@example.com")
    _git(tmp_path, "config", "user.name", "t")
    (tmp_path / "f.swift").write_text("committed content\n")
    _git(tmp_path, "add", "-A")
    _git(tmp_path, "commit", "-qm", "initial")
    return tmp_path


class TestStaleBufferDetection:
    def test_a_file_written_with_an_older_mtime_is_reported(self, repo: Path) -> None:
        """The signature: content differs from HEAD AND the mtime predates the
        commit, which is what an editor re-saving a pre-commit buffer leaves."""
        target = repo / "f.swift"
        target.write_text("stale buffer content\n")
        # 2020 — necessarily older than the commit made moments ago.
        os.utime(target, (1_577_854_800, 1_577_854_800))

        mod = _load()
        found = mod.stale_overwrites(repo)

        assert len(found) == 1
        relative, mtime, committed = found[0]
        assert relative == "f.swift"
        assert mtime < committed

    def test_an_ordinary_fresh_edit_is_not_reported(self, repo: Path) -> None:
        """THE control, and the reason the detector keys on time at all.

        Without it, "reports a stale buffer" is satisfied by a check that
        reports every modified file — identical to `git status`, useless, and
        noisy enough that the real signal would be ignored.
        """
        (repo / "f.swift").write_text("a genuine new edit\n")

        mod = _load()

        assert mod.stale_overwrites(repo) == []

    def test_a_clean_tree_is_not_reported(self, repo: Path) -> None:
        mod = _load()

        assert mod.stale_overwrites(repo) == []

    def test_an_untracked_file_is_not_reported(self, repo: Path) -> None:
        """`git diff` lists tracked changes only, and an untracked file has no
        commit to be older than — there is no claim to make about it."""
        new = repo / "scratch.swift"
        new.write_text("brand new\n")
        os.utime(new, (1_577_854_800, 1_577_854_800))

        mod = _load()

        assert mod.stale_overwrites(repo) == []

    def test_main_exits_one_and_names_the_file(self, repo: Path, capsys) -> None:
        target = repo / "f.swift"
        target.write_text("stale buffer content\n")
        os.utime(target, (1_577_854_800, 1_577_854_800))

        mod = _load()
        code = mod.main(["--repo", str(repo)])

        assert code == 1
        out = capsys.readouterr().out
        assert "f.swift" in out
        # Both timestamps must appear: a report saying "stale" without them
        # cannot be checked by the person reading it.
        assert "mtime" in out and "last commit" in out

    def test_main_exits_zero_on_a_clean_tree(self, repo: Path, capsys) -> None:
        mod = _load()

        assert mod.main(["--repo", str(repo)]) == 0
        assert "PASS" in capsys.readouterr().out
