"""Keeps the pointers in `CLAUDE.md` true.

The Single-Source-of-Truth table exists to stop a second implementation being
written, so a stale row does the exact opposite of its job: it sends the next
session to a file that no longer holds the thing, and the duplicate gets written
anyway. That is not hypothetical here. Until Wave 2 was already shipped the table
still promised the Layout probe as future work, and it named `VerdictFramesKey`,
a symbol that survives only in a historical comment.

`docs/kernel.md` is pinned to the code by `KernelDocumentationTests` for the same
reason. This is that guard for the one page every session is told to read first.
"""

import re
from pathlib import Path

import pytest

pytestmark = pytest.mark.quick

_PROJECT_ROOT = Path(__file__).resolve().parents[1]
_CLAUDE_MD = _PROJECT_ROOT / "CLAUDE.md"
_SSOT_HEADING = "## Canonical Implementations (SSoT)"


def _text() -> str:
    return _CLAUDE_MD.read_text(encoding="utf-8")


def _ssot_rows() -> list[list[str]]:
    """Body rows of the SSoT table, each split into cells.

    Scoped to the one table on purpose: `CLAUDE.md` has several, and a parser that
    silently reads the wrong one proves nothing about the right one.
    """
    lines = _text().splitlines()
    if _SSOT_HEADING not in lines:
        pytest.fail(f"CLAUDE.md has no '{_SSOT_HEADING}' section — did it get renamed?")
    rows: list[list[str]] = []
    for line in lines[lines.index(_SSOT_HEADING) + 1 :]:
        if line.startswith("|"):
            if "---" in line:
                continue
            rows.append([cell.strip() for cell in line.strip().strip("|").split("|")])
        elif rows:
            break
    return rows[1:]


def _inline_code(text: str) -> list[str]:
    """Single-backtick spans, with fenced blocks removed first.

    Pairing backticks naively across the whole page straddles the ``` fences and
    yields multi-line spans instead of inline code, which silently finds nothing.
    """
    without_fences = re.sub(r"```.*?```", "", text, flags=re.DOTALL)
    return re.findall(r"`([^`\n]+)`", without_fences)


def _symbols(cell: str) -> list[str]:
    """Identifier components a canonical-implementation cell names.

    ``.verdictProbe(id:)`` becomes ``verdictProbe`` and ``TreeAssembly.assemble``
    becomes both halves, because the source declares the name without the leading
    dot and wraps its argument list across lines.
    """
    names: list[str] = []
    for token in re.findall(r"`([^`]+)`", cell):
        bare = token.split("(")[0].lstrip(".")
        names.extend(part for part in bare.split(".") if part)
    return names


class TestClaudeMdSSoT:
    """Grouped in a class so `scripts/mutation-check.py` can name these as
    `file::Class::test` node ids, which its catalog guard requires."""

    def test_the_ssot_table_parses_into_the_shape_the_other_tests_assume(self) -> None:
        """Without this, a parser that matched nothing would make the rest pass empty."""
        rows = _ssot_rows()
        assert len(rows) >= 5, f"parsed only {len(rows)} SSoT rows — parser or table shape changed"
        for row in rows:
            assert len(row) == 4, f"unexpected SSoT row shape: {row}"

    def test_every_ssot_location_exists(self) -> None:
        for row in _ssot_rows():
            location = row[2].strip("`")
            assert (_PROJECT_ROOT / location).exists(), (
                f"SSoT row points at a missing path: {location}"
            )

    def test_every_ssot_symbol_lives_where_the_table_says(self) -> None:
        """Only the canonical-implementation column is checked. The notes column
        legitimately mentions types that live elsewhere (`GeometryReader`, a Wave 3
        consumer), so asserting on it would fail for being right."""
        for row in _ssot_rows():
            location = row[2].strip("`")
            source = (_PROJECT_ROOT / location).read_text(encoding="utf-8")
            names = _symbols(row[1])
            assert names, f"SSoT row names no symbol at all: {row}"
            for name in names:
                assert name in source, (
                    f"CLAUDE.md says `{name}` lives in {location}, but it does not"
                )

    def test_every_repo_relative_path_named_anywhere_exists(self) -> None:
        """Home-relative paths (`~/...`) are skipped deliberately: asserting on them
        would tie the suite to the machine rather than to the checkout. Tokens holding
        a space are shell snippets, not paths."""
        candidates = {
            token.rstrip("/")
            for token in _inline_code(_text())
            if "/" in token and " " not in token and not token.startswith(("~", "/", "http"))
        }
        assert len(candidates) >= 8, (
            f"path scan found only {len(candidates)} paths — check the regex"
        )
        missing = sorted(path for path in candidates if not (_PROJECT_ROOT / path).exists())
        assert not missing, f"CLAUDE.md names paths that do not exist: {missing}"
