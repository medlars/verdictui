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
    spec.loader.exec_module(module)  # type: ignore[union-attr]
    return module
