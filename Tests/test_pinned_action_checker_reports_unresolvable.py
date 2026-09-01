"""The pinned-action checker must report three states, never two.

get_latest_version() returns None on any HTTPError or timeout. Folding that
into the up-to-date branch made a silent API failure indistinguishable from a
verified-current pin -- the report literally said "up to date (or could not
check)". CIS-3D2AFCC3, lesson 202/382.

The subject is the SHIPPED workflow: the script is extracted from the YAML
rather than duplicated here, so a regression in the real artifact fails this.
"""

from __future__ import annotations

import io
import json
import textwrap
import urllib.error
import urllib.request
from pathlib import Path

import pytest

WORKFLOW = Path(__file__).resolve().parents[1] / ".github/workflows/check-pinned-actions.yml"

STALE_PIN, CURRENT_PIN, UNRESOLVABLE_PIN = "a" * 40, "c" * 40, "b" * 40
MOVED_TO = "f" * 40


def _embedded_script() -> str:
    lines = WORKFLOW.read_text().split("\n")
    start = next(i for i, line in enumerate(lines) if "python3.14 << 'EOF'" in line)
    end = next(i for i, line in enumerate(lines) if i > start and line.strip() == "EOF")
    return textwrap.dedent("\n".join(lines[start + 1 : end]))


class _Response(io.BytesIO):
    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


def _fake_urlopen(req, timeout=None):
    url = req.full_url
    if "actions/cache" in url:
        # the whole point: this action cannot be resolved
        raise urllib.error.HTTPError(url, 404, "Not Found", {}, None)
    if "/releases/latest" in url:
        body = {"tag_name": "v1", "published_at": "2026-01-01"}
    elif "/git/ref/tags/" in url:
        sha = CURRENT_PIN if "setup-python" in url else MOVED_TO
        body = {"object": {"type": "commit", "sha": sha}}
    else:
        raise urllib.error.HTTPError(url, 500, "unexpected url", {}, None)
    return _Response(json.dumps(body).encode())


@pytest.fixture
def checker_output(tmp_path, monkeypatch, capsys) -> str:
    workflows = tmp_path / ".github/workflows"
    workflows.mkdir(parents=True)
    (workflows / "w.yml").write_text(
        "jobs:\n  x:\n    steps:\n"
        f"      - uses: actions/checkout@{STALE_PIN}\n"
        f"      - uses: actions/setup-python@{CURRENT_PIN}\n"
        f"      - uses: actions/cache@{UNRESOLVABLE_PIN}\n"
    )
    monkeypatch.chdir(tmp_path)
    monkeypatch.setenv("GITHUB_TOKEN", "x")
    monkeypatch.delenv("GITHUB_OUTPUT", raising=False)
    monkeypatch.setattr(urllib.request, "urlopen", _fake_urlopen)
    exec(compile(_embedded_script(), str(WORKFLOW), "exec"), {"__name__": "__main__"})
    return capsys.readouterr().out


@pytest.mark.quick
def test_an_unresolvable_pin_is_reported_not_folded_into_up_to_date(checker_output):
    assert "Could NOT resolve 1 of 3 pins" in checker_output
    assert "actions/cache" in checker_output


@pytest.mark.quick
def test_a_stale_pin_is_still_reported(checker_output):
    """Positive control: without this the test above passes on a checker that
    reports nothing at all, which is not the behaviour being guarded."""
    assert "actions/checkout" in checker_output
    assert MOVED_TO[:8] in checker_output


@pytest.mark.quick
def test_a_current_pin_is_not_reported_as_needing_an_update(checker_output):
    """Second control: the checker must not simply flag everything."""
    update_section = checker_output.split("may need updates:")[-1]
    assert "actions/setup-python" not in update_section
