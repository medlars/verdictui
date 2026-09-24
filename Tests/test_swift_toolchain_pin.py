"""Local and CI must compile with ONE Swift toolchain, and drift must be loud.

CTS-6D1E7A0F. CI's macOS job printed `swift --version` and never compared it:
local ran Swift 6.3.3 while CI ran 6.1.2, so a strict-concurrency error that
only 6.1 reports (LiveCommands.withPid, two errors) reddened main after a green
local build. A version string printed and never compared is a gate that stopped
asking (no.md #68). The pin lives in `.github/swift-toolchain-version`; the CI
step fails when the runner's major.minor differs, and the local test fails when
the developer's does. These tests RUN the CI step's shell, never grep it.
"""

from __future__ import annotations

import re
import shutil
import subprocess
from pathlib import Path
from typing import cast

import pytest

yaml = pytest.importorskip("yaml")

ROOT = Path(__file__).resolve().parents[1]
PIN = ROOT / ".github" / "swift-toolchain-version"
CI = ROOT / ".github" / "workflows" / "ci.yml"
_VERSION_RE = re.compile(r"Apple Swift version (\d+\.\d+)")


def _pin() -> str:
    return PIN.read_text(encoding="utf-8").strip()


def _version_step() -> str:
    steps = yaml.safe_load(CI.read_text(encoding="utf-8"))["jobs"]["swift"]["steps"]
    matches = [s for s in steps if str(s.get("name", "")).startswith("Swift version")]
    assert len(matches) == 1, "exactly one 'Swift version' step must exist in the swift job"
    return matches[0]["run"]


def _run_step_with_fake_swift(tmp_path: Path, printed: str) -> subprocess.CompletedProcess[str]:
    fake = tmp_path / "bin" / "swift"
    fake.parent.mkdir()
    fake.write_text(f"#!/bin/sh\necho '{printed}'\n", encoding="utf-8")
    fake.chmod(0o755)
    bash = shutil.which("bash")
    assert bash is not None, "bash is required to run the CI step"
    # B603 false positive: resolved bash running this repo's own workflow step.
    return subprocess.run(  # nosec B603
        [bash, "-e", "-c", _version_step()],
        cwd=ROOT,
        env={"PATH": f"{fake.parent}:/usr/bin:/bin"},
        capture_output=True,
        text=True,
        timeout=30,
        check=False,
    )


def test_the_pin_is_a_major_minor_version() -> None:
    assert re.fullmatch(r"\d+\.\d+", _pin()), f"{PIN.name} must hold MAJOR.MINOR, got {_pin()!r}"


def test_the_ci_step_fails_when_the_runner_toolchain_drifts(tmp_path: Path) -> None:
    drifted = "Apple Swift version 6.1.2 (swiftlang-6.1.2.1.2 clang-1700.0.13.5)"
    assert not drifted.startswith(f"Apple Swift version {_pin()}"), "control needs a mismatch"
    result = _run_step_with_fake_swift(tmp_path, drifted)
    assert result.returncode != 0, result.stdout + result.stderr


def test_the_ci_step_passes_when_the_runner_matches_the_pin(tmp_path: Path) -> None:
    result = _run_step_with_fake_swift(tmp_path, f"Apple Swift version {_pin()} (swiftlang-x)")
    assert result.returncode == 0, result.stdout + result.stderr


def test_the_local_toolchain_matches_the_pin() -> None:
    swift = shutil.which("swift")
    if swift is None:
        pytest.skip("no swift on PATH (the Linux lint job); the CI step covers the runner")
    # B603 false positive: resolved swift binary, fixed argv.
    out = subprocess.run(  # nosec B603
        [cast(str, swift), "--version"], capture_output=True, text=True, timeout=60, check=False
    )
    found = _VERSION_RE.search(out.stdout + out.stderr)
    assert found, f"could not read a Swift version from: {out.stdout + out.stderr!r}"
    assert found.group(1) == _pin(), (
        f"local Swift {found.group(1)} differs from the pinned CI toolchain {_pin()}: "
        "a green local build is not evidence about what CI compiles (CTS-6D1E7A0F)"
    )
