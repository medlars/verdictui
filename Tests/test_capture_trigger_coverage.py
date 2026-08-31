"""The capture trigger must name every workflow in this repo.

A `workflow_run` trigger fires ONLY for workflows listed under `workflows:`.
One omitted is INERT while looking identical to a working entry: its failures
file no ci-failure issue and close none, and nothing reports the gap.

Measured 2026-08-31: "Persist run-v2 evidence" was rolled out to 10 repos and
added to none of their capture lists. Only the 2 repos carrying this guard
(kastdrive, kasttune) went red; the other 8 drifted silently — which is the
whole argument for the guard existing in every repo rather than two.
Prior instance: F-053, KastTune's Relay Uptime Probe failed 11x, no issue filed.
"""

from __future__ import annotations

from pathlib import Path

import pytest

yaml = pytest.importorskip("yaml")

REPO = Path(__file__).resolve().parents[1]
WORKFLOW_DIR = REPO / ".github" / "workflows"
CAPTURE = WORKFLOW_DIR / "capture-ci-failures-to-github-issue.yml"

# YAML 1.1 reads a bare `on:` key as the boolean True. The workflow is fine;
# the loader is the problem. Look under both spellings.
ON_KEYS = (True, "on")


def _load(path: Path) -> dict:
    return yaml.safe_load(path.read_text())


def _trigger(doc: dict) -> dict:
    for key in ON_KEYS:
        if key in doc:
            return doc[key]
    raise AssertionError(f"workflow has no `on:` trigger; keys={list(doc)}")


def _watched() -> set[str]:
    return set(_trigger(_load(CAPTURE))["workflow_run"]["workflows"])


def _present() -> set[str]:
    names = set()
    for path in sorted(WORKFLOW_DIR.glob("*.yml")):
        if path.name == CAPTURE.name:
            continue
        doc = _load(path)
        if isinstance(doc, dict) and doc.get("name"):
            names.add(doc["name"])
    return names


@pytest.mark.skipif(not CAPTURE.exists(), reason="repo has no capture workflow")
def test_capture_trigger_watches_every_workflow_in_the_repo() -> None:
    missing = _present() - _watched()
    assert not missing, (
        f"workflows never watched by the capture trigger: {sorted(missing)} — "
        "a failure in them files no issue and closes none, while looking healthy"
    )


@pytest.mark.skipif(not CAPTURE.exists(), reason="repo has no capture workflow")
def test_positive_control_an_unwatched_workflow_is_caught() -> None:
    """The same assertion, fed a list with one real workflow removed, must FAIL.

    Without this, a rule that is always true is indistinguishable from a
    working one — the guard would pass even if `_present()` returned nothing.
    """
    present = _present()
    if not present:
        pytest.skip("no sibling workflows to drop")
    watched = _watched() - {sorted(present)[0]}
    with pytest.raises(AssertionError):
        missing = present - watched
        assert not missing, sorted(missing)
