"""Smoke, parity and mutation-catalog stages for `VerdictUIPM` (SLO benches: `verdictui_pm_bench`).

Same mixin rule as `verdictui_pm_stages`: inherited, never re-exported.
"""

from __future__ import annotations

import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import verdictui_pm_support as S
from verdictui_pm_support import (
    NO_OUTPUT,
    TIMEOUT_PYTEST,
    TIMEOUT_STANDARD,
    TIMEOUT_SWIFT_BUILD,
    _documented_mcp_tools,
    _reinstall_hint,
)
from verdictui_pm_swift import (
    HELP_PROBE_TIMEOUT_SECONDS,
    _run_locked_swift_build_product,
)

sys.path.insert(0, str(Path(__file__).resolve().parent))
from trusted_exe import trusted_exe  # noqa: E402 - vendored sibling

sys.path.insert(0, str(Path(__file__).resolve().parent))

_PYTEST_EVIDENCE_PATH = S.PROJECT_ROOT / "logs" / "pytest-latest.json"
WORKBENCH_NATIVE_TIMEOUT = 40


def _run_workbench_native(arguments, *, cwd, timeout):
    """Share the acceptance wrapper's retained ownership and TERM-first boundary."""
    path = Path(__file__).with_name("workbench-acceptance.py")
    spec = importlib.util.spec_from_file_location("workbench_acceptance_owner", path)
    if spec is None or spec.loader is None:
        raise ValueError("native acceptance process owner unavailable")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.run_owned_command(arguments, cwd=cwd, timeout=timeout)


def _save_pytest_evidence(
    stdout: str, stderr: str, returncode: int | None, *, timed_out: bool
) -> None:
    """Retain the actual child output before reducing it to a dashboard line."""
    path = _PYTEST_EVIDENCE_PATH
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w", encoding="utf-8", dir=path.parent, prefix=".pytest-evidence-", delete=False
        ) as stream:
            temporary = stream.name
            json.dump(
                {
                    "stdout": stdout,
                    "stderr": stderr,
                    "returncode": returncode,
                    "timed_out": timed_out,
                    "timeout_seconds": TIMEOUT_PYTEST,
                },
                stream,
            )
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        temporary = None
    finally:
        if temporary is not None:
            # DELETION-REVIEW: 1) Remove the leftover temporary evidence file when os.replace did not complete, so no partial evidence is left. 2) Consequences: none, the temporary name is only set to None after a successful replace, so this runs only for an unreplaced temp file the same function created; the final evidence file is untouched. 3) Backup: none needed, the temp holds only the evidence being written and the stage will regenerate it. 4) Following steps: the original exception propagates to the PM stage.
            os.unlink(temporary)


class VerdictUISmokeMixin:
    """Smoke, parity and mutation-catalog stages for `VerdictUIPM`."""

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

    def stage_consumer_runner(self) -> dict:
        """Cold compilation plus rebuild/recovery through persistent transports."""
        binary = S.PROJECT_ROOT / ".build/debug/verdictui"
        for mode, marker in (
            ("--cold", "cold external consumer auto-build PASS"),
            ("--reload", "consumer reload PASS: same MCP/daemon PID"),
        ):
            result = subprocess.run(
                [
                    sys.executable,
                    str(S.PROJECT_ROOT / "examples/ConsumerApp/verify-integration.py"),
                    str(binary),
                    mode,
                ],
                cwd=S.PROJECT_ROOT,
                capture_output=True,
                text=True,
                timeout=660,
            )
            if result.returncode != 0 or marker not in result.stdout:
                return {
                    "passed": False,
                    "detail": f"consumer {mode} acceptance failed: "
                    + (result.stderr or result.stdout)[-700:],
                }
        return {
            "passed": True,
            "detail": "cold external consumer and persistent CLI/MCP rebuild/recovery PASS",
        }

    def stage_real_products(self) -> dict:
        """Actual browser/native artifact acceptance; unavailable is not a skip."""
        binary = S.PROJECT_ROOT / ".build/debug/verdictui"
        result = subprocess.run(
            [
                sys.executable,
                str(S.PROJECT_ROOT / "scripts/product-smoke.py"),
                "--binary",
                str(binary),
            ],
            cwd=S.PROJECT_ROOT,
            capture_output=True,
            text=True,
            timeout=360,
        )
        try:
            report = json.loads(result.stdout)
            passed = (
                result.returncode == 0
                and report.get("status") == "PASS"
                and bool(report.get("checks"))
                and bool(report.get("sha256"))
            )
        except json.JSONDecodeError, AttributeError:
            passed = False
        return {
            "passed": passed,
            "detail": "real browser and native CLI/MCP acceptance PASS"
            if passed
            else "real product acceptance failed: " + (result.stderr or result.stdout)[-700:],
        }

    def stage_workbench(self) -> dict:
        """Require layout smoke plus the real packaged native bridge workflow."""
        result = subprocess.run(
            [
                sys.executable,
                str(S.PROJECT_ROOT / "scripts/workbench-smoke.py"),
                str(S.PROJECT_ROOT),
                "--artifact-dir",
                str(S.PROJECT_ROOT / "logs/workbench-smoke"),
            ],
            cwd=S.PROJECT_ROOT,
            capture_output=True,
            text=True,
            timeout=180,
        )
        measured = re.search(
            r"^WORKBENCH SMOKE PASS: ([1-9][0-9]*) passed, 0 failed, 2/2 browser flows complete$",
            result.stdout,
            re.MULTILINE,
        )
        passed = result.returncode == 0 and measured is not None
        if passed:
            try:
                prepared = subprocess.run(
                    [
                        trusted_exe("bash"),
                        str(S.PROJECT_ROOT / "scripts/build-workbench-acceptance.sh"),
                        "debug",
                    ],
                    cwd=S.PROJECT_ROOT,
                    capture_output=True,
                    text=True,
                    timeout=900,
                )
                if prepared.returncode != 0:
                    return {
                        "passed": False,
                        "detail": "native Workbench preparation failed: "
                        + (prepared.stderr or prepared.stdout)[-700:],
                    }
                inputs = json.loads(
                    (S.PROJECT_ROOT / "dist/workbench-acceptance-inputs.json").read_text()
                )
                log_root = S.PROJECT_ROOT / "logs"
                log_root.mkdir(exist_ok=True)
                attempt = tempfile.mkdtemp(prefix="workbench-native-", dir=log_root)
                native = _run_workbench_native(
                    [
                        sys.executable,
                        str(S.PROJECT_ROOT / "scripts/workbench-acceptance.py"),
                        "--app",
                        inputs["app"],
                        "--consumer-runner",
                        inputs["consumer_runner"],
                        "--consumer-build-receipt",
                        inputs["consumer_build_receipt"],
                        "--output",
                        attempt + "/run",
                    ],
                    cwd=S.PROJECT_ROOT,
                    timeout=WORKBENCH_NATIVE_TIMEOUT,
                )
                observed = re.search(
                    r"^WORKBENCH ACCEPTANCE PASS: ([1-9][0-9]*) assertions, 10/10 native phases complete$",
                    native.stdout,
                    re.MULTILINE,
                )
                if native.returncode != 0 or observed is None:
                    return {
                        "passed": False,
                        "detail": "native Workbench acceptance unavailable or failed: "
                        + (native.stderr + "\n" + native.stdout)[-700:],
                    }
                return {
                    "passed": True,
                    "detail": (measured.group(0) if measured else "") + "; " + observed.group(0),
                }
            except (OSError, ValueError, KeyError, subprocess.TimeoutExpired) as error:
                return {
                    "passed": False,
                    "detail": f"native Workbench acceptance unavailable: {error}",
                }
        return {
            "passed": passed,
            "detail": measured.group(0)
            if passed and measured
            else "workbench acceptance failed: " + (result.stderr or result.stdout)[-700:],
        }

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
        # stage_build and stage_cli_smoke exercise debug. A previous release
        # can match a stale install while both lack the command just built.
        built = S.PROJECT_ROOT / ".build" / "debug" / "verdictui"
        if not built.exists():
            return {
                "passed": False,
                "detail": "installed parity unavailable: run stage_build first",
            }

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
                    # Wrapped descriptions align beyond the two-space command
                    # column; their first words are not executable verbs.
                    if line.startswith("   "):
                        continue
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
        timed_out = False
        try:
            r = subprocess.run(  # noqa: S603 -- fixed argv built from constants
                [sys.executable, "-m", "pytest", "Tests", "-q", "-p", "no:cacheprovider"],
                cwd=S.PROJECT_ROOT,
                capture_output=True,
                env={**os.environ, "PYTEST_DISABLE_PLUGIN_AUTOLOAD": "1"},
                text=True,
                timeout=TIMEOUT_PYTEST,
            )
        except subprocess.TimeoutExpired as exc:
            timed_out = True

            def decoded(value: bytes | str | None) -> str:
                return (
                    value.decode("utf-8", errors="replace")
                    if isinstance(value, bytes)
                    else value or ""
                )

            r = subprocess.CompletedProcess(exc.cmd, -1, decoded(exc.stdout), decoded(exc.stderr))
        try:
            _save_pytest_evidence(
                r.stdout, r.stderr, None if timed_out else r.returncode, timed_out=timed_out
            )
        except OSError as exc:
            return {
                "passed": False,
                "detail": f"pytest evidence could not be retained: {exc}"[:300],
            }
        evidence = {"evidence": str(_PYTEST_EVIDENCE_PATH)}
        if timed_out:
            return {
                "passed": False,
                "detail": f"pytest timed out after {TIMEOUT_PYTEST}s",
                **evidence,
            }
        output = r.stdout + r.stderr
        match = re.search(r"(\d+) passed", output)
        if match is None:
            tail = output.strip().splitlines()
            detail = tail[-1] if tail else NO_OUTPUT
            return {
                "passed": False,
                "detail": f"no pytest summary line: {detail}"[:300],
                **evidence,
            }
        passed = int(match.group(1))
        if r.returncode != 0:
            failing = [ln for ln in output.splitlines() if ln.startswith("FAILED")]
            first = failing[0] if failing else output.strip().splitlines()[-1]
            return {"passed": False, "detail": first[:300], **evidence}
        if passed == 0:
            return {
                "passed": False,
                "detail": "pytest collected 0 tests -- the suite is not being found",
                **evidence,
            }
        return {"passed": True, "detail": f"{passed} Python tests PASS", **evidence}
