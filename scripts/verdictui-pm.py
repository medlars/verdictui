#!/usr/bin/env python3.14
"""VerdictUI PM. Run: python3.14 scripts/verdictui-pm.py --quick"""

from __future__ import annotations

import logging
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
TIMEOUT_WHICH_PROBE = 5
TIMEOUT_SWIFT_BUILD = 900
TIMEOUT_SWIFT_TEST = 600
TIMEOUT_STANDARD = 120


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
        """Swift package build including test targets (stage_test then only runs)."""
        if not (PROJECT_ROOT / "Package.swift").exists():
            return {"passed": False, "detail": "Package.swift not found"}
        swift = subprocess.run(  # noqa: S603,S607 — fixed argv, no user input
            ["which", "swift"], capture_output=True, timeout=TIMEOUT_WHICH_PROBE
        )
        if swift.returncode != 0:
            return {"passed": True, "detail": "swift not installed — build skipped"}
        _LOCK_DIR.mkdir(parents=True, exist_ok=True)
        _, run_swift_build, _ = _swift_runner()
        return run_swift_build(
            PROJECT_ROOT,
            lock_dir=_LOCK_DIR,
            log=_pm_log,
            timeout=TIMEOUT_SWIFT_BUILD,
            extra_flags=["--build-tests"],
        )

    def stage_test(self) -> dict:
        """Run Swift unit tests (kernel + probe suites)."""
        swift = subprocess.run(  # noqa: S603,S607 — fixed argv, no user input
            ["which", "swift"], capture_output=True, timeout=TIMEOUT_WHICH_PROBE
        )
        if swift.returncode != 0:
            return {"passed": True, "detail": "swift not installed — test skipped"}
        _LOCK_DIR.mkdir(parents=True, exist_ok=True)
        _, _, run_swift_test = _swift_runner()
        return run_swift_test(
            PROJECT_ROOT,
            lock_dir=_LOCK_DIR,
            log=_pm_log,
            timeout=TIMEOUT_SWIFT_TEST,
            min_test_count=1,
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
        """ruff check on the project root (PM/scripts are Python). Skips if not installed."""
        if shutil.which("ruff") is None:
            return {"passed": True, "detail": "ruff not installed; skipped"}
        r = subprocess.run(  # noqa: S603 — fixed argv, no user input
            ["ruff", "check", "."],  # noqa: S607 — presence guarded by shutil.which above
            cwd=PROJECT_ROOT,
            capture_output=True,
            text=True,
            timeout=TIMEOUT_STANDARD,
        )
        return {
            "passed": r.returncode == 0,
            "detail": (r.stdout.strip() or "clean")[:500],
        }

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
            ("stage_architecture", self.stage_architecture),
            ("stage_ai_artifacts", self.stage_ai_artifacts),
            ("stage_todo_review", self.stage_todo_review),
            ("stage_last20", self.stage_last20),
            ("stage_test_alongside", self.stage_test_alongside),
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
