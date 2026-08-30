"""Loader preamble shared by the PM-stage tests and the gate-script tests.

Extracted when `test_verdictui_pm.py` was split (CTS-E51CBEEB). It is a module
rather than a duplicated block in each file because the PM is loaded from a
HYPHENATED path through `spec_from_file_location`, and two copies of that
incantation drift in the one direction neither file can observe: each would keep
testing whatever module its own copy loaded, and a divergence would look like a
behaviour difference in the PM rather than in the harness (lesson 284).
"""

import importlib.util
import sys
from pathlib import Path

import pytest

_PROJECT_ROOT = Path(__file__).resolve().parents[1]
_PM_PATH = str(_PROJECT_ROOT / "scripts" / "verdictui-pm.py")
_PYTHON = sys.executable

# The PM is FIVE files: the entrypoint plus the four siblings it composes (see
# the entrypoint's docstring). A test that asserts on "the PM's source" must
# read all of them or its subject silently leaves its window — and the failure
# is in the PASSING direction, because an absence assertion over a file the
# code left reads exactly like a clean result (lesson 1368).
PM_MODULE_PATHS = (
    _PROJECT_ROOT / "scripts" / "verdictui-pm.py",
    _PROJECT_ROOT / "scripts" / "verdictui_pm_support.py",
    _PROJECT_ROOT / "scripts" / "verdictui_pm_swift.py",
    _PROJECT_ROOT / "scripts" / "verdictui_pm_stages.py",
    _PROJECT_ROOT / "scripts" / "verdictui_pm_smoke.py",
)


def pm_source() -> str:
    """Concatenated source of every module the PM is made of."""
    return "\n".join(path.read_text() for path in PM_MODULE_PATHS)


# floor-check asserts dev-machine surfaces (~/.claude skills, iTerm2 profile)
# that do not exist on a CI runner. Tests whose SUBJECT is the full floor must
# skip there rather than fail for "the environment lacks the thing" (lesson 221).
_ON_DEV_MACHINE = (Path.home() / ".claude" / "skills" / "verdictui" / "SKILL.md").exists()
_needs_dev_machine = pytest.mark.skipif(
    not _ON_DEV_MACHINE,
    reason="floor-check asserts dev-machine surfaces absent on CI runners",
)


def load_pm():
    """Load `verdictui-pm.py` without package machinery.

    The filename is hyphenated, so it is not importable as a module name; this
    is the only supported way to reach it from a test.
    """
    spec = importlib.util.spec_from_file_location("verdictui_pm", _PM_PATH)
    module = importlib.util.module_from_spec(spec)  # type: ignore[arg-type]
    # REGISTER BEFORE EXEC. `@dataclass(slots=True)` rebuilds the class and, to
    # resolve string annotations, looks the owning module up in `sys.modules`
    # by `cls.__module__`. A module loaded by path alone is absent from there,
    # so that lookup returns None and the decorator dies with a bare
    # `AttributeError: 'NoneType' object has no attribute '__dict__'` — an
    # error that names neither the dataclass nor this loader, and so reads as
    # a defect in whatever file happened to declare it.
    #
    # Measured 2026-08-22: adding the first slotted dataclass to the PM broke
    # COLLECTION of this entire suite, with a traceback pointing into CPython's
    # dataclasses.py. Registering the module is what a real import does; doing
    # it here makes a path-loaded module behave like an imported one instead of
    # subtly differently (`no.md` #14 — the apparatus, not the subject).
    sys.modules[spec.name] = module  # type: ignore[union-attr]
    try:
        spec.loader.exec_module(module)  # type: ignore[union-attr]
    except BaseException:
        # Never leave a half-executed module registered: the next importer
        # would receive it and see partially-defined names rather than a
        # clean failure.
        sys.modules.pop(spec.name, None)  # type: ignore[union-attr]
        raise
    return module
