"""Tests for the PM's timing gate: `stage_runtime_bench` and the no-sleeps guard.

Split out of `test_verdictui_pm.py` (CTS-E51CBEEB). SLO 1's gate is its own
subject: every test here targets a way the stage could report health it did not
measure, which is the only failure mode that matters in a performance gate — an
over-budget run is loud, while a gate that silently stops measuring is not.
The lane that decides whether the budget is ASSERTED or merely RECORDED is
`no.md` #13/#15/#17.
"""

import re

import pytest
from pm_test_support import _PROJECT_ROOT, load_pm

# Quick gate: pure-python, sub-second — belongs in the pre-merge gate.
# Without a marker the quick gate selects ZERO tests and reports success (lesson 183).
pytestmark = pytest.mark.quick

_mod = load_pm()
VerdictUIPM = _mod.VerdictUIPM


class TestStageRuntimeBench:
    """SLO 1's gate. Every test here targets a way it could report health it
    did not measure — which is the only failure mode that matters in a
    performance gate, because an over-budget run is loud and a gate that
    stopped measuring is silent."""

    @staticmethod
    def _pm():
        return VerdictUIPM.__new__(VerdictUIPM)

    @staticmethod
    def _fake_swift(monkeypatch, *, stdout: str, returncode: int = 0) -> None:
        """Replace the streaming Swift runner with a canned result."""

        def run_swift_test(**_kwargs):
            executed = [int(m) for m in re.findall(r"Executed (\d+) test", stdout)]
            return {
                "passed": returncode == 0,
                "detail": "swift test failed" if returncode else "swift test passed",
                "output": stdout,
                "test_count": max(executed, default=0),
            }

        monkeypatch.setattr(_mod.shutil, "which", lambda _: "/usr/bin/swift")
        monkeypatch.setattr(_mod, "_timing_record_only_environment", lambda: False)
        monkeypatch.setattr(_mod, "_run_streamed_swift_test", run_swift_test)

    def test_uses_the_streaming_serial_runner_with_the_benchmark_filter(self, monkeypatch) -> None:
        calls = []

        def run_swift_test(**kwargs):
            calls.append(kwargs)
            return {
                "passed": True,
                "detail": "swift test passed",
                "output": "SLO1-PERFORM p50=20.03ms p95=32.23ms n=3\n"
                "Executed 3 tests, with 0 failures\n",
                "test_count": 3,
            }

        monkeypatch.setattr(_mod.shutil, "which", lambda _: "/usr/bin/swift")
        monkeypatch.setattr(_mod, "_timing_record_only_environment", lambda: False)
        monkeypatch.setattr(_mod, "_run_streamed_swift_test", run_swift_test)

        result = self._pm().stage_runtime_bench()

        assert result["passed"], result["detail"]
        assert len(calls) == 1
        kwargs = calls[0]
        assert kwargs["timeout"] == _mod.TIMEOUT_SWIFT_TEST
        assert kwargs["min_test_count"] == 1
        assert kwargs["log_name"] == "swift-runtime-bench-latest.log"
        assert "--parallel" not in kwargs["extra_flags"]
        assert "--filter" in kwargs["extra_flags"]
        assert "HarnessPerformanceTests" in kwargs["extra_flags"]

    def test_over_budget_records_in_a_constrained_timing_environment(self, monkeypatch) -> None:
        self._fake_swift(
            monkeypatch,
            stdout="SLO1-PERFORM p50=118.00ms p95=160.50ms mean=120.00ms max=200.0ms n=150\n"
            "Executed 2 tests, with 0 failures\n",
        )
        monkeypatch.setattr(_mod, "_timing_record_only_environment", lambda: True)

        result = self._pm().stage_runtime_bench()

        assert result["passed"], result["detail"]
        assert "recorded in constrained timing environment" in result["detail"]

    def test_under_budget_passes_and_reports_the_figure(self, monkeypatch) -> None:
        self._fake_swift(
            monkeypatch,
            stdout="SLO1-PERFORM p50=20.03ms p95=32.23ms mean=22.97ms max=89.79ms n=60\n"
            "Executed 2 tests, with 0 failures\n",
        )
        result = self._pm().stage_runtime_bench()
        assert result["passed"], result["detail"]
        assert "32.23ms" in result["detail"]

    def test_over_budget_fails(self, monkeypatch) -> None:
        self._fake_swift(
            monkeypatch,
            stdout="SLO1-PERFORM p50=90.00ms p95=140.50ms mean=95.00ms max=200.0ms n=60\n"
            "Executed 2 tests, with 0 failures\n",
        )
        result = self._pm().stage_runtime_bench()
        assert not result["passed"]
        assert "90.00ms" in result["detail"]

    def test_a_contended_tail_does_not_fail_the_stage(self, monkeypatch) -> None:
        """The figures below are a REAL measurement, not an invented shape:
        the PM run of 2026-08-07 reported exactly this pair while two isolated
        runs of the same commit gave p95 58.43 and 77.01 ms on an unchanged
        p50. `HarnessPerformanceTests` already decided this — it records p95
        and asserts p50, because p95 moves 56.7 -> 106.7 ms purely with
        contention while p50 sits at 49.6-51.2 ms in every context observed.

        The stage re-imposed the tail gate one level up, so the decision held
        in the test and was reversed by its own consumer. A gate that fails
        for load teaches its reader to ignore it, which is the failure mode
        that makes a false positive worse than a missing check."""
        self._fake_swift(
            monkeypatch,
            stdout="SLO1-PERFORM p50=49.09ms p95=105.51ms mean=50.00ms max=140.0ms n=150\n"
            "Executed 2 tests, with 0 failures\n",
        )
        result = self._pm().stage_runtime_bench()
        assert result["passed"], result["detail"]
        # Recorded, so a human reading the log still sees the tail.
        assert "105.51" in result["detail"]

    def test_a_regressed_median_fails_even_with_a_healthy_tail(self, monkeypatch) -> None:
        """The other direction, which is the one that matters: the median is
        the load-stable statistic, so it is the one that can carry a claim
        about the CODE. A p50 over its budget is a regression even when the
        tail happens to look fine, and asserting only the tail would miss it.

        Paired with the test above so 'the stage stopped failing' cannot
        satisfy both — one demands PASS on a contended tail, the other demands
        FAIL on a moved median."""
        self._fake_swift(
            monkeypatch,
            stdout="SLO1-PERFORM p50=88.00ms p95=95.00ms mean=89.00ms max=99.0ms n=150\n"
            "Executed 2 tests, with 0 failures\n",
        )
        result = self._pm().stage_runtime_bench()
        assert not result["passed"]
        assert "88.00ms" in result["detail"]

    def test_a_missing_p50_fails_rather_than_falling_back_to_the_tail(self, monkeypatch) -> None:
        """The gated figure must be the one parsed. A line carrying p95 but no
        p50 means the reporting format moved under the stage, and reading
        whichever number is present would silently re-point the gate at the
        statistic this change exists to stop asserting."""
        self._fake_swift(
            monkeypatch,
            stdout="SLO1-PERFORM p95=32.00ms mean=22.0ms n=150\n"
            "Executed 2 tests, with 0 failures\n",
        )
        result = self._pm().stage_runtime_bench()
        assert not result["passed"]
        assert "did not report" in result["detail"]

    def test_a_missing_summary_line_fails_rather_than_passing_quietly(self, monkeypatch) -> None:
        """The benchmark ran tests but printed no figure. That is not health —
        it means the reporting line was renamed or removed, and a gate that
        treats 'no number' as 'no problem' is exactly the fail-open this
        stage exists to avoid."""
        self._fake_swift(monkeypatch, stdout="Executed 2 tests, with 0 failures\n")
        result = self._pm().stage_runtime_bench()
        assert not result["passed"]
        assert "did not report" in result["detail"]

    def test_zero_executed_tests_fails_even_though_swift_exits_zero(self, monkeypatch) -> None:
        """`swift test --filter` exits 0 when the filter matches nothing. A
        stale filter must read as a broken gate, not as a fast one."""
        self._fake_swift(monkeypatch, stdout="Executed 0 tests, with 0 failures\n")
        result = self._pm().stage_runtime_bench()
        assert not result["passed"]
        assert "no executed tests" in result["detail"]

    def test_no_executed_line_at_all_fails(self, monkeypatch) -> None:
        """Not even a summary line: the runner died or never started."""
        self._fake_swift(monkeypatch, stdout="")
        result = self._pm().stage_runtime_bench()
        assert not result["passed"]

    def test_budget_boundary_is_exclusive(self, monkeypatch) -> None:
        """p50 exactly at its budget fails. The budget reads '<', so a figure
        landing on it is over, and pinning it here stops a later refactor
        turning `>=` into `>` without anyone noticing.

        Asserted on the GATED statistic. It formerly fed the boundary through
        p95, which stopped testing the boundary the moment the gate moved --
        a boundary test aimed at a recorded-only number cannot fail for the
        reason it exists."""
        self._fake_swift(
            monkeypatch,
            stdout=f"SLO1-PERFORM p50={_mod.SLO1_P50_BUDGET_MS:.2f}ms p95=80.0ms n=150\n"
            "Executed 2 tests, with 0 failures\n",
        )
        result = self._pm().stage_runtime_bench()
        assert not result["passed"]

    def test_the_gated_budget_agrees_with_the_swift_test(self) -> None:
        """Two files hold this threshold and neither can see the other, so the
        agreement is only real if something compares them. The Swift test
        spells it `50 * 1.4`; the PM cannot import Swift, so the number is
        duplicated and this test is the joint.

        Without it, moving one and not the other gives a PM that passes a
        median the test rejects (or the reverse) -- and the disagreement is
        invisible from either side, which is exactly how the p95 gate survived
        being retired in the test while the PM kept asserting it."""
        source = (
            _PROJECT_ROOT / "Tests" / "VerdictUIProbeTests" / "HarnessPerformanceTests.swift"
        ).read_text()
        match = re.search(r"performP50BudgetMs:\s*Double\s*=\s*([0-9.]+)\s*\*\s*([0-9.]+)", source)
        assert match is not None, "performP50BudgetMs is no longer spelled as a product"
        swift_budget = float(match.group(1)) * float(match.group(2))
        assert swift_budget == _mod.SLO1_P50_BUDGET_MS, (
            f"the Swift test asserts p50 < {swift_budget} ms but the PM gates at "
            f"{_mod.SLO1_P50_BUDGET_MS} ms — one moved without the other"
        )

    def test_the_swift_and_python_timing_lanes_agree(self) -> None:
        """The same marker class is spelled in two languages that cannot read
        each other, so the agreement is only real if something compares them.

        A marker present on one side only is silent in the expensive direction:
        the forgetful side keeps ASSERTING a median the host cannot hold, which
        is the Codex-sandbox failure (`no.md` #17) -- p50 167.50 ms against a
        70 ms budget on source measuring ~49 ms, and three P1 tickets for a
        regression that did not exist. Same joint as
        ``test_the_gated_budget_agrees_with_the_swift_test``, one level up: that
        pins the number, this pins the set of hosts it applies to.
        """
        # Lives in the LIBRARY, not the probe test target: SLO 3's suite is in a
        # different test target and could otherwise only have had a COPY, which
        # is the drift this type exists to end.
        source = (
            _PROJECT_ROOT / "Sources" / "VerdictUIProbe" / "ConstrainedTimingEnvironment.swift"
        ).read_text()
        block = re.search(r"static let markers = \[(.*?)\]", source, re.DOTALL)
        assert block is not None, "ConstrainedTimingEnvironment.markers is no longer a list literal"
        swift_markers = set(re.findall(r'"([^"]+)"', block.group(1)))

        assert swift_markers == set(_mod.CONSTRAINED_TIMING_ENV_MARKERS), (
            f"Swift marks {sorted(swift_markers)} as timing-constrained but the PM marks "
            f"{sorted(_mod.CONSTRAINED_TIMING_ENV_MARKERS)} — a host in one set and not the "
            "other asserts a budget it cannot hold, or exempts one it can"
        )

    def test_swift_failure_is_surfaced_not_swallowed(self, monkeypatch) -> None:
        self._fake_swift(
            monkeypatch,
            stdout="HarnessPerformanceTests.swift:110: error: p95 over budget\n",
            returncode=1,
        )
        result = self._pm().stage_runtime_bench()
        assert not result["passed"]
        assert "error:" in result["detail"]

    def test_missing_swift_fails_closed(self, monkeypatch) -> None:
        monkeypatch.setattr(_mod.shutil, "which", lambda _: None)
        result = self._pm().stage_runtime_bench()
        assert not result["passed"]
        assert "swift not installed" in result["detail"]

    def test_the_stage_is_registered_in_the_pipeline(self) -> None:
        """A stage that exists but is never run is not a gate. Read the source
        rather than the stage list, which is built inside a method."""
        source = (_PROJECT_ROOT / "scripts" / "verdictui-pm.py").read_text()
        assert '("stage_runtime_bench", self.stage_runtime_bench)' in source

    def test_the_budget_matches_the_published_slo(self) -> None:
        """docs/slo.md is the SSoT for the number. The constant is duplicated
        into the PM deliberately (parsing a threshold out of prose fails open
        when the prose is reworded), so the two must be asserted equal."""
        slo = (_PROJECT_ROOT / "docs" / "slo.md").read_text()
        assert f"< {int(_mod.SLO1_P95_BUDGET_MS)} ms p95" in slo


class TestSharedSLOParse:
    """`_parse_slo_line`, which BOTH SLO gates read their figure through.

    It carries the two fail-closed conditions that separate "measured and fast"
    from "never measured": a `--filter` matching nothing exits 0 having run no
    tests, and a benchmark that stopped reporting emits no marker line. Both
    look exactly like health to a stage that only checks an exit code.

    Tested directly rather than only through the stages because one helper now
    serves two callers: a weakening here is a weakening of both, and a test that
    reached it only via `stage_runtime_bench` would say nothing about SLO 3.
    """

    _GOOD = "Executed 3 tests, with 0 failures\nSLO3-MCP p50=9.61ms p95=10.25ms n=60\n"

    def test_it_reads_the_gated_median_and_records_the_tail(self) -> None:
        parsed = _mod._parse_slo_line({"test_count": 3}, self._GOOD, marker="SLO3-MCP")
        assert parsed["p50"] == 9.61
        assert "10.25ms recorded" in parsed["p95_note"]
        assert parsed["executed"] == 3

    def test_a_filter_that_matched_nothing_is_a_failure_not_a_pass(self) -> None:
        """Zero executed tests must never yield a figure.

        `swift test --filter` exits 0 when the filter matches nothing, so
        without this a renamed test class turns both SLO gates green forever.
        """
        parsed = _mod._parse_slo_line({"test_count": 0}, "Executed 0 tests\n", marker="SLO3-MCP")
        assert "p50" not in parsed
        assert "stale" in parsed["detail"]

    def test_a_missing_marker_line_is_a_failure_not_a_skip(self) -> None:
        """A run that executed tests but reported no figure measured nothing."""
        parsed = _mod._parse_slo_line(
            {"test_count": 3}, "Executed 3 tests, with 0 failures\n", marker="SLO3-MCP"
        )
        assert "p50" not in parsed
        assert "did not report" in parsed["detail"]

    def test_a_missing_tail_does_not_fail_the_parse(self) -> None:
        """p95 is recorded, never gated, so its absence cannot decide a verdict.

        The asymmetry is deliberate: failing here would let a formatting change
        to a NON-decisive figure fail a stage whose gated number parsed fine.
        """
        parsed = _mod._parse_slo_line(
            {"test_count": 1}, "Executed 1 test\nSLO3-MCP p50=9.00ms n=60\n", marker="SLO3-MCP"
        )
        assert parsed["p50"] == 9.0
        assert parsed["p95_note"] == ""

    def test_it_reads_only_its_own_marker(self) -> None:
        """Two SLO lines can share one output; each gate must read its own.

        Without this, a helper matching any `p50=` would let SLO 3 report SLO
        1's median — a number from a different measurement entirely, and one
        that would look plausible in every log.
        """
        both = (
            "Executed 4 tests\n"
            "SLO1-PERFORM p50=49.97ms p95=68.90ms n=150\n"
            "SLO3-MCP p50=9.61ms p95=10.25ms n=60\n"
        )
        assert _mod._parse_slo_line({"test_count": 4}, both, marker="SLO1-PERFORM")["p50"] == 49.97
        assert _mod._parse_slo_line({"test_count": 4}, both, marker="SLO3-MCP")["p50"] == 9.61


class TestStageMCPLatency:
    """SLO 3's gate: the warm MCP round trip through the real stdio transport.

    SLO 1 measures the ENGINE in-process; an agent measures the WIRE. A tool can
    be fast by SLO 1 and slow to every caller, and only this stage can say so.
    """

    def test_it_is_registered_in_the_quick_pipeline(self) -> None:
        pm = VerdictUIPM.__new__(VerdictUIPM)
        names = [name for name, _fn in pm.define_stages("quick")]
        assert "stage_mcp_latency" in names

    def test_it_runs_after_the_stage_that_builds_the_binary(self) -> None:
        """Order is load-bearing: `stage_cli_smoke` builds what this drives.

        Reversed, it would report a missing binary on every clean checkout — a
        failure whose cause is the pipeline rather than the code.
        """
        pm = VerdictUIPM.__new__(VerdictUIPM)
        names = [name for name, _fn in pm.define_stages("quick")]
        assert names.index("stage_cli_smoke") < names.index("stage_mcp_latency")

    def test_it_reports_a_missing_binary_rather_than_passing(self, tmp_path, monkeypatch) -> None:
        """An absent artifact is 'could not observe', never 'observed and fast'."""
        monkeypatch.setattr(_mod, "PROJECT_ROOT", tmp_path)
        pm = VerdictUIPM.__new__(VerdictUIPM)
        result = pm.stage_mcp_latency()
        assert not result["passed"]
        assert "binary" in result["detail"]

    def test_the_gated_budget_agrees_with_the_swift_test(self) -> None:
        """One budget, two languages, and neither can read the other's constant.

        The Swift suite asserts the median and this stage gates it; if the two
        numbers drift, the stage passes runs the test failed, or vice versa —
        and nothing else compares them. Same joint as SLO 1's.
        """
        swift = (
            _PROJECT_ROOT / "Tests" / "VerdictUICLICoreTests" / "MCPLatencyTests.swift"
        ).read_text()
        match = re.search(r"warmP50BudgetMs: Double = ([0-9.]+)", swift)
        assert match is not None, "the Swift budget is no longer a literal — update this test"
        assert float(match.group(1)) == _mod.SLO3_MCP_P50_BUDGET_MS

    def test_the_budget_matches_the_published_slo(self) -> None:
        """docs/slo.md is the SSoT for the published number."""
        slo = (_PROJECT_ROOT / "docs" / "slo.md").read_text()
        assert f"< {int(_mod.SLO3_MCP_P95_BUDGET_MS)} ms p95" in slo

    def test_the_gated_figure_is_the_median_not_the_tail(self) -> None:
        """The tail must not decide a verdict, on this metric by measurement.

        Under 8 spinning cores the median moved 8.3 → 11.3 ms while the tail
        moved 8.4 → 45.8 ms on unchanged code. A gate on p95 would fail for a
        busy neighbour and teach its reader to discount it.
        """
        source = (_PROJECT_ROOT / "scripts" / "verdictui-pm.py").read_text()
        stage = source.split("def stage_mcp_latency")[1].split("\n    def ")[0]
        assert "p50 >= SLO3_MCP_P50_BUDGET_MS" in stage
        assert "p95 >=" not in stage, "the tail must be recorded, never gated"


class TestNoSleepsInHarnessSource:
    """Wave 3 exit gate: zero sleeps anywhere in the harness.

    The product's claim is that verification is deterministic — settle returns
    when the UI is quiet, not when a guessed interval elapses. A `sleep` in
    Sources/ would be that claim quietly abandoned, and it is the single
    easiest thing to add when a test is flaky, which is exactly when it is
    most tempting and most wrong.

    `VerdictClock` is the sanctioned exception: it IMPLEMENTS Swift's `Clock`
    protocol, whose requirement is literally named `sleep(until:tolerance:)`,
    and its whole purpose is to make waiting controllable rather than real.
    """

    _PATTERN = re.compile(r"\b(?:Thread\.sleep|usleep|nanosleep)\b|(?<![.\w])sleep\s*\(")

    def test_no_real_sleeps_outside_the_virtual_clock(self) -> None:
        offenders: list[str] = []
        for path in sorted((_PROJECT_ROOT / "Sources").rglob("*.swift")):
            if path.name == "VerdictClock.swift":
                continue  # implements Clock.sleep by design — see the class docstring
            for number, line in enumerate(path.read_text().splitlines(), start=1):
                code = line.split("//", 1)[0]
                if self._PATTERN.search(code):
                    rel = path.relative_to(_PROJECT_ROOT)
                    offenders.append(f"{rel}:{number}: {line.strip()}")
        assert not offenders, "sleeps found in harness source:\n" + "\n".join(offenders)

    def test_the_detector_actually_fires(self, tmp_path, monkeypatch) -> None:
        """The test above passes on an empty match set, so on its own it cannot
        tell 'no sleeps' from 'the pattern stopped matching'. This plants one."""
        fake = tmp_path / "Sources" / "VerdictUIProbe"
        fake.mkdir(parents=True)
        (fake / "Bad.swift").write_text("func wait() {\n    Thread.sleep(forTimeInterval: 1)\n}\n")
        monkeypatch.setattr(_mod, "PROJECT_ROOT", tmp_path)
        # Re-run the same scan against the planted tree.
        offenders = [
            line
            for path in (tmp_path / "Sources").rglob("*.swift")
            for number, line in enumerate(path.read_text().splitlines(), start=1)
            if self._PATTERN.search(line.split("//", 1)[0])
        ]
        assert offenders, "the sleep detector failed to notice a planted Thread.sleep"


class TestSLODocumentStructure:
    """Every objective in the table has a section explaining it.

    A row without a section is indistinguishable, to a reader, from an
    objective nobody thought hard about — and it is exactly how CTS-1BB886E8
    arose: the doc declared four SLOs in its table and explained only two, so
    an auditor counting `### SLO` headings reported the project as missing
    objectives it had actually defined. Counting one representation and not the
    other is what made a complete document read as an incomplete one.
    """

    _SLO_DOC = _PROJECT_ROOT / "docs" / "slo.md"
    _ROW = re.compile(r"^\|\s*(\d+)\s*\|", re.MULTILINE)
    _HEADING = re.compile(r"^### SLO (\d+)", re.MULTILINE)

    def test_every_table_row_has_its_own_section(self) -> None:
        text = self._SLO_DOC.read_text(encoding="utf-8")
        rows = {int(m.group(1)) for m in self._ROW.finditer(text)}
        headings = {int(m.group(1)) for m in self._HEADING.finditer(text)}

        assert rows, "docs/slo.md declares no SLO table rows at all"
        assert rows == headings, (
            f"SLO table rows {sorted(rows)} and explanatory sections "
            f"{sorted(headings)} disagree — every declared objective needs both"
        )

    def test_the_guard_would_notice_a_missing_section(self) -> None:
        """The control. Without it, the assertion above is satisfied by a
        document with no rows AND no sections — two empty sets are equal."""
        text = "| 1 | A | x | y | z |\n| 2 | B | x | y | z |\n\n### SLO 1 — only one\n"
        rows = {int(m.group(1)) for m in self._ROW.finditer(text)}
        headings = {int(m.group(1)) for m in self._HEADING.finditer(text)}
        assert rows != headings, "the row/section comparison cannot detect a gap"
