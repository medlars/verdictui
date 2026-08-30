"""Shared state and helpers for the VerdictUI PM.

SINGLE OWNER of every module-level name the PM test suite monkeypatches
(`PROJECT_ROOT`, `_LOCK_DIR`, `_pm_log`, `contention_evidence`, ...). The PM
entrypoint and the stage mixins reach those names through THIS module
(`S.PROJECT_ROOT`), never by a `from ... import` copy: a module attribute is
resolved at call time, so `monkeypatch.setattr(S, name, ...)` is seen
everywhere, while an import-time copy silently stops binding and leaves the
suite green while testing nothing (CTS-6DBFF8C6).
"""

from __future__ import annotations

import logging
import os
import re
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass
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


# PINNED, never `__name__`. The PM entrypoint is loaded by path as
# `verdictui_pm` under pytest and as `__main__` from the CLI, so `__name__`
# already relabelled these records depending on the caller; moving `_pm_log`
# into this module would have relabelled them again, silently, and
# `test_pm_log_routes_through_logging` is the only thing that could notice.
# One spelling so the emitter and every consumer agree by construction.
_logger = logging.getLogger("verdictui_pm")


_SWIFT_MODULE_CACHE = PROJECT_ROOT / ".build" / "clang-module-cache"
_SWIFT_MODULE_CACHE.mkdir(parents=True, exist_ok=True)
os.environ.setdefault("CLANG_MODULE_CACHE_PATH", str(_SWIFT_MODULE_CACHE))
_SWIFTPM_SHARED_CACHE = PROJECT_ROOT / ".build" / "swiftpm-cache"
_SWIFTPM_CONFIG = PROJECT_ROOT / ".build" / "swiftpm-config"
_SWIFTPM_SHARED_CACHE.mkdir(parents=True, exist_ok=True)
_SWIFTPM_CONFIG.mkdir(parents=True, exist_ok=True)


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


# A fleet sweep runs `check.py --all --quick`, which builds ~127 projects
# through the SAME SwiftPM build directory this repo uses. Nothing is written
# to this tree, so `mutation_sweep_in_progress` cannot see it — yet a PM
# sampling the tree during one measures a queue rather than the code.
CONTENTION_PROBE_TIMEOUT_SECONDS = 5
CONTENTION_PROCESS_PATTERNS = (
    # A fleet sweep: ~127 projects through this tree's SwiftPM build dir.
    "check.py --all",
    # A SECOND PM on this same tree. `ceo.py --watch` calls every PM with
    # `--fix` as its "Obligate" step, so this is the commonest contender and
    # the first version of this list was blind to it — measured 2026-08-20
    # with one live for 15+ minutes while the guard read False.
    "verdictui-pm.py",
    # The WATCHER ITSELF, not merely the PM it happens to be driving. Both
    # entries above name THIS project's own processes, so a sweep parked inside
    # a SIBLING project was invisible — measured 2026-08-21, when `ceo.py
    # --watch 30` drove a full SagaMail `swift test --parallel` suite to load
    # average 241.37 while this tree's timing stages ran. One commit (fda4c1d)
    # read 120.23ms contended and 9.63ms exclusive: a 12x swing that filed
    # three P1s naming code that was never slow.
    #
    # What saturates this machine is that the watcher is sweeping AT ALL, never
    # which project it is inside. Keying on the watcher's VICTIM rather than on
    # the watcher is `no.md` #76 recurring one pattern along — a guard built
    # from one observed cause, blind to the commonest one. The comment above
    # already NAMED `ceo.py --watch` as the commonest contender while the code
    # matched something else: a claim in prose that the pattern list did not
    # encode.
    "ceo.py --watch",
)


# Phrases a stage uses when it PASSED WITHOUT OBSERVING ITS SUBJECT. Anchored
# to how the detail OPENS or to a whole phrase, never to a bare "skip"
# substring: `no.md` #58/#62 record 12 suite hits for "skipped" that were test
# NAMES, every one passing, so a substring rule would call a fully-executed
# suite a skip — the same false reading in the opposite direction.
STAGE_SKIP_MARKERS = (
    "not installed — skipped",
    "not installed - skipped",
    "skipped:",
    "nothing to compare",
    "no release build",
    "unavailable:",
)


def stage_result_is_skip(detail: str) -> bool:
    """True when a passing stage says, in its own words, that it measured nothing.

    "Could not measure" and "measured and clean" are opposite states, and a
    reader scans the MARKER, not the detail text. Measured 2026-08-20 on this
    project's own report: `[PASS] watch_testwatch  testwatch: not installed —
    skipped`. The sentence was honest; the [PASS] beside it was not.

    Surfaced by a peer session that found 24 of 52 stages in another project
    reporting PASS while never observing their subject. VerdictUI returns dicts
    rather than that project's 3-tuple contract, so this classifies at the
    RECORDING layer — trusting 47 individual call sites to volunteer a flag is
    what let the divergence exist in the first place.

    Advisory by design: it changes what the reader SEES, never the exit code.
    A skip is not a failure; it is an absence of evidence, and the fix for that
    is to make the absence legible (lesson 202, lesson 206).
    """
    lowered = detail.lower().strip()
    # ANCHOR TO THE START, never a substring anywhere in the line. A stage that
    # observed NOTHING leads with that fact; a stage that RAN and skipped a
    # SUB-check names its measurements first and mentions the skip mid-sentence
    # ("1 tests passed | ... | output anomaly skipped: no samples"). A substring
    # rule marks that partial run as unverified, hiding executing work while
    # claiming to reveal hidden work — the inverse false reading, reported by a
    # peer session 2026-08-20 and then measured live against this classifier.
    head = lowered.split("|", 1)[0].strip()
    return any(head.startswith(marker) or marker in head for marker in STAGE_SKIP_MARKERS)


# A load average is only meaningful against the core count that serves it:
# load 8 is idle on a 64-core host and a 2x queue on a 4-core one. So the
# reportable number is the RATIO, and the threshold is stated once here rather
# than inline at a call site where a second copy could drift (lesson 990).
SEVERE_OVERSUBSCRIPTION = 2.0


@dataclass(frozen=True, slots=True)
class ContentionEvidence:
    """What is competing for this tree, and how hard the machine is working.

    A bare ``True`` cannot separate "one idle sibling process" from "21.7x
    oversubscribed", yet only the second explains an inflated p95 — and that
    distinction is the whole reason a reader consults this guard. Measured
    2026-08-22: `ceo.py --watch 30` (pid 884) swept the fleet at load average
    346.99 on 16 cores while this project's PM ran, and the guard reported the
    same value it would have reported for a single quiet process.

    ``load1`` is Optional because `os.getloadavg()` raises where unsupported.
    A lost reading costs only the number: the contender `pgrep` positively
    found is still reported, because dropping the whole finding would trade a
    real signal for a missing decimal (lesson 202).
    """

    culprit: str
    pids: tuple[str, ...]
    load1: float | None
    cpus: int | None

    @property
    def oversubscription(self) -> float | None:
        """Runnable work per core. None when either input is unknown."""
        if self.load1 is None or not self.cpus:
            return None
        return self.load1 / self.cpus

    @property
    def is_severe(self) -> bool:
        """True only for a MEASURED ratio at or past the threshold.

        Unknown load reads False, never True: a guard that escalates on absent
        evidence is asserting something it did not observe.
        """
        ratio = self.oversubscription
        return ratio is not None and ratio >= SEVERE_OVERSUBSCRIPTION

    def render(self) -> str:
        """A report a reader can act on without re-deriving the measurement."""
        if self.load1 is None or self.cpus is None:
            load = "load average unavailable on this host"
        else:
            ratio = self.oversubscription or 0.0
            verdict = "SEVERE" if self.is_severe else "mild"
            load = (
                f"load average {self.load1:.2f} on {self.cpus} cores "
                f"= {ratio:.1f}x oversubscribed ({verdict})"
            )
        pids = ", ".join(self.pids[:4]) + ("…" if len(self.pids) > 4 else "")
        return (
            f"\n  ⚠ CONTENTION — a red here may be a QUEUE, not a defect.\n"
            f"      contender : {self.culprit}  (pid {pids})\n"
            f"      machine   : {load}\n"
            f"    Timing and build stages measure the queue under contention: this\n"
            f"    project read p50 102.52ms vs 49.80ms exclusive on one commit, and\n"
            f"    120.23ms vs 9.63ms on another — a 12x swing on unchanged code.\n"
            f"    Re-measure on an exclusive tree before filing any of this as a defect:\n"
            f"      git worktree add -q --detach /tmp/wt-verify HEAD\n"
            f"      cd /tmp/wt-verify && python3.14 scripts/verdictui-pm.py --quick\n"
        )


def _current_load() -> tuple[float | None, int | None]:
    """(1-minute load average, core count), each None when unreadable."""
    try:
        load1 = os.getloadavg()[0]
    except OSError, AttributeError:
        return None, None
    return load1, os.cpu_count()


def contention_evidence() -> ContentionEvidence | None:
    """The contender competing for this tree, or None when the tree is ours.

    This is the SINGLE producer of the contention verdict. `tree_is_contended`
    is derived from it rather than re-deriving the answer, because two signals
    answering one question drift apart while each stays green (lesson 990).
    """
    for pattern in CONTENTION_PROCESS_PATTERNS:
        try:
            probe = subprocess.run(  # noqa: S603 — argv is a module constant
                ["pgrep", "-f", pattern],
                capture_output=True,
                text=True,
                timeout=CONTENTION_PROBE_TIMEOUT_SECONDS,
            )
        except OSError, subprocess.SubprocessError:
            continue
        if probe.returncode != 0:
            continue
        # EXCLUDE OURSELVES. `verdictui-pm.py` matches the very process running
        # this check, so without this the PM reports its own existence as
        # contention — permanently True, which is worse than the blind spot it
        # replaced: a guard that always fires teaches its reader to ignore it
        # (no.md #72 — a detector must not fire on its own subject).
        others = tuple(pid for pid in probe.stdout.split() if pid.strip() != str(os.getpid()))
        if others:
            load1, cpus = _current_load()
            return ContentionEvidence(culprit=pattern, pids=others, load1=load1, cpus=cpus)
    return None


def tree_is_contended() -> bool:
    """True while a fleet-wide sweep is competing for this tree's build dir.

    Measured 2026-08-19/20: ten P1s were filed against this project in one day,
    every one of them a `check.py --all --quick` sweep racing this worktree.
    `stage_runtime_bench` read 102.52ms against a 70ms budget while an exclusive
    run of the same commit read 49.80ms; `stage_mcp_latency` read 43.82ms
    against 8.32ms — a 5x swing on unchanged code. Each ticket carried a precise
    file:line citation, and two were RESURRECTED re-files of rows already
    settled for the same cause.

    That is the expensive direction: a fabricated defect is indistinguishable
    from a real one at the point of use, so the next session inherits it as
    fact and re-derives the falsification from scratch. `no.md` #15/#38/#40
    record the same signature three times over.

    This is the CONTENTION half of the sweep guard. `mutation_sweep_in_progress`
    covers a tree being REWRITTEN; this covers a tree being COMPETED FOR, which
    that marker cannot observe because the sweep writes nothing here.

    Fails toward NOISE, never toward silence: if the probe cannot run, the
    answer is "uncontended" so real findings still surface. A guard that
    suppressed reporting whenever it could not measure would be a check that
    cannot fail for its own reason (lesson 202).

    DERIVED, never re-derived: this is a thin read of `contention_evidence()`
    so the predicate and the report can never disagree about one tree. Two
    signals answering the same question is how a producer and a store drift
    apart while both stay green (lesson 990).
    """
    return contention_evidence() is not None


def _documented_mcp_tools() -> set[str]:
    """Tool names the published MCP contract documents as SERVED.

    `stage_transport_smoke` asserts that every one of these answers over the
    real wire. Deriving the set means a newly shipped tool is covered the
    moment it is documented; the alternative — a literal set in the stage —
    is a hand-copied claim about the catalog that goes stale silently. That
    is not hypothetical: the literal it replaced named six verbs and had
    stopped covering `focus`, `judge_appkit` and `actions` as each shipped,
    so the gate could not fail for the three most recently added tools.

    Headings are third-level and backtick-quoted, `name(args)`. One marked NOT SERVED is
    excluded by the same line that says so — `baseline_accept` is documented
    precisely as absent, and asserting it must ANSWER would invert the SD4
    guarantee this stage checks two lines later.

    Returns an empty set when the contract cannot be read, and the caller
    FAILS on that rather than proceeding: a required-set of nothing is
    satisfied by any catalog, including an empty one, so a silent parse
    failure would turn this gate into a check that cannot fail.
    """
    contract = PROJECT_ROOT / "contracts" / "mcp-tools.md"
    try:
        text = contract.read_text(encoding="utf-8")
    except OSError:
        return set()
    tools: set[str] = set()
    for raw in text.splitlines():
        line = raw.strip()
        # Tolerant of whitespace between the marker and the backtick: a literal
        # `startswith("### \x60")` reads the contract's FORMATTING as part of the
        # contract, so `ruff`-style reflow or a hand-typed extra space would
        # empty the required set. That fails CLOSED (the caller errors on an
        # empty parse) but for a reason no message could explain, so the parser
        # accepts what a human would call the same heading.
        if not line.startswith("###") or "NOT SERVED" in line:
            continue
        marker = line[3:].lstrip()
        if not marker.startswith("`"):
            continue
        name = marker[1:].split("(")[0].split("`")[0].strip()
        if name:
            tools.add(name)
    return tools


def _pm_log(message: str, level: str = "INFO") -> None:
    _logger.log(getattr(logging, level, logging.INFO), message)


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


def _verdictui_copies_on_path() -> list[str]:
    """Every verdictui on PATH, not merely the first.

    `shutil.which` returns the FIRST hit, which on a developer machine is the
    developer's own build — in parity by construction, since the session that
    builds also installs it. The copy that SHIPS (a Homebrew tap, a packaged
    install) sits later on PATH and is exactly the one that goes stale
    unnoticed. Measured 2026-08-19: ~/.local/bin matched the repo while the
    tap symlink was four subcommands behind, and the gate reported parity.
    """
    first = shutil.which("verdictui")
    if first is None:
        # The resolver is the authority on whether ANY copy is reachable.
        # Asking it first keeps one seam for both questions and means an
        # absent install stays the advisory state the stage documents.
        return []
    seen: list[str] = [first]
    resolved = {str(Path(first).resolve())}
    for directory in os.environ.get("PATH", "").split(os.pathsep):
        if not directory:
            continue
        candidate = Path(directory) / "verdictui"
        if not candidate.is_file() or not os.access(candidate, os.X_OK):
            continue
        real = str(candidate.resolve())
        if real not in resolved:
            resolved.add(real)
            seen.append(str(candidate))
    return seen


def _reinstall_hint(copy: str, built: Path) -> str:
    """A package-managed copy must never be overwritten in place.

    The Homebrew copy is read-only (-r-xr-xr-x) behind an INSTALL_RECEIPT.json
    and an SBOM; `install -m 755` over its symlink would clobber the tap and
    desync the receipt from what is on disk. That path needs a release, not a
    file copy.
    """
    if "/Cellar/" in str(Path(copy).resolve()) or copy.startswith("/opt/homebrew/"):
        return (
            "Fix: cut a release and `brew upgrade verdictui` — do NOT copy over a tap-managed file."
        )
    return f"Fix: install -m 755 {built} {copy}"
