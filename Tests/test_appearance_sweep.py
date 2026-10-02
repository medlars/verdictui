"""scripts/appearance-sweep.py: the verdict must tell 'no effect' from 'unmeasured'."""

import importlib.util
from pathlib import Path

import pytest

pytestmark = pytest.mark.quick

_SPEC = importlib.util.spec_from_file_location(
    "appearance_sweep", Path(__file__).resolve().parents[1] / "scripts" / "appearance-sweep.py"
)
assert _SPEC and _SPEC.loader
sweep = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(sweep)


def test_modal_background_picks_the_most_frequent_colour_in_any_rendering():
    text = (
        '{"color.background": "#ffffff"} color.background: #FFFFFF color.background=#1E1E1E '
        "color.foreground: #000000"
    )
    assert sweep.modal_background(text) == "#FFFFFF"


def test_modal_background_is_none_without_a_sample():
    assert sweep.modal_background("color.contrast: 4.5") is None


def test_verdict_passes_only_when_dark_is_darker():
    assert sweep.verdict({"light": "#FFFFFF", "dark": "#1E1E1E"})[0] == 0


def test_verdict_fails_when_the_scheme_had_no_effect():
    code, reason = sweep.verdict({"light": "#1E1E1E", "dark": "#1E1E1E"})
    assert code == 1 and "no effect" in reason


def test_verdict_fails_when_dark_is_lighter():
    assert sweep.verdict({"light": "#1E1E1E", "dark": "#FFFFFF"})[0] == 1


def test_verdict_is_unavailable_not_failed_when_a_launch_was_unmeasured():
    code, reason = sweep.verdict({"light": "#FFFFFF", "dark": None})
    assert code == 2 and "dark" in reason


def test_a_dark_launch_on_a_light_host_is_unavailable_not_failed_or_passed():
    code, reason = sweep.verdict(
        {"light": "#FFFFFF", "dark": "#FFFFFF"}, {"light": False, "dark": False}
    )
    assert code == 2 and "not realised" in reason


def test_an_unobservable_host_appearance_is_unavailable_not_a_pass():
    code, _ = sweep.verdict({"light": "#FFFFFF", "dark": "#1E1E1E"}, {"light": None, "dark": None})
    assert code == 2


def test_a_dark_launch_on_a_dark_host_is_judged_on_its_colours():
    host = {"light": True, "dark": True}
    assert sweep.verdict({"light": "#FFFFFF", "dark": "#1E1E1E"}, host)[0] == 0
    assert sweep.verdict({"light": "#FFFFFF", "dark": "#FFFFFF"}, host)[0] == 1


def test_dark_cell_status_reads_the_sweep_report():
    report = (
        '{"app":"/A.app","cells":[{"colorScheme":"light","status":"pass"},'
        '{"colorScheme":"dark","status":"unavailable"}]}'
    )
    assert sweep.dark_cell_status(report) == "unavailable"
    assert sweep.dark_cell_status("not json") is None
    assert sweep.dark_cell_status('{"cells":[{"colorScheme":"light","status":"pass"}]}') is None


def test_product_verdict_requires_the_host_expectation():
    assert sweep.product_verdict("unavailable", "unavailable")[0] == 0
    assert sweep.product_verdict("unavailable", "pass")[0] == 1
    assert sweep.product_verdict("realised", "fail")[0] == 0
    assert sweep.product_verdict("realised", "unavailable")[0] == 1
    assert sweep.product_verdict("realised", None)[0] == 2
