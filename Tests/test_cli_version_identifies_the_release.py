"""`verdictui --version` must identify the BUILD, not the wire schema.

CTS-959AB320. Measured 2026-08-26 against the v1.0.1 release tarball: the
binary printed `1.1`, which is SchemaVersion.current. That matches no release,
makes two builds sharing a schema indistinguishable, and makes a bug report
ambiguous. The wire format is a 1.0 compatibility promise (ADR 2026-022) so it
must stay stable across releases — it cannot double as a release identifier,
because the two have opposite change rates by design.

Verified BY RUNNING THE BUILT ARTIFACT, never by reading source (no.md
#32/#34/#37): a constant can be right in the file and wrong in the binary that
ships.
"""

from __future__ import annotations

import re
import subprocess
from pathlib import Path

import pytest

pytestmark = pytest.mark.quick

ROOT = Path(__file__).resolve().parent.parent
BINARY = ROOT / ".build" / "debug" / "verdictui"

_RELEASE_RE = re.compile(r"^(\d+\.\d+\.\d+) \(schema (\d+\.\d+)\)$")


def _version_line() -> str:
    if not BINARY.exists():
        pytest.skip(f"{BINARY} is not built — run `swift build` first")
    proc = subprocess.run([str(BINARY), "--version"], capture_output=True, text=True, timeout=60)
    assert proc.returncode == 0, f"--version exited {proc.returncode}: {proc.stderr[-500:]}"
    return proc.stdout.strip()


def test_version_reports_a_three_component_release_and_names_the_schema_separately() -> None:
    line = _version_line()
    match = _RELEASE_RE.match(line)
    assert match, (
        f"--version printed {line!r}; expected '<release> (schema <wire>)', e.g. "
        "'1.0.1 (schema 1.1)'. A bare wire version cannot identify the installed build."
    )
    release, schema = match.groups()
    assert release != schema, (
        f"release {release!r} and schema {schema!r} are the same string — the two are "
        "supposed to move independently, so reporting one where the other is expected "
        "is the defect this test exists to catch"
    )


def test_the_release_version_matches_the_declared_constant() -> None:
    """The binary and the source must agree — a stale constant ships silently."""
    source = (ROOT / "Sources" / "VerdictUICLICore" / "ReleaseVersion.swift").read_text()
    declared = re.search(r'current\s*=\s*"([^"]+)"', source)
    assert declared, "ReleaseVersion.current is not a literal string any more"
    assert _version_line().startswith(declared.group(1) + " ")
