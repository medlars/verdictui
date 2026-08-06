#!/usr/bin/env python3.14
"""VerdictUI PM. Run: python3.14 scripts/verdictui-pm.py --quick"""

from __future__ import annotations

import json
import logging
import re
import shutil
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path.home() / "Projects/shared-libs/pm-base"))
# Guarded like every other shared-libs import in this file: shared-libs is a
# SIBLING repo, absent on CI runners — an unguarded import raises at COLLECTION
# time and takes down the whole quick gate, not just the PM tests (Lesson 168).
try:
    from pm_base import PmBase  # type: ignore  # noqa: E402 — must follow sys.path setup
except ImportError as _imp_err:
    logging.getLogger(__name__).warning("pm_base unavailable (%s) — stages disabled", _imp_err)

    class PmBase:  # type: ignore[no-redef]
        def run_pipeline(self, mode: str = "quick") -> None:
            # Fails CLOSED on purpose: reporting a pass would make "shared-libs
            # missing" indistinguishable from "the PM ran and passed" (Lesson 239).
            if mode not in ("quick", "full"):
                raise ValueError(f"invalid mode: {mode!r}")
            raise SystemExit("shared-libs pm-base unavailable — PM cannot run here")


_logger = logging.getLogger(__name__)

PROJECT_ROOT = Path(__file__).resolve().parents[1]
PROJECT_NAME = "VerdictUI"

__all__ = ["PROJECT_ROOT", "PROJECT_NAME", "VerdictUIPM"]

sys.path.insert(0, str(Path.home() / "Projects/shared-libs/release-tools"))

_LOCK_DIR = PROJECT_ROOT / "logs"

# Swift build/test timeouts (seconds). Small package today; headroom for the
# SwiftSyntax dependency arriving in Wave 4 (macro target compiles are slow).
TIMEOUT_SWIFT_BUILD = 900
TIMEOUT_SWIFT_TEST = 600
TIMEOUT_STANDARD = 120

# Immaculate-build bar: any Swift warning fails the build stage. Applied at the
# invocation layer (not Package.swift unsafeFlags) so downstream consumers of
# the library are unaffected. CI mirrors these flags — keep the two in sync.
SWIFT_STRICT_FLAGS = ["-Xswiftc", "-warnings-as-errors"]
# SLO 1 from docs/slo.md. Kept here rather than read from the doc: a gate that
# parses its own threshold out of prose fails open the moment the prose is
# reworded. HarnessPerformanceTests carries the same number and both move together.
SLO1_P95_BUDGET_MS = 100.0


def _pm_log(message: str, level: str = "INFO") -> None:
    _logger.log(getattr(logging, level, logging.INFO), message)


def _swift_runner():  # noqa: ANN201 — heterogeneous tuple of shared-libs callables
    """Lazy import of swift_runner — keeps hook-snapshot imports of this module fast."""
    from swift_runner import (  # type: ignore  # noqa: PLC0415 — lazy on purpose (startup cost)
        kill_zombie_swift_processes,
        run_swift_build,
        run_swift_test,
    )

    return kill_zombie_swift_processes, run_swift_build, run_swift_test


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
            extra_flags=["--build-tests", *SWIFT_STRICT_FLAGS],
        )

    def stage_test(self) -> dict:
        """Run Swift unit tests (kernel + probe suites), warnings-as-errors."""
        if shutil.which("swift") is None:
            return {"passed": False, "detail": "swift not installed -- tests cannot be verified"}
        _LOCK_DIR.mkdir(parents=True, exist_ok=True)
        _, _, run_swift_test = _swift_runner()
        return run_swift_test(
            PROJECT_ROOT,
            lock_dir=_LOCK_DIR,
            log=_pm_log,
            timeout=TIMEOUT_SWIFT_TEST,
            min_test_count=1,
            extra_flags=SWIFT_STRICT_FLAGS,
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
                detail = (r.stdout.strip() or r.stderr.strip() or "no output")[:400]
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
        # Flags go BEFORE the target name. `swift run VerdictUIDemo -Xswiftc ...`
        # passes everything after the target to the executable as argv, so the
        # strict flags would be silently dropped — and, because the resulting
        # build configuration differs from `stage_build`'s, the whole package
        # would be recompiled here rather than reusing those products.
        r = subprocess.run(  # noqa: S603 — fixed argv built from constants
            ["swift", "run", *SWIFT_STRICT_FLAGS, "VerdictUIDemo"],
            cwd=PROJECT_ROOT,
            capture_output=True,
            text=True,
            timeout=TIMEOUT_SWIFT_BUILD,
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
            "detail": (r.stdout.strip() or r.stderr.strip() or "no output")[:300],
        }

    def stage_runtime_bench(self) -> dict:
        """SLO 1: act -> settle -> verdict p95 stays under its published budget.

        `docs/slo.md` names this stage as SLO 1's measurement, and SLO 1 is the
        product thesis in one number -- if the in-process cycle is not an order
        of magnitude faster than a screenshot round trip, the product has no
        reason to exist.

        Reads the figure from `HarnessPerformanceTests`' `SLO1-PERFORM` line
        rather than trusting the test's own exit code alone. The test asserts
        its budget, so a green run already means "under 100 ms" -- but a run
        that executed ZERO tests also exits 0 (`swift test --filter` does that
        when the filter matches nothing), and a benchmark that silently stopped
        running is exactly the failure a performance gate must not report as
        health. So the summary line must be present AND parse AND be under
        budget; a missing line is a failure, never a skip.
        """
        if shutil.which("swift") is None:
            return {"passed": False, "detail": "swift not installed -- bench cannot be run"}
        r = subprocess.run(  # noqa: S603 -- fixed argv built from constants
            [
                "swift",
                "test",
                *SWIFT_STRICT_FLAGS,
                "--filter",
                "HarnessPerformanceTests",
            ],
            cwd=PROJECT_ROOT,
            capture_output=True,
            text=True,
            timeout=TIMEOUT_SWIFT_TEST,
        )
        output = r.stdout + r.stderr
        if r.returncode != 0:
            failure = next(
                (line.strip() for line in output.splitlines() if "error:" in line),
                (r.stderr.strip() or "no stderr"),
            )
            return {"passed": False, "detail": failure[:300]}

        # A filter that matched nothing exits 0 having run no tests, so the
        # executed count is checked before the figure is trusted.
        executed = [int(m) for m in re.findall(r"Executed (\d+) test", output)]
        if not executed or max(executed) == 0:
            return {
                "passed": False,
                "detail": "the benchmark reported no executed tests -- filter is stale",
            }

        match = re.search(r"SLO1-PERFORM .*?p95=([0-9.]+)ms", output)
        if match is None:
            return {
                "passed": False,
                "detail": "no SLO1-PERFORM line in output -- the benchmark did not report",
            }
        p95 = float(match.group(1))
        if p95 >= SLO1_P95_BUDGET_MS:
            return {
                "passed": False,
                "detail": f"act->settle->verdict p95 {p95:.2f}ms over SLO 1's {SLO1_P95_BUDGET_MS}ms",
            }
        return {
            "passed": True,
            "detail": f"SLO 1 p95 {p95:.2f}ms < {SLO1_P95_BUDGET_MS}ms ({max(executed)} tests)",
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
            text=True,
            timeout=TIMEOUT_STANDARD,
        )
        output = r.stdout + r.stderr
        match = re.search(r"(\d+) passed", output)
        if match is None:
            tail = output.strip().splitlines()
            detail = tail[-1] if tail else "no output"
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
        return stage_codewatch_impl(home=Path.home(), project_root=str(PROJECT_ROOT))

    def stage_issuewatch(self) -> dict:
        try:
            from pm_base_pm_stages import (  # type: ignore  # noqa: PLC0415 — deferred shared-libs import (skip sentinel pattern)
                stage_issuewatch_impl,
            )
        except ImportError as e:
            return self._skipped_shared_libs(e)
        return stage_issuewatch_impl(project_name=self.PROJECT_NAME)

    def stage_capabilitywatch(self) -> dict:
        try:
            from pm_base_pm_stages import (  # type: ignore  # noqa: PLC0415 — deferred shared-libs import (skip sentinel pattern)
                stage_capabilitywatch_impl,
            )
        except ImportError as e:
            return self._skipped_shared_libs(e)
        return stage_capabilitywatch_impl(project_name=self.PROJECT_NAME)

    def stage_cis_health(self) -> dict:
        """CIS health via shared-libs. Surfaces real errors — never swallows them."""
        try:
            from pm_base_pm_stages import (  # type: ignore  # noqa: PLC0415 — deferred shared-libs import (skip sentinel pattern)
                stage_cis_health_impl,
            )
        except ImportError as e:
            return {"passed": True, "detail": f"CIS skipped (shared-libs unavailable): {e}"}
        return stage_cis_health_impl(project_name=self.PROJECT_NAME)

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
            ("stage_mutations", self.stage_mutations),
            ("stage_runtime_bench", self.stage_runtime_bench),
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
        stages = stages + list(
            build_watch_stages(
                str(PROJECT_ROOT),
                PROJECT_NAME,
                quick=(mode == "quick"),
            )
        )
        return stages


if __name__ == "__main__":
    pm = VerdictUIPM()
    mode = "full" if "--full" in sys.argv else "quick"
    pm.run_pipeline(mode=mode)
