#!/usr/bin/env python3
"""Admit completed Swift test output, never build-only or all-skipped success.

XCTest repeats aggregate counts for nested suites; take its largest summary.
Swift Testing counts skipped tests in its run total, so count individual skip
messages (not suite messages) separately. Both frameworks may share one log.
"""

import argparse
import json
import re
from pathlib import Path

_XCTEST = re.compile(
    r"Executed (\d+) tests?, with (?:(\d+) tests? skipped and )?"
    r"(\d+) failures? \(\d+ unexpected\) in [\d.]+ \([\d.]+\) seconds"
)
_SWIFT = re.compile(
    r"Test run with (\d+) tests?(?: in \d+ suites?)? (passed|failed) after [\d.]+ seconds?[^\n]*\."
)
_SKIP = re.compile(r"^\s*(?:\S+\s+)?Test (?!run with ).+ skipped(?:\.|:)", re.MULTILINE)
_ANSI = re.compile(r"\x1b\[[0-9;]*m")


def verify(output: str, exit_code: int) -> dict[str, object]:
    """Return explicit counts and a fail-closed admission decision."""
    output = _ANSI.sub("", output)
    xctest = [(int(n), int(s or 0), int(f)) for n, s, f in _XCTEST.findall(output)]
    swift = [(int(n), status) for n, status in _SWIFT.findall(output)]
    xc_total = max((n for n, _, _ in xctest), default=0)
    xc_skips = max((s for _, s, _ in xctest), default=0)
    failures = max((f for _, _, f in xctest), default=0)
    swift_total = max((n for n, _ in swift), default=0)
    swift_skips = len(_SKIP.findall(output))
    total = xc_total + swift_total
    skipped = xc_skips + swift_skips
    observed = total - skipped
    reason = "completed tests observed"
    if exit_code != 0:
        reason = f"test command exited {exit_code}"
    elif not xctest and not swift:
        reason = "missing completed test summary"
    elif failures or any(status == "failed" for _, status in swift):
        reason = "test failures reported"
    elif xc_skips > xc_total or swift_skips > swift_total:
        reason = "inconsistent skip accounting"
    elif total == 0:
        reason = "zero tests reported"
    elif observed <= 0:
        reason = "all tests skipped"
    return {
        "passed": reason == "completed tests observed",
        "detail": reason,
        "exit_code": exit_code,
        "tests": total,
        "skipped": skipped,
        "observed": observed,
        "xctest_failures": failures,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", type=Path)
    parser.add_argument("--exit-code", type=int, required=True)
    args = parser.parse_args()
    result = verify(args.log.read_text(errors="replace"), args.exit_code)
    print(json.dumps(result, sort_keys=True))
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
