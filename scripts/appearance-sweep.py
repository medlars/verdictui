#!/usr/bin/env python3
"""Measure a real app's root background under a light and a dark launch (CTS-EA04B049).

Exit 0 only when the two launches measure different modal backgrounds with the
dark one darker; exit 2 when a launch could not be measured, or when its requested
appearance could not be realised (a dark launch on a Light host: no launch argument
makes an app dark there, measured in run 36986731637, CIS-D1582551) — never a pass
and never a defect in the app.

`--product-sweep unavailable|realised` instead checks `verdictui sweep --app
--color-schemes dark`: on a Light host its dark cell must be reported unavailable,
on a Dark host it must be launched and judged.
"""

import argparse
import collections
import json
import re
import subprocess
import sys
import time
from pathlib import Path

LAUNCH_ARGS = {
    "light": ["-NSRequiresAquaSystemAppearance", "YES"],
    "dark": ["-AppleInterfaceStyle", "Dark"],
}
# Tolerates JSON, `key: value` and `key=value` renderings of the attribute.
_BACKGROUND = re.compile(r"color\.background\W{0,6}(#[0-9A-Fa-f]{6})")
_HEX_COLOR = re.compile(r"#[0-9A-Fa-f]{6}")
_APPEARANCE_QUERY = (
    'tell application "System Events" to tell appearance preferences to get dark mode'
)
SETTLE_SECONDS = 8
COMMAND_TIMEOUT_SECONDS = 120


def modal_background(output: str) -> str | None:
    """Most frequent `color.background` in `inspect --colors` output, or None."""
    counts = collections.Counter(m.upper() for m in _BACKGROUND.findall(output))
    return counts.most_common(1)[0][0] if counts else None


def luminance(hex_color: str) -> float:
    """Rec. 709 relative brightness in 0...255 of `#RRGGBB`.

    Anything else raises: sliced at fixed offsets, `FFFFFF` or `#FFFFFF80`
    would yield a plausible but wrong brightness.
    """
    if not _HEX_COLOR.fullmatch(hex_color):
        raise ValueError(f"not a #RRGGBB colour: {hex_color!r}")
    r, g, b = (int(hex_color[i : i + 2], 16) for i in (1, 3, 5))
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def verdict(
    measured: dict[str, str | None], host_dark: dict[str, bool | None] | None = None
) -> tuple[int, str]:
    """Exit code and one-line reason from the per-scheme modal backgrounds.

    `host_dark` is the system appearance observed at each launch; a dark launch
    on a host not observed Dark did not get the appearance it asked for.
    """
    if host_dark is not None and host_dark.get("dark") is not True:
        return 2, (
            "unavailable: the dark launch ran on a host not observed in Dark mode "
            f"({host_dark.get('dark')}), so its appearance was not realised"
        )
    missing = [scheme for scheme in LAUNCH_ARGS if not measured.get(scheme)]
    if missing:
        return 2, f"unavailable: no color.background measured for {', '.join(missing)}"
    light, dark = measured["light"], measured["dark"]
    assert light and dark
    if light == dark:
        return 1, f"both launches measured {light}: the scheme argument had no effect"
    if luminance(dark) >= luminance(light):
        return 1, f"dark {dark} is not darker than light {light}"
    return 0, f"light {light} vs dark {dark}"


def host_is_dark() -> bool | None:
    """The system appearance as System Events reports it, or None if unobservable.

    Not `defaults read -g AppleInterfaceStyle`: that key can read Dark while
    apps still launch light (run 36986731637).
    """
    try:
        done = subprocess.run(
            ["osascript", "-e", _APPEARANCE_QUERY],  # nosec B607 - osascript from the fixed system PATH
            capture_output=True,
            text=True,
            check=False,
            timeout=COMMAND_TIMEOUT_SECONDS,
        )
    except subprocess.SubprocessError, OSError:
        return None
    answer = done.stdout.strip()
    return {"true": True, "false": False}.get(answer) if done.returncode == 0 else None


def dark_cell_status(report: str) -> str | None:
    """The `status` of the dark cell in `verdictui sweep --app` JSON, or None."""
    try:
        cells = json.loads(report)["cells"]
    except ValueError, KeyError, TypeError:
        return None
    for cell in cells if isinstance(cells, list) else []:
        if isinstance(cell, dict) and str(cell.get("colorScheme", "")).lower() == "dark":
            status = cell.get("status")
            return status if isinstance(status, str) else None
    return None


def product_verdict(expected: str, status: str | None) -> tuple[int, str]:
    """Whether the product sweep's dark cell matches the host's expectation."""
    if status is None:
        return 2, "unavailable: the sweep printed no dark cell status"
    realised = status != "unavailable"
    if (expected == "realised") == realised:
        return 0, f"dark cell status {status}, as expected ({expected})"
    return 1, f"dark cell status {status}, expected {expected}"


def _product_sweep(binary: Path, app: Path, expected: str) -> int:
    done = subprocess.run(
        [str(binary), "sweep", "--app", str(app), "--color-schemes", "dark"],
        capture_output=True,
        text=True,
        check=False,
        timeout=COMMAND_TIMEOUT_SECONDS,
    )
    print(f"[product] sweep exit {done.returncode}", flush=True)
    if done.stderr:
        print(done.stderr[-2000:], file=sys.stderr)
    code, reason = product_verdict(expected, dark_cell_status(done.stdout))
    print(f"appearance-sweep product: exit {code}: {reason}")
    return code


def _measure(binary: Path, app: Path, scheme: str) -> str | None:
    process_name = app.stem
    subprocess.run(["pkill", "-x", process_name], check=False, timeout=30)  # nosec B607 - fixed system PATH
    time.sleep(2)
    try:
        subprocess.run(
            ["open", "-n", "-a", str(app), "--args", *LAUNCH_ARGS[scheme]],  # nosec B607
            check=True,
            timeout=60,
        )
        time.sleep(SETTLE_SECONDS)
        pid = subprocess.run(
            ["pgrep", "-nx", process_name],  # nosec B607
            capture_output=True,
            text=True,
            check=True,
            timeout=30,
        ).stdout.strip()
        done = subprocess.run(
            [str(binary), "inspect", "--pid", pid, "--colors"],
            capture_output=True,
            text=True,
            check=False,
            timeout=COMMAND_TIMEOUT_SECONDS,
        )
        print(f"[{scheme}] inspect exit {done.returncode}, {len(done.stdout)} bytes", flush=True)
        if done.returncode != 0:
            print(done.stderr[-2000:], file=sys.stderr)
        return modal_background(done.stdout)
    except (subprocess.SubprocessError, OSError) as error:
        print(f"[{scheme}] could not measure: {error}", file=sys.stderr)
        return None
    finally:
        subprocess.run(["pkill", "-x", process_name], check=False, timeout=30)  # nosec B607 - fixed system PATH


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--product-sweep", choices=["unavailable", "realised"])
    args = parser.parse_args(argv)
    print(f"host dark mode: {host_is_dark()}", flush=True)
    if args.product_sweep:
        return _product_sweep(args.binary, args.app, args.product_sweep)
    measured: dict[str, str | None] = {}
    host_dark: dict[str, bool | None] = {}
    for scheme in LAUNCH_ARGS:
        host_dark[scheme] = host_is_dark()
        measured[scheme] = _measure(args.binary, args.app, scheme)
    code, reason = verdict(measured, host_dark)
    print(f"appearance-sweep: exit {code}: {reason}")
    return code


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
