#!/usr/bin/env python3.14
"""Detect a tracked file that was overwritten by a STALE editor buffer.

The failure this catches, observed four times during Wave 2 (CIS-638133AE): an
IDE holds a file open, an agent edits and commits it, and minutes later the
editor re-saves its own older buffer over the top. The working tree then differs
from HEAD with nothing in the git log to say why, and every later measurement —
a mutation restore, a PM grade — describes bytes nobody chose.

An ordinary uncommitted edit looks identical to `git status`. What separates
them is TIME: a file you just edited has an mtime NEWER than the last commit
touching it, while a stale buffer carries the timestamp of when the editor
loaded it, which is necessarily OLDER than the commit it just clobbered. That
comparison is the whole detector, and it is why this reports something
`git status` cannot.

Exit codes: 0 nothing suspicious, 1 at least one stale-looking overwrite.
A file that is merely dirty is NOT reported — that is normal work in progress,
and a check that flags it would be ignored within a day.
"""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

SUMMARY = "Detect tracked files overwritten by a stale editor buffer."

REPO = Path(__file__).resolve().parent.parent


def _git(args: list[str], cwd: Path) -> str:
    """Run git and return stdout, or "" when the command fails.

    A failing git call means the question cannot be answered for that path, and
    the caller treats an unanswerable path as not-suspicious rather than
    guessing — a false accusation here would send someone hunting a phantom.
    """
    result = subprocess.run(  # noqa: S603 — fixed argv, no shell
        ["git", *args],
        cwd=cwd,
        capture_output=True,
        text=True,
        timeout=30,
        check=False,
    )
    return result.stdout if result.returncode == 0 else ""


def modified_tracked_files(repo: Path) -> list[str]:
    """Tracked files differing from HEAD, as repo-relative paths."""
    return [line for line in _git(["diff", "--name-only"], repo).splitlines() if line]


def last_commit_time(repo: Path, relative: str) -> int | None:
    """Unix timestamp of the last commit touching `relative`, or None."""
    raw = _git(["log", "-1", "--format=%ct", "--", relative], repo).strip()
    if not raw:
        return None
    try:
        return int(raw)
    except ValueError:
        return None


def stale_overwrites(repo: Path) -> list[tuple[str, int, int]]:
    """Modified files whose mtime PREDATES the commit that last touched them.

    Returns `(path, mtime, commit_time)` so the caller can show both numbers —
    a report that says "stale" without the two timestamps cannot be checked by
    the person reading it.
    """
    found: list[tuple[str, int, int]] = []
    for relative in modified_tracked_files(repo):
        committed = last_commit_time(repo, relative)
        if committed is None:
            continue
        path = repo / relative
        try:
            mtime = int(path.stat().st_mtime)
        except OSError:
            # Deleted or unreadable: a different problem, and not this one.
            continue
        if mtime < committed:
            found.append((relative, mtime, committed))
    return found


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=SUMMARY)
    parser.add_argument(
        "--repo",
        default=str(REPO),
        help="repository root to inspect (default: this project)",
    )
    args = parser.parse_args(argv)

    found = stale_overwrites(Path(args.repo))
    if not found:
        print("PASS: no tracked file looks overwritten by a stale editor buffer")
        return 0

    print(f"{len(found)} file(s) modified with an mtime OLDER than the commit that touched them:")
    for relative, mtime, committed in found:
        print(f"  {relative}: mtime {mtime} < last commit {committed}")
    print("")
    print("That is the signature of an editor re-saving a buffer it loaded before the commit.")
    print("Check `git diff` before trusting any measurement of this tree; if the diff is")
    print("content you did not write, `git checkout -- <path>` restores the committed bytes.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
