#!/usr/bin/env python3.14
"""VerdictUI PM. Run: python3.14 scripts/verdictui-pm.py --quick

Entrypoint only. The implementation lives in four siblings in this directory:

| Module                    | Owns                                                     |
| ------------------------- | -------------------------------------------------------- |
| `verdictui_pm_support`    | Project paths, constants, logging, contention, timing env |
| `verdictui_pm_swift`      | SwiftPM lock files, runner, streamed test, locked build   |
| `verdictui_pm_stages`     | Build/test/architecture/lint/demo/governance stage mixin  |
| `verdictui_pm_smoke`      | Smoke, parity, mutation-catalog and SLO-bench stage mixin |

Two rules keep the split from going quietly hollow (CTS-6DBFF8C6):

1. The stages are inherited as MIXINS, never re-exported. Inheritance leaves
   every method resolving on `VerdictUIPM`, so `monkeypatch.setattr(VerdictUIPM,
   ...)` keeps binding; a facade that re-exported them would move the object a
   patch reaches and unbind existing patch sites without failing anything.
2. Every name the suite monkeypatches has exactly ONE owner module and is read
   through it (`S.PROJECT_ROOT`, `SW._swift_runner`). A `from ... import` copy
   binds at import time, so a patch on the owner would stop reaching the reader
   and the suite would stay green while testing nothing — a failure in the
   PASSING direction, which is strictly worse than the long file this split
   replaced. `test_the_patched_names_have_exactly_one_owner` enforces it.
"""

from __future__ import annotations

import argparse
import contextlib  # noqa: F401 — reached as `_mod.contextlib` by the test suite
import json
import os  # noqa: F401 — patched as `_mod.os` by the test suite
import shutil  # noqa: F401 — patched as `_mod.shutil` by the test suite
import signal  # noqa: F401 — read as `_mod.signal` by the test suite
import subprocess  # noqa: F401 — patched as `_mod.subprocess` by the test suite
import sys
import tempfile  # noqa: F401 — patched as `_mod.tempfile` by the test suite
import time
from pathlib import Path

# The suite loads this file BY PATH (`spec_from_file_location`), which does not
# put `scripts/` on `sys.path`, so the siblings below would not resolve under
# pytest even though they do from the CLI. Declared rather than assumed: the
# same omission cost 55 spurious failures on a sibling project's PM (lesson 201).
sys.path.insert(0, str(Path(__file__).resolve().parent))

import verdictui_pm_support as S  # noqa: E402 — must follow the sys.path setup
import verdictui_pm_swift as SW  # noqa: E402 — must follow the sys.path setup
from verdictui_pm_smoke import VerdictUISmokeMixin  # noqa: E402
from verdictui_pm_stages import VerdictUIStagesMixin  # noqa: E402
from verdictui_pm_support import PROJECT_NAME, PmBase, stage_result_is_skip  # noqa: E402

__all__ = ["PROJECT_NAME", "S", "SW", "VerdictUIPM", "main"]


# How long a mutation-sweep marker stays believable. Must equal
# `mutation-check.py`'s SWEEP_MARKER_TTL_SECONDS — the harness WRITES the marker
# and this reads it, so a disagreement is a window where one side thinks a sweep
# is live and the other does not. Not imported, because `mutation-check.py` is
# hyphen-named and therefore not importable as a module; the two are bound by
# `test_the_pm_and_the_harness_agree_on_the_marker_ttl` instead, which is the
# only thing that can notice a drift (neither file can read the other's value).
MUTATION_SWEEP_TTL_SECONDS = 3600


def mutation_sweep_in_progress() -> bool:
    """True while `scripts/mutation-check.py` is deliberately mutating this tree.

    A mutation sweep rewrites source in place and restores it, so any concurrent
    READER sees a tree the author never intended to ship. Measured 2026-08-12: a
    background PM sampled this repo during a hand-applied mutation and filed two
    P1s (CTS-36AA316A, CTS-D69CD61A) describing a regression that did not exist,
    each carrying a precise-looking file:line citation. Both were falsified on a
    clean tree at HEAD and closed.

    That is the expensive direction — a fabricated defect is indistinguishable
    from a real one at the point of use, and the next session inherits it as
    fact. Anything that FILES an issue from this tree should consult this first.

    `no.md` #14/#21 cover concurrent WRITERS; this covers readers, which the
    per-row hash guard cannot see because nothing wrote anything.
    """
    marker = Path(__file__).resolve().parent.parent / "logs" / ".mutation-in-progress"
    try:
        raw = marker.read_text().split()
    except OSError:
        return False
    if len(raw) != 2:
        return False
    try:
        started = float(raw[1])
    except ValueError:
        return False
    # Stale markers do not suppress forever: a SIGKILLed sweep cannot run its
    # `finally`, and a permanent silence is worse than the noise it prevents.
    return (time.time() - started) < MUTATION_SWEEP_TTL_SECONDS


class VerdictUIPM(VerdictUIStagesMixin, VerdictUISmokeMixin, PmBase):
    """Project Manager for VerdictUI — owns build, test, architecture, and governance stages.

    The stage methods come from the two mixins, which precede `PmBase` in the
    MRO so `super()` in an override still reaches the real base class.
    """

    PROJECT_NAME = PROJECT_NAME
    PROJECT_ROOT = S.PROJECT_ROOT

    def __init__(self) -> None:
        super().__init__()
        # Persist to logs/pm-last-status.json — the file the Stop hook snapshots
        # for grade-regression detection (pm_legacy defaults to /tmp, wiped on reboot).
        self.status_file = self.PROJECT_ROOT / "logs" / "pm-last-status.json"

    def publish_to_dashboard(self, status: dict) -> None:
        try:
            # Pyright binds PmBase to the CI fallback stub above,
            # which has no publish_to_dashboard; the real base class does.
            super().publish_to_dashboard(status)  # type: ignore[misc]
        except PermissionError as e:
            S._pm_log(f"Dashboard publish skipped: {e}", "WARN")

    def define_stages(self, mode: str) -> list:
        stages = [
            ("stage_build", self.stage_build),
            ("stage_test", self.stage_test),
            ("stage_floor", self.stage_floor),
            ("stage_contracts", self.stage_contracts),
            ("stage_architecture", self.stage_architecture),
            ("stage_ai_artifacts", self.stage_ai_artifacts),
            ("stage_todo_review", self.stage_todo_review),
            ("stage_last20", self.stage_last20),
            ("stage_test_alongside", self.stage_test_alongside),
            ("stage_demo", self.stage_demo),
            ("stage_cli_smoke", self.stage_cli_smoke),
            # Must follow stage_cli_smoke, which is what builds the binary both
            # of them drive.
            ("stage_transport_smoke", self.stage_transport_smoke),
            ("stage_mutations", self.stage_mutations),
            ("stage_appkit_example", self.stage_appkit_example),
            ("stage_installed_parity", self.stage_installed_parity),
            ("stage_stale_buffer", self.stage_stale_buffer),
            ("stage_runtime_bench", self.stage_runtime_bench),
            # SLO 3. Also needs the binary stage_cli_smoke builds, and sits
            # beside SLO 1 because the two answer the same question at
            # different layers: the engine's speed, and the speed a caller
            # actually experiences through the wire.
            ("stage_mcp_latency", self.stage_mcp_latency),
            ("stage_pytest", self.stage_pytest),
            ("stage_lint", self.stage_lint),
            ("stage_codewatch", self.stage_codewatch),
            ("stage_issuewatch", self.stage_issuewatch),
            ("stage_capabilitywatch", self.stage_capabilitywatch),
            ("stage_cis_health", self.stage_cis_health),
        ]
        # WatchTools fleet-wide stages — ImportError means not installed, skip gracefully
        try:
            from pm_base_pm_stages import (  # type: ignore  # noqa: PLC0415 — deferred shared-libs import (skip sentinel pattern)
                build_watch_stages,
            )
        except ImportError:
            return stages
        if S._timing_record_only_environment():
            return stages
        stages = stages + list(
            build_watch_stages(
                str(S.PROJECT_ROOT),
                PROJECT_NAME,
                quick=(mode == "quick"),
            )
        )
        return stages

    def run_query(
        self,
        kind: str,
        *,
        file_path: str | None = None,
        stage: str | None = None,
    ) -> int:
        payload: dict[str, object] = {"project": PROJECT_NAME, "query": kind}
        if kind == "risk":
            target = file_path or ""
            payload["file"] = target
            payload["risk"] = (
                "high"
                if target.startswith(("Sources/", "Tests/VerdictUIProbeTests/"))
                or target == "scripts/verdictui-pm.py"
                else "medium"
                if target.endswith((".py", ".swift"))
                else "low"
            )
            payload["notes"] = [
                "Run the focused Swift or pytest target for the touched file.",
                "Run scripts/verdictui-pm.py --quick before declaring the repair done.",
            ]
        elif kind == "coverage":
            target = file_path or ""
            payload["file"] = target
            payload["tests"] = sorted(
                str(path.relative_to(S.PROJECT_ROOT))
                for root in (S.PROJECT_ROOT / "Tests",)
                for path in root.rglob("*")
                if path.name.startswith("test_") or path.name.endswith("Tests.swift")
            )
        elif kind == "why-failed":
            payload["stage"] = stage
            try:
                status = json.loads(self.status_file.read_text())
            except FileNotFoundError:
                payload["error"] = "No cached PM status; run --quick first"
                print(json.dumps(payload, indent=2, sort_keys=True))
                return 1
            except (json.JSONDecodeError, OSError) as exc:
                payload["error"] = f"Cached PM status is unreadable: {exc}"
                print(json.dumps(payload, indent=2, sort_keys=True))
                return 1
            stages = status.get("stages", {})
            cached_failed = status.get("failed_stages")
            if isinstance(cached_failed, list):
                payload["failed_stages"] = cached_failed
            elif isinstance(stages, dict):
                payload["failed_stages"] = [
                    name
                    for name, result in stages.items()
                    if isinstance(result, dict) and result.get("passed") is False
                ]
            else:
                payload["failed_stages"] = []
            payload["detail"] = (
                stages.get(stage or "", {}) if isinstance(stages, dict) and stage else {}
            )
        else:
            payload["error"] = f"Unknown query kind: {kind}"
            print(json.dumps(payload, indent=2, sort_keys=True))
            return 2
        print(json.dumps(payload, indent=2, sort_keys=True))
        return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="VerdictUI PM")
    mode_group = parser.add_mutually_exclusive_group()
    mode_group.add_argument("--quick", action="store_true", help="Run the quick PM gate")
    mode_group.add_argument("--full", action="store_true", help="Run the full PM gate")
    mode_group.add_argument(
        "--fix", action="store_true", help="Run quick mode with auto-fix enabled"
    )
    parser.add_argument("command", nargs="?", choices=["query"])
    parser.add_argument("query_kind", nargs="?")
    parser.add_argument("--file")
    parser.add_argument("--stage")
    args = parser.parse_args(argv)

    pm = VerdictUIPM()
    if args.command == "query":
        if not args.query_kind:
            parser.error("query requires one of: risk, coverage, why-failed")
        return pm.run_query(args.query_kind, file_path=args.file, stage=args.stage)

    mode = "full" if args.full else "quick"
    status = pm.run_pipeline(mode=mode, fix=args.fix)
    if status is None:
        return 1
    # `status` is re-bound through an explicit annotation because pyright
    # resolves run_pipeline across two base classes with different return
    # types: it treats the value as Optional at the call (so the guard above is
    # REQUIRED — removing it produces three Optional errors) and then narrows
    # to Never afterwards, at which point nothing can be read from it. Deleting
    # either half is wrong; naming the post-guard type is what satisfies both.
    stages: dict[str, object] = dict(status.get("stages") or {})
    skipped = sorted(
        name
        for name, row in stages.items()
        if isinstance(row, dict)
        and row.get("passed")
        and stage_result_is_skip(str(row.get("detail", "")))
    )
    if skipped:
        # A skip renders as [PASS], and the marker is what a reader scans. Say
        # plainly which stages measured nothing, so "could not observe" is never
        # read as "observed and clean" (lesson 202/206). Advisory: the exit code
        # is untouched, because an absence of evidence is not a failure.
        print(
            f"\n  ⓘ {len(skipped)} stage(s) passed WITHOUT observing their subject "
            f"— UNVERIFIED, not clean:\n    " + "\n    ".join(skipped) + "\n"
        )
    if not status["all_passed"]:
        # The exit code is NOT softened: a red stays red. Suppressing a failure
        # on a contention guess is how a real regression gets waved through.
        # What changes is that the reader is told the measurement is suspect,
        # because the alternative is a precise-looking file:line citation that
        # reads as a code defect and gets filed as one (ten such P1s on
        # 2026-08-19/20, every one falsified on an exclusive tree).
        #
        # The report NAMES the matched contender and the measured load rather
        # than asserting a fixed one. The previous version hardcoded "a fleet
        # sweep (check.py --all)" while the pattern list had four entries, so
        # on 2026-08-22 — when the live contender was `ceo.py --watch` at load
        # 346.99 — it would have sent its reader to pgrep for a process that
        # was not running, and finding nothing reads as "the warning is
        # spurious" (`no.md` #60: prose asserting what the code does not check).
        if (evidence := S.contention_evidence()) is not None:
            print(evidence.render())
    return 0 if status["all_passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
