"""Tests for scripts/floor-check.py's `_check_todo_tracking`.

The check is load-bearing for every floor run: a project with neither a
TODO.md nor a Central TODO Store record should FAIL the floor, and the only
way to see that branch is to drive the function against fakes. It runs at
import time against the real repo, so the tests drive the function through
monkeypatched globals.
"""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path
from typing import Any

import pytest  # noqa: F401 -- kept so the import-census guard sees the fixture type

_FC_PATH = Path(__file__).resolve().parents[1] / "scripts" / "floor-check.py"
_spec = importlib.util.spec_from_file_location("floor_check", _FC_PATH)
assert _spec is not None and _spec.loader is not None, "floor-check.py not found"
fc = importlib.util.module_from_spec(_spec)
try:
    _spec.loader.exec_module(fc)
except SystemExit:
    # floor-check.py ends with sys.exit(main()); the exit status of that call
    # is the script's CLI contract and is not what these tests exercise.
    pass


class _Bridge:
    @staticmethod
    def todo_tracking_ok(root: Any) -> tuple[bool, str]:
        return False, "no CTS record"


class TestCheckTodoTracking:
    def test_a_project_with_todo_md_passes_without_consulting_cts(
        self, monkeypatch: Any, tmp_path: Path
    ) -> None:
        monkeypatch.setattr(fc, "ROOT", tmp_path)
        (tmp_path / "TODO.md").write_text("- [ ] x\n")
        before = len(fc.GAPS)
        fc._check_todo_tracking()
        assert len(fc.GAPS) == before

    def test_no_todo_md_and_no_cts_bridge_fails_the_floor(
        self, monkeypatch: Any, tmp_path: Path
    ) -> None:
        monkeypatch.setattr(fc, "ROOT", tmp_path)
        monkeypatch.setitem(sys.modules, "cts_bridge", None)
        before = len(fc.GAPS)
        fc._check_todo_tracking()
        assert len(fc.GAPS) == before + 1
        assert fc.GAPS[-1]["item"] == "TODO.md"

    def test_cts_bridge_saying_not_ok_fails_the_floor(
        self, monkeypatch: Any, tmp_path: Path
    ) -> None:
        monkeypatch.setattr(fc, "ROOT", tmp_path)
        monkeypatch.setitem(sys.modules, "cts_bridge", _Bridge())
        before = len(fc.GAPS)
        fc._check_todo_tracking()
        assert len(fc.GAPS) == before + 1
        assert fc.GAPS[-1]["status"] == "missing (no CTS record)"
