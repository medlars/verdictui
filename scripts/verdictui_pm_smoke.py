"""Smoke, parity, mutation-catalog and SLO-benchmark stages for `VerdictUIPM`.

Same mixin rule as `verdictui_pm_stages`: inherited, never re-exported.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

import verdictui_pm_support as S
import verdictui_pm_swift as SW
from verdictui_pm_support import (
    NO_OUTPUT,
    SLO1_P50_BUDGET_MS,
    SLO1_P95_BUDGET_MS,
    SLO3_MCP_P50_BUDGET_MS,
    SLO3_MCP_P95_BUDGET_MS,
    SWIFT_PM_FLAGS,
    SWIFT_STRICT_FLAGS,
    TIMEOUT_PYTEST,
    TIMEOUT_STANDARD,
    TIMEOUT_SWIFT_BUILD,
    TIMEOUT_SWIFT_TEST,
    _documented_mcp_tools,
    _parse_slo_line,
    _reinstall_hint,
)
from verdictui_pm_swift import (
    HELP_PROBE_TIMEOUT_SECONDS,
    _run_locked_swift_build_product,
    _swift_timing_environment,
)


class VerdictUISmokeMixin:
    """Smoke, parity, mutation-catalog and SLO-benchmark stages for `VerdictUIPM`."""

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

        binary = S.PROJECT_ROOT / ".build" / "debug" / "verdictui"
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

        The verb list itself is now READ FROM THE CONTRACT (2026-08-18) rather
        than written here. A hand-copied set is a claim about the catalog with
        nothing keeping the two in step, and this one had already rotted: it
        named six tools and had silently stopped covering `focus`,
        `judge_appkit` and `actions` as each shipped, so the gate could not fail
        for the three most recently added — the ones most likely to break. Same
        shape as the count it replaced, one level up. `_documented_mcp_tools()`
        returning nothing is a FAILURE here, never an empty requirement: a
        required-set of nothing is satisfied by any catalog at all.
        """
        binary = S.PROJECT_ROOT / ".build" / "debug" / "verdictui"
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
        # The required set is READ FROM THE PUBLISHED CONTRACT, never hand-copied
        # here. A literal set is a claim about the catalog that goes stale the
        # moment a tool ships: this one was written with six verbs and silently
        # stopped covering `focus`, `judge_appkit` and `actions` as each landed,
        # so the gate could not fail for the tools most recently added — exactly
        # the ones most likely to break. Deriving it means a new tool is covered
        # the moment it is documented, and a tool that is served but undocumented
        # is caught by its own test in MCPServerTests.
        required = _documented_mcp_tools()
        if not required:
            return {
                "passed": False,
                "detail": (
                    "could not parse any tool from contracts/mcp-tools.md — the gate would "
                    "otherwise pass vacuously, requiring nothing of the served catalog"
                ),
            }
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
        script = S.PROJECT_ROOT / "scripts" / "mutation-check.py"
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
        exe = S.PROJECT_ROOT / ".build" / "debug" / "AppKitRunnerExample"
        if not exe.exists():
            return {"passed": False, "detail": "AppKitRunnerExample not built — run swift build"}
        cli = S.PROJECT_ROOT / ".build" / "debug" / "verdictui"
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
        copies = S._verdictui_copies_on_path()
        if not copies:
            return {"passed": True, "detail": "no installed verdictui on PATH — nothing to compare"}
        built = S.PROJECT_ROOT / ".build" / "release" / "verdictui"
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
                    # A BLANK line closes the block. The original predicate was
                    # `if line and not line.startswith(" ")` — that leading
                    # `line and` SKIPS blanks, so the walk ran straight into the
                    # trailing "See 'verdictui help ...'" footer, which is
                    # indented and whose first token is a valid identifier,
                    # collecting a phantom subcommand named "See" (measured
                    # 2026-08-19 against the live binary). Dropping `line and`
                    # is the whole fix, so it is written as ONE condition: two
                    # cooperating checks would each mask the other's removal.
                    if not line.startswith(" ") or not line.strip():
                        break
                    tok = line.strip().split(" ", 1)[0]
                    if tok and tok.isidentifier():
                        names.add(tok)
            return names

        built_names = subcommands(str(built))
        if not built_names:
            return {"passed": False, "detail": "could not parse subcommands from the built binary"}
        for copy in copies:
            missing = sorted(built_names - subcommands(copy))
            if missing:
                return {
                    "passed": False,
                    "detail": (
                        f"installed verdictui STALE at {copy} — missing {missing}. "
                        f"{_reinstall_hint(copy, built)}"
                    ),
                }
        return {
            "passed": True,
            "detail": f"installed parity ok ({len(built_names)} subcommands, {len(copies)} copies)",
        }

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
        script = S.PROJECT_ROOT / "scripts" / "stale-buffer-check.py"
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
            cwd=S.PROJECT_ROOT,
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
