"""The diagnostic probes must be runnable the obvious way, or nobody re-runs them.

`scripts/ax-window-publication-probe.swift` and `scripts/ax-appkit-anchor-probe.swift`
exist so the next session can re-measure a degraded host in one command instead of
rebuilding the apparatus. That value is entirely conditional on them RUNNING.

Measured 2026-08-17: the publication probe crashed under
`swift scripts/ax-window-publication-probe.swift` with
`*** -[NSConcreteTask terminate]: task not launched`. Two defects, and the first
hid the second — `try? child.run()` swallowed the launch failure, so the crash
surfaced twenty lines later at `terminate()`, pointing at the wrong line entirely.

These probes re-exec themselves to create a child GUI process, which cannot work
under `swift <file>` because argv[0] is then the SOURCE PATH rather than an
executable. That is a legitimate constraint; crashing to express it is not. So
the invariant is: refuse clearly, with the working invocation, and exit 2.

Why 2 specifically: it is the repo-wide "no verdict could be produced" code
(`docs/tree-contract.md`). A probe that could not measure must not exit 0, which
a caller reads as a clean result.
"""

import subprocess
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[1]


# These probes import AppKit, an Apple-only framework, so on Linux `swift <file>`
# fails at "no such module 'AppKit'" (exit 1) before any probe code runs. The
# assertions below are about the probe's REFUSAL BEHAVIOUR, and a toolchain that
# cannot compile the file has not exercised that behaviour at all — a red here on
# Linux says nothing about the subject (lesson 268: only the runner that can see
# the property may judge it).
#
# The guard keys on the CAPABILITY, not on the OS name, and it is checked once at
# import. Keying on `sys.platform != "darwin"` would also skip on a macOS host
# whose Swift toolchain is broken, hiding a real regression as a skip; requiring
# AppKit to actually resolve means a macOS runner can only ever SKIP for a reason
# that is itself a louder failure elsewhere (Build & Test cannot compile either).
def _appkit_is_available() -> bool:
    try:
        probe = subprocess.run(
            ["swift", "-e", "import AppKit"],
            capture_output=True,
            text=True,
            timeout=120,
        )
    except OSError, subprocess.SubprocessError:
        return False
    return probe.returncode == 0


_NO_APPKIT = not _appkit_is_available()

# Scoped deliberately, NOT module-level. `test_every_self_exec_probe_is_listed_here`
# only READS files, so it is observable everywhere and must keep running on Linux —
# a module-level mark would skip the one test in this file that catches a probe
# added without coverage, which is exactly the gap it exists to close.
needs_appkit = pytest.mark.skipif(
    _NO_APPKIT,
    reason=(
        "AppKit does not resolve for this Swift toolchain, so these probes cannot "
        "compile and their refusal behaviour is unobservable here. Judged on the "
        "macOS job instead — see the Build & Test (macOS) matrix."
    ),
)

# Every probe that re-execs itself. A new one added without a row here is not a
# gap this test can see, which is why the guard below also scans for the pattern.
SELF_EXEC_PROBES = [
    "scripts/ax-window-publication-probe.swift",
    "scripts/ax-appkit-anchor-probe.swift",
]


def _run(path: Path) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["swift", str(path)],
        capture_output=True,
        text=True,
        timeout=300,
        cwd=REPO,
    )


@needs_appkit
@pytest.mark.parametrize("relative", SELF_EXEC_PROBES)
def test_probe_refuses_interpretation_instead_of_crashing(relative: str) -> None:
    """Run the probe the obvious way and require a clean refusal, not a trap."""
    path = REPO / relative
    assert path.exists(), f"{relative} is missing — the probe cannot be re-run at all"

    result = _run(path)
    combined = result.stdout + result.stderr

    # The specific crash this test was written for. Asserting on the exit code
    # alone would miss it: an uncaught ObjC exception also exits non-zero, so the
    # code cannot distinguish "refused cleanly" from "crashed".
    assert "task not launched" not in combined, (
        f"{relative} crashed instead of refusing:\n{combined[:400]}"
    )
    assert "NSInvalidArgumentException" not in combined, (
        f"{relative} raised an ObjC exception:\n{combined[:400]}"
    )
    assert result.returncode == 2, (
        f"{relative} must exit 2 (no verdict producible), got {result.returncode}"
    )


@needs_appkit
@pytest.mark.parametrize("relative", SELF_EXEC_PROBES)
def test_the_refusal_names_the_working_invocation(relative: str) -> None:
    """A refusal that does not say what to do instead just relocates the dead end."""
    result = _run(REPO / relative)
    combined = result.stdout + result.stderr

    assert "swiftc" in combined, (
        f"{relative} refuses without naming the compile step that works:\n{combined[:400]}"
    )
    assert Path(relative).name in combined, (
        f"{relative}'s refusal does not name the file to compile:\n{combined[:400]}"
    )


def test_every_self_exec_probe_is_listed_here() -> None:
    """A probe added later must not silently escape this suite.

    Without this the parametrize list is a claim nobody checks, and the third
    probe would ship with the same crash the first two had.
    """
    scripts = REPO / "scripts"
    found = {
        f"scripts/{path.name}"
        for path in scripts.glob("*.swift")
        # The tell for a self-exec probe: it re-runs its own argv[0].
        if "CommandLine.arguments[0]" in path.read_text(encoding="utf-8")
    }
    missing = found - set(SELF_EXEC_PROBES)
    assert not missing, (
        f"self-exec probes not covered by this suite: {sorted(missing)}. "
        "Add them to SELF_EXEC_PROBES so they are held to the same contract."
    )
