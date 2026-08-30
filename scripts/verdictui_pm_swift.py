"""SwiftPM invocation for the VerdictUI PM — lock files, runner, streamed test, build.

Owns the three monkeypatched swift entry points (`_swift_runner`,
`_run_streamed_swift_test`, `_clear_project_swiftpm_lock_files`); everything
else it needs comes from `verdictui_pm_support`, and the patched names there
are reached as `S.<name>` so a test patch binds at call time.
"""

from __future__ import annotations

import contextlib
import os
import re
import signal
import subprocess
import tempfile
from collections.abc import Iterator
from pathlib import Path

import verdictui_pm_support as S
from verdictui_pm_support import SWIFT_PM_FLAGS, SWIFT_STRICT_FLAGS, TIMING_RECORD_ONLY_ENV

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
            S._pm_log(f"Could not remove SwiftPM lock sentinel {path}: {exc}", "WARN")
    return removed


@contextlib.contextmanager
def _swift_timing_environment() -> Iterator[None]:
    previous = os.environ.get(TIMING_RECORD_ONLY_ENV)
    if S._timing_record_only_environment():
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
            S._pm_log(
                f"Swift zombie sweep skipped after {e.timeout}s timeout while inspecting locks",
                "WARN",
            )
            if removed:
                S._pm_log(f"Removed {removed} stale SwiftPM lock sentinel(s)", "WARN")
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
    killed = kill_zombie_swift_processes(S.PROJECT_ROOT)
    if killed:
        S._pm_log(f"Killed {len(killed)} zombie swift process(es) before test: {killed}", "WARN")

    cmd = ["swift", "test", *extra_flags]
    swift_log = S.PROJECT_ROOT / "logs" / log_name
    swift_log.parent.mkdir(parents=True, exist_ok=True)

    import swift_runner  # type: ignore  # noqa: PLC0415 — lazy, shares PM path setup

    with (
        swift_log.open("w", encoding="utf-8", errors="replace") as fh,
        swift_runner.swiftpm_command_lock(  # type: ignore[attr-defined]
            cmd,
            cache_dir=S._LOCK_DIR,
            log=S._pm_log,
            stage_name="test",
        ),
    ):
        proc = subprocess.Popen(
            cmd,
            cwd=S.PROJECT_ROOT,
            stdout=fh,
            stderr=subprocess.STDOUT,
            text=True,
            start_new_session=True,
        )
        try:
            returncode = proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            _terminate_process_group(proc)
            _clear_project_swiftpm_lock_files(S.PROJECT_ROOT)
            output = swift_log.read_text(encoding="utf-8", errors="replace")
            S._pm_log(f"Tests: FAIL — timed out after {timeout}s", "ERROR")
            return {
                "passed": False,
                "detail": f"swift test timed out after {timeout}s",
                "output": output,
                "test_count": 0,
            }
        except BaseException:
            _terminate_process_group(proc)
            _clear_project_swiftpm_lock_files(S.PROJECT_ROOT)
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
        S._pm_log(f"Tests: PASS — {test_count} tests{skipped_note}", level)
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
        S._pm_log(
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
        S._pm_log(
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
        S._pm_log(
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
        S._pm_log(f"Tests: FAIL — {fail_count} failure(s) in {test_count} tests", "ERROR")
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
    S._pm_log(f"Tests: FAIL (exit {returncode}) {failure[:200]}", "ERROR")
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
    S._LOCK_DIR.mkdir(parents=True, exist_ok=True)

    import swift_runner  # type: ignore  # noqa: PLC0415 — lazy, shares PM path setup

    with swift_runner.swiftpm_command_lock(  # type: ignore[attr-defined]
        build_cmd,
        cache_dir=S._LOCK_DIR,
        log=S._pm_log,
        stage_name="cli_smoke",
    ):
        proc = subprocess.Popen(
            build_cmd,
            cwd=S.PROJECT_ROOT,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            start_new_session=True,
        )
        try:
            stdout, stderr = proc.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            _terminate_process_group(proc)
            _clear_project_swiftpm_lock_files(S.PROJECT_ROOT)
            stdout, stderr = proc.communicate()
            return subprocess.CompletedProcess(
                build_cmd,
                124,
                stdout=stdout,
                stderr=(stderr or "") + f"\nswift build timed out after {timeout}s",
            )
        except BaseException:
            _terminate_process_group(proc)
            _clear_project_swiftpm_lock_files(S.PROJECT_ROOT)
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
        proc.wait(timeout=S.TIMEOUT_PROC_TERM_GRACE)
    except ProcessLookupError, subprocess.TimeoutExpired:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
            proc.wait(timeout=S.TIMEOUT_PROC_TERM_GRACE)
        except ProcessLookupError:
            pass
        except subprocess.TimeoutExpired:
            pass
