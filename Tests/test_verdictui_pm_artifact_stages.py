"""Subprocess-level PM stages: the ones that drive the BUILT ARTIFACT.

Split out of `test_verdictui_pm.py` (CTS-6E588C14) along a seam the code
already had, not at an arbitrary line number. Everything here shares one
property that nothing in the parent file does: it exercises a stage whose
subject is a **process** — the compiled `verdictui` binary, its unix socket,
its stdio MCP transport — rather than the PM's own Python behaviour.

That distinction is the whole reason these stages exist. `no.md` #32 records
what happens without them: the library suite was 8/8 GREEN against a binary
that could not execute a single command, because the defect was in how the
process STARTS and no in-process test can observe that.

The shared fixtures come from `pm_test_support`, which is the module the parent
file and four others already load the PM through — so the split moves tests
without duplicating a loader, and `_pm_log` keeps emitting under the
`verdictui_pm` logger name (the trap that reverted an earlier split of the PM
itself, `no.md` #22).
"""

import inspect
import json
import shlex
import signal
import subprocess
import sys
import time
import types
from pathlib import Path

import pytest
from pm_test_support import _needs_dev_machine, load_pm

pytestmark = pytest.mark.quick

_mod = load_pm()
VerdictUIPM = _mod.VerdictUIPM

# Resolved from this file rather than from the PM module, whose PROJECT_ROOT the
# fixtures below deliberately monkeypatch away.
_REPO_ROOT = Path(__file__).resolve().parents[1]


class TestStageCLISmoke:
    """The stage that runs the BUILT binary rather than the test suite."""

    def test_it_hard_fails_when_swift_is_missing(self, monkeypatch) -> None:
        monkeypatch.setattr(_mod.shutil, "which", lambda _: None)
        pm = VerdictUIPM.__new__(VerdictUIPM)
        result = pm.stage_cli_smoke()
        assert not result["passed"]
        assert "swift not installed" in result["detail"]

    def test_the_build_takes_the_shared_swiftpm_lock(self) -> None:
        """This stage's `swift build` must serialize against the Swift stages.

        It is reachable from BOTH the pipeline and `stage_pytest` — the test
        below drives it — so one PM run can invoke it while its own Swift stage
        holds the package's single build directory. Measured 2026-08-12: that
        produced **Grade B on a clean tree at 629/629 green**, with the stage
        naming a test that passes in isolation. A gate failing for the
        environment rather than the code teaches its reader to discount it
        (`no.md` #15), and "it passed on retry" is not a diagnosis.

        Read as source rather than by running: the failure needs two concurrent
        SwiftPM invocations to reproduce, which a unit test cannot stage
        deterministically. What CAN be asserted is that the lock is taken.
        """
        stage_source = inspect.getsource(VerdictUIPM.stage_cli_smoke)
        helper_source = inspect.getsource(_mod._run_locked_swift_build_product)
        assert "_run_locked_swift_build_product" in stage_source
        assert "swiftpm_command_lock" in helper_source, (
            "stage_cli_smoke builds without the shared SwiftPM lock, so it "
            "contends with a concurrent swift test for the build directory"
        )
        lock_at = helper_source.index("swiftpm_command_lock")
        build_at = helper_source.index("subprocess.Popen")
        assert lock_at < build_at, "the lock must be acquired BEFORE the build runs"

    def test_an_interrupted_build_kills_the_child_before_releasing_the_lock(
        self, monkeypatch, tmp_path
    ) -> None:
        """Ctrl-C during CLI build must not leave SwiftPM holding `.build`."""
        _link_contract_into(tmp_path)
        monkeypatch.setattr(_mod, "PROJECT_ROOT", tmp_path)
        monkeypatch.setattr(_mod, "_LOCK_DIR", tmp_path / ".lock")

        class _FakeProc:
            pid = 4242

            def communicate(self, timeout=None):  # noqa: ARG002 — signature parity
                raise KeyboardInterrupt

            def wait(self, timeout=None):  # noqa: ARG002 — signature parity
                return 0

        fake_swift_runner = types.SimpleNamespace(
            swiftpm_command_lock=lambda *_a, **_k: _mod.contextlib.nullcontext()
        )
        kills = []
        cleaned = []
        monkeypatch.setattr(_mod.subprocess, "Popen", lambda *_a, **_k: _FakeProc())
        monkeypatch.setattr(_mod.os, "killpg", lambda pid, sig: kills.append((pid, sig)))

        def _record_cleanup(root) -> int:
            """Record the cleaned root and report zero files removed.

            Spelled as a def rather than `lambda root: cleaned.append(root) or 0`.
            That idiom works — `append` returns None, so `or 0` yields the int the
            real function returns — but it reads as a bug and a type checker calls
            it one ("append of list does not return a value"), which is a finding
            a reader has to re-derive every time they meet it.
            """
            cleaned.append(root)
            return 0

        monkeypatch.setattr(_mod, "_clear_project_swiftpm_lock_files", _record_cleanup)
        monkeypatch.setitem(sys.modules, "swift_runner", fake_swift_runner)

        with pytest.raises(KeyboardInterrupt):
            _mod._run_locked_swift_build_product(timeout=60)

        assert kills == [(4242, signal.SIGTERM)]
        assert cleaned == [tmp_path]

    def test_it_is_registered_in_the_quick_pipeline(self) -> None:
        """`swift test` does not build executable PRODUCTS, so without this
        stage a Grade A says nothing about whether the shipped binary starts —
        measured 2026-08-11, when 8/8 CLI tests passed against a binary that
        failed at launch (no.md #32)."""
        pm = VerdictUIPM.__new__(VerdictUIPM)
        names = [name for name, _fn in pm.define_stages("quick")]
        assert "stage_cli_smoke" in names

    @_needs_dev_machine
    def test_it_passes_against_the_real_binary(self) -> None:
        pm = VerdictUIPM.__new__(VerdictUIPM)
        result = pm.stage_cli_smoke()
        assert result["passed"], result["detail"]
        assert "exit codes 0/1/2" in result["detail"]


def _link_contract_into(root) -> None:
    """Copy the real MCP contract under a fixture root.

    These fixtures repoint `PROJECT_ROOT` at a tmp dir so the stage finds a STUB
    BINARY rather than the built one. The stage also reads its required-verb set
    from `contracts/mcp-tools.md` under that same root, so without this the
    contract is absent and the stage fails for a reason no fixture intended —
    which reads exactly like the stage being broken.

    The real file is copied rather than a fake written, so a fixture cannot
    quietly disagree with the contract the product ships.
    """
    contract = _REPO_ROOT / "contracts" / "mcp-tools.md"
    target = root / "contracts"
    target.mkdir(parents=True, exist_ok=True)
    (target / "mcp-tools.md").write_text(contract.read_text(encoding="utf-8"), encoding="utf-8")


def _served_tools() -> list[dict]:
    """The tool catalog a healthy binary advertises.

    Spelled once and shared by both fixtures so the bad-handshake test and its
    control differ in exactly ONE reply. A fixture that also served the wrong
    catalog would fail for two reasons at once, and the test could no longer
    show which one the stage actually caught.

    DERIVED FROM THE CONTRACT (2026-08-18), never listed here. A literal list
    was the same hand-copied claim the stage itself used to carry, and it rots
    the same way: it named six verbs and had already stopped covering `focus`,
    `judge_appkit` and `actions`. Worse in a FIXTURE than in the stage — a
    healthy-catalog fixture missing a real verb makes the control fail for a
    reason the test never intended, which reads as the stage being broken.
    """
    return [{"name": name} for name in sorted(_mod._documented_mcp_tools())]


class TestStageTransportSmoke:
    """The stage that speaks the MCP wire protocol to the shipped binary.

    The library suite structurally cannot answer this question. `MCPServer` and
    `VerdictDaemon.handle` were correct and fully tested for a whole wave while
    nothing read stdin or bound a socket — the runbook printed an `nc -U`
    example against a path that never existed (no.md #34).
    """

    def test_it_reports_a_missing_binary_rather_than_passing(self, tmp_path, monkeypatch) -> None:
        """An absent binary is 'could not observe', never 'observed and fine'.

        The fail-open this closes: a stage that skipped when the artifact was
        missing would report clean on exactly the builds where the artifact is
        broken.
        """
        _link_contract_into(tmp_path)
        monkeypatch.setattr(_mod, "PROJECT_ROOT", tmp_path)
        pm = VerdictUIPM.__new__(VerdictUIPM)
        result = pm.stage_transport_smoke()
        assert not result["passed"]
        assert "missing" in result["detail"]

    def test_it_is_registered_in_the_quick_pipeline(self) -> None:
        pm = VerdictUIPM.__new__(VerdictUIPM)
        names = [name for name, _fn in pm.define_stages("quick")]
        assert "stage_transport_smoke" in names

    def test_it_runs_after_the_stage_that_builds_the_binary(self) -> None:
        """Order is load-bearing: `stage_cli_smoke` builds what this drives.

        Reversed, this stage would report a missing binary on every clean
        checkout — a hard failure whose cause is the pipeline, not the code.
        """
        pm = VerdictUIPM.__new__(VerdictUIPM)
        names = [name for name, _fn in pm.define_stages("quick")]
        assert names.index("stage_cli_smoke") < names.index("stage_transport_smoke")

    @_needs_dev_machine
    def test_it_passes_against_the_real_binary(self) -> None:
        pm = VerdictUIPM.__new__(VerdictUIPM)
        # stage_cli_smoke is what builds the product both stages drive.
        assert pm.stage_cli_smoke()["passed"]
        result = pm.stage_transport_smoke()
        assert result["passed"], result["detail"]
        assert "isError=false" in result["detail"]

    def test_the_handshake_it_sends_is_the_one_a_real_client_sends(self) -> None:
        """`initialize` must carry params, because every real client's does.

        This is not cosmetic. `params` is free-form per JSON-RPC method, and a
        server that decodes it strictly as `tools/call`'s shape rejects the
        ENVELOPE, so the message never reaches its handler. Sending `initialize`
        with no `params` key is the ONE spelling that decodes either way — which
        is why this stage passed for a whole wave against a binary that answered
        every real client's opening message with a parse error.

        Reading the payload is the only way to see this: the stage's own PASS
        cannot, by construction, since it was passing throughout.
        """
        source = inspect.getsource(VerdictUIPM.stage_transport_smoke)
        assert '"method":"initialize"' in source, "the stage must exercise the handshake"
        handshake = next(line for line in source.splitlines() if '"method":"initialize"' in line)
        assert '"params":' in handshake, (
            "initialize is sent without params — the one spelling that cannot "
            f"catch a strict-envelope regression: {handshake.strip()}"
        )

    def test_a_handshake_that_errors_fails_the_stage(self, tmp_path, monkeypatch) -> None:
        """The stage must FAIL when initialize is answered with an error.

        The negative control for the assertion above, and the one that matters:
        counting replies cannot see this defect, because a parse error IS a
        reply — the count stays 3 while no client can connect at all. Without
        this test, deleting the handshake check leaves every other assertion
        green.

        The catalog and tool-call replies below are well-formed on purpose, so
        the stage can only fail for the handshake.
        """
        binary = tmp_path / ".build" / "debug" / "verdictui"
        binary.parent.mkdir(parents=True)
        replies = [
            {"jsonrpc": "2.0", "error": {"code": -32700, "message": "parse error"}},
            # The real verb names, because the stage asserts WHICH tools are
            # served rather than how many — placeholder names satisfied the old
            # count check while telling a reader nothing, and in the
            # bad-handshake fixture they would make the stage fail for TWO
            # reasons at once, so it could no longer show which one it caught.
            {"jsonrpc": "2.0", "id": 2, "result": {"tools": _served_tools()}},
            {
                "jsonrpc": "2.0",
                "id": 3,
                "result": {
                    "isError": False,
                    "content": [{"text": json.dumps({"status": "FAIL", "findings": [{}]})}],
                },
            },
        ]
        stdout = "\n".join(json.dumps(r) for r in replies) + "\n"
        binary.write_text(f"#!/bin/sh\ncat >/dev/null\nprintf '%s' {shlex.quote(stdout)}\n")
        binary.chmod(0o755)
        _link_contract_into(tmp_path)
        monkeypatch.setattr(_mod, "PROJECT_ROOT", tmp_path)

        pm = VerdictUIPM.__new__(VerdictUIPM)
        result = pm.stage_transport_smoke()

        assert not result["passed"], (
            "a handshake answered with a parse error must fail the stage: no MCP "
            f"client can connect, yet the reply COUNT is still 3 — {result['detail']}"
        )
        assert "initialize" in result["detail"]

    def test_a_missing_tool_fails_the_stage_and_names_it(self, tmp_path, monkeypatch) -> None:
        """A catalog short one verb must fail, naming which one.

        The count check this replaced could see a wrong SIZE but never say what
        was absent, and it fired on `act` being ADDED — a stage that fails when
        the product grows and cannot report what it lost. Everything else in
        this fixture is well-formed, so the stage can only fail for the catalog.
        """
        served = [tool for tool in _served_tools() if tool["name"] != "act"]
        result = self._drive(tmp_path, monkeypatch, tools=served)

        assert not result["passed"]
        assert "act" in result["detail"], result["detail"]

    def test_the_destructive_verb_being_advertised_fails_the_stage(
        self, tmp_path, monkeypatch
    ) -> None:
        """Serving `baseline_accept` must fail, however complete the rest is.

        Accepting a baseline REPLACES the record of what a screen should look
        like. The whole catalog is present here, so a stage that only checked
        for missing verbs would pass this — which is why the absence is asserted
        separately rather than inferred from a count.
        """
        result = self._drive(
            tmp_path, monkeypatch, tools=_served_tools() + [{"name": "baseline_accept"}]
        )

        assert not result["passed"]
        assert "baseline_accept" in result["detail"], result["detail"]

    def _drive(self, tmp_path, monkeypatch, tools: list[dict]) -> dict:
        """Run the stage against a stub binary serving `tools`."""
        binary = tmp_path / ".build" / "debug" / "verdictui"
        binary.parent.mkdir(parents=True)
        replies = [
            {"jsonrpc": "2.0", "id": 1, "result": {"protocolVersion": "2024-11-05"}},
            {"jsonrpc": "2.0", "id": 2, "result": {"tools": tools}},
            {
                "jsonrpc": "2.0",
                "id": 3,
                "result": {
                    "isError": False,
                    "content": [{"text": json.dumps({"status": "FAIL", "findings": [{}]})}],
                },
            },
        ]
        stdout = "\n".join(json.dumps(r) for r in replies) + "\n"
        binary.write_text(f"#!/bin/sh\ncat >/dev/null\nprintf '%s' {shlex.quote(stdout)}\n")
        binary.chmod(0o755)
        _link_contract_into(tmp_path)
        monkeypatch.setattr(_mod, "PROJECT_ROOT", tmp_path)

        pm = VerdictUIPM.__new__(VerdictUIPM)
        return pm.stage_transport_smoke()

    def test_a_well_formed_handshake_still_passes(self, tmp_path, monkeypatch) -> None:
        """Control for the test above: the same fixture, handshake repaired.

        Without it, "fails on a bad handshake" is satisfied by a stage that
        fails on everything — including this fixture, which differs only in
        that one reply.
        """
        binary = tmp_path / ".build" / "debug" / "verdictui"
        binary.parent.mkdir(parents=True)
        replies = [
            {"jsonrpc": "2.0", "id": 1, "result": {"protocolVersion": "2024-11-05"}},
            # The real verb names, because the stage asserts WHICH tools are
            # served rather than how many — placeholder names satisfied the old
            # count check while telling a reader nothing, and in the
            # bad-handshake fixture they would make the stage fail for TWO
            # reasons at once, so it could no longer show which one it caught.
            {"jsonrpc": "2.0", "id": 2, "result": {"tools": _served_tools()}},
            {
                "jsonrpc": "2.0",
                "id": 3,
                "result": {
                    "isError": False,
                    "content": [{"text": json.dumps({"status": "FAIL", "findings": [{}]})}],
                },
            },
        ]
        stdout = "\n".join(json.dumps(r) for r in replies) + "\n"
        binary.write_text(f"#!/bin/sh\ncat >/dev/null\nprintf '%s' {shlex.quote(stdout)}\n")
        binary.chmod(0o755)
        _link_contract_into(tmp_path)
        monkeypatch.setattr(_mod, "PROJECT_ROOT", tmp_path)

        pm = VerdictUIPM.__new__(VerdictUIPM)
        result = pm.stage_transport_smoke()

        assert result["passed"], result["detail"]


class _FakeCompleted:
    """Minimal CompletedProcess stand-in for the contention probe.

    Defined locally rather than imported from the sibling test module: a
    fixture shared across test files is a cross-file coupling that `no.md` #19
    already ruled against here, and this one is four lines.
    """

    def __init__(self, stdout: str = "", returncode: int = 0) -> None:
        self.stdout = stdout
        self.returncode = returncode


class TestSkippedStagesAreVisibleAsSkips:
    """A stage that could not observe its subject must not read as PASS.

    Found 2026-08-20 from a peer report (PanoMac, 24 of 52 stages) and then
    MEASURED here rather than assumed: the live PM report carried
    `[PASS] watch_testwatch  testwatch: not installed — skipped`. The detail
    text was honest; the MARKER was not, and the marker is what a reader scans.

    "Could not measure" and "measured and clean" are opposite states that must
    never render identically (lesson 202, lesson 206). VerdictUI returns dicts
    rather than the 3-tuple contract the peer describes, so the fix is a
    reporting-layer classification, not a contract change: recognise the skip
    where the row is RECORDED rather than trusting 47 call sites to volunteer
    a flag.
    """

    def test_a_skipped_detail_is_classified_as_a_skip_not_a_pass(self):
        for detail in (
            "testwatch: not installed — skipped (0.1s)",
            "skipped: shared-libs unavailable: ImportError",
            "no installed verdictui on PATH — nothing to compare",
            "no release build — run swift build -c release",
        ):
            assert _mod.stage_result_is_skip(detail), detail

    def test_a_stage_that_RAN_but_skipped_a_SUB_check_is_not_a_skip(self):
        """A partial run that honestly names a skipped sub-check still RAN.

        Reported by a peer session (PanoMac, 2026-08-20) that hit this in its
        own recogniser, then MEASURED here rather than assumed: both strings
        below classified as skips against this project's classifier, because
        `"skipped:"` appears MID-SENTENCE in a detail whose stage executed.

        VerdictUI's own stage details happen not to contain that shape today,
        so nothing but luck separated this project from the defect — which is
        exactly why it is pinned rather than left to surface later. A stage
        that ran and reported a sub-check skip is the OPPOSITE of a stage that
        observed nothing, and rendering it as UNVERIFIED hides executing work
        while claiming to reveal hidden work.
        """
        for detail in (
            "1 tests passed | 1 tests passed | output anomaly skipped: no trust score samples",
            "1 keys within freshness budget | background lifecycle skipped: app or log not present",
        ):
            assert not _mod.stage_result_is_skip(detail), (
                f"a stage that RAN and named a skipped sub-check is not a skipped stage: {detail}"
            )

    def test_a_real_pass_is_never_classified_as_a_skip(self):
        """The negative control. Without it, 'detects skips' is satisfied by an
        implementation that calls EVERY passing stage a skip — which would make
        the marker meaningless in the opposite direction."""
        for detail in (
            "871 tests PASS",
            "ruff check + format clean",
            "installed parity ok (13 subcommands, 2 copies)",
            "SLO 1 p50 49.80ms < 70.0ms, p95 92.30ms recorded (3 tests)",
            "VerdictUIKernel platform-pure (no UI imports)",
        ):
            assert not _mod.stage_result_is_skip(detail), detail

    def test_the_word_skip_inside_a_test_name_is_not_a_skip(self):
        """`no.md` #58/#62: 12 suite hits for "skipped" were test NAMES, every
        one passing. A classifier keyed on the bare substring would call a
        fully-executed suite a skip — the same false reading in reverse."""
        assert not _mod.stage_result_is_skip(
            "871 tests PASS (testNodesWithoutMetricsAreSkipped ok)"
        )


class TestMainSurfacesSkippedStages:
    """The classifier must reach the reader, or it is not an integration."""

    def _run(self, monkeypatch, stages):
        monkeypatch.setattr(
            _mod.VerdictUIPM,
            "run_pipeline",
            lambda _self, **_k: {"all_passed": True, "stages": stages},
            raising=False,
        )
        monkeypatch.setattr(_mod, "tree_is_contended", lambda: False)
        printed: list[str] = []
        monkeypatch.setattr(
            "builtins.print", lambda *a, **_k: printed.append(" ".join(map(str, a)))
        )
        return _mod.main(["--quick"]), "\n".join(printed)

    def test_a_green_run_with_a_skipped_stage_says_so(self, monkeypatch):
        code, out = self._run(
            monkeypatch,
            {
                "stage_test": {"passed": True, "detail": "871 tests PASS"},
                "watch_testwatch": {"passed": True, "detail": "testwatch: not installed — skipped"},
            },
        )
        assert code == 0, "a skip is an absence of evidence, never a failure"
        assert "watch_testwatch" in out, out
        assert "unverified" in out.lower() or "skip" in out.lower(), out

    def test_a_fully_measured_green_run_claims_nothing_extra(self, monkeypatch):
        """Negative control: without it, 'reports skips' is satisfied by an
        implementation that appends the caveat to every green run."""
        code, out = self._run(
            monkeypatch,
            {"stage_test": {"passed": True, "detail": "871 tests PASS"}},
        )
        assert code == 0
        assert "unverified" not in out.lower(), out


class TestPublishToDashboard:
    """The dashboard publish must not let an unwritable file fail the PM.

    Untested until 2026-08-20 (TODO.md testwatch P1). The override exists for
    one reason: `~/Projects/ceo-dashboard.json` is shared by ~127 projects and
    can be momentarily unwritable, and a PM that reports a grade of F because a
    REPORTING side-effect failed is describing the wrong subject entirely.

    Both directions are load-bearing and they fail differently. Not delegating
    means the dashboard silently stops updating while every stage stays green —
    the shape lesson 329 names, where a display slot goes stale without anyone
    touching its subject. Swallowing too much means a real bug in the base
    publisher disappears, and nothing anywhere reports it.
    """

    def _pm(self):
        return object.__new__(_mod.VerdictUIPM)

    def test_a_successful_publish_delegates_to_the_base(self, monkeypatch):
        seen: list[dict] = []
        monkeypatch.setattr(
            _mod.PmBase, "publish_to_dashboard", lambda _s, st: seen.append(st), raising=False
        )
        payload = {"grade": "A"}
        self._pm().publish_to_dashboard(payload)
        assert seen == [payload], "the override must forward, not reimplement"

    def test_a_permission_error_is_logged_and_swallowed(self, monkeypatch):
        """A read-only dashboard is an environment state, not a product defect."""

        def deny(_self, _status):
            raise PermissionError("read-only file system")

        logged: list[tuple[str, str]] = []
        monkeypatch.setattr(_mod.PmBase, "publish_to_dashboard", deny, raising=False)
        monkeypatch.setattr(_mod, "_pm_log", lambda msg, lvl="INFO": logged.append((msg, lvl)))

        self._pm().publish_to_dashboard({"grade": "A"})

        assert logged, "swallowing silently would make the dashboard stop updating unnoticed"
        message, level = logged[0]
        assert level == "WARN"
        assert "skipped" in message.lower()

    def test_any_other_error_still_propagates(self, monkeypatch):
        """The negative control. Without it, 'handles PermissionError' is
        satisfied by a bare `except Exception`, which would bury a real defect
        in the shared publisher and report success."""

        def boom(_self, _status):
            raise ValueError("malformed status payload")

        monkeypatch.setattr(_mod.PmBase, "publish_to_dashboard", boom, raising=False)
        with pytest.raises(ValueError, match="malformed status payload"):
            self._pm().publish_to_dashboard({"grade": "A"})


class TestReinstallHint:
    """The hint must never propose clobbering a package-managed binary.

    Untested until the Step-12 cold read of 2026-08-20 caught it — a function
    written the same session whose whole job is REFUSING a destructive
    suggestion, shipped with no witness. An unexercised path is an untested
    claim, and this one's failure mode is telling the reader to run a command
    that desyncs a Homebrew tap from its own receipt.

    Both branches are asserted, because either alone is satisfiable by a broken
    implementation: only-refuses would be met by never offering the copy at
    all (useless for a plain install), and only-offers by proposing it
    everywhere (the destructive case).
    """

    _BUILT = Path("/repo/.build/release/verdictui")

    def test_a_homebrew_symlink_is_refused_and_says_why(self):
        hint = _mod._reinstall_hint("/opt/homebrew/bin/verdictui", self._BUILT)
        assert "install -m 755" not in hint, (
            "the Homebrew copy is -r-xr-xr-x behind an INSTALL_RECEIPT.json; copying over it "
            f"clobbers the tap. got: {hint}"
        )
        assert "brew upgrade" in hint, "must name the SAFE path, not merely refuse the unsafe one"

    def test_a_cellar_path_is_refused_even_without_the_bin_prefix(self):
        """Resolution matters: a symlink elsewhere on PATH can still land in
        the Cellar, so the check reads the RESOLVED path, not the spelling."""
        hint = _mod._reinstall_hint(
            "/opt/homebrew/Cellar/verdictui/1.0.1/bin/verdictui", self._BUILT
        )
        assert "install -m 755" not in hint, hint

    def test_a_plain_user_install_still_gets_the_copy_command(self):
        """The paired control. Without it, 'refuses the unsafe path' is met by
        an implementation that never offers a usable fix at all — which would
        leave a genuinely stale ~/.local/bin copy with no stated remedy."""
        hint = _mod._reinstall_hint("/Users/dev/.local/bin/verdictui", self._BUILT)
        assert "install -m 755" in hint, hint
        assert str(self._BUILT) in hint, "must name the source binary to copy FROM"


class TestTreeIsContended:
    """`tree_is_contended` — the guard that separates a busy tree from a broken one.

    Added 2026-08-20 after TEN false P1s in a single day. A
    `check.py --all --quick` fleet sweep builds 127 projects through the same
    SwiftPM build directory this repo uses, so a PM sampling the tree during one
    measures contention and reports it as a defect with a precise-looking
    file:line citation. Measured that day: `stage_runtime_bench` read 102.52ms
    against a 70ms budget while an exclusive run of the same commit read
    49.80ms, and `stage_mcp_latency` read 43.82ms against 8.32ms — a 5x swing on
    unchanged code.

    `mutation_sweep_in_progress` already covered a tree being REWRITTEN. This
    covers a tree being CONTENDED, which the marker cannot see because the
    sweep writes nothing here.

    The direction that matters is the same one: reading FALSE during a sweep
    files fabricated defects that the next session inherits as fact; reading
    TRUE forever would silence real ones. So this fails toward NOISE — anything
    it cannot establish is reported as uncontended.
    """

    def test_no_sweep_process_means_an_uncontended_tree(self, monkeypatch):
        monkeypatch.setattr(_mod.subprocess, "run", lambda *_a, **_k: _FakeCompleted("", 1))
        assert _mod.tree_is_contended() is False

    def test_a_running_fleet_sweep_is_contention(self, monkeypatch):
        monkeypatch.setattr(
            _mod.subprocess,
            "run",
            lambda *_a, **_k: _FakeCompleted("46571\n", 0),
        )
        assert _mod.tree_is_contended() is True

    def test_a_concurrent_pm_run_is_contention_too(self, monkeypatch):
        """A second PM on this tree contends for the SAME build directory.

        Measured 2026-08-20: `ceo.py --watch` calls every PM with `--fix` as
        its "Obligate" step, so a `verdictui-pm.py --fix` was live on this tree
        for 15+ minutes while this session measured. The first version of this
        guard matched only `check.py --all` and returned False throughout —
        blind to the contender directly in front of it.

        The pattern list is a CLAIM ABOUT THE WORLD, and every spelling it
        omits is not merely unmatched but invisible (lesson 219/240). This is
        the second entry, added because the first was demonstrably incomplete.
        """
        calls: list[str] = []

        def probe(argv, **_k):
            calls.append(argv[-1])
            hit = argv[-1] == "verdictui-pm.py"
            return _FakeCompleted("51039\n" if hit else "", 0 if hit else 1)

        monkeypatch.setattr(_mod.subprocess, "run", probe)
        assert _mod.tree_is_contended() is True
        assert "verdictui-pm.py" in calls, calls

    def test_a_sibling_projects_pm_saturating_the_machine_is_contention(self, monkeypatch):
        """The contender that matched NEITHER pattern, measured 2026-08-21.

        `ceo.py --watch 30` was driving a full **SagaMail** `swift test
        --parallel` suite on this machine while this project's timing stages
        ran. Load average was 241.37. Measured on one commit (fda4c1d):

            testWarmVerifyRoundTripMeetsTheLatencyBudget  120.23 ms contended
                                                            9.63 ms exclusive
            testPerformCycleMeetsTheSLO1Gate              249.57 ms contended
                                                           50.03 ms exclusive

        A 12x swing on unchanged code. Three P1s were filed for it.

        The pattern list read `check.py --all` and `verdictui-pm.py`, so a
        sibling project's PM was INVISIBLE — even though the guard's own
        docstring already named `ceo.py --watch` as "the commonest contender".
        The list encoded the WATCHER'S VICTIM rather than the watcher, which is
        `no.md` #76 recurring one pattern along: a guard built from one observed
        cause is blind to the commonest one.

        Keyed on the watcher itself, because what saturates this machine is that
        it is sweeping AT ALL, never which project it happens to be inside.
        """
        calls: list[str] = []

        # Keyed on the EXACT pattern, never a substring of it. A `"ceo.py" in`
        # test matches a mutated `"ceo.py --a-pattern-no-process-can-match"`
        # just as readily, so the row scored UNNOTICED on its first run — the
        # assertion was satisfied identically by the working and the broken
        # list (`no.md` #12/#17). This fake stands in for a real `pgrep -f`,
        # which answers about the pattern it was actually given.
        def probe(argv, **_k):
            calls.append(argv[-1])
            hit = argv[-1] == "ceo.py --watch"
            return _FakeCompleted("863\n" if hit else "", 0 if hit else 1)

        monkeypatch.setattr(_mod.subprocess, "run", probe)
        assert _mod.tree_is_contended() is True
        assert "ceo.py --watch" in calls, calls

    def test_the_pm_does_not_report_ITSELF_as_contention(self, monkeypatch):
        """The false-positive direction, and the one that would destroy the guard.

        `verdictui-pm.py` matches the very process running this check, so
        without a self-exclusion `pgrep` returns our own pid and the PM reports
        contention on every single run — permanently True. That is strictly
        worse than the blind spot it replaced: a guard that always fires
        teaches its reader to discount it, and it pays that cost on every
        future finding rather than only the wrong one (`no.md` #72).
        """
        import os as _os

        monkeypatch.setattr(
            _mod.subprocess, "run", lambda *_a, **_k: _FakeCompleted(f"{_os.getpid()}\n", 0)
        )
        assert _mod.tree_is_contended() is False, "the PM must not see its own pid as a contender"

    def test_a_real_contender_beside_our_own_pid_still_registers(self, monkeypatch):
        """The paired control: excluding self must not exclude everyone.

        Without this, 'ignores its own pid' is satisfied by an implementation
        that ignores every pid — which silently restores the original defect
        while this class stays green.
        """
        import os as _os

        monkeypatch.setattr(
            _mod.subprocess,
            "run",
            lambda *_a, **_k: _FakeCompleted(f"{_os.getpid()}\n51039\n", 0),
        )
        assert _mod.tree_is_contended() is True

    def test_the_probe_stops_at_the_first_match_rather_than_asking_twice(self, monkeypatch):
        """Cheapness is part of the contract — this runs on every PM invocation."""
        calls: list[str] = []

        def probe(argv, **_k):
            calls.append(argv[-1])
            return _FakeCompleted("999\n", 0)

        monkeypatch.setattr(_mod.subprocess, "run", probe)
        assert _mod.tree_is_contended() is True
        assert len(calls) == 1, f"must short-circuit on the first hit, probed {calls}"

    def test_an_unavailable_probe_reports_uncontended_never_contended(self, monkeypatch):
        """Fail toward NOISE. A guard that cannot run must not suppress reporting.

        If pgrep is missing or errors, 'I could not tell' must read as
        'uncontended' — the alternative silences every real finding on any host
        where the probe is unavailable, and silence is what nobody alerts on
        (lesson 202: a check may only claim clean for work it performed).
        """

        def boom(*_a, **_k):
            raise OSError("pgrep not found")

        monkeypatch.setattr(_mod.subprocess, "run", boom)
        assert _mod.tree_is_contended() is False

    def test_a_timed_out_probe_reports_uncontended(self, monkeypatch):
        def slow(*_a, **_k):
            raise _mod.subprocess.TimeoutExpired(cmd="pgrep", timeout=1)

        monkeypatch.setattr(_mod.subprocess, "run", slow)
        assert _mod.tree_is_contended() is False


class TestMainWarnsWhenTheTreeIsContended:
    """A failure measured on a contended tree must SAY it may be contention.

    The guard is only worth the call site that invokes it (`no.md`: a ported API
    with no caller is not an integration). Ten P1s were filed against this
    project on 2026-08-19/20 by sweeps racing this worktree, each reading as a
    code defect. The exit code is deliberately NOT changed — a red stays red,
    because suppressing a failure on a contention guess is how a real
    regression gets waved through. Only the REPORT gains a line.
    """

    def _run(self, monkeypatch, *, contended: bool, all_passed: bool):
        # Patch the CLASS method and let main() build its own instance: an
        # object.__new__ stand-in skips __init__, so the real run_pipeline's
        # bookkeeping attributes are missing and the failure is the fixture's,
        # not the code's (measured while writing this — no.md #18).
        monkeypatch.setattr(
            _mod.VerdictUIPM,
            "run_pipeline",
            lambda _self, **_k: {"all_passed": all_passed},
            raising=False,
        )
        monkeypatch.setattr(_mod, "tree_is_contended", lambda: contended)
        printed: list[str] = []
        monkeypatch.setattr(
            "builtins.print", lambda *a, **_k: printed.append(" ".join(map(str, a)))
        )
        code = _mod.main(["--quick"])
        return code, "\n".join(printed)

    def test_a_failure_on_a_contended_tree_is_flagged_as_possibly_contention(self, monkeypatch):
        code, out = self._run(monkeypatch, contended=True, all_passed=False)
        assert code == 1, "a red must stay red — the warning never suppresses a failure"
        assert "contention" in out.lower(), out
        assert "exclusive" in out.lower(), "must tell the reader how to get a trustworthy result"

    def test_a_failure_on_an_exclusive_tree_carries_no_contention_excuse(self, monkeypatch):
        """The negative control. Without it, 'warns on contention' is satisfied
        by an implementation that prints the excuse on EVERY failure — which
        would teach the reader to discount every real red."""
        code, out = self._run(monkeypatch, contended=False, all_passed=False)
        assert code == 1
        assert "contention" not in out.lower(), out

    def test_a_pass_is_never_annotated(self, monkeypatch):
        code, out = self._run(monkeypatch, contended=True, all_passed=True)
        assert code == 0
        assert "contention" not in out.lower(), out


class TestMutationSweepInProgress:
    """`mutation_sweep_in_progress` — the READER-side half of the sweep guard.

    Untested until 2026-08-13 (CIS-10F7CCF8). It decides whether anything
    sampling this repo should trust what it sees: a sweep rewrites source in
    place, so a concurrent reader can file a precise-looking P1 about a
    regression that does not exist (measured 2026-08-12, two such rows, both
    falsified on a clean tree at HEAD).

    Both directions matter and they fail differently. Reading FALSE during a
    live sweep files fabricated defects; reading TRUE forever after a crashed
    sweep silences real ones — and the silent failure is the one nobody notices.
    """

    def _marker(self, tmp_path, monkeypatch):
        """Point the module's marker lookup at a tmp tree.

        The function derives its path from `__file__`, so the redirect is done
        by faking that parent rather than by patching a constant — there is no
        constant to patch, which is itself why this needed a test.
        """
        logs = tmp_path / "logs"
        logs.mkdir()
        monkeypatch.setattr(_mod, "__file__", str(tmp_path / "scripts" / "verdictui-pm.py"))
        return logs / ".mutation-in-progress"

    def test_no_marker_means_no_sweep(self, tmp_path, monkeypatch):
        self._marker(tmp_path, monkeypatch)
        assert _mod.mutation_sweep_in_progress() is False

    def test_a_fresh_marker_reports_a_live_sweep(self, tmp_path, monkeypatch):
        marker = self._marker(tmp_path, monkeypatch)
        marker.write_text(f"12345 {time.time()}\n")

        assert _mod.mutation_sweep_in_progress() is True

    def test_a_stale_marker_does_not_suppress_forever(self, tmp_path, monkeypatch):
        marker = self._marker(tmp_path, monkeypatch)
        # A SIGKILLed sweep never runs its `finally`, so without a TTL this
        # marker would silence issue filing permanently — and the symptom of
        # that is everything looking quiet, which nothing alerts on.
        marker.write_text(f"12345 {time.time() - _mod.MUTATION_SWEEP_TTL_SECONDS - 1}\n")

        assert _mod.mutation_sweep_in_progress() is False

    def test_a_malformed_marker_is_not_read_as_a_live_sweep(self, tmp_path, monkeypatch):
        marker = self._marker(tmp_path, monkeypatch)
        # Fail toward NOISE, never toward silence: an unparseable marker must
        # not be trusted to suppress reporting.
        marker.write_text("not-a-marker\n")

        assert _mod.mutation_sweep_in_progress() is False


class TestMCPInputSurfaceSurvivesHostileInput:
    """The MCP server must answer garbage and STAY ALIVE.

    Wave 10 Task 3 asks for the input surface to be fuzzed. The reason is
    specific to how agents use this binary: an MCP server is a long-lived
    process reading whatever a client sends, so a crash on a malformed frame is
    a denial of service for the whole session, and a hang is worse — the agent
    waits forever on a reply that will never come.

    The assertion that matters is the LAST one: after every malformed frame, a
    valid request must still be answered. Without it this test is satisfied by
    a server that dies on frame two, because a dead server also fails to
    produce a wrong answer.
    """

    # Each entry is (label, raw line). The frames escalate: malformed JSON,
    # valid JSON that is not JSON-RPC, valid JSON-RPC naming nothing real, and
    # valid calls carrying wrong-typed or missing arguments.
    _HOSTILE = [
        ("not json at all", "not json at all"),
        ("no method key", '{"jsonrpc":"2.0"}'),
        ("unknown method", '{"jsonrpc":"2.0","id":3,"method":"nonexistent/method"}'),
        (
            "unknown tool",
            '{"jsonrpc":"2.0","id":4,"method":"tools/call",'
            '"params":{"name":"no_such_tool","arguments":{}}}',
        ),
        (
            "unknown scenario",
            '{"jsonrpc":"2.0","id":5,"method":"tools/call",'
            '"params":{"name":"verify","arguments":{"scenario":"does-not-exist"}}}',
        ),
        (
            "missing argument",
            '{"jsonrpc":"2.0","id":6,"method":"tools/call",'
            '"params":{"name":"verify","arguments":{}}}',
        ),
        (
            "wrong-typed argument",
            '{"jsonrpc":"2.0","id":7,"method":"tools/call",'
            '"params":{"name":"verify","arguments":{"scenario":12345}}}',
        ),
        ("top-level array", "[]"),
    ]

    _HANDSHAKE = (
        '{"jsonrpc":"2.0","id":1,"method":"initialize","params":'
        '{"protocolVersion":"2024-11-05","capabilities":{},'
        '"clientInfo":{"name":"fuzz","version":"1"}}}'
    )
    _FINAL_PROBE = '{"jsonrpc":"2.0","id":999,"method":"tools/list"}'

    @_needs_dev_machine
    def test_every_malformed_frame_is_answered_and_the_server_survives(self) -> None:
        binary = _mod.PROJECT_ROOT / ".build" / "release" / "verdictui"
        if not binary.exists():
            pytest.skip(f"{binary} absent — build with swift build -c release")

        frames = [self._HANDSHAKE, *[line for _label, line in self._HOSTILE], self._FINAL_PROBE]
        completed = subprocess.run(  # noqa: S603 - fixed argv, no shell
            [str(binary), "mcp"],
            input="\n".join(frames) + "\n",
            capture_output=True,
            text=True,
            timeout=120,
            check=False,
        )

        replies = [json.loads(line) for line in completed.stdout.splitlines() if line.strip()]

        # Every frame answered: nothing swallowed, nothing merged.
        assert len(replies) == len(frames), (
            f"sent {len(frames)} frames, got {len(replies)} replies — "
            "a frame was swallowed or the server died mid-stream"
        )

        # Every reply is well-formed JSON-RPC carrying exactly one outcome.
        for reply in replies:
            assert reply.get("jsonrpc") == "2.0", reply
            assert ("result" in reply) != ("error" in reply), (
                f"reply carries both or neither result and error: {reply}"
            )

        # THE ASSERTION THAT MAKES THIS A TEST: the server answered the final
        # valid request, so it survived everything before it. A crash on frame
        # two would satisfy every check above except this one.
        final = replies[-1]
        assert final.get("id") == 999, f"final reply is not the probe: {final}"
        assert "result" in final, f"server degraded before the final probe: {final}"
        assert final["result"]["tools"], "the catalog came back empty after hostile input"

        # Nothing leaked to stderr: a server that logs a stack trace per bad
        # frame is one malformed client away from filling a disk.
        assert completed.stderr == "", f"unexpected stderr: {completed.stderr[:400]!r}"


class TestDocumentedMCPTools:
    """The required-verb set that `stage_transport_smoke` asserts over the wire.

    That set used to be a literal written in the stage, and it had ALREADY
    rotted: it named six tools and silently stopped covering `focus`,
    `judge_appkit` and `actions` as each shipped, so the gate could not fail for
    the three most recently added — the ones most likely to break. A hand-copied
    membership list is blind to everything it omits (lessons 219/240), and the
    omission is invisible because the gate keeps passing.

    Reading the contract instead means a tool is covered the moment it is
    documented. That moves the failure mode rather than removing it, so both new
    ways to be wrong are pinned here: a parse that finds NOTHING (which would
    make the gate require nothing of any catalog), and a parse that wrongly
    includes the one tool documented as deliberately absent.
    """

    def test_it_parses_the_tools_the_contract_documents(self) -> None:
        tools = _mod._documented_mcp_tools()

        # The verbs a client can actually call. Named individually rather than
        # compared to a count: a count is the same hand-copied claim one step
        # removed, and it cannot say WHICH tool disappeared.
        for verb in (
            "list_scenarios",
            "render",
            "focus",
            "verify",
            "act",
            "actions",
            "sweep",
            "baseline_diff",
            "judge_appkit",
        ):
            assert verb in tools, (
                f"contracts/mcp-tools.md documents '{verb}' but the parser missed it — "
                f"stage_transport_smoke would stop requiring it over the wire. Parsed: "
                f"{sorted(tools)}"
            )

    def test_the_deliberately_unserved_verb_is_excluded(self) -> None:
        """`baseline_accept` is documented precisely as NOT SERVED.

        The negative control, and it is not decoration: without it, "reads the
        contract" is satisfied by a parser that returns every heading, which
        would make `stage_transport_smoke` demand that the destructive verb
        ANSWER over the wire — inverting the SD4 guarantee the very next
        assertion in that stage checks.
        """
        tools = _mod._documented_mcp_tools()

        assert "baseline_accept" not in tools, (
            "baseline_accept is documented as DELIBERATELY NOT SERVED, so requiring it "
            "over the wire would invert SD4 — the destructive verb must not reach an agent"
        )

    def test_it_reads_a_heading_a_human_would_call_the_same(
        self, monkeypatch: pytest.MonkeyPatch, tmp_path
    ) -> None:
        """Heading whitespace is FORMATTING, not contract.

        A literal `startswith("### `")` reads the contract's typography as part
        of the contract: one extra space, or a reflow by any markdown formatter,
        and the parser returns nothing. That fails CLOSED — the caller errors on
        an empty parse rather than requiring nothing — but for a reason no error
        message could explain, and a gate that breaks on cosmetics is a gate
        people learn to route around.

        Measured before this was written: `###   `render(a)`` returned the empty
        set against the original parser.
        """
        contract = tmp_path / "contracts"
        contract.mkdir()
        (contract / "mcp-tools.md").write_text(
            "###   `spaced_out(a)`\n###\t`tabbed()`\n  ### `indented()`\n### `plain()`\n",
            encoding="utf-8",
        )
        monkeypatch.setattr(_mod, "PROJECT_ROOT", tmp_path)

        assert _mod._documented_mcp_tools() == {
            "spaced_out",
            "tabbed",
            "indented",
            "plain",
        }, "heading whitespace must not decide which tools the wire gate requires"

    def test_a_deeper_heading_level_is_not_a_tool(
        self, monkeypatch: pytest.MonkeyPatch, tmp_path
    ) -> None:
        """The control for the tolerance above.

        Widening the heading match is only safe because something ELSE still
        rejects deeper levels — and it is worth naming WHICH, because the
        obvious answer is wrong. `####` DOES satisfy `startswith("###")`. What
        excludes it is the next line: after dropping exactly three characters
        the marker reads `#`, not a backtick, so the row is skipped. Measured,
        not reasoned: a mutation that loosened the heading test alone left this
        test PASSING (both implementations agree), while one that changed the
        drop to `lstrip("#")` made it FAIL naming both sub-headings. An
        assertion satisfied by the correct and the broken form alike is not a
        weak test, it is not a test (`no.md` #12) — so the mutation that proves
        this one is the second, and the docstring says so rather than pointing
        a future reader at the line that does not carry the weight.

        The failure it prevents: a contract documenting a tool's OPTIONS under
        `####` would silently add those option names to the set of verbs the
        wire gate demands answer, failing the stage against a correct catalog.
        """
        contract = tmp_path / "contracts"
        contract.mkdir()
        (contract / "mcp-tools.md").write_text(
            "### `real_tool()`\n#### `not_a_tool()`\n##### `also_not()`\n",
            encoding="utf-8",
        )
        monkeypatch.setattr(_mod, "PROJECT_ROOT", tmp_path)

        assert _mod._documented_mcp_tools() == {"real_tool"}, (
            "a #### sub-heading documents an ARGUMENT, not a served tool — "
            "requiring it over the wire would fail the gate on a correct catalog"
        )

    def test_an_unreadable_contract_yields_nothing_rather_than_a_guess(
        self, monkeypatch: pytest.MonkeyPatch, tmp_path
    ) -> None:
        """A contract that cannot be read returns the empty set.

        The stage treats that as a FAILURE rather than an empty requirement,
        which is the half that matters: a required-set of nothing is satisfied
        by any catalog at all, including an empty one, so a silent parse failure
        would turn a wire gate into a check that cannot fail (lesson 202).
        """
        # Deliberately NOT linked: tmp_path holds no contract, which is the
        # whole subject of this test.
        monkeypatch.setattr(_mod, "PROJECT_ROOT", tmp_path)

        assert _mod._documented_mcp_tools() == set(), (
            "an absent contract must yield the empty set so the caller can fail loudly, "
            "never a partial guess that looks like a real requirement"
        )
