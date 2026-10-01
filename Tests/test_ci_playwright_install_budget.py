"""The Lint PM scripts job must budget the Playwright install apart from the tests (CIS-9DD618AC).

On 2026-10-01 `playwright install --with-deps` (apt) took ~8 of the job's 10
minutes and the job was cancelled one second after pytest printed a green
result. The install now has its own step and timeout inside a job budget that
holds both, and the browser download is cached on the pinned version.
"""

from __future__ import annotations

import re
from pathlib import Path

import yaml

WORKFLOW = Path(__file__).resolve().parents[1] / ".github" / "workflows" / "ci.yml"


def _job() -> dict:
    return yaml.safe_load(WORKFLOW.read_text())["jobs"]["python-scripts"]


def _step(job: dict, name: str) -> dict:
    [step] = [s for s in job["steps"] if s.get("name") == name]
    return step


def test_install_and_tests_have_their_own_budgets_inside_the_job():
    job = _job()
    install = _step(job, "Install Playwright Chromium")
    tests = _step(job, "Python test suite (PM + kernel symbol audit)")
    assert "playwright install --with-deps chromium" in install["run"]
    assert "playwright install" not in tests["run"]
    assert install["timeout-minutes"] + tests["timeout-minutes"] < job["timeout-minutes"]


def test_browser_cache_precedes_the_install_and_tracks_the_pinned_version():
    job = _job()
    names = [s.get("name") for s in job["steps"]]
    assert names.index("Cache Playwright browsers") < names.index("Install Playwright Chromium")
    cache = _step(job, "Cache Playwright browsers")
    pinned = re.search(r"playwright==([\d.]+)", _step(job, "Install Playwright Chromium")["run"])
    assert pinned, "playwright must be pinned"
    assert cache["with"]["path"] == "~/.cache/ms-playwright"
    assert f"playwright-{pinned.group(1)}-" in cache["with"]["key"]
