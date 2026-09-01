"""The pinned-action checker must keep four buckets, never two.

Two collapses are possible and both are harmful. Folding "could not observe"
into "up to date" makes a silent API failure indistinguishable from a verified
pin (lesson 202/382). Folding "the pin is NEWER than the tag" into `stale` is
worse: it produces an issue telling a reader to move a SHA pin BACKWARDS, which
is a supply-chain downgrade presented as an update. That happens whenever
`releases/latest` is a moving major tag lagging its own patch releases.

The scripts under .github/scripts/ are shared verbatim with FinanceFlow and
Archivist; these tests lock the behaviour this repo depends on. CIS-3D2AFCC3,
CIS-8B2A821F.
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / ".github" / "scripts"))

from check_pinned_actions import classify_pins  # noqa: E402
from resolve_action_sha import Resolved, Unresolvable  # noqa: E402

PIN = "a" * 40
TAG_SHA = "b" * 40


def _pins():
    return [("actions/checkout", PIN, 4, ".github/workflows/w.yml")]


@pytest.mark.quick
def test_an_unresolvable_action_is_its_own_bucket():
    rows = classify_pins(
        _pins(), {"actions/checkout": Unresolvable("actions/checkout", "HTTP 404")}
    )
    assert len(rows["unresolvable"]) == 1
    assert rows["unresolvable"][0]["reason"] == "HTTP 404"
    # the whole point: it must NOT be counted as verified-current
    assert rows["uptodate"] == []
    assert rows["stale"] == []


@pytest.mark.quick
def test_a_matching_pin_is_up_to_date():
    """Positive control: without this, the test above passes on a classifier
    that puts everything in `unresolvable`."""
    resolved = Resolved("actions/checkout", "v1", PIN, "2026-01-01", committed="2026-01-01")
    rows = classify_pins(_pins(), {"actions/checkout": resolved})
    assert len(rows["uptodate"]) == 1
    assert rows["stale"] == [] and rows["unresolvable"] == []


@pytest.mark.quick
def test_a_genuinely_stale_pin_is_reported():
    resolved = Resolved("actions/checkout", "v2", TAG_SHA, "2026-06-01", committed="2026-06-01")
    rows = classify_pins(_pins(), {"actions/checkout": resolved}, pin_dates={PIN: "2026-01-01"})
    assert len(rows["stale"]) == 1
    assert rows["stale"][0]["latest_sha"] == TAG_SHA


@pytest.mark.quick
def test_a_pin_newer_than_its_tag_is_ahead_not_stale():
    """A moving major tag lags its own patches. Reporting that as stale tells
    the reader to move the pin BACKWARDS -- a downgrade, not an update."""
    resolved = Resolved("actions/checkout", "v1", TAG_SHA, "2026-01-01", committed="2026-01-01")
    rows = classify_pins(_pins(), {"actions/checkout": resolved}, pin_dates={PIN: "2026-06-01"})
    assert len(rows["ahead"]) == 1
    assert rows["stale"] == [], "a newer pin must never be reported as needing an update"


@pytest.mark.quick
def test_an_unknown_pin_date_degrades_to_stale_rather_than_guessing():
    """An unknown date must not manufacture an `ahead`."""
    resolved = Resolved("actions/checkout", "v2", TAG_SHA, "2026-06-01", committed="2026-06-01")
    rows = classify_pins(_pins(), {"actions/checkout": resolved}, pin_dates={})
    assert len(rows["stale"]) == 1 and rows["ahead"] == []
