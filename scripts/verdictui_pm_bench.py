"""SLO benchmark stages for `VerdictUIPM`: SLO 1 (in-process act cycle) and SLO 3 (warm MCP).

Same mixin rule as `verdictui_pm_stages`: inherited, never re-exported.
"""

from __future__ import annotations

import shutil

import verdictui_pm_support as S
import verdictui_pm_swift as SW
from verdictui_pm_support import (
    SLO1_P50_BUDGET_MS,
    SLO1_P95_BUDGET_MS,
    SLO3_MCP_P50_BUDGET_MS,
    SLO3_MCP_P95_BUDGET_MS,
    SWIFT_PM_FLAGS,
    SWIFT_STRICT_FLAGS,
    TIMEOUT_SWIFT_TEST,
    _parse_slo_line,
)
from verdictui_pm_swift import _swift_timing_environment


class VerdictUIBenchMixin:
    """SLO benchmark stages for `VerdictUIPM`."""

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
        S._LOCK_DIR.mkdir(parents=True, exist_ok=True)
        record_only = S._timing_record_only_environment()
        with _swift_timing_environment():
            result = SW._run_streamed_swift_test(
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

        binary = S.PROJECT_ROOT / ".build" / "debug" / "verdictui"
        release = S.PROJECT_ROOT / ".build" / "release" / "verdictui"
        if not binary.exists() and not release.exists():
            return {
                "passed": False,
                "detail": "no verdictui binary -- run stage_cli_smoke first",
            }

        S._LOCK_DIR.mkdir(parents=True, exist_ok=True)
        record_only = S._timing_record_only_environment()
        with _swift_timing_environment():
            result = SW._run_streamed_swift_test(
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
