"""Puts this directory on `sys.path` so the split test files can share helpers.

`test_verdictui_pm.py` and `test_verdictui_gates.py` both import
`pm_test_support` as a bare module (CTS-E51CBEEB). pytest's rootdir insertion
does not reliably provide that under this layout — measured: collection failed
with `ModuleNotFoundError: No module named 'pm_test_support'` — so the path is
declared here rather than assumed. `conftest.py` is imported before collection,
which is the only hook early enough to matter.

The matching declaration for static analysis is `extraPaths` in
`pyproject.toml`; pyright has no equivalent of pytest's rule and needs telling
separately, so the two must move together.
"""

import sys
from pathlib import Path

_TESTS_DIR = str(Path(__file__).resolve().parent)

if _TESTS_DIR not in sys.path:
    sys.path.insert(0, _TESTS_DIR)
