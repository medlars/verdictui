"""Packaging inputs declared by scripts/build-workbench.sh must exist in the tree."""

from __future__ import annotations

from pathlib import Path

import pytest

pytestmark = pytest.mark.quick

_ROOT = Path(__file__).resolve().parents[1]


def test_workbench_packaging_icon_is_tracked() -> None:
    icon = _ROOT / "assets" / "workbench-icon.icns"
    assert icon.is_file(), (
        "build-workbench.sh copies assets/workbench-icon.icns; "
        "regenerate with the recipe in docs/workbench-design.md"
    )
    assert icon.read_bytes()[:4] == b"icns"
