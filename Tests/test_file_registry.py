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

from pathlib import Path

import pytest

pytestmark = pytest.mark.quick

_PROJECT_ROOT = Path(__file__).resolve().parents[1]
_REGISTRY = _PROJECT_ROOT / "docs" / "FILE_REGISTRY.md"

_ACTIVE_HEADING = "## Source Files"
_ARCHIVED_HEADING = "## Archived / Removed"

# Where authored source lives. `test_no_source_directory_is_invisible_to_the_scan`
# exists so that adding a fifth directory cannot quietly shrink this guard's reach.
_SOURCE_DIRS = ("Sources", "Tests", "scripts", "contracts")
_ROOT_MANIFESTS = ("Package.swift", "pyproject.toml")
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
    """Every source file a human wrote, as repo-relative posix paths.

    Caches and build products are skipped by ignoring any dot-prefixed path
    component, which also keeps `.build` out without naming it.
    """
    found = set()
    for directory in _SOURCE_DIRS:
        for path in (_PROJECT_ROOT / directory).rglob("*"):
            relative = path.relative_to(_PROJECT_ROOT)
            if any(part.startswith((".", "__")) for part in relative.parts):
                continue
            if path.is_file() and path.suffix in _SOURCE_SUFFIXES:
                found.add(relative.as_posix())
    return found | {name for name in _ROOT_MANIFESTS if (_PROJECT_ROOT / name).is_file()}


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

    def test_no_source_directory_is_invisible_to_the_scan(self) -> None:
        """`_SOURCE_DIRS` is a hardcoded list, so a new top-level source directory
        would be skipped in silence — the scan would still pass, having looked
        at less of the tree than it did yesterday."""
        for entry in _PROJECT_ROOT.iterdir():
            if not entry.is_dir() or entry.name.startswith("."):
                continue
            if entry.name in _SOURCE_DIRS:
                continue
            code = [
                p.relative_to(_PROJECT_ROOT).as_posix()
                for p in entry.rglob("*")
                if p.suffix in {".swift", ".py"} and not p.name.startswith(".")
            ]
            assert not code, (
                f"'{entry.name}/' holds source the registry scan never looks at "
                f"({code[:3]}) — add it to _SOURCE_DIRS"
            )
