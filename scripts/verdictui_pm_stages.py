"""Build, test, architecture, lint, demo and governance stages for `VerdictUIPM`.

A MIXIN rather than a facade: inheritance leaves every method resolving on
`VerdictUIPM` itself, so existing `monkeypatch.setattr(VerdictUIPM, ...)`
sites keep binding. Re-exporting the methods would move the object a patch
reaches and silently unbind them.
"""

from __future__ import annotations

import json
import shutil
import subprocess
import sys
from pathlib import Path

import verdictui_pm_support as S
import verdictui_pm_swift as SW
from verdictui_pm_support import (
    NO_OUTPUT,
    SWIFT_PM_FLAGS,
    SWIFT_STRICT_FLAGS,
    TIMEOUT_STANDARD,
    TIMEOUT_SWIFT_BUILD,
    TIMEOUT_SWIFT_TEST,
)


class VerdictUIStagesMixin:
    """Build, test, architecture, lint, demo and governance stages for `VerdictUIPM`."""

    # Supplied by `VerdictUIPM`. ANNOTATED, never assigned: a bare annotation
    # states the contract for the type checker and binds nothing at runtime,
    # where an assignment here would be a second copy of a value the entrypoint
    # already owns.
    PROJECT_NAME: str

    def stage_build(self) -> dict:
        """Swift build incl. test targets, warnings-as-errors (immaculate-build bar)."""
        if not (S.PROJECT_ROOT / "Package.swift").exists():
            return {"passed": False, "detail": "Package.swift not found"}
        if shutil.which("swift") is None:
            return {"passed": False, "detail": "swift not installed -- build cannot be verified"}
        S._LOCK_DIR.mkdir(parents=True, exist_ok=True)
        _, run_swift_build, _ = SW._swift_runner()
        return run_swift_build(
            S.PROJECT_ROOT,
            lock_dir=S._LOCK_DIR,
            log=S._pm_log,
            timeout=TIMEOUT_SWIFT_BUILD,
            extra_flags=[*SWIFT_PM_FLAGS, "--build-tests", *SWIFT_STRICT_FLAGS],
        )

    def stage_test(self) -> dict:
        """Run Swift unit tests (kernel + probe suites), warnings-as-errors."""
        if shutil.which("swift") is None:
            return {"passed": False, "detail": "swift not installed -- tests cannot be verified"}
        S._LOCK_DIR.mkdir(parents=True, exist_ok=True)
        # Do not set VERDICTUI_RECORD_TIMING_ONLY around the whole suite. That
        # explicit override is intentionally stronger than clock-marker
        # detection: it also suppresses elapsed-invariant assertions such as the
        # settle-timeout overshoot guard. Swift tests can detect constrained
        # clock lanes themselves from CODEX/CI markers and unwritable SwiftPM
        # caches, while still keeping ordering invariants live.
        return SW._run_streamed_swift_test(
            timeout=TIMEOUT_SWIFT_TEST,
            min_test_count=1,
            extra_flags=[*SWIFT_PM_FLAGS, *SWIFT_STRICT_FLAGS],
        )

    def stage_floor(self) -> dict:
        """Floor compliance check."""
        fc = S.PROJECT_ROOT / "scripts" / "floor-check.py"
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
        validator = S.PROJECT_ROOT / "contracts" / "validate-contracts.py"
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
        kernel = S.PROJECT_ROOT / "Sources" / "VerdictUIKernel"
        if not kernel.exists():
            return {"passed": False, "detail": "Sources/VerdictUIKernel missing"}
        banned = ("import SwiftUI", "import AppKit", "import CoreGraphics", "import UIKit")
        violations = []
        for p in kernel.rglob("*.swift"):
            text = p.read_text(errors="replace")
            for token in banned:
                if token in text:
                    violations.append(f"{p.relative_to(S.PROJECT_ROOT)}: {token}")
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
        passed, detail = stage_todo_review_impl(S.PROJECT_ROOT)
        return {"passed": passed, "detail": detail}

    def stage_last20(self) -> dict:
        try:
            from stage_last20 import (
                run_stage_last20,  # type: ignore  # noqa: PLC0415 — deferred shared-libs import (skip sentinel pattern)
            )
        except ImportError as e:
            return self._skipped_shared_libs(e)
        passed, detail, _elapsed = run_stage_last20(S.PROJECT_ROOT)
        return {"passed": passed, "detail": detail}

    def stage_test_alongside(self) -> dict:
        try:
            from stage_test_alongside import (  # type: ignore  # noqa: PLC0415 — deferred shared-libs import (skip sentinel pattern)
                run_stage_test_alongside,
            )
        except ImportError as e:
            return self._skipped_shared_libs(e)
        passed, detail, _elapsed = run_stage_test_alongside(S.PROJECT_ROOT)
        return {"passed": passed, "detail": detail}

    def stage_ai_artifacts(self) -> dict:
        try:
            from stage_ai_artifacts import (  # type: ignore  # noqa: PLC0415 — deferred shared-libs import (skip sentinel pattern)
                run_stage_ai_artifacts,
            )
        except ImportError as e:
            return self._skipped_shared_libs(e)
        # src_dirs takes subdirectory NAMES relative to project_root, not Paths.
        passed, detail, _score = run_stage_ai_artifacts(S.PROJECT_ROOT, src_dirs=["Sources"])
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
                cwd=S.PROJECT_ROOT,
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
        demo = S.PROJECT_ROOT / ".build" / "debug" / "VerdictUIDemo"
        if not demo.exists():
            return {
                "passed": False,
                "detail": ".build/debug/VerdictUIDemo missing -- run stage_build first",
            }
        r = subprocess.run(  # noqa: S603 — fixed argv built from constants
            [str(demo)],
            cwd=S.PROJECT_ROOT,
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

    def stage_codewatch(self) -> dict:
        try:
            from pm_base_pm_stages import (  # type: ignore  # noqa: PLC0415 — deferred shared-libs import (skip sentinel pattern)
                stage_codewatch_impl,
            )
        except ImportError as e:
            return self._skipped_shared_libs(e)
        return self._skip_unavailable_external_store(
            stage_codewatch_impl(home=Path.home(), project_root=str(S.PROJECT_ROOT))
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
            return {
                "passed": False,
                "detail": f"could not observe — CIS skipped (shared-libs unavailable): {e}",
            }
        return self._skip_unavailable_external_store(
            stage_cis_health_impl(project_name=self.PROJECT_NAME)
        )
