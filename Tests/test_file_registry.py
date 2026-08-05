"""Keeps `docs/FILE_REGISTRY.md` honest about what is in the tree.

The registry calls itself the single source of truth for source files, but
nothing measured that claim: `floor-check.py` only asserts the file exists. The
result is the gap you would predict. Three source files were added during Waves
1-2 without a row, and each was found by hand, one at a time, during a later
audit — `Tests/test_mutation_check.py`, `Tests/test_claude_md_ssot.py`, and
`scripts/mutation-check.py` itself, a peer of two scripts that were listed.

A registry that is quietly incomplete is worse than no registry, because the
next session reads it and believes it. So the invariant is enforced in both
directions: every source file has a row, and every row still names something
real.
"""

import subprocess
from pathlib import Path

import pytest

pytestmark = pytest.mark.quick

_PROJECT_ROOT = Path(__file__).resolve().parents[1]
_REGISTRY = _PROJECT_ROOT / "docs" / "FILE_REGISTRY.md"

_ACTIVE_HEADING = "## Source Files"
_ARCHIVED_HEADING = "## Archived / Removed"

# The registry's scope is code, not the scaffold's prose: `README.md` and
# `docs/roadmap.md` have no rows and want none. Authored docs that *do* have rows
# are still checked by the reverse direction, which asserts every row resolves.
_SOURCE_SUFFIXES = frozenset({".swift", ".py", ".sh", ".json", ".toml"})


def _text() -> str:
    return _REGISTRY.read_text(encoding="utf-8")


def _rows(heading: str) -> list[list[str]]:
    """Body rows under one heading, each split into stripped cells.

    Cells are stripped because the repo's markdown formatter pads them to align
    the pipes, so column content is not at a fixed offset.
    """
    lines = _text().splitlines()
    if heading not in lines:
        pytest.fail(f"FILE_REGISTRY.md has no '{heading}' section — did it get renamed?")
    rows: list[list[str]] = []
    for line in lines[lines.index(heading) + 1 :]:
        if line.startswith("|"):
            if set(line) <= set("| -:"):
                continue
            rows.append([cell.strip() for cell in line.strip().strip("|").split("|")])
        elif rows:
            break
    return rows[1:]


def _registered(heading: str, *, status: str | None = None) -> set[str]:
    """The file paths named in a section, optionally filtered by status cell."""
    paths = set()
    for row in _rows(heading):
        if status is not None and row[2] != status:
            continue
        paths.add(row[0].strip("`").rstrip("/"))
    return paths


def _authored_source_files() -> set[str]:
    """Every tracked source file, as repo-relative posix paths.

    Asking git rather than walking a hardcoded list of directories is what makes
    this guard hold as the tree grows: a source file in a directory nobody
    thought of is still tracked, so it is still covered. It also excludes build
    products and generated artifacts for free — `pm-baselines.json` sits in the
    root, is never committed, and would otherwise read as an unregistered file.
    Matches `Agents/tests/test_file_registry_parity.py`, the fleet's prior art.
    """
    listed = subprocess.run(
        ["git", "ls-files"],
        cwd=_PROJECT_ROOT,
        capture_output=True,
        text=True,
        check=True,
    ).stdout
    return {line for line in listed.splitlines() if Path(line).suffix in _SOURCE_SUFFIXES}


class TestFileRegistry:
    """Grouped in a class so `scripts/mutation-check.py` can name these as
    `file::Class::test` node ids, which its catalog guard requires."""

    def test_the_registry_parses_into_the_shape_the_other_tests_assume(self) -> None:
        """A parser that matched nothing would make every other test here pass empty."""
        active = _rows(_ACTIVE_HEADING)
        archived = _rows(_ARCHIVED_HEADING)
        assert len(active) >= 50, f"parsed only {len(active)} active rows — table shape changed"
        assert archived, "parsed no archived rows — table shape changed"
        for row in active:
            assert len(row) == 4, f"unexpected active row shape: {row}"
        for row in archived:
            assert len(row) == 3, f"unexpected archived row shape: {row}"

    def test_the_scan_finds_the_source_tree(self) -> None:
        """Guards the guard: an empty scan would make the completeness test vacuous."""
        found = _authored_source_files()
        assert len(found) >= 50, f"scanned only {len(found)} source files — check the scan"

    def test_every_authored_source_file_has_an_active_row(self) -> None:
        missing = sorted(_authored_source_files() - _registered(_ACTIVE_HEADING))
        assert not missing, (
            f"source files with no FILE_REGISTRY row (add one, or archive the file): {missing}"
        )

    def test_every_active_row_points_at_a_path_that_exists(self) -> None:
        """The other direction: a row left behind by a rename sends the next
        session to a file that is not there."""
        for location in sorted(_registered(_ACTIVE_HEADING, status="Active")):
            resolved = (_PROJECT_ROOT / location).resolve()
            # An absolute path or a `../` resolves outside the checkout, where
            # it may well exist — letting a wrong row satisfy the check.
            assert resolved.is_relative_to(_PROJECT_ROOT), (
                f"registry row points outside the repo: {location}"
            )
            assert resolved.exists(), f"registry row points at a missing path: {location}"

    def test_no_archived_row_names_a_file_that_came_back(self) -> None:
        """A resurrected file listed only under Archived reads as deleted."""
        resurrected = sorted(
            location
            for location in _registered(_ARCHIVED_HEADING)
            if (_PROJECT_ROOT / location).exists()
        )
        assert not resurrected, (
            f"archived rows name files that exist again — move them back to Source Files: "
            f"{resurrected}"
        )

    def test_the_scan_reaches_past_the_directories_source_happens_to_live_in_today(
        self,
    ) -> None:
        """A scan of a fixed directory list shrinks in silence: source added
        somewhere new is simply not looked at, and the guard still passes."""
        found = _authored_source_files()
        # Both sit outside Sources/Tests/scripts/contracts and had to be named
        # one by one while this walked directories.
        assert {"Package.swift", "pyproject.toml"} <= found, (
            f"the scan lost the root manifests: {sorted(found)[:5]}"
        )
        # The other failure mode: a walk pulls in build output, which would
        # demand registry rows for thousands of generated files.
        assert not [p for p in found if p.startswith(".build/")], "the scan reached into .build/"
