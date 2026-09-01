"""Scan workflows for SHA-pinned actions and report only the GENUINELY stale ones.

Four buckets, never two: stale, up-to-date, unresolvable, and ahead. Collapsing
"could not observe" into either of the first two is what makes a checker fire
forever; collapsing "the pin is NEWER than the tag" into `stale` is worse, because
the resulting issue tells a reader to move a SHA pin BACKWARDS. That happens
whenever `releases/latest` is a moving major tag ("v1") lagging its own patch
releases — see resolve_action_sha for the measurement.
"""

from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from resolve_action_sha import (  # noqa: E402
    Resolved,
    commit_date,
    default_api,
    resolve_tag_to_commit,
)

_PIN = re.compile(r"uses:\s*([^\s@]+)@([a-f0-9]{40})\b")


def extract_pinned_actions(workflow_file: Path) -> list[tuple[str, str, int]]:
    content = workflow_file.read_text()
    out = []
    for match in _PIN.finditer(content):
        line_num = content[: match.start()].count("\n") + 1
        out.append((match.group(1), match.group(2), line_num))
    return out


def classify_pins(pins, resolved, pin_dates=None) -> dict:
    """Bucket each pin. `pin_dates` maps a pinned sha to its committer date.

    A pin with no known date degrades to the old two-way comparison rather than
    guessing a direction — an unknown date must not manufacture an `ahead`.
    """
    pin_dates = pin_dates or {}
    stale, uptodate, unresolvable, ahead = [], [], [], []
    for action, sha, line, wf_file in pins:
        latest = resolved.get(action)
        if not isinstance(latest, Resolved):
            unresolvable.append(
                {
                    "action": action,
                    "file": wf_file,
                    "line": line,
                    "reason": getattr(latest, "reason", "not resolved"),
                }
            )
        elif latest.sha == sha:
            uptodate.append({"action": action, "file": wf_file, "line": line})
        elif pin_dates.get(sha) and latest.committed and pin_dates[sha] >= latest.committed:
            # Both dates are ISO-8601 UTC from the same API, so they sort lexically.
            ahead.append(
                {
                    "action": action,
                    "file": wf_file,
                    "line": line,
                    "current_sha": sha,
                    "tag_sha": latest.sha,
                    "tag": latest.tag,
                    "reason": (
                        f"pin ({pin_dates[sha]}) is newer than {latest.tag} "
                        f"({latest.committed}) — moving tag lag, not staleness"
                    ),
                }
            )
        else:
            stale.append(
                {
                    "action": action,
                    "file": wf_file,
                    "line": line,
                    "current_sha": sha,
                    "latest_sha": latest.sha,
                    "latest_tag": latest.tag,
                    "published": latest.published,
                }
            )
    return {
        "stale": stale,
        "uptodate": uptodate,
        "unresolvable": unresolvable,
        "ahead": ahead,
    }


def observed_nothing(pins, rows) -> bool:
    """True when there were pins to check and NOT ONE could be resolved.

    Partial unresolvability is normal and must not trip this: an action with no
    releases resolves nothing and is a legitimate `unresolvable` row. Resolving
    NONE of N pins is different in kind -- an expired token, a rate limit or an
    API outage -- and reporting it as `updates_found=false` with exit 0 is
    "could not observe" wearing "observed and clean" at the JOB level, which is
    the level a human and a dashboard read.
    """
    return bool(pins) and not (rows["uptodate"] or rows["stale"] or rows["ahead"])


def main() -> int:
    pins = []
    for workflow_file in sorted(Path(".github/workflows").glob("*.yml")):
        for action, sha, line in extract_pinned_actions(workflow_file):
            pins.append((action, sha, line, str(workflow_file)))

    api = default_api()
    resolved = {a: resolve_tag_to_commit(a, api) for a in {p[0] for p in pins}}
    # Only pins that DIFFER from their tag need a date; that is the sole case
    # where direction matters, and it keeps the extra API calls near zero.
    pin_dates = {}
    for action, sha, _line, _wf in pins:
        latest = resolved.get(action)
        if isinstance(latest, Resolved) and latest.sha != sha and sha not in pin_dates:
            pin_dates[sha] = commit_date(action, sha, api)

    rows = classify_pins(pins, resolved, pin_dates)

    print(f"pinned actions scanned : {len(pins)}")
    print(f"  up to date           : {len(rows['uptodate'])}")
    print(f"  genuinely stale      : {len(rows['stale'])}")
    print(f"  could not resolve    : {len(rows['unresolvable'])}")
    print(f"  pin ahead of tag     : {len(rows['ahead'])}")
    for row in rows["unresolvable"]:
        print(f"    ? {row['action']} ({row['file']}:{row['line']}) — {row['reason']}")
    for row in rows["ahead"]:
        print(f"    ^ {row['action']} ({row['file']}:{row['line']}) — {row['reason']}")
    for row in rows["stale"]:
        print(
            f"    ! {row['action']} {row['current_sha'][:8]} -> {row['latest_sha'][:8]} ({row['latest_tag']})"
        )

    Path("/tmp/updates.json").write_text(json.dumps(rows["stale"]))
    github_output = os.environ.get("GITHUB_OUTPUT", "")
    if github_output:
        with open(github_output, "a") as handle:
            handle.write(f"updates_found={'true' if rows['stale'] else 'false'}\n")
            handle.write(f"count={len(rows['stale'])}\n")
            handle.write(f"unresolved={len(rows['unresolvable'])}\n")
            handle.write(f"ahead={len(rows['ahead'])}\n")

    # Outputs are written FIRST so a consumer can still read `unresolved`, then
    # the step fails: a run that resolved nothing must not report success.
    if observed_nothing(pins, rows):
        print(
            f"FAILED: none of the {len(pins)} pinned actions could be resolved. "
            "This is an instrument failure (expired token, rate limit, API outage), "
            "not evidence that the pins are current."
        )
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
