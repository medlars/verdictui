"""The prebuilt-CLI release path: tap formula bump and public-asset scan (CIS-467913BC).

The source repo is private, so Homebrew installs an archive from the public
medlars/verdictui-releases repo. `bump-tap-formula.sh` must refuse an edit that
did not take, and `package-cli-release.sh --scan` must refuse an archive that
would publish a home path or a secret. Real scripts, real files; no network.
"""

from __future__ import annotations

import shutil
import subprocess
import zipfile
from pathlib import Path

import pytest

pytestmark = pytest.mark.quick

ROOT = Path(__file__).resolve().parent.parent
BUMP = ROOT / "scripts" / "bump-tap-formula.sh"
PACKAGE = ROOT / "scripts" / "package-cli-release.sh"
OLD_SHA = "bd497b340cb32a5087dbc82c84f5dba1ef36a0f0b20503154eee815cf22df386"
NEW_SHA = "0123456789abcdef" * 4
ASSETS = "https://github.com/medlars/verdictui-releases/releases/download"

FORMULA = f"""class Verdictui < Formula
  desc "SwiftUI verification engine giving semantic verdicts, not screenshots"
  homepage "https://github.com/medlars/verdictui-releases"
  url "{ASSETS}/v1.1.4/verdictui-1.1.4-macos-universal.zip"
  sha256 "{OLD_SHA}"
  license "MIT"

  depends_on macos: :ventura

  def install
    bin.install "verdictui"
  end
end
"""


def _bump(formula: Path, *args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["bash", str(BUMP), str(formula), *args],
        capture_output=True,
        text=True,
        timeout=60,
    )


def test_the_bump_rewrites_url_and_sha_and_nothing_else(tmp_path: Path) -> None:
    formula = tmp_path / "verdictui.rb"
    formula.write_text(FORMULA)
    proc = _bump(formula, "1.2.0", NEW_SHA)
    assert proc.returncode == 0, proc.stderr
    expected = FORMULA.replace("v1.1.4/verdictui-1.1.4-", "v1.2.0/verdictui-1.2.0-").replace(
        OLD_SHA, NEW_SHA
    )
    assert formula.read_text() == expected


def test_a_formula_without_a_url_line_is_refused_and_left_untouched(tmp_path: Path) -> None:
    formula = tmp_path / "verdictui.rb"
    broken = FORMULA.replace("  url ", "  # url ")
    formula.write_text(broken)
    proc = _bump(formula, "1.2.0", NEW_SHA)
    assert proc.returncode == 1
    assert "exactly one top-level url" in proc.stderr
    assert formula.read_text() == broken


@pytest.mark.parametrize(
    ("version", "sha", "message"),
    [("v1.2", NEW_SHA, "is not X.Y.Z"), ("1.2.0", "ABC", "is not 64 lowercase hex")],
)
def test_malformed_inputs_are_refused(tmp_path: Path, version: str, sha: str, message: str) -> None:
    formula = tmp_path / "verdictui.rb"
    formula.write_text(FORMULA)
    proc = _bump(formula, version, sha)
    assert proc.returncode == 1
    assert message in proc.stderr
    assert formula.read_text() == FORMULA


scan_tools = pytest.mark.skipif(
    not (shutil.which("gitleaks") and shutil.which("strings") and shutil.which("zipinfo")),
    reason="the asset scan needs gitleaks, strings and zipinfo",
)


def _archive(tmp_path: Path, payload: bytes) -> Path:
    zip_path = tmp_path / "verdictui-9.9.9-macos-universal.zip"
    with zipfile.ZipFile(zip_path, "w") as zf:
        zf.writestr("verdictui-9.9.9/verdictui", payload)
        zf.writestr("verdictui-9.9.9/LICENSE", "MIT License\n")
    return zip_path


def _scan(zip_path: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["bash", str(PACKAGE), "--scan", str(zip_path)],
        capture_output=True,
        text=True,
        timeout=120,
    )


@scan_tools
def test_a_clean_archive_passes_the_scan(tmp_path: Path) -> None:
    proc = _scan(_archive(tmp_path, b"\x00\x01verdictui engine /verdictui/Sources/main.swift\x00"))
    assert proc.returncode == 0, proc.stderr
    assert "gitleaks clean" in proc.stdout


@scan_tools
def test_an_embedded_home_path_is_refused(tmp_path: Path) -> None:
    home = "/Users/" + "alice"  # split so this file does not trip the home-path guard
    proc = _scan(
        _archive(tmp_path, f"\x00{home}/Projects/VerdictUI/Sources/main.swift\x00".encode())
    )
    assert proc.returncode == 1
    assert "embeds a /Users/<name> path" in proc.stderr


@scan_tools
def test_an_embedded_secret_is_refused(tmp_path: Path) -> None:
    token = "ghp_" + "R7d2Kq9XvLmP4sT8wYbN3cJ6hF1aZ0eUoG5i"  # split: fake token, not a real one
    proc = _scan(_archive(tmp_path, f"\x00github_token={token}\x00".encode()))
    assert proc.returncode == 1
    assert "gitleaks flagged" in proc.stderr
