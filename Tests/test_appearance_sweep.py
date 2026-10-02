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


@pytest.mark.parametrize(
    ("colour", "expected"),
    [
        ("#000000", 0.0),
        ("#FFFFFF", 255.0),
        ("#ffffff", 255.0),
        ("#FF0000", 0.2126 * 255),
        ("#00FF00", 0.7152 * 255),
        ("#0000FF", 0.0722 * 255),
        ("#1E1E1E", 30.0),
        ("#010203", 0.2126 * 1 + 0.7152 * 2 + 0.0722 * 3),
    ],
)
def test_luminance_weights_each_channel_by_rec709(colour, expected):
    assert sweep.luminance(colour) == pytest.approx(expected)


def test_luminance_orders_green_over_red_over_blue_at_equal_intensity():
    assert sweep.luminance("#00FF00") > sweep.luminance("#FF0000") > sweep.luminance("#0000FF")


@pytest.mark.parametrize(
    "bad", ["FFFFFF", "#FFF", "#FFFFFF80", "#GGGGGG", "", "#12345", " #FFFFFF", "#FFFFFF\n"]
)
def test_luminance_refuses_anything_but_rrggbb(bad):
    with pytest.raises(ValueError):
        sweep.luminance(bad)


_STUB_COMMAND = """#!/bin/bash
printf '%s\\n' "$(basename "$0") $*" >> "$SWEEP_CALLS"
case "$(basename "$0")" in
  open) [ -n "$OPEN_FAILS" ] && exit 1; printf '%s' "$*" > "$SWEEP_LAUNCH" ;;
  pgrep) [ -n "$PGREP_FAILS" ] && exit 1; echo 4242 ;;
  verdictui)
    case "$(cat "$SWEEP_LAUNCH")" in
      *AppleInterfaceStyle*) colour="#1E1E1E" ;;
      *) colour="#FFFFFF" ;;
    esac
    printf 'color.background: %s\\ncolor.background: %s\\ncolor.background: #808080\\n' \\
      "$colour" "$colour"
    echo "inspect diagnostics" >&2
    exit "${INSPECT_EXIT:-0}" ;;
esac
exit 0
"""


@pytest.fixture
def launch_host(tmp_path, monkeypatch):
    """Real subprocesses against stub `pkill`/`open`/`pgrep`/verdictui on PATH."""
    bindir = tmp_path / "bin"
    bindir.mkdir()
    for name in ("pkill", "open", "pgrep", "verdictui"):
        (bindir / name).write_text(_STUB_COMMAND)
        (bindir / name).chmod(0o755)
    calls = tmp_path / "calls"
    calls.write_text("")
    monkeypatch.setenv("PATH", f"{bindir}:/usr/bin:/bin")
    monkeypatch.setenv("SWEEP_CALLS", str(calls))
    monkeypatch.setenv("SWEEP_LAUNCH", str(tmp_path / "launch"))
    for name in ("OPEN_FAILS", "PGREP_FAILS", "INSPECT_EXIT"):
        monkeypatch.delenv(name, raising=False)
    monkeypatch.setattr(sweep.time, "sleep", lambda _seconds: None)

    def calls_made() -> list[str]:
        return calls.read_text().splitlines()

    return bindir / "verdictui", calls_made


APP = Path("/System/Applications/Dictionary.app")


def test_measure_launches_the_app_with_the_scheme_arguments_and_inspects_its_pid(launch_host):
    binary, calls_made = launch_host
    assert sweep._measure(binary, APP, "light") == "#FFFFFF"
    assert calls_made() == [
        "pkill -x Dictionary",
        f"open -n -a {APP} --args -NSRequiresAquaSystemAppearance YES",
        "pgrep -nx Dictionary",
        "verdictui inspect --pid 4242 --colors",
        "pkill -x Dictionary",
    ]


def test_measure_returns_the_dark_launch_background(launch_host):
    binary, calls_made = launch_host
    assert sweep._measure(binary, APP, "dark") == "#1E1E1E"
    assert f"open -n -a {APP} --args -AppleInterfaceStyle Dark" in calls_made()


def test_measure_reports_a_failed_inspect_on_stderr_and_still_reads_its_output(
    launch_host, capsys, monkeypatch
):
    binary, _ = launch_host
    monkeypatch.setenv("INSPECT_EXIT", "3")
    assert sweep._measure(binary, APP, "light") == "#FFFFFF"
    captured = capsys.readouterr()
    assert "[light] inspect exit 3" in captured.out
    assert "inspect diagnostics" in captured.err


def test_measure_is_unmeasured_not_a_crash_when_the_app_never_appears(
    launch_host, capsys, monkeypatch
):
    binary, calls_made = launch_host
    monkeypatch.setenv("PGREP_FAILS", "1")
    assert sweep._measure(binary, APP, "dark") is None
    assert "[dark] could not measure" in capsys.readouterr().err
    assert calls_made()[-1] == "pkill -x Dictionary", "the launched app must be killed"
    assert not any(c.startswith("verdictui") for c in calls_made())


def test_measure_is_unmeasured_not_a_crash_when_the_launch_fails(launch_host, capsys, monkeypatch):
    """A crash exits 1, which `main` reserves for a defect in the app; unmeasured is 2."""
    binary, calls_made = launch_host
    monkeypatch.setenv("OPEN_FAILS", "1")
    assert sweep._measure(binary, APP, "light") is None
    assert "[light] could not measure" in capsys.readouterr().err
    assert calls_made()[-1] == "pkill -x Dictionary"


def test_measure_is_unmeasured_when_the_binary_cannot_run(launch_host, tmp_path):
    _, calls_made = launch_host
    assert sweep._measure(tmp_path / "missing-verdictui", APP, "light") is None
    assert calls_made()[-1] == "pkill -x Dictionary"
