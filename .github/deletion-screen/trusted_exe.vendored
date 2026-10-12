"""Resolve a program name from fixed system folders, never from $PATH.

Usage:
    from trusted_exe import trusted_exe

    subprocess.run([trusted_exe("git"), "status"], check=False)

A bare name in a subprocess argv runs whatever binary comes first on $PATH, so a
planted binary earlier on the path wins (bandit B607). shutil.which() searches the
same $PATH in the same order and is not a fix. This helper looks only in
TRUSTED_DIRS, plus the running interpreter's folder for python programs.

Order matters: the root-owned system folders come first. /opt/homebrew/bin is
writable by the owner's own account, so a program macOS ships (git, bash, osascript)
always resolves to the system copy and a fake planted in Homebrew cannot win.
Homebrew-only tools (gh, gcloud, node, python3.x) can only come from Homebrew; a
process running as the owner could replace those files directly whatever the lookup.
~/.local/bin is searched last, for programs whose installer puts them only there
(claude); it is owner-writable like Homebrew, so it never outranks a fixed folder.
Never fall back to $PATH: an nvm or CI tool-cache copy must be named by full path.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

__all__ = ["TRUSTED_DIRS", "TrustedExeNotFoundError", "trusted_exe"]

TRUSTED_DIRS: tuple[str, ...] = (
    "/usr/bin",
    "/bin",
    "/usr/sbin",
    "/sbin",
    "/opt/homebrew/bin",
    "/usr/local/bin",
)


class TrustedExeNotFoundError(FileNotFoundError):
    """The program is in none of the trusted folders."""


def _search_dirs(name: str) -> tuple[str, ...]:
    dirs = (*TRUSTED_DIRS, str(Path.home() / ".local" / "bin"))
    if name.startswith("python"):
        return (*dirs, str(Path(sys.executable).parent))
    return dirs


def trusted_exe(name: str) -> str:
    """Absolute path of executable `name` found only in the trusted folders."""
    if not name or "/" in name or "\0" in name or name in {".", ".."}:
        raise ValueError(f"trusted_exe needs a bare program name, got {name!r}")
    dirs = _search_dirs(name)
    for directory in dirs:
        candidate = os.path.join(directory, name)
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    raise TrustedExeNotFoundError(
        f"program {name!r} not found in trusted folders: {', '.join(dirs)}"
    )
