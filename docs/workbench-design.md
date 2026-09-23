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
