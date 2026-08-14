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
import time

import pytest
from pm_test_support import _needs_dev_machine, load_pm

pytestmark = pytest.mark.quick

_mod = load_pm()
VerdictUIPM = _mod.VerdictUIPM


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
        source = inspect.getsource(VerdictUIPM.stage_cli_smoke)
        assert "swiftpm_command_lock" in source, (
            "stage_cli_smoke builds without the shared SwiftPM lock, so it "
            "contends with a concurrent swift test for the build directory"
        )
        lock_at = source.index("swiftpm_command_lock")
        build_at = source.index("subprocess.run")
        assert lock_at < build_at, "the lock must be acquired BEFORE the build runs"

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


def _served_tools() -> list[dict]:
    """The tool catalog a healthy binary advertises.

    Spelled once and shared by both fixtures so the bad-handshake test and its
    control differ in exactly ONE reply. A fixture that also served the wrong
    catalog would fail for two reasons at once, and the test could no longer
    show which one the stage actually caught.
    """
    return [
        {"name": name}
        for name in ("list_scenarios", "render", "verify", "act", "sweep", "baseline_diff")
    ]


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
        monkeypatch.setattr(_mod, "PROJECT_ROOT", tmp_path)

        pm = VerdictUIPM.__new__(VerdictUIPM)
        result = pm.stage_transport_smoke()

        assert result["passed"], result["detail"]


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
