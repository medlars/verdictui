#!/usr/bin/env python3
"""Measure a real app's root background under a light and a dark launch (CTS-EA04B049).

Run on a host whose system appearance is Light so the DARK launch is the direction
that cannot be faked by the host. Exit 0 only when the two launches measure
different modal backgrounds with the dark one darker; exit 2 when a launch could
not be measured at all, never a skip.
"""

import argparse
import collections
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
SETTLE_SECONDS = 8
COMMAND_TIMEOUT_SECONDS = 120


def modal_background(output: str) -> str | None:
    """Most frequent `color.background` in `inspect --colors` output, or None."""
    counts = collections.Counter(m.upper() for m in _BACKGROUND.findall(output))
    return counts.most_common(1)[0][0] if counts else None


def luminance(hex_color: str) -> float:
    """Rec. 709 relative brightness in 0...255 of `#RRGGBB`."""
    r, g, b = (int(hex_color[i : i + 2], 16) for i in (1, 3, 5))
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def verdict(measured: dict[str, str | None]) -> tuple[int, str]:
    """Exit code and one-line reason from the per-scheme modal backgrounds."""
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


def _measure(binary: Path, app: Path, scheme: str) -> str | None:
    process_name = app.stem
    subprocess.run(["pkill", "-x", process_name], check=False, timeout=30)
    time.sleep(2)
    subprocess.run(
        ["open", "-n", "-a", str(app), "--args", *LAUNCH_ARGS[scheme]], check=True, timeout=60
    )
    time.sleep(SETTLE_SECONDS)
    try:
        pid = subprocess.run(
            ["pgrep", "-nx", process_name], capture_output=True, text=True, check=True, timeout=30
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
        subprocess.run(["pkill", "-x", process_name], check=False, timeout=30)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--app", type=Path, required=True)
    args = parser.parse_args(argv)
    host = subprocess.run(
        ["defaults", "read", "-g", "AppleInterfaceStyle"],
        capture_output=True,
        text=True,
        check=False,
    )
    print(f"host appearance: {host.stdout.strip() or 'Light (key unset)'}", flush=True)
    measured = {scheme: _measure(args.binary, args.app, scheme) for scheme in LAUNCH_ARGS}
    code, reason = verdict(measured)
    print(f"appearance-sweep: exit {code}: {reason}")
    return code


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
