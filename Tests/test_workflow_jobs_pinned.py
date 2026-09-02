"""The workflow jobs that guard this repo must exist and name their mechanisms.

A CI job that is silently dropped reads exactly like one that ran clean (the
no.md #68 shape: a gate that stops asking is indistinguishable at the summary
line). These tests pin the three guard jobs -- secret-scan, the pinned-action
checker, and the capture pipeline's close-on-green -- so removing a job fails
a local test instead of silently un-guarding CI.
"""

from __future__ import annotations

from pathlib import Path

import pytest

yaml = pytest.importorskip("yaml")

WORKFLOW_DIR = Path(__file__).resolve().parents[1] / ".github" / "workflows"


def _load(path: Path) -> dict:
    return yaml.safe_load(path.read_text())


def test_every_workflow_yaml_parses() -> None:
    workflows = sorted(WORKFLOW_DIR.glob("*.yml"))
    assert len(workflows) >= 3, "the repo's workflow set shrank unexpectedly"
    for path in workflows:
        doc = yaml.safe_load(path.read_text())
        assert isinstance(doc, dict), f"{path.name} is not a mapping"


def test_the_secret_scan_job_still_exists_in_ci() -> None:
    doc = _load(WORKFLOW_DIR / "ci.yml")
    jobs = doc.get("jobs", {})
    assert "secret-scan" in jobs, "the gitleaks job must stay in CI"


def test_the_pinned_action_checker_workflow_names_its_checker() -> None:
    path = WORKFLOW_DIR / "check-pinned-actions.yml"
    doc = _load(path)
    assert doc.get("jobs"), "no jobs in check-pinned-actions.yml"
    text = path.read_text()
    # Only the checker is invoked; resolve_action_sha.py is reached through
    # its import, and its contract is pinned by Tests/test_resolve_action_sha.py.
    assert "check_pinned_actions.py" in text, "the workflow must run the checker"


def test_the_capture_workflow_still_closes_on_green() -> None:
    doc = _load(WORKFLOW_DIR / "capture-ci-failures-to-github-issue.yml")
    jobs = doc.get("jobs", {})
    assert "close-on-green" in jobs, "the close-on-green job must stay wired"
