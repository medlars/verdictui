"""This repository is public: tracked files must not name a real macOS home directory.

Evidence paths written as `/Users/<name>/...` leak the maintainer's account name
and machine layout. Write `~/...` instead. Test fixtures may use the generic
placeholder accounts below, which belong to no one.
"""

import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PLACEHOLDER_ACCOUNTS = {"dev", "runner", "someone", "test", "username", "x", "you"}
HOME_PATH = re.compile(r"/Users/([A-Za-z0-9_-][A-Za-z0-9._-]*)")


def _tracked_text_files() -> list[Path]:
    out = subprocess.run(
        ["git", "-C", str(ROOT), "grep", "-I", "-l", "-E", "/Users/[A-Za-z0-9_-]"],
        capture_output=True,
        text=True,
        check=False,
    )
    assert out.returncode in (0, 1), out.stderr
    return [ROOT / rel for rel in out.stdout.splitlines()]


def owner_home_paths(text: str) -> list[str]:
    return [m.group(0) for m in HOME_PATH.finditer(text) if m.group(1) not in PLACEHOLDER_ACCOUNTS]


def test_the_detector_flags_a_real_account_and_spares_placeholders():
    real = "/Users/" + "alice"  # split so this file does not trip its own scan
    assert owner_home_paths(f"see {real}/Temp/receipt.json") == [real]
    assert owner_home_paths("/Users/x/Projects and /Users/dev/.local and ~/Temp") == []


def test_no_tracked_file_names_a_real_home_directory():
    found = {
        str(path.relative_to(ROOT)): hits
        for path in _tracked_text_files()
        if (hits := owner_home_paths(path.read_text(encoding="utf-8", errors="replace")))
    }
    assert not found, f"write ~/... instead of a real home directory: {found}"
