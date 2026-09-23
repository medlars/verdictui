# VerdictUI desktop workbench design

## Brief and critique before implementation

Audience: the developer verifying their own product. The workbench's job is to
turn declared checks into inspectable evidence without overstating what ran.
The owner's direction is a web-rendered macOS app with CleanMyMac-like polish,
not a copy of its identity. References: [MacPaw's official product page](https://macpaw.com/cleanmymac)
and [official release page](https://macpaw.com/cleanmymac/whats-new). Inspected the
actual product screenshot from the first page: a translucent violet sidebar,
large dimensional Smart Care object, generous open space, and a single primary
action. The workbench carries forward the material and focal-object approach;
the owner's pearl/lilac direction replaces the reference's dark purple canvas.
Reference captures: `/tmp/verdictui-workbench-design-artifacts/cleanmymac-app-reference.png`
and `cleanmymac-product-reference.png`. No MacPaw assets are bundled.

Three layouts considered: a metrics dashboard, a full-screen animated lens, and
a quiet project sidebar beside a verification workspace. The dashboard suggests
coverage totals we have not measured; the full-screen lens hides findings.
Select the workspace: give the lens one focal area and keep evidence adjacent.

```text
Projects          Project name                 Run checks
  folder          selected path · saved checks
                  Verification lens | Check sequence
Workspace         Findings / Checks / History
Checks            cited findings or honest empty state
History
```

Tokens: pearl `#f8f7fb`, lilac mist `#eeebf6`, ink `#252337`,
iris `#6653cc`, sea glass `#177c68`, clay `#ae493f`. Body uses the native
Apple system sans; display uses the locally installed rounded system face;
SFMono/Menlo names paths and evidence. No downloaded fonts or external assets.
Spacing follows a 4px unit; surfaces have 16–24px radii, controls 9–12px.

Signature: a dimensional verification lens. Concentric translucent shells,
a solid V-shaped aperture, and small orbital markers express inspection.
The lens is sculptural while idle, visibly rotates only on a real `running`
progress message, and resolves to the actual report status. It does not
manufacture progress, sweep fake files, or imply unmeasured success.

Critique: a purple gradient dashboard with floating cards would be generic.
Keep the pearl canvas largely flat, use one lens instead of decoration in every
panel, align evidence as readable rows, and reserve accent color for active
navigation and the primary action. The ring is never a percentage; a separate
fraction reports terminal checks received / total checks.

## Motion and accessibility contract

The design-motion frequency gate rules out page-load choreography and animated
tab/list navigation. Orbit animation has one purpose: indicate actual work.
Only transforms/opacity animate; movement stops on result, error, or confirmed
cancellation. Cancellation requests remain visibly pending until the host ends
the work. Press feedback is 120ms; occasional state feedback is 180ms with
`cubic-bezier(0.23, 1, 0.32, 1)`. Keyboard changes are immediate. Reduced motion
removes all infinite motion and positional effects, retaining color feedback.

Every action uses a semantic button. Inputs have visible labels, keyboard focus
is explicit, progress uses a status region, and findings use readable text in
addition to severity color. Layout must avoid horizontal overflow at 1000×700
and 360px wide. Unavailable connections disable host actions and explain the
required action. Empty projects, empty checks, and empty evidence each retain a
next step; none display a success badge.

## Data boundary

Only the native host supplies projects, saved checks, results, and history.
No localStorage, network calls, sample results, timers simulating progress, or
untrusted HTML. The UI posts the six specified actions to the WebKit handler;
the host calls `window.verdictui.receive`. Test fixtures belong to an external
test harness and are never bundled with the app.

## Rendered critique and verification — 2026-09-23

Playwright Chromium and WebKit passed 76 assertions (38 in each engine).
The external harness injects the bridge; no fixture state is in the bundled UI.
It covers all four check editors and bridge actions, explicit save acknowledgement,
duplicate-name recovery, malformed/duplicate progress, actual rendered motion,
cancellation, findings/history, keyboard navigation, text injection, empty-report
refusal, absent connection, and reduced motion. There were no page exceptions.

Measured geometry in both engines:

| Surface | Measurement |
| --- | --- |
| 1000×700 desktop | document width 1000; sidebar 204; stage/evidence x=236, width=732 |
| 360px narrow layout | document width 360; stage/evidence x=18, width=324 |
| Navigation siblings | all 44px high |
| Desktop name/type controls | both 339.5×38px |

The screenshot critique found two visible defects before delivery: suppressed
mobile line breaks joined adjacent words, and WebKit's native select stayed
20px high beside a 37px input. Preserve whitespace around responsive line breaks;
give the select and input matching geometry and an explicit local chevron.
The progress warning now clears when a complete result arrives. These fixes
passed the final rendered rerun.

Motion proof compares actual lens-region pixels across frames. WebKit's
composited animation can leave `getComputedStyle().transform` at its base value
even while visible pixels move, so a timer or computed-style check alone is
insufficient. The running state has six active loops; idle/final/reduced-motion
states have none. No process is slowed to make an animation visible.

Artifacts and reproducible harness:
`/Users/eiman/.codex/visualizations/2026/09/23/01a0cd0e-b53d-7052-ad1d-cd9b7ef78b87/workbench-design/`.
Review `webkit-running-1000.png`, `webkit-findings-1000.png`,
`webkit-findings-360.png`, `webkit-checks-360.png`, `verification.json`, and the
rectangle JSON files. Run `python3.14 verify_workbench.py <repository-root>`.

Frontend verification is complete. The native shell's real engine execution,
packaging, and end-to-end evidence remain the integration lane's responsibility;
an injected bridge is not evidence that those native paths ran.

## Durable smoke command and dependencies

The checked-in `scripts/workbench-smoke.py` now owns this acceptance flow. It
accepts a repository root (defaults to its own repository) and `--artifact-dir`.
The only test-only dependencies are `playwright==1.61.0` and `Pillow==12.3.0`,
using Python 3.14. Install the matching official browser runtimes with
`python3.14 -m playwright install chromium webkit`.

```bash
python3.14 scripts/workbench-smoke.py --artifact-dir /tmp/verdictui-workbench-smoke
python3.14 -m pytest Tests/test_workbench_smoke.py -q
```

The terminal gate is `WORKBENCH SMOKE PASS` with a positive measured assertion
count and both browser flows complete. `verification.json` records actual
passed assertions, failures, and completed/expected browsers separately.
An absent browser/dependency is a failure, never a successful check. Seven fast
Python regressions prove empty runs, absent browser assertions, runtime
unavailability, and missing resources cannot produce the pass marker; failed
assertions count once and retain earlier measured passes. The durable rerun
passed 86 browser assertions, zero failures, and both complete browser flows;
all seven Python gate regressions passed as well.

The durable flow also covers inherited-property check kinds (`__proto__`,
`constructor`, `toString`) and preserving a saved web expected-text value.
HTTP/HTTPS requests are blocked and counted; a passing run made none.

## Source review and app icon

Source/asset review found one concrete availability defect: looking up
`fields[check.kind]` without an own-property check allowed a persisted kind such
as `__proto__` to crash rendering. The integration lane fixed all three lookups;
the durable smoke tests reproduce those inputs. Saved web expectations and the
unsupported scenario runner field were also corrected by the integration lane.
Untrusted evidence uses text nodes, DOM properties, and fixed attribute names;
there is no `innerHTML`, storage dependency, eval, or external asset request.
The host remains responsible for validating bridge messages and running targets.

The app icon is the original lens signature in `assets/workbench-icon.svg`:
local gradients, concentric optical shells, and the VerdictUI aperture on a pearl
rounded square. Its 1024×1024 browser render is measured; it contains no external
references or third-party branding. `assets/workbench-icon.icns` contains all ten
standard macOS representations (16 through 1024 pixels). `iconutil` round-trip
verification confirmed each size and pixel-identical 1024px source content.
No new runtime dependency is needed by the app.

Regenerate from the repository root with the pinned Playwright dependency above,
its Chromium runtime, and macOS's built-in `sips` and `iconutil`. Intermediate
PNGs live in the temporary directory; only the resulting ICNS belongs in Git.

```bash
python3.14 - <<'PY'
from pathlib import Path
import subprocess
import tempfile
from playwright.sync_api import sync_playwright

source = Path('assets/workbench-icon.svg').resolve()
with tempfile.TemporaryDirectory(prefix='verdictui-icon-') as temporary:
    temporary = Path(temporary)
    raster = temporary / 'source.png'
    iconset = temporary / 'VerdictUI.iconset'
    iconset.mkdir()
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch()
        page = browser.new_page(
            viewport={'width': 1024, 'height': 1024}, device_scale_factor=1
        )
        page.goto(source.as_uri())
        page.screenshot(path=str(raster), omit_background=True)
        browser.close()
    for size in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            suffix = '@2x' if scale == 2 else ''
            target = iconset / f'icon_{size}x{size}{suffix}.png'
            pixels = str(size * scale)
            subprocess.run(
                ['sips', '-z', pixels, pixels, str(raster), '--out', str(target)],
                check=True, capture_output=True,
            )
    subprocess.run(
        ['iconutil', '-c', 'icns', str(iconset),
         '-o', 'assets/workbench-icon.icns'], check=True,
    )
PY
```

Independent review of the integrated native window confirmed the same bundled
design and actual persisted pass/fail/unavailable history. The read-only visual
review identified a history alignment defect: content-width status pills placed
the date/count column at x=335.27, 295.50, and 302.67 respectively in a 1000px
WebKit viewport. The integration lane repaired the status column to 70px. The
expanded smoke gate measures all three history states at 1000px and 360px in both
engines and passed against the integrated assets: 94 assertions, zero failures,
2/2 browser flows complete. Date/count columns now share x=340 at desktop and
x=113 at 360px; result buttons align and the document has no horizontal overflow.
The narrow screenshot also confirms readable wrapped dates and unclipped badges.
Evidence: `/tmp/verdictui-workbench-final-review/verification.json`,
`webkit-history-1000-rects.json`, `webkit-history-360-rects.json`, and their PNGs
in the same directory. No other high-confidence visual defect was observed;
this review remains separate from the native engine acceptance.
