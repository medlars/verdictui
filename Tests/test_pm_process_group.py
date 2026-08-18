"""Real process-group termination for the PM's child runners.

Split out of `test_verdictui_pm.py` (CTS-C37A9949): every test here spawns an
ACTUAL child with `start_new_session=True` -- the same way the PM starts
`swift` -- and asserts the process is gone afterwards, which makes it a
distinct subject from the stage-wiring tests that file covers.

The module loader comes from `pm_test_support.load_pm`, the shared helper the
sibling test files already use, so the preamble is not duplicated here.
"""

import os
import signal
import subprocess
import time

import pytest
from pm_test_support import load_pm

_mod = load_pm()


class TestTerminateProcessGroup:
    """`_terminate_process_group` against REAL process groups.

    Every test here spawns an actual child with `start_new_session=True` (the
    same way the PM starts `swift`) and asserts the process is GONE afterwards.
    A test that only asserts `killpg` was called cannot distinguish a working
    terminator from one that signals the wrong pid (`no.md` #12).
    """

    @staticmethod
    def _spawn_group(command: list[str]) -> subprocess.Popen:
        return subprocess.Popen(  # noqa: S603 — fixed argv, no shell
            command,
            start_new_session=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )

    def test_a_live_process_group_is_actually_terminated(self) -> None:
        proc = self._spawn_group(["sleep", "30"])
        try:
            assert proc.poll() is None, "the fixture died before the terminator ran"

            started = time.monotonic()
            _mod._terminate_process_group(proc)
            elapsed = time.monotonic() - started

            # `wait` here is the assertion: the process must already be reaped.
            # A timeout means the terminator returned while the child lived on.
            assert proc.wait(timeout=5) is not None
            assert proc.returncode is not None, "the child outlived the terminator"
            # WHICH signal ended it is the discriminator. Asserting only "it is
            # gone" passes against a terminator that never sends SIGTERM at all:
            # the graceful wait then times out and the SIGKILL fallback reaps it
            # anyway, ~10s later (`no.md` #12 -- an assertion both the correct
            # and the broken implementation satisfy is not a test).
            assert proc.returncode == -signal.SIGTERM, (
                f"expected a graceful SIGTERM death, got returncode {proc.returncode}"
            )
            assert elapsed < _mod.TIMEOUT_PROC_TERM_GRACE, (
                f"took {elapsed:.2f}s -- it waited out the grace period, so the "
                "SIGKILL fallback did the work the SIGTERM path should have"
            )
        finally:
            if proc.poll() is None:  # pragma: no cover — only on a failed run
                proc.kill()
                proc.wait(timeout=5)

    def test_a_child_ignoring_sigterm_is_escalated_to_sigkill(self, monkeypatch, tmp_path) -> None:
        """The escalation path: SIGTERM is trapped, so only SIGKILL can end it.

        The grace period is shortened so the test measures the ESCALATION rather
        than the production 10s wait. Without the SIGKILL branch this hangs at
        the grace timeout and then fails, rather than passing slowly.
        """
        # Trap SIGTERM and keep running: only an uncatchable signal ends this.
        # The shell TOUCHES a readiness file after installing the trap, so the
        # test can wait for the real precondition instead of guessing at it.
        ready = tmp_path / "trap-installed"
        script = f"trap '' TERM; : > {ready}; while :; do sleep 0.2; done"
        proc = self._spawn_group(["/bin/sh", "-c", script])
        try:
            assert proc.poll() is None, "the fixture died before the terminator ran"
            # POLL for the trap, never a fixed sleep. A sleep that is long enough
            # on an idle machine is a claim about an idle machine (lesson 357),
            # and this fleet routinely runs several sessions plus their test
            # runners at once — the old time.sleep(0.5) was a race that passes
            # until the box is busy, then signals a shell with no trap installed
            # and silently tests the WRONG path (CIS-5BD2FEBC).
            deadline = time.monotonic() + 10
            while not ready.exists():
                assert proc.poll() is None, "the fixture died before installing its trap"
                assert time.monotonic() < deadline, (
                    "the shell never installed its SIGTERM trap — the escalation "
                    "path cannot be exercised, so this test would prove nothing"
                )
                time.sleep(0.01)

            # monkeypatch, not a bare attribute assignment: `_mod` is loaded at
            # runtime via spec_from_file_location, so pyright types it as a plain
            # ModuleType and rejects assigning an attribute it cannot see
            # (CIS-014FAE5E / CIS-32D281B3). setattr also restores on teardown, so
            # a failure between the two assignments cannot leak the shortened
            # grace period into the next test.
            monkeypatch.setattr(_mod, "TIMEOUT_PROC_TERM_GRACE", 1)
            _mod._terminate_process_group(proc)

            assert proc.wait(timeout=5) is not None
            assert proc.returncode is not None, (
                "a SIGTERM-ignoring child survived — the SIGKILL escalation did not run"
            )
            # -9 is the signal that actually ended it; -15 would mean the trap
            # never installed and the test proved nothing about escalation.
            assert proc.returncode == -signal.SIGKILL, (
                f"expected death by SIGKILL, got returncode {proc.returncode}"
            )
        finally:
            if proc.poll() is None:  # pragma: no cover — only on a failed run
                proc.kill()
                proc.wait(timeout=5)

    def test_an_already_exited_process_does_not_raise(self) -> None:
        """The PM calls this from an `except BaseException` handler, where the
        child has often already died. Raising there would mask the original
        error with a ProcessLookupError.
        """
        proc = self._spawn_group(["/bin/sh", "-c", "exit 0"])
        proc.wait(timeout=5)
        assert proc.returncode is not None, "the fixture did not exit"

        # No assertion beyond "this returns": the contract is that it is safe.
        _mod._terminate_process_group(proc)

    def test_a_reaped_process_group_is_tolerated(self) -> None:
        """`killpg` on a fully-reaped group raises ProcessLookupError, which the
        terminator must swallow rather than propagate to the PM's error path.
        """
        proc = self._spawn_group(["/bin/sh", "-c", "exit 0"])
        proc.wait(timeout=5)

        # Signal 0 probes existence without delivering anything: this asserts the
        # fixture really is gone, so the terminator below is exercising the
        # already-reaped path rather than quietly killing a live process.
        with pytest.raises(ProcessLookupError):
            os.killpg(proc.pid, 0)

        _mod._terminate_process_group(proc)
