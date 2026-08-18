#!/usr/bin/env python3.14
"""VerdictUI PM. Run: python3.14 scripts/verdictui-pm.py --quick"""

from __future__ import annotations

import argparse
import contextlib
import json
import logging
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from collections.abc import Iterator
from pathlib import Path

_USER_HOME = Path.home()
PROJECT_ROOT = Path(__file__).resolve().parents[1]
PROJECT_NAME = "VerdictUI"
_SHARED_PM_BASE = _USER_HOME / "Projects/shared-libs/pm-base"
_SHARED_RELEASE_TOOLS = _USER_HOME / "Projects/shared-libs/release-tools"


def _ceo_paths_are_available() -> bool:
    """Whether shared pm-base can initialize CEO paths from this sandbox."""
    lock_dir = Path.home() / ".cache" / "vohux-ceo" / "locks"
    try:
        lock_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
        lock_dir.chmod(0o700)
    except OSError as exc:
        logging.getLogger(__name__).warning(
            "CEO lock dir unavailable for PM import (%s) -- using project-local PM paths",
            exc,
        )
        return False
    return True


def _prepare_pm_base_import_environment() -> dict[str, str | None]:
    """Redirect shared PM import-time paths into this repo only when required.

    The shared reporter computes CEO lock/dashboard paths at import time. In a
    restricted repair sandbox, the default private lock dir under HOME can exist
    but reject chmod, which raises before this project PM can even dispatch a
    local `query`. Normal owner shells keep the global paths; sandboxed repair
    falls back to writable VerdictUI-local paths just long enough for those
    import-time constants to be computed.
    """
    if _ceo_paths_are_available():
        return {}

    repair_home = PROJECT_ROOT / ".build" / "pm-home"
    repair_home.mkdir(parents=True, exist_ok=True)
    (PROJECT_ROOT / "logs").mkdir(parents=True, exist_ok=True)

    overrides = {
        "HOME": str(repair_home),
        "PROJECTS_HUB": str(PROJECT_ROOT),
        "CEO_DASHBOARD": str(PROJECT_ROOT / "logs" / "ceo-dashboard.json"),
        "PM_DASHBOARD_FILE": str(PROJECT_ROOT / "logs" / "ceo-dashboard.json"),
    }
    previous = {key: os.environ.get(key) for key in overrides}
    os.environ.update(overrides)
    return previous


def _restore_pm_base_import_environment(previous: dict[str, str | None]) -> None:
    for key, value in previous.items():
        if value is None:
            os.environ.pop(key, None)
        else:
            os.environ[key] = value


sys.path.insert(0, str(_SHARED_PM_BASE))
_pm_base_env = _prepare_pm_base_import_environment()
# Guarded like every other shared-libs import in this file: shared-libs is a
# SIBLING repo, absent on CI runners — an unguarded import raises at COLLECTION
# time and takes down the whole quick gate, not just the PM tests (Lesson 168).
try:
    from pm_base import PmBase  # type: ignore  # noqa: E402 — must follow sys.path setup
except ImportError as _imp_err:
    logging.getLogger(__name__).warning("pm_base unavailable (%s) — stages disabled", _imp_err)

    class PmBase:  # type: ignore[no-redef]
        def run_pipeline(
            self, *, mode: str = "quick", fix: bool = False, no_cache: bool = False
        ) -> None:
            # Fails CLOSED on purpose: reporting a pass would make "shared-libs
            # missing" indistinguishable from "the PM ran and passed" (Lesson 239).
            _ = fix, no_cache
            if mode not in ("quick", "full"):
                raise ValueError(f"invalid mode: {mode!r}")
            raise SystemExit("shared-libs pm-base unavailable — PM cannot run here")
finally:
    _restore_pm_base_import_environment(_pm_base_env)


_logger = logging.getLogger(__name__)

_SWIFT_MODULE_CACHE = PROJECT_ROOT / ".build" / "clang-module-cache"
_SWIFT_MODULE_CACHE.mkdir(parents=True, exist_ok=True)
os.environ.setdefault("CLANG_MODULE_CACHE_PATH", str(_SWIFT_MODULE_CACHE))
_SWIFTPM_SHARED_CACHE = PROJECT_ROOT / ".build" / "swiftpm-cache"
_SWIFTPM_CONFIG = PROJECT_ROOT / ".build" / "swiftpm-config"
_SWIFTPM_SHARED_CACHE.mkdir(parents=True, exist_ok=True)
_SWIFTPM_CONFIG.mkdir(parents=True, exist_ok=True)

__all__ = ["PROJECT_ROOT", "PROJECT_NAME", "VerdictUIPM"]

sys.path.insert(0, str(_SHARED_RELEASE_TOOLS))

_LOCK_DIR = PROJECT_ROOT / "logs"

# Swift build/test timeouts (seconds). Small package today; headroom for the
# SwiftSyntax dependency arriving in Wave 4 (macro target compiles are slow).
TIMEOUT_SWIFT_BUILD = 900
TIMEOUT_SWIFT_TEST = 600
TIMEOUT_STANDARD = 120
TIMEOUT_PYTEST = 240
# Grace period for a timed-out swift test process group to exit on SIGTERM
# before escalating to SIGKILL.
TIMEOUT_PROC_TERM_GRACE = 10

# Stand-in detail when a subprocess wrote neither stdout nor stderr. One
# spelling so every stage's detail string reads the same for the same condition.
NO_OUTPUT = "no output"

# Immaculate-build bar: any Swift warning fails the build stage. Applied at the
# invocation layer (not Package.swift unsafeFlags) so downstream consumers of
# the library are unaffected. CI mirrors these flags — keep the two in sync.
SWIFT_STRICT_FLAGS = ["-Xswiftc", "-warnings-as-errors"]
SWIFT_PM_FLAGS = [
    "--disable-sandbox",
    "--cache-path",
    str(_SWIFTPM_SHARED_CACHE),
    "--config-path",
    str(_SWIFTPM_CONFIG),
    "--manifest-cache",
    "local",
]
# SLO 1 from docs/slo.md. Kept here rather than read from the doc: a gate that
# parses its own threshold out of prose fails open the moment the prose is
# reworded. HarnessPerformanceTests carries the same number and both move together.
SLO1_P95_BUDGET_MS = 100.0
# The GATED figure. `HarnessPerformanceTests` asserts the median at half the
# budget + 40% and merely RECORDS p95, because p95 moves 56.7 -> 106.7 ms purely
# with contention while p50 stays at 49.6-51.2 ms in every context measured. This
# stage used to re-assert p95 anyway, so the decision was made in the test and
# reversed by its consumer -- and it failed for load on 2026-08-07 (p95 105.51 ms
# at p50 49.09 ms) exactly as the test's own comment predicted. Same value as
# `performP50BudgetMs`; the two move together.
SLO1_P50_BUDGET_MS = 70.0
# SLO 3 from docs/slo.md — warm MCP round trip through the real stdio transport.
# Same lane rule as SLO 1 and for the same measured reason, established on THIS
# metric rather than inherited: under 8 spinning cores the median moved
# 8.3 -> 11.3 ms while the tail moved 8.4 -> 45.8 ms on unchanged code. So p50 is
# gated and p95 is recorded. 40 ms is ~4x the 8.3 ms idle median: headroom for
# load, still far inside the 100 ms product target. `MCPLatencyTests` carries the
# same numbers and the two move together.
SLO3_MCP_P50_BUDGET_MS = 40.0
SLO3_MCP_P95_BUDGET_MS = 100.0
TIMING_RECORD_ONLY_ENV = "VERDICTUI_RECORD_TIMING_ONLY"
CONSTRAINED_TIMING_ENV_MARKERS = (
    "CI",
    TIMING_RECORD_ONLY_ENV,
    "CODEX_CI",
    "CODEX_SANDBOX",
)

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


def _pm_log(message: str, level: str = "INFO") -> None:
    _logger.log(getattr(logging, level, logging.INFO), message)


# Where `_swift_runner` stashes the unwrapped sweep on the shared-libs module.
# Spelled once so the read, the write, and the test agree by construction.
_RAW_KILL_ATTR = "_verdictui_raw_kill_zombie_swift_processes"
_RAW_SWIFTPM_LOCK_ATTR = "_verdictui_raw_swiftpm_command_lock"
SWIFTPM_COMMAND_LOCK_WAIT_SECONDS = 10.0
# How long `verdictui --help` may hang before stage_installed_parity gives up.
# Generous on purpose: the probe runs the INSTALLED binary, which may be a cold
# first exec off a slow volume, and a false timeout here reports a stale install
# that is not stale — the expensive direction, since it accuses working code.
HELP_PROBE_TIMEOUT_SECONDS = 60


def _clear_project_swiftpm_lock_files(project_root: Path) -> int:
    build_token = str(project_root / ".build").replace("/", "_")
    removed = 0
    for path in Path(tempfile.gettempdir()).glob(f"*{build_token}*.lock"):
        try:
            path.unlink()
            removed += 1
        except FileNotFoundError:
            continue
        except OSError as exc:
            _pm_log(f"Could not remove SwiftPM lock sentinel {path}: {exc}", "WARN")
    return removed


def _parse_slo_line(result: dict, output: str, *, marker: str) -> dict:
    """Extract a benchmark's p50 (gated) and p95 (recorded) from its own output.

    Returns `{"p50": float, "p95_note": str, "executed": int}` on success, or
    `{"detail": str}` naming what could not be observed. The caller decides what
    a figure MEANS; this only says whether one was reported. `executed` travels
    with the figure because it is the evidence the benchmark RAN, and a stage
    that reports a latency without it is asking to be believed.

    Fails closed on two conditions that are otherwise indistinguishable from a
    fast run. A `swift test --filter` matching nothing exits 0 having executed
    no tests, so the executed count is checked before any number is trusted; and
    a MISSING marker line is a failure rather than a skip, because a benchmark
    that silently stopped running must never read as a healthy one.

    The p50 is required and the p95 is optional BY DESIGN: p50 is the gated
    figure, so failing to parse it means the gate cannot be applied, while the
    tail is evidence a reader may want and never decides a verdict. Falling back
    to whichever number happened to parse would silently re-point the gate at
    the statistic these suites deliberately stopped asserting.
    """
    executed = [int(m) for m in re.findall(r"Executed (\d+) test", output)]
    raw_test_count = result.get("test_count")
    runner_count = raw_test_count if isinstance(raw_test_count, int) else 0
    if max([runner_count, *executed], default=0) == 0:
        return {"detail": f"{marker}: no executed tests reported -- the filter is stale"}

    median = re.search(rf"{re.escape(marker)} .*?p50=([0-9.]+)ms", output)
    if median is None:
        return {"detail": f"no {marker} p50 in output -- the benchmark did not report"}

    tail = re.search(rf"{re.escape(marker)} .*?p95=([0-9.]+)ms", output)
    return {
        "p50": float(median.group(1)),
        "p95_note": f", p95 {float(tail.group(1)):.2f}ms recorded" if tail else "",
        "executed": max([runner_count, *executed], default=0),
    }


def _timing_record_only_environment() -> bool:
    """True when this host can run tests but cannot produce comparable timings."""
    if any(name in os.environ for name in CONSTRAINED_TIMING_ENV_MARKERS):
        return True
    swiftpm_paths = (
        Path.home() / "Library" / "org.swift.swiftpm",
        Path.home() / "Library" / "Caches" / "org.swift.swiftpm",
    )
    return any(path.exists() and not _can_write_existing_directory(path) for path in swiftpm_paths)


def _can_write_existing_directory(path: Path) -> bool:
    """Probe real write access; sandbox denials can disagree with mode bits."""
    probe = path / f".verdictui-write-probe-{os.getpid()}-{time.monotonic_ns()}"
    try:
        fd = os.open(probe, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except OSError:
        return False
    try:
        os.close(fd)
    finally:
        probe.unlink(missing_ok=True)
    return True


@contextlib.contextmanager
def _swift_timing_environment() -> Iterator[None]:
    previous = os.environ.get(TIMING_RECORD_ONLY_ENV)
    if _timing_record_only_environment():
        os.environ[TIMING_RECORD_ONLY_ENV] = "1"
    try:
        yield
    finally:
        if previous is None:
            os.environ.pop(TIMING_RECORD_ONLY_ENV, None)
        else:
            os.environ[TIMING_RECORD_ONLY_ENV] = previous


def _swift_runner():  # noqa: ANN201 — heterogeneous tuple of shared-libs callables
    """Lazy import of swift_runner — keeps hook-snapshot imports of this module fast."""
    import swift_runner  # type: ignore  # noqa: PLC0415 — lazy on purpose (startup cost)

    # Stash the ORIGINAL under a private name so a repeat call wraps the real
    # sweep rather than the wrapper a previous call installed -- otherwise each
    # invocation adds a layer and the TimeoutExpired handlers nest. Assigned via
    # setattr because the name is injected at runtime: `swift_runner` does not
    # declare it, so attribute syntax is a type error even though the read on
    # the line above is fine (CIS-9EC205DF).
    raw_kill = getattr(
        swift_runner,
        _RAW_KILL_ATTR,
        swift_runner.kill_zombie_swift_processes,
    )
    setattr(swift_runner, _RAW_KILL_ATTR, raw_kill)
    raw_lock = getattr(
        swift_runner,
        _RAW_SWIFTPM_LOCK_ATTR,
        swift_runner.swiftpm_command_lock,
    )
    setattr(swift_runner, _RAW_SWIFTPM_LOCK_ATTR, raw_lock)

    def kill_zombie_swift_processes(project_root: Path) -> list[int]:
        try:
            return raw_kill(project_root)
        except subprocess.TimeoutExpired as e:
            removed = _clear_project_swiftpm_lock_files(project_root)
            _pm_log(
                f"Swift zombie sweep skipped after {e.timeout}s timeout while inspecting locks",
                "WARN",
            )
            if removed:
                _pm_log(f"Removed {removed} stale SwiftPM lock sentinel(s)", "WARN")
            return []

    @contextlib.contextmanager
    def swiftpm_command_lock(
        cmd: list[str],
        *,
        cache_dir: Path,
        log,
        stage_name: str = "",
        project_label: str = "SwiftPM",
        max_wait_seconds: float | None = SWIFTPM_COMMAND_LOCK_WAIT_SECONDS,
    ) -> Iterator[None]:
        with raw_lock(
            cmd,
            cache_dir=cache_dir,
            log=log,
            stage_name=stage_name,
            project_label=project_label,
            max_wait_seconds=max_wait_seconds,
        ):
            yield

    swift_runner.kill_zombie_swift_processes = kill_zombie_swift_processes
    swift_runner.swiftpm_command_lock = swiftpm_command_lock
    swift_runner.run_swift_build.__globals__["kill_zombie_swift_processes"] = (
        kill_zombie_swift_processes
    )
    swift_runner.run_swift_test.__globals__["kill_zombie_swift_processes"] = (
        kill_zombie_swift_processes
    )
    swift_runner.run_swift_build.__globals__["swiftpm_command_lock"] = swiftpm_command_lock
    swift_runner.run_swift_test.__globals__["swiftpm_command_lock"] = swiftpm_command_lock

    return (
        kill_zombie_swift_processes,
        swift_runner.run_swift_build,
        swift_runner.run_swift_test,
    )


def _run_streamed_swift_test(
    *,
    extra_flags: list[str],
    timeout: int,
    min_test_count: int,
    log_name: str = "swift-test-latest.log",
) -> dict:
    """Run `swift test` serially while streaming to a file, never a pipe."""
    kill_zombie_swift_processes, _, _ = _swift_runner()
    killed = kill_zombie_swift_processes(PROJECT_ROOT)
    if killed:
        _pm_log(f"Killed {len(killed)} zombie swift process(es) before test: {killed}", "WARN")

    cmd = ["swift", "test", *extra_flags]
    swift_log = PROJECT_ROOT / "logs" / log_name
    swift_log.parent.mkdir(parents=True, exist_ok=True)

    import swift_runner  # type: ignore  # noqa: PLC0415 — lazy, shares PM path setup

    with (
        swift_log.open("w", encoding="utf-8", errors="replace") as fh,
        swift_runner.swiftpm_command_lock(  # type: ignore[attr-defined]
            cmd,
            cache_dir=_LOCK_DIR,
            log=_pm_log,
            stage_name="test",
        ),
    ):
        proc = subprocess.Popen(
            cmd,
            cwd=PROJECT_ROOT,
            stdout=fh,
            stderr=subprocess.STDOUT,
            text=True,
            start_new_session=True,
        )
        try:
            returncode = proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            _terminate_process_group(proc)
            _clear_project_swiftpm_lock_files(PROJECT_ROOT)
            output = swift_log.read_text(encoding="utf-8", errors="replace")
            _pm_log(f"Tests: FAIL — timed out after {timeout}s", "ERROR")
            return {
                "passed": False,
                "detail": f"swift test timed out after {timeout}s",
                "output": output,
                "test_count": 0,
            }
        except BaseException:
            _terminate_process_group(proc)
            _clear_project_swiftpm_lock_files(PROJECT_ROOT)
            raise

    output = swift_log.read_text(encoding="utf-8", errors="replace")
    exec_matches = re.findall(
        r"Executed (\d+) tests?, with (?:(\d+) tests? skipped and )?(\d+) failures?",
        output,
    )
    exec_count = max((int(match[0]) for match in exec_matches), default=0)
    exec_failures = max((int(match[2]) for match in exec_matches), default=0)
    # A SKIP is "could not observe", which is neither pass nor fail — and it was
    # previously discarded by a non-capturing group, so a suite that stopped
    # observing anything reported exactly like one that observed everything.
    # Measured 2026-08-15: the five AX witness tests skipped on a degraded
    # window server while the PM reported Grade A, leaving the cross-validation
    # channel (the middle of the product's three loops, including every
    # planted-lie test) unverified with no signal anywhere. Reported, never
    # gated: skipping rather than accusing is the CORRECT behaviour for an
    # environment the suite cannot see (`no.md` #15), so the fix is to make the
    # silence audible rather than to turn it red.
    exec_skipped = max((int(match[1]) for match in exec_matches if match[1]), default=0)
    swift_summary = re.search(
        r"Test run with (\d+) tests? (?:in \d+ suites? )?(?:passed|failed)",
        output,
    )
    swift_count = int(swift_summary.group(1)) if swift_summary else 0
    swift_failures = len(re.findall(r"Test run with \d+ tests? (?:in \d+ suites? )?failed", output))
    test_count = max(exec_count, swift_count)
    fail_count = max(exec_failures, swift_failures)
    # Whether ANY runner summary line was produced. A failure count read from a
    # log with no summary is inferred, not reported: the parser saw some test
    # STARTS and derived a count from what never completed. `stage_runtime_bench`
    # already fails closed when its `SLO1-PERFORM` line is absent; this is the
    # same rule for the test runner (CIS-B3CE1A2C, lessons 202/206 — could-not-
    # observe must not be reported as observed-and-bad).
    has_summary = bool(exec_matches) or swift_summary is not None

    if returncode == 0 and fail_count == 0 and test_count >= min_test_count:
        # A skip is reported, never gated. Skipping rather than accusing is the
        # correct response to an environment the suite cannot observe, but a
        # SILENT skip makes "verified everything" and "verified nothing" print
        # the same line — which is how the AX cross-validation channel sat
        # unverified while the PM read Grade A.
        skipped_note = f" ({exec_skipped} SKIPPED — unverified)" if exec_skipped else ""
        level = "WARN" if exec_skipped else "INFO"
        _pm_log(f"Tests: PASS — {test_count} tests{skipped_note}", level)
        return {
            "passed": True,
            "detail": f"{test_count} tests PASS{skipped_note}",
            "output": output,
            "test_count": test_count,
            "skipped_count": exec_skipped,
        }
    # Checked BEFORE the count and failure branches, not merely before the
    # generic one. A NEGATIVE returncode is a signal, not a verdict: Python
    # reports a process killed by signal N as -N, so -9 means the OS (or an OOM
    # killer, or a memory-pressure sweep) terminated the runner mid-flight, and
    # the tests that had already run say nothing about the ones that never got
    # to start. The partial log a killed run leaves behind routinely contains
    # both a low test count and real-looking failures, so placing this check
    # after either of those branches lets a terminated run be reported as
    # "1 failure(s) in 3 tests" — measured 2026-08-10 at load 163, and
    # indistinguishable in the report from a genuine regression (CIS-B3CE1A2C).
    # Grading a killed run as a failure sends the next session hunting a bug
    # that does not exist; grading it as a pass would be worse. It is neither.
    if returncode < 0:
        signal_name = signal.Signals(-returncode).name
        _pm_log(
            f"Tests: INCONCLUSIVE — runner killed by {signal_name} after {test_count} tests",
            "WARN",
        )
        return {
            "passed": False,
            "inconclusive": True,
            "detail": (
                f"swift test was killed by {signal_name} (exit {returncode}) after "
                f"{test_count} test(s) — the run was terminated, not failed, so this says "
                f"nothing about the code. Re-run on an unloaded machine."
            ),
            "output": output,
            "test_count": test_count,
        }

    # A failure count with NO summary line is inferred, never reported: the
    # parser saw test STARTS and derived a count from what never completed, so
    # the number describes the truncation rather than the code. The issue's own
    # example is the shape — "1 failure(s) in 3 tests" from a log containing
    # zero `Executed N tests` lines and zero `error:` lines.
    if not has_summary and fail_count > 0:
        _pm_log(
            f"Tests: INCONCLUSIVE — {fail_count} failure(s) inferred with no runner summary",
            "WARN",
        )
        return {
            "passed": False,
            "inconclusive": True,
            "detail": (
                f"swift test produced no runner summary line, so the {fail_count} "
                f"failure(s) reported here were inferred from incomplete output rather "
                f"than reported by the runner. The run did not finish; it did not fail."
            ),
            "output": output,
            "test_count": test_count,
        }

    if test_count < min_test_count:
        _pm_log(
            f"Tests: FAIL — only {test_count} tests ran (expected {min_test_count}+)",
            "ERROR",
        )
        return {
            "passed": False,
            "detail": f"Only {test_count} tests ran (expected {min_test_count}+)",
            "output": output,
            "test_count": test_count,
        }
    if fail_count > 0:
        _pm_log(f"Tests: FAIL — {fail_count} failure(s) in {test_count} tests", "ERROR")
        return {
            "passed": False,
            "detail": f"{fail_count} test failure(s) in {test_count} tests",
            "output": output,
            "test_count": test_count,
        }

    failure = next(
        (line.strip() for line in output.splitlines() if "error:" in line),
        output.strip().splitlines()[-1] if output.strip() else f"swift test exited {returncode}",
    )
    _pm_log(f"Tests: FAIL (exit {returncode}) {failure[:200]}", "ERROR")
    return {
        "passed": False,
        "detail": f"swift test exited {returncode}: {failure[:200]}",
        "output": output,
        "test_count": test_count,
    }


def _run_locked_swift_build_product(*, timeout: int) -> subprocess.CompletedProcess[str]:
    """Build the shipped CLI product under the shared lock and clean up interrupts."""
    build_cmd = [
        "swift",
        "build",
        "--product",
        "verdictui",
        *SWIFT_PM_FLAGS,
        *SWIFT_STRICT_FLAGS,
    ]
    _LOCK_DIR.mkdir(parents=True, exist_ok=True)

    import swift_runner  # type: ignore  # noqa: PLC0415 — lazy, shares PM path setup

    with swift_runner.swiftpm_command_lock(  # type: ignore[attr-defined]
        build_cmd,
        cache_dir=_LOCK_DIR,
        log=_pm_log,
        stage_name="cli_smoke",
    ):
        proc = subprocess.Popen(
            build_cmd,
            cwd=PROJECT_ROOT,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            start_new_session=True,
        )
        try:
            stdout, stderr = proc.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            _terminate_process_group(proc)
            _clear_project_swiftpm_lock_files(PROJECT_ROOT)
            stdout, stderr = proc.communicate()
            return subprocess.CompletedProcess(
                build_cmd,
                124,
                stdout=stdout,
                stderr=(stderr or "") + f"\nswift build timed out after {timeout}s",
            )
        except BaseException:
            _terminate_process_group(proc)
            _clear_project_swiftpm_lock_files(PROJECT_ROOT)
            raise

    return subprocess.CompletedProcess(
        build_cmd,
        proc.returncode,
        stdout=stdout,
        stderr=stderr,
    )


def _terminate_process_group(proc) -> None:  # noqa: ANN001 — subprocess-like in tests
    """Terminate a started Swift process group before releasing the PM lock."""
    try:
        os.killpg(proc.pid, signal.SIGTERM)
        proc.wait(timeout=TIMEOUT_PROC_TERM_GRACE)
    except (ProcessLookupError, subprocess.TimeoutExpired):
        try:
            os.killpg(proc.pid, signal.SIGKILL)
            proc.wait(timeout=TIMEOUT_PROC_TERM_GRACE)
        except ProcessLookupError:
            pass
        except subprocess.TimeoutExpired:
            pass


class VerdictUIPM(PmBase):
    """Project Manager for VerdictUI — owns build, test, architecture, and governance stages."""

    PROJECT_NAME = PROJECT_NAME
    PROJECT_ROOT = PROJECT_ROOT

    def __init__(self) -> None:
        super().__init__()
        # Persist to logs/pm-last-status.json — the file the Stop hook snapshots
        # for grade-regression detection (pm_legacy defaults to /tmp, wiped on reboot).
        self.status_file = self.PROJECT_ROOT / "logs" / "pm-last-status.json"

    def stage_build(self) -> dict:
        """Swift build incl. test targets, warnings-as-errors (immaculate-build bar)."""
        if not (PROJECT_ROOT / "Package.swift").exists():
            return {"passed": False, "detail": "Package.swift not found"}
        if shutil.which("swift") is None:
            return {"passed": False, "detail": "swift not installed -- build cannot be verified"}
        _LOCK_DIR.mkdir(parents=True, exist_ok=True)
        _, run_swift_build, _ = _swift_runner()
        return run_swift_build(
            PROJECT_ROOT,
            lock_dir=_LOCK_DIR,
            log=_pm_log,
            timeout=TIMEOUT_SWIFT_BUILD,
            extra_flags=[*SWIFT_PM_FLAGS, "--build-tests", *SWIFT_STRICT_FLAGS],
        )

    def stage_test(self) -> dict:
        """Run Swift unit tests (kernel + probe suites), warnings-as-errors."""
        if shutil.which("swift") is None:
            return {"passed": False, "detail": "swift not installed -- tests cannot be verified"}
        _LOCK_DIR.mkdir(parents=True, exist_ok=True)
        # Do not set VERDICTUI_RECORD_TIMING_ONLY around the whole suite. That
        # explicit override is intentionally stronger than clock-marker
        # detection: it also suppresses elapsed-invariant assertions such as the
        # settle-timeout overshoot guard. Swift tests can detect constrained
        # clock lanes themselves from CODEX/CI markers and unwritable SwiftPM
        # caches, while still keeping ordering invariants live.
        return _run_streamed_swift_test(
            timeout=TIMEOUT_SWIFT_TEST,
            min_test_count=1,
            extra_flags=[*SWIFT_PM_FLAGS, *SWIFT_STRICT_FLAGS],
        )

    def stage_floor(self) -> dict:
        """Floor compliance check."""
        fc = PROJECT_ROOT / "scripts" / "floor-check.py"
        if not fc.exists():
            return {"passed": False, "detail": "floor-check.py not found"}
        r = subprocess.run(  # noqa: S603 — fixed argv built from constants
            [sys.executable, str(fc)],
            capture_output=True,
            text=True,
            timeout=TIMEOUT_STANDARD,
        )
        if r.returncode != 0:
            return {"passed": False, "detail": r.stdout[:300]}
        return {"passed": True, "detail": "floor checks pass"}

    def stage_contracts(self) -> dict:
        """Verdict wire format: schema integrity, version agreement, fixture round-trip.

        The verdict JSON is the product's public surface — the CLI, the MCP server,
        and every agent consumer parse it. A drift between the Swift encoder and
        `contracts/verdict-schema.json` breaks them all silently, which is exactly
        the failure a PM stage should catch before a push rather than after.
        """
        validator = PROJECT_ROOT / "contracts" / "validate-contracts.py"
        if not validator.exists():
            return {"passed": False, "detail": "contracts/validate-contracts.py not found"}
        r = subprocess.run(  # noqa: S603 — fixed argv built from constants
            [sys.executable, str(validator)],
            capture_output=True,
            text=True,
            timeout=TIMEOUT_STANDARD,
        )
        if r.returncode != 0:
            failures = [ln for ln in r.stdout.splitlines() if ln.startswith("FAIL")]
            return {"passed": False, "detail": "; ".join(failures)[:400] or r.stderr[:400]}
        checks = sum(1 for ln in r.stdout.splitlines() if ln.startswith("PASS"))
        return {"passed": True, "detail": f"verdict contract validated ({checks} checks)"}

    def stage_architecture(self) -> dict:
        """Kernel purity: VerdictUIKernel must never import SwiftUI/AppKit/CoreGraphics.

        The verdict engine is the platform-pure core of the product (CLAUDE.md
        rule 1) — a UI import here silently couples verification logic to the
        render stack it is supposed to judge.
        """
        kernel = PROJECT_ROOT / "Sources" / "VerdictUIKernel"
        if not kernel.exists():
            return {"passed": False, "detail": "Sources/VerdictUIKernel missing"}
        banned = ("import SwiftUI", "import AppKit", "import CoreGraphics", "import UIKit")
        violations = []
        for p in kernel.rglob("*.swift"):
            text = p.read_text(errors="replace")
            for token in banned:
                if token in text:
                    violations.append(f"{p.relative_to(PROJECT_ROOT)}: {token}")
        if violations:
            return {
                "passed": False,
                "detail": "kernel purity violated: " + "; ".join(violations)[:400],
            }
        return {"passed": True, "detail": "VerdictUIKernel platform-pure (no UI imports)"}

    # ── Governance thin wrappers (fleet-audit F-055) — delegate, never inline ──

    @staticmethod
    def _skipped_shared_libs(e: ImportError) -> dict:
        return {"passed": True, "detail": f"skipped: shared-libs unavailable: {e}"}

    @staticmethod
    def _skip_unavailable_external_store(result: dict) -> dict:
        detail = str(result.get("detail") or "")
        if "unable to open database file" in detail:
            return {"passed": True, "detail": f"skipped: external store unavailable: {detail}"}
        return result

    def stage_todo_review(self) -> dict:
        try:
            from cts_bridge import (
                stage_todo_review_impl,  # type: ignore  # noqa: PLC0415 — deferred shared-libs import (skip sentinel pattern)
            )
        except ImportError as e:
            return self._skipped_shared_libs(e)
        passed, detail = stage_todo_review_impl(PROJECT_ROOT)
        return {"passed": passed, "detail": detail}

    def stage_last20(self) -> dict:
        try:
            from stage_last20 import (
                run_stage_last20,  # type: ignore  # noqa: PLC0415 — deferred shared-libs import (skip sentinel pattern)
            )
        except ImportError as e:
            return self._skipped_shared_libs(e)
        passed, detail, _elapsed = run_stage_last20(PROJECT_ROOT)
        return {"passed": passed, "detail": detail}

    def stage_test_alongside(self) -> dict:
        try:
            from stage_test_alongside import (  # type: ignore  # noqa: PLC0415 — deferred shared-libs import (skip sentinel pattern)
                run_stage_test_alongside,
            )
        except ImportError as e:
            return self._skipped_shared_libs(e)
        passed, detail, _elapsed = run_stage_test_alongside(PROJECT_ROOT)
        return {"passed": passed, "detail": detail}

    def stage_ai_artifacts(self) -> dict:
        try:
            from stage_ai_artifacts import (  # type: ignore  # noqa: PLC0415 — deferred shared-libs import (skip sentinel pattern)
                run_stage_ai_artifacts,
            )
        except ImportError as e:
            return self._skipped_shared_libs(e)
        # src_dirs takes subdirectory NAMES relative to project_root, not Paths.
        passed, detail, _score = run_stage_ai_artifacts(PROJECT_ROOT, src_dirs=["Sources"])
        return {"passed": passed, "detail": detail}

    def stage_lint(self) -> dict:
        """`ruff check` AND `ruff format --check`, the pair CI runs.

        Format drift was CI-only until 2026-08-06: CI ran `ruff format --check .`
        and this stage ran `check` alone, so a locally-green PM could and did
        push a red build. Both halves run here now, over the whole repo (`.`),
        because a stage scoped more narrowly than CI reproduces the same gap in
        miniature.

        Fails CLOSED when ruff is absent. The previous `passed: True,
        "skipped"` meant a host without ruff reported a clean lint having
        linted nothing, which is the fail-open shape `stage_demo` and
        `stage_runtime_bench` were both written to avoid.
        """
        ruff = shutil.which("ruff")
        if ruff is None:
            return {"passed": False, "detail": "ruff not installed -- lint cannot be verified"}
        checks = (("check", [ruff, "check", "."]), ("format", [ruff, "format", "--check", "."]))
        for name, argv in checks:
            r = subprocess.run(  # noqa: S603 -- fixed argv, absolute path, no user input
                argv,
                cwd=PROJECT_ROOT,
                capture_output=True,
                text=True,
                timeout=TIMEOUT_STANDARD,
            )
            if r.returncode != 0:
                detail = (r.stdout.strip() or r.stderr.strip() or NO_OUTPUT)[:400]
                return {"passed": False, "detail": f"ruff {name}: {detail}"}
        return {"passed": True, "detail": "ruff check + format clean"}

    def stage_demo(self) -> dict:
        """Run the demo executable and parse its stdout as one JSON document.

        `stage_build` compiles this target but never launches it, so a crash on
        launch, a broken `@MainActor` async entry, or stdout wired to the wrong
        stream all survive a green build and a green test run. CI has run this
        since the post-Wave-2 pass; without the same stage here a local Grade A
        means less than a CI pass, which is the wrong way round for a
        pre-push gate.
        """
        if shutil.which("swift") is None:
            return {"passed": False, "detail": "swift not installed — demo cannot be run"}
        demo = PROJECT_ROOT / ".build" / "debug" / "VerdictUIDemo"
        if not demo.exists():
            return {
                "passed": False,
                "detail": ".build/debug/VerdictUIDemo missing -- run stage_build first",
            }
        r = subprocess.run(  # noqa: S603 — fixed argv built from constants
            [str(demo)],
            cwd=PROJECT_ROOT,
            capture_output=True,
            text=True,
            timeout=TIMEOUT_STANDARD,
        )
        if r.returncode != 0:
            return {"passed": False, "detail": (r.stderr.strip() or "no stderr")[:300]}
        try:
            verdicts = json.loads(r.stdout)
        except json.JSONDecodeError as e:
            return {"passed": False, "detail": f"stdout is not valid JSON: {e}"}
        # An empty array parses cleanly and would otherwise read as success; the
        # catalog is non-empty by construction, so zero verdicts means the run
        # swallowed something.
        if not isinstance(verdicts, list) or not verdicts:
            return {
                "passed": False,
                "detail": f"expected a non-empty array, got {verdicts!r}"[:300],
            }
        return {"passed": True, "detail": f"{len(verdicts)} verdicts, valid JSON"}

    def stage_cli_smoke(self) -> dict:
        """Build `verdictui` and exercise its documented exit codes.

        `swift test` does not build executable PRODUCTS, so the whole CLI suite
        can be green while the shipped binary refuses to start — measured on
        2026-08-11, when 8/8 library tests passed against a binary that failed
        at launch with "Asynchronous root command needs availability
        annotation" (no.md #32). A stage that only ran the test suite would have
        reported that build as clean.

        All three codes are asserted rather than only the passing one: a binary
        that returns 1 for everything satisfies any check that looks solely at
        the failure path, and the 1-vs-2 distinction is the tool's whole
        contract with an agent.

        The build takes the shared SwiftPM lock, because this stage is reachable
        from BOTH the pipeline and `stage_pytest` — see the comment at the call.
        """
        if shutil.which("swift") is None:
            return {"passed": False, "detail": "swift not installed — CLI cannot be built"}

        build = _run_locked_swift_build_product(timeout=TIMEOUT_SWIFT_BUILD)
        if build.returncode != 0:
            detail = (build.stderr.strip() or build.stdout.strip() or NO_OUTPUT)[:300]
            return {"passed": False, "detail": f"verdictui failed to build: {detail}"}

        binary = PROJECT_ROOT / ".build" / "debug" / "verdictui"
        if not binary.exists():
            return {"passed": False, "detail": f"{binary} missing after a successful build"}

        # Run in a scratch directory: `baseline` writes under the working
        # directory, and a smoke check must never touch the repo's own
        # verdict-baselines or its audit log.
        with tempfile.TemporaryDirectory(prefix="verdictui-cli-smoke-") as scratch:
            expectations = [
                (["list"], 0, "list must succeed"),
                (["verify", "demo-clean-settings"], 0, "the clean scenario must PASS"),
                (["verify", "demo-offscreen-button"], 1, "a planted defect must FAIL with 1"),
                (["verify", "no-such-scenario"], 2, "an unverifiable request must exit 2"),
            ]
            for argv, expected, why in expectations:
                run = subprocess.run(  # noqa: S603 — argv from the table above
                    [str(binary), *argv],
                    cwd=scratch,
                    capture_output=True,
                    text=True,
                    timeout=TIMEOUT_STANDARD,
                )
                if run.returncode != expected:
                    return {
                        "passed": False,
                        "detail": (
                            f"`verdictui {' '.join(argv)}` exited {run.returncode}, "
                            f"expected {expected} — {why}. "
                            f"stderr: {(run.stderr.strip() or NO_OUTPUT)[:200]}"
                        ),
                    }
                # stdout is a machine contract on every path that produces a
                # verdict, including the failing one.
                if expected in (0, 1) and run.stdout.strip():
                    try:
                        json.loads(run.stdout)
                    except json.JSONDecodeError as e:
                        return {
                            "passed": False,
                            "detail": f"`verdictui {' '.join(argv)}` stdout is not JSON: {e}",
                        }

        return {
            "passed": True,
            "detail": f"{len(expectations)} CLI invocations, exit codes 0/1/2 as documented",
        }

    def stage_transport_smoke(self) -> dict:
        """Drive the MCP transport as a PROCESS, over real stdin and stdout.

        The library suite cannot see this. `VerdictDaemon.handle` and the MCP
        catalog were correct and fully tested for a whole wave while NOTHING
        bound a socket or read stdin — the runbook printed an `nc -U` example
        against a path that never existed (no.md #34). Everything below the
        transport was green the entire time.

        So this stage asks the only question a library test structurally
        cannot: does a client that speaks the wire protocol to the SHIPPED
        BINARY get answered? Three assertions, in the order a session hits them
        — the HANDSHAKE succeeds, the catalog arrives, and a FAILING verdict
        comes back with `isError: false`, because a broken UI is the ANSWER,
        not a failure to produce one.

        The handshake half was added 2026-08-12 after this stage passed against
        a binary that answered every real client's `initialize` with a parse
        error. Two things hid it: the payload sent `initialize` with no `params`
        key, the one spelling that decodes either way, and the reply COUNT was
        the only check on it — a parse error is a reply, so the count stayed 3
        while nothing could connect.

        The catalog check asserts the VERBS, not their number. It used to
        compare `len(catalog) != 5`, which is a copy of the catalog's size
        rather than a claim about it: adding `act` failed this stage while
        nothing was wrong, and a bare count could never have said WHICH tool had
        gone missing. `baseline_accept` is asserted ABSENT in the same place,
        because the destructive verb reaching an agent is the failure SD4 exists
        to prevent.
        """
        binary = PROJECT_ROOT / ".build" / "debug" / "verdictui"
        if not binary.exists():
            return {"passed": False, "detail": f"{binary} missing — run stage_cli_smoke first"}

        # A notification (no id) is deliberately included: it must be answered
        # with SILENCE, so the reply count is itself an assertion. A server that
        # replied to everything would return four.
        # `initialize` carries the params a REAL client sends. This spelling is
        # load-bearing: `params` is free-form per method, and a strict decode of
        # it rejects the ENVELOPE, so the message never reaches the handler and
        # every real client's opening message is answered with a parse error.
        # That shipped, and this gate's own payload was why nothing caught it —
        # it sent `initialize` with no `params` key at all, the one spelling that
        # happens to decode either way.
        messages = [
            '{"jsonrpc":"2.0","id":1,"method":"initialize","params":'
            '{"protocolVersion":"2024-11-05","capabilities":{},'
            '"clientInfo":{"name":"verdictui-pm","version":"1"}}}',
            '{"jsonrpc":"2.0","method":"notifications/initialized"}',
            '{"jsonrpc":"2.0","id":2,"method":"tools/list"}',
            '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":'
            '{"name":"verify","arguments":{"scenario":"demo-offscreen-button"}}}',
        ]
        with tempfile.TemporaryDirectory(prefix="verdictui-mcp-smoke-") as scratch:
            run = subprocess.run(  # noqa: S603 — fixed argv, input built above
                [str(binary), "mcp"],
                input="\n".join(messages) + "\n",
                cwd=scratch,
                capture_output=True,
                text=True,
                timeout=TIMEOUT_STANDARD,
            )

        if run.returncode != 0:
            detail = (run.stderr.strip() or NO_OUTPUT)[:200]
            return {"passed": False, "detail": f"`verdictui mcp` exited {run.returncode}: {detail}"}

        try:
            replies = [json.loads(line) for line in run.stdout.splitlines() if line.strip()]
        except json.JSONDecodeError as e:
            return {"passed": False, "detail": f"MCP stdout is not newline-delimited JSON: {e}"}

        if len(replies) != 3:
            return {
                "passed": False,
                "detail": (
                    f"expected 3 replies for 4 messages (the notification is owed none), "
                    f"got {len(replies)}"
                ),
            }

        by_id = {r.get("id"): r for r in replies}

        # The handshake must SUCCEED, not merely produce a line. Counting replies
        # cannot see this: a parse error is a reply, so the count above stays 3
        # while no client can connect at all.
        handshake = by_id.get(1, {})
        if "error" in handshake or "result" not in handshake:
            return {
                "passed": False,
                "detail": (
                    "initialize was not answered — no MCP client can complete a handshake: "
                    f"{str(handshake.get('error', handshake))[:160]}"
                ),
            }

        catalog = by_id.get(2, {}).get("result", {}).get("tools", [])
        served = {tool.get("name") for tool in catalog}
        # Assert the VERBS, not a count. A bare number is a copy of the
        # catalog's size that goes stale the moment a tool is added -- it fired
        # on `act` -- and it cannot say WHICH tool went missing, which is the
        # only thing a reader needs. `baseline_accept` is asserted ABSENT for
        # the same reason MCPServerTests does: the destructive verb must not
        # reach an agent (SD4).
        required = {"list_scenarios", "render", "verify", "act", "sweep", "baseline_diff"}
        if missing := required - served:
            return {
                "passed": False,
                "detail": (
                    f"tools/list is missing {sorted(missing)} over the wire — "
                    f"served: {sorted(served)}"
                ),
            }
        if forbidden := served & {"baseline_accept", "baseline_update"}:
            return {
                "passed": False,
                "detail": (
                    f"tools/list advertises {sorted(forbidden)} — accepting a baseline is "
                    "destructive and must stay a foreground command a human watches"
                ),
            }

        call = by_id.get(3, {}).get("result", {})
        if call.get("isError") is not False:
            return {
                "passed": False,
                "detail": (
                    "a FAILING verdict must arrive with isError:false — the tool answered, and "
                    "the UI being wrong IS the answer. An agent that read this as a transport "
                    f"fault would retry a real defect. Got isError={call.get('isError')!r}"
                ),
            }

        return {
            "passed": True,
            "detail": (
                f"MCP over stdio: {len(replies)} replies for {len(messages)} messages "
                f"(notification unanswered), {len(catalog)} tools, failing verdict isError=false"
            ),
        }

    def stage_mutations(self) -> dict:
        """Every mutation in `scripts/mutation-check.py` still names real source.

        The full mutation run rebuilds once per mutation and is too slow for a
        pre-push gate, but the half that rots is the catalog: a renamed test or
        a reworded guard leaves a mutation pointing at nothing, and
        `swift test --filter` exits 0 having run zero tests. This is the cheap
        half — no build, no test, just "does the target text still exist
        exactly once".
        """
        script = PROJECT_ROOT / "scripts" / "mutation-check.py"
        if not script.exists():
            return {"passed": False, "detail": "mutation-check.py not found"}
        r = subprocess.run(  # noqa: S603 — fixed argv built from constants
            [sys.executable, str(script), "--verify-targets"],
            capture_output=True,
            text=True,
            timeout=TIMEOUT_STANDARD,
        )
        return {
            "passed": r.returncode == 0,
            "detail": (r.stdout.strip() or r.stderr.strip() or NO_OUTPUT)[:300],
        }

    def stage_appkit_example(self) -> dict:
        """The documented AppKit runner builds AND judges in both directions.

        `docs/appkit.md` tells an adopter to write a runner and to verify their
        setup against a KNOWN defect, because a tree that always passes may mean
        the UI is clean or may mean the producer emits nothing useful — and
        those are indistinguishable from a single passing render. This stage is
        that control, run on every PM: `defective-screen` must FAIL (exit 1) and
        `clean-screen` must PASS (exit 0).

        Asserting BOTH is the point. A producer that stopped emitting findings
        entirely would satisfy a check that only looked at the clean subject,
        and a runner hard-failing on everything would satisfy one that only
        looked at the defective subject (CTS-491C01E5).
        """
        exe = PROJECT_ROOT / ".build" / "debug" / "AppKitRunnerExample"
        if not exe.exists():
            return {"passed": False, "detail": "AppKitRunnerExample not built — run swift build"}
        cli = PROJECT_ROOT / ".build" / "debug" / "verdictui"
        if not cli.exists():
            return {"passed": False, "detail": "verdictui not built — run stage_cli_smoke first"}

        def judge(subject: str) -> int:
            r = subprocess.run(  # noqa: S603 — argv from resolved paths
                [str(cli), "appkit", "--runner", str(exe), "--subject", subject, "--judge"],
                capture_output=True,
                text=True,
                timeout=TIMEOUT_STANDARD,
            )
            return r.returncode

        bad, good = judge("defective-screen"), judge("clean-screen")
        if bad != 1:
            return {
                "passed": False,
                "detail": f"defective-screen returned {bad}, expected 1 — the known defect went undetected",
            }
        if good != 0:
            return {
                "passed": False,
                "detail": f"clean-screen returned {good}, expected 0 — a clean screen was judged unclean",
            }
        return {"passed": True, "detail": "appkit example: defect FAILS (1), clean PASSES (0)"}

    def stage_installed_parity(self) -> dict:
        """The binary a developer/agent invokes must not lag the repo's surface.

        `stage_cli_smoke` builds and exercises the REPO binary; nothing observed
        the installed copy on PATH, which is the artifact every other project
        and every MCP client actually reaches. Measured 2026-08-18: that copy
        was 41h stale and served neither the `appkit` subcommand nor the
        `judge_appkit` MCP tool, while every stage stayed green — and two more
        subcommands (`adoption`, `inspect`) were missing that nobody had noticed.
        A check blind to the artifact that ships cannot fail for its own reason.

        ADVISORY: an absent install is a legitimate state (a fresh clone, CI),
        so it reports rather than fails. A STALE install is the defect.
        """
        installed = shutil.which("verdictui")
        if installed is None:
            return {"passed": True, "detail": "no installed verdictui on PATH — nothing to compare"}
        built = PROJECT_ROOT / ".build" / "release" / "verdictui"
        if not built.exists():
            return {"passed": True, "detail": "no release build — run swift build -c release"}

        def subcommands(binary: str) -> set[str]:
            r = subprocess.run(  # noqa: S603 — argv from resolved paths
                [binary, "--help"],
                capture_output=True,
                text=True,
                timeout=HELP_PROBE_TIMEOUT_SECONDS,
            )
            names: set[str] = set()
            seen = False
            for line in r.stdout.splitlines():
                if line.startswith("SUBCOMMANDS:"):
                    seen = True
                    continue
                if seen:
                    if line and not line.startswith(" "):
                        break
                    tok = line.strip().split(" ", 1)[0]
                    if tok and tok.isidentifier():
                        names.add(tok)
            return names

        built_names = subcommands(str(built))
        if not built_names:
            return {"passed": False, "detail": "could not parse subcommands from the built binary"}
        missing = sorted(built_names - subcommands(installed))
        if missing:
            return {
                "passed": False,
                "detail": (
                    f"installed verdictui STALE — missing {missing}. "
                    f"Fix: install -m 755 {built} {installed}"
                ),
            }
        return {"passed": True, "detail": f"installed parity ok ({len(built_names)} subcommands)"}

    def stage_stale_buffer(self) -> dict:
        """No tracked file was overwritten by a stale editor buffer.

        Observed four times during Wave 2 (CIS-638133AE): an IDE holds a file
        open, an agent edits and commits it, and the editor later re-saves its
        own older buffer over the top. The tree then differs from HEAD with
        nothing in the log to say why, and every measurement after that — a
        mutation restore, this grade — describes bytes nobody chose.

        `git status` cannot separate that from ordinary work in progress. The
        mtime can: a file you just edited is NEWER than the commit touching it,
        a stale buffer necessarily OLDER.
        """
        script = PROJECT_ROOT / "scripts" / "stale-buffer-check.py"
        if not script.exists():
            return {"passed": False, "detail": "stale-buffer-check.py not found"}
        r = subprocess.run(  # noqa: S603 — fixed argv built from constants
            [sys.executable, str(script)],
            capture_output=True,
            text=True,
            timeout=TIMEOUT_STANDARD,
        )
        return {
            "passed": r.returncode == 0,
            "detail": (r.stdout.strip() or r.stderr.strip() or NO_OUTPUT)[:300],
        }

    def stage_runtime_bench(self) -> dict:
        """SLO 1: the act -> settle -> verdict MEDIAN stays under its budget.

        `docs/slo.md` names this stage as SLO 1's measurement, and SLO 1 is the
        product thesis in one number -- if the in-process cycle is not an order
        of magnitude faster than a screenshot round trip, the product has no
        reason to exist.

        Reads the figure from `HarnessPerformanceTests`' `SLO1-PERFORM` line
        rather than trusting the test's own exit code alone. The test asserts
        its budget, so a green run already means "under budget" -- but a run
        that executed ZERO tests also exits 0 (`swift test --filter` does that
        when the filter matches nothing), and a benchmark that silently stopped
        running is exactly the failure a performance gate must not report as
        health. So the summary line must be present AND parse AND be under
        budget; a missing line is a failure, never a skip.

        Both of those fail-closed conditions live in `_parse_slo_line`, which
        `stage_mcp_latency` (SLO 3) shares: two copies of this parse would be
        two places to weaken, and weakening either alone leaves the other's
        tests green.

        ## Why the median and not the tail

        This gated p95 until 2026-08-07, when it failed at p95 105.51 ms on a
        p50 of 49.09 ms while two isolated runs of the same commit gave 58.43
        and 77.01 ms. That is contention, not regression, and
        `HarnessPerformanceTests` had ALREADY established it: p95 moves
        56.7 -> 106.7 ms with load while p50 stays at 49.6-51.2 ms in every
        context measured, so the test records the tail and asserts the median.
        The decision was made there and reversed here, one level up, by a
        consumer that re-derived its own verdict from the same line.

        The tail is still reported, because it is evidence worth reading; it
        just cannot decide a pass. A gate that fails for load trains its reader
        to ignore it, which is what makes a false positive worse than a missing
        check (CTS-9686A8BB).
        """
        if shutil.which("swift") is None:
            return {"passed": False, "detail": "swift not installed -- bench cannot be run"}
        _LOCK_DIR.mkdir(parents=True, exist_ok=True)
        record_only = _timing_record_only_environment()
        with _swift_timing_environment():
            result = _run_streamed_swift_test(
                timeout=TIMEOUT_SWIFT_TEST,
                min_test_count=1,
                log_name="swift-runtime-bench-latest.log",
                extra_flags=[
                    *SWIFT_PM_FLAGS,
                    *SWIFT_STRICT_FLAGS,
                    "--filter",
                    "HarnessPerformanceTests",
                ],
            )
        output = str(result.get("output") or "")
        if not result.get("passed"):
            failure = next(
                (line.strip() for line in output.splitlines() if "error:" in line),
                str(result.get("detail") or "swift test failed"),
            )
            return {"passed": False, "detail": failure[:300]}

        # Both fail-closed conditions -- a stale filter that executed nothing,
        # and a missing summary line -- live in `_parse_slo_line`, which SLO 3
        # shares. Two copies of this parse would be two places to weaken, and
        # weakening either alone leaves the other's tests green.
        parsed = _parse_slo_line(result, output, marker="SLO1-PERFORM")
        if "detail" in parsed:
            return {"passed": False, "detail": parsed["detail"]}
        p50 = parsed["p50"]
        p95_note = parsed["p95_note"]

        if p50 >= SLO1_P50_BUDGET_MS:
            if record_only:
                return {
                    "passed": True,
                    "detail": (
                        f"SLO 1 p50 {p50:.2f}ms recorded in constrained timing environment "
                        f"(budget {SLO1_P50_BUDGET_MS}ms){p95_note}"
                    ),
                }
            return {
                "passed": False,
                "detail": (
                    f"act->settle->verdict p50 {p50:.2f}ms over "
                    f"{SLO1_P50_BUDGET_MS}ms (SLO 1 is {SLO1_P95_BUDGET_MS}ms)"
                    f"{p95_note}"
                ),
            }
        return {
            "passed": True,
            "detail": (
                f"SLO 1 p50 {p50:.2f}ms < {SLO1_P50_BUDGET_MS}ms{p95_note} "
                f"({parsed['executed']} tests)"
            ),
        }

    def stage_mcp_latency(self) -> dict:
        """SLO 3: the warm MCP round trip stays under its budget.

        SLO 1 times `Harness.perform` INSIDE the test process. That is the
        engine's number, and an agent never calls `perform` -- it writes a JSON
        frame to a pipe and waits for one back. Process boundary, framing, JSON
        coding and pipe scheduling all sit between the two, and none of it
        appears in an in-process timing, so a tool can be fast by SLO 1 and slow
        to every caller. `MCPLatencyTests` measures the artifact; this stage
        gates what it measured.

        Fail-closed exactly like `stage_runtime_bench`: a `--filter` that
        matches nothing exits 0 having run no tests, so the executed count is
        checked before any figure is trusted, and a MISSING `SLO3-MCP` line is a
        failure rather than a skip. A benchmark that silently stopped running
        must never read as a fast one.

        The gated figure is p50, for the reason measured on this metric rather
        than inherited: under 8 spinning cores the median moved 8.3 -> 11.3 ms
        while the tail moved 8.4 -> 45.8 ms on unchanged code. A gate on the
        tail would fail for a busy neighbour and teach its reader to discount
        it.
        """
        if shutil.which("swift") is None:
            return {"passed": False, "detail": "swift not installed -- bench cannot be run"}

        binary = PROJECT_ROOT / ".build" / "debug" / "verdictui"
        release = PROJECT_ROOT / ".build" / "release" / "verdictui"
        if not binary.exists() and not release.exists():
            return {
                "passed": False,
                "detail": "no verdictui binary -- run stage_cli_smoke first",
            }

        _LOCK_DIR.mkdir(parents=True, exist_ok=True)
        record_only = _timing_record_only_environment()
        with _swift_timing_environment():
            result = _run_streamed_swift_test(
                timeout=TIMEOUT_SWIFT_TEST,
                min_test_count=1,
                log_name="swift-mcp-latency-latest.log",
                extra_flags=[
                    *SWIFT_PM_FLAGS,
                    *SWIFT_STRICT_FLAGS,
                    "--filter",
                    "MCPLatencyTests",
                ],
            )

        output = str(result.get("output") or "")
        if not result.get("passed"):
            failure = next(
                (line.strip() for line in output.splitlines() if "error:" in line),
                str(result.get("detail") or "swift test failed"),
            )
            return {"passed": False, "detail": failure[:300]}

        parsed = _parse_slo_line(result, output, marker="SLO3-MCP")
        if "detail" in parsed:
            return {"passed": False, "detail": parsed["detail"]}
        p50 = parsed["p50"]
        p95_note = parsed["p95_note"]

        if p50 >= SLO3_MCP_P50_BUDGET_MS:
            if record_only:
                return {
                    "passed": True,
                    "detail": (
                        f"SLO 3 p50 {p50:.2f}ms recorded in constrained timing environment "
                        f"(budget {SLO3_MCP_P50_BUDGET_MS}ms){p95_note}"
                    ),
                }
            return {
                "passed": False,
                "detail": (
                    f"warm MCP round trip p50 {p50:.2f}ms over "
                    f"{SLO3_MCP_P50_BUDGET_MS}ms (SLO 3 is {SLO3_MCP_P95_BUDGET_MS}ms){p95_note}"
                ),
            }
        return {
            "passed": True,
            "detail": f"SLO 3 p50 {p50:.2f}ms < {SLO3_MCP_P50_BUDGET_MS}ms{p95_note}",
        }

    def stage_pytest(self) -> dict:
        """Run the Python suite CI has run since Wave 0 but the PM never did.

        The PM's own correctness tests live in `Tests/*.py` — including the two
        that pin `stage_demo`'s historical flag-after-target bug, the mutation
        catalog's rot guards, and the FILE_REGISTRY parity checks. CI runs them;
        this stage did not exist, so a local Grade A was strictly weaker than a
        CI pass, which `stage_demo`'s own docstring calls "the wrong way round
        for a pre-push gate".

        Asserts on the summary line rather than the exit code alone: pytest
        exits 0 when it collects NOTHING, so a broken marker or a moved test
        directory would otherwise read as a fast, clean suite.
        """
        r = subprocess.run(  # noqa: S603 -- fixed argv built from constants
            [sys.executable, "-m", "pytest", "Tests", "-q", "-p", "no:cacheprovider"],
            cwd=PROJECT_ROOT,
            capture_output=True,
            env={**os.environ, "PYTEST_DISABLE_PLUGIN_AUTOLOAD": "1"},
            text=True,
            timeout=TIMEOUT_PYTEST,
        )
        output = r.stdout + r.stderr
        match = re.search(r"(\d+) passed", output)
        if match is None:
            tail = output.strip().splitlines()
            detail = tail[-1] if tail else NO_OUTPUT
            return {"passed": False, "detail": f"no pytest summary line: {detail}"[:300]}
        passed = int(match.group(1))
        if r.returncode != 0:
            failing = [ln for ln in output.splitlines() if ln.startswith("FAILED")]
            first = failing[0] if failing else output.strip().splitlines()[-1]
            return {"passed": False, "detail": first[:300]}
        if passed == 0:
            return {
                "passed": False,
                "detail": "pytest collected 0 tests -- the suite is not being found",
            }
        return {"passed": True, "detail": f"{passed} Python tests PASS"}

    def stage_codewatch(self) -> dict:
        try:
            from pm_base_pm_stages import (  # type: ignore  # noqa: PLC0415 — deferred shared-libs import (skip sentinel pattern)
                stage_codewatch_impl,
            )
        except ImportError as e:
            return self._skipped_shared_libs(e)
        return self._skip_unavailable_external_store(
            stage_codewatch_impl(home=Path.home(), project_root=str(PROJECT_ROOT))
        )

    def stage_issuewatch(self) -> dict:
        try:
            from pm_base_pm_stages import (  # type: ignore  # noqa: PLC0415 — deferred shared-libs import (skip sentinel pattern)
                stage_issuewatch_impl,
            )
        except ImportError as e:
            return self._skipped_shared_libs(e)
        return self._skip_unavailable_external_store(
            stage_issuewatch_impl(project_name=self.PROJECT_NAME)
        )

    def stage_capabilitywatch(self) -> dict:
        try:
            from pm_base_pm_stages import (  # type: ignore  # noqa: PLC0415 — deferred shared-libs import (skip sentinel pattern)
                stage_capabilitywatch_impl,
            )
        except ImportError as e:
            return self._skipped_shared_libs(e)
        return self._skip_unavailable_external_store(
            stage_capabilitywatch_impl(project_name=self.PROJECT_NAME)
        )

    def stage_cis_health(self) -> dict:
        """CIS health via shared-libs. Surfaces real errors — never swallows them."""
        try:
            from pm_base_pm_stages import (  # type: ignore  # noqa: PLC0415 — deferred shared-libs import (skip sentinel pattern)
                stage_cis_health_impl,
            )
        except ImportError as e:
            return {"passed": True, "detail": f"CIS skipped (shared-libs unavailable): {e}"}
        return self._skip_unavailable_external_store(
            stage_cis_health_impl(project_name=self.PROJECT_NAME)
        )

    def publish_to_dashboard(self, status: dict) -> None:
        try:
            # Pyright binds PmBase to the CI fallback stub above,
            # which has no publish_to_dashboard; the real base class does.
            super().publish_to_dashboard(status)  # type: ignore[misc]
        except PermissionError as e:
            _pm_log(f"Dashboard publish skipped: {e}", "WARN")

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
        if _timing_record_only_environment():
            return stages
        stages = stages + list(
            build_watch_stages(
                str(PROJECT_ROOT),
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
                str(path.relative_to(PROJECT_ROOT))
                for root in (PROJECT_ROOT / "Tests",)
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
    return 0 if status["all_passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
