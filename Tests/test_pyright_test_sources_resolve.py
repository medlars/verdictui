"""Every bare import in a test file must resolve for STATIC analysis too.

A test file that resolves script modules at RUN time via `sys.path.insert`
gets nothing from pyright, which reads its directory list from `extraPaths`
in `pyproject.toml` instead. The two declarations must move together -- that
contract is stated in `Tests/conftest.py` and in the config's own comment --
but nothing enforced it, so the pinned-action checker's test directory
(`.github/scripts`) was inserted at runtime and never declared, and pyright
reported `reportMissingImport` twice on source that runs green (CIS-032856FB,
CIS-814FD60D). This guard is witnessed over the WHOLE Tests/ directory rather
than one file, so the next inserted directory cannot reopen the class without
a new row.
"""

from __future__ import annotations

import json
import shutil
import subprocess
from pathlib import Path

import pytest

_PROJECT_ROOT = Path(__file__).resolve().parents[1]


class TestPyrightResolvesTestSources:
    def test_pyright_resolves_every_import_in_the_test_sources(self) -> None:
        if shutil.which("pyright") is None:
            pytest.skip("pyright not installed")
        test_sources = sorted(str(p) for p in (_PROJECT_ROOT / "Tests").glob("test_*.py"))
        assert test_sources, "no test sources found -- the guard is aimed at nothing"
        proc = subprocess.run(
            ["pyright", "--outputjson", *test_sources],
            capture_output=True,
            text=True,
            cwd=_PROJECT_ROOT,
            check=False,
        )
        report = json.loads(proc.stdout)
        # `extraPaths` is relative to the project root, so the shared-libs
        # siblings only resolve when the checkout sits beside them under
        # ~/Projects (same condition as the PM-script pyright guard).
        if not (_PROJECT_ROOT / ".." / "shared-libs").resolve().is_dir():
            pytest.skip(
                "shared-libs is not a sibling of this checkout, so pyright's "
                "relative extraPaths cannot resolve it; run from ~/Projects"
            )
        missing = [
            d for d in report["generalDiagnostics"] if d.get("rule") == "reportMissingImports"
        ]
        # The rule this guard exists for is missing-import resolution; any other
        # error class in the test sources gets its own finding rather than hiding
        # behind this message.
        assert not missing, (
            "test-source imports pyright cannot resolve -- a sys.path.insert in a "
            "test file needs the same directory declared in pyproject.toml "
            f"extraPaths (offenders: {sorted({Path(d['file']).name for d in missing})})"
        )
        assert report["summary"]["errorCount"] == 0, proc.stdout
