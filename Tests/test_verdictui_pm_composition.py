"""The PM must actually COMPOSE the mixins its stages live in.

CIS-A5A83803 (`VerdictUISmokeMixin`) and CIS-DD1B92FE (`VerdictUIStagesMixin`)
are the only two of the 13 testwatch rows on this project that are genuinely
new. The other 11 name stages that existed in the pre-split monolith and are
RELOCATED, which the TestWatch detector fix (364de9a) accounts for; these two
are classes the 2073-line split created as containers, so they have no earlier
path to be relocated from.

NAMING A CLASS IN A TEST WOULD BE VACUOUS — the symbol-reference pattern
CIS-F5AF8E70 exists to stop TestWatch rewarding. A container class has almost no
behaviour of its own, and every stage it carries is exercised through the PM
already.

There is exactly one thing about it that can silently be WRONG, and it is worth
a test: the composition. Drop a mixin from the bases and every stage it carries
disappears from the PM, while the module still imports, the class still
constructs, and nothing raises. The stages simply stop running — a PM that
measures less and reports the same.
"""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[1]
# The PM imports pm_base at module load; CI clones this repo alone, so the honest
# result there is a SKIP -- never a red for an absent optional sibling.
PM_BASE = Path.home() / "Projects" / "shared-libs" / "pm-base"
requires_pm_base = pytest.mark.skipif(
    not PM_BASE.exists(), reason="shared-libs/pm-base absent; the PM module cannot import"
)
PM = REPO / "scripts" / "verdictui-pm.py"
SCRIPTS = REPO / "scripts"


@pytest.fixture(scope="module")
def pm_module():
    """Load the hyphenated PM script by path, with scripts/ importable."""
    if str(SCRIPTS) not in sys.path:
        sys.path.insert(0, str(SCRIPTS))
    spec = importlib.util.spec_from_file_location("verdictui_pm", PM)
    if spec is None or spec.loader is None:
        pytest.fail(f"cannot load {PM}")
    mod = importlib.util.module_from_spec(spec)
    sys.modules["verdictui_pm"] = mod
    spec.loader.exec_module(mod)
    return mod


@requires_pm_base
def test_the_pm_composes_both_stage_mixins(pm_module) -> None:
    names = [base.__name__ for base in pm_module.VerdictUIPM.__mro__]
    for mixin in ("VerdictUIStagesMixin", "VerdictUISmokeMixin"):
        assert mixin in names, (
            f"{mixin} is not in VerdictUIPM's MRO, so every stage it carries has "
            f"silently left the pipeline. The module still imports and the class "
            f"still constructs — nothing raises. MRO: {names}"
        )


@requires_pm_base
def test_every_stage_each_mixin_defines_is_reachable_on_the_pm(pm_module) -> None:
    """The composition is the mechanism; THIS is the consequence, and it is what
    actually matters. Asserting the base list alone would pass if a mixin were
    present but its stages renamed out from under the runner."""
    import verdictui_pm_smoke  # noqa: PLC0415 — resolved via the fixture's sys.path
    import verdictui_pm_stages  # noqa: PLC0415

    missing: list[str] = []
    total = 0
    for module in (verdictui_pm_stages, verdictui_pm_smoke):
        for cls_name in ("VerdictUIStagesMixin", "VerdictUISmokeMixin"):
            cls = getattr(module, cls_name, None)
            if cls is None:
                continue
            for attr in vars(cls):
                if not attr.startswith("stage_"):
                    continue
                total += 1
                if not hasattr(pm_module.VerdictUIPM, attr):
                    missing.append(f"{cls_name}.{attr}")
    # POSITIVE CONTROL. If the walk found no stages at all — a renamed prefix, a
    # failed import, a changed class name — then `missing` is empty for a reason
    # that has nothing to do with composition, and the assertion below would pass
    # vacuously (lesson 328).
    assert total >= 5, f"only {total} stage(s) discovered; the walk is not reading the mixins"
    assert not missing, f"stages defined on a mixin but absent from the PM: {missing}"
