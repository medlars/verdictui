# Wave 8 — measured AX ground truth (before any witness code)

Everything below was MEASURED with throwaway spikes on 2026-08-12, not reasoned
from the plan. `no.md` #24: measure the current output first and read it as a
finding, because the shapes with no coverage are the ones most likely to differ
from what the plan assumed.

## 1. The witness MUST run out-of-process

A process cannot read its own AX tree. `AXUIElementCopyAttributeValue` for
`kAXWindowsAttribute` on `AXUIElementCreateApplication(getpid())` returns
**-25208 (`kAXErrorAttributeUnsupported`)** while `NSApp.windows.count == 1` and
`visible == 1` in the same instant. The accessibility server mediates
cross-process; a self-query is not a supported path.

Consequence for Task 1: the witness is a **windowed host subprocess** plus an
in-test **reader**. It cannot be a function called inside the test process, and
no amount of permission changes that.

## 2. `NSApp.run()` is the registration trigger — not the window, not the bundle

A visible `NSWindow` in a trusted, bundled process is still invisible to an
external reader (**-25204 `kAXErrorAPIDisabled`**) until the real AppKit event
loop runs. Measured across four variables, changed one at a time:

| Variable                         | Result |
| -------------------------------- | ------ |
| `.accessory` policy + `orderFront` + `RunLoop.run` | -25204 |
| `.regular` + `activate` + `makeKeyAndOrderFront` + `RunLoop.run` | -25204 |
| ...plus a real `.app` bundle with `Info.plist`     | -25204 |
| ...with **`NSApp.run()`** instead of `RunLoop.run` | **err=0, full tree** |

`RunLoop.current.run(until:)` pumps the runloop but does not complete AppKit
activation. This is the single line that separates a working witness from one
that reports "no windows" forever.

## 3. The trust check is necessary but NOT sufficient

`AXIsProcessTrusted()` returned `true` in every failing case above. A witness
that gates only on `AXIsProcessTrusted` will proceed confidently and then read
an empty tree — indistinguishable, at the point of use, from a scenario that
genuinely renders nothing. Task 3's warning path must therefore be driven by
**the read failing**, not by the trust flag alone.

Positive control that proves the reader itself works: pointing the same reader
at Finder returns `err=0` and a full window tree. Without that control,
"-25204" reads as "the reader is broken" and sends the investigation at the
wrong subject.

## 4. Role mapping is 1:1 with the Wave 1 vocabulary

Measured against a `VStack` of `Text` / `Button` / `Toggle` / `TextField` / `Image`:

| AX role        | subrole          | `Role`       | text source |
| -------------- | ---------------- | ------------ | ----------- |
| `AXWindow`     | `AXStandardWindow` | (root)     | —           |
| `AXGroup`      | `AXHostingView`  | `.container` | —           |
| `AXStaticText` | —                | `.text`      | `AXValue`   |
| `AXButton`     | —                | `.button`    | `AXDescription` |
| `AXCheckBox`   | —                | `.toggle`    | `AXDescription` (+ `AXValue` = 0/1 state) |
| `AXTextField`  | —                | `.textField` | `AXValue`   |
| `AXImage`      | —                | `.image`     | `AXDescription` |

**Text lives in two different attributes depending on role.** Reading only
`AXValue` loses every button and image label; reading only `AXDescription`
loses all static text and field contents. A normalizer that picks one is wrong
for half the vocabulary, and the half it loses still produces a tree that looks
populated.

## 5. Coordinates: screen-space, y-DOWN, converted WITHOUT screen height

AX reports y-down from the top of the screen; AppKit places windows y-up from
the bottom. The full conversion checks out exactly (delta **0.0**):

    ax_window_y == screen_height_pts - (appkit_y + window_height)
    745.0       == 1117.0 - (100.0 + 272.0)

But the normalizer must **not** use that formula: subtracting the *content
group's* AX origin yields SwiftUI root coordinates directly, needs no display
metrics, and is immune to a screen change or a multi-monitor setup.

    root_y = ax_node_y - ax_content_group_y

Verified against the measured tree (content group at y=777.0):

| Node      | AX y   | root y  |
| --------- | ------ | ------- |
| Text      | 824.25 |   47.25 |
| Button    | 852.50 |   75.50 |
| Toggle    | 888.50 |  111.50 |
| TextField | 918.00 |  141.00 |
| Image     | 955.00 |  178.00 |

The window frame also carries a **32 pt titlebar** above the content group, which
is why the window origin is the wrong anchor and the hosting group is the right one.

## 6. `OracleHost` stays windowless — the witness does not reuse it

`OracleHost` never attaches to an `NSWindow` on purpose: that is the CI story,
proven by a sandbox spike that denies every `com.apple.windowserver*` mach-lookup.
The witness needs the opposite. These are two hosts with two different
constraints, and merging them would trade the CI property for the AX one.

## 7. A `Process`-spawned host is invisible to AX — the launch PATH is the variable

Found while wiring the integration test, and it cost the most time of anything
here because the failure names the wrong subject: the test failed with
`-25204`, the same code a permission problem produces, against a host that had
just been verified working by hand minutes earlier.

Measured, one variable at a time:

| Launch path                                   | AX read |
| --------------------------------------------- | ------- |
| shell (`./verdictui-witness-host`)             | **err=0, 1 window** |
| `Process` from `xctest`                        | -25204 |
| `Process` from a plain Swift CLI parent        | -25204 |
| `open -a` on a minimal `.app` bundle           | **err=0, 1 window** |

Two theories were tested and **falsified** before the real one was found, and
recording them matters as much as the answer:

- **Session/graphic access.** `SessionGetInfo` reports the identical session id
  (`100022`) and `sessionHasGraphicAccess: true` in both the shell and the
  xctest process. Not the cause.
- **Registration latency.** A shell-launched host is readable within 0.3 s and
  stays readable; a `Process`-spawned one is never readable, at any delay out to
  the full timeout. Not a race.

The cause is that a fork/exec child does not join the GUI session as a launched
application. `open` routes through **LaunchServices**, which registers it, and
the same spawning parent then reads a full tree. `WitnessHostProcess` therefore
generates a minimal `.app` at run time (never shipped, so it cannot drift from
the binary) and launches through `open -n -a`.

**`-n` is not optional**: without it LaunchServices reuses a still-terminating
host from a previous scenario, so the reader verifies the PREVIOUS scenario's
window while reporting the current scenario's name — a wrong answer that looks
entirely well-formed.

Two consequences worth carrying forward:

1. **`xctest` was not the culprit**, though it was the obvious suspect. Testing a
   plain CLI parent is what ruled it out, and without that control the fix would
   have been aimed at the test harness.
2. **The readiness handshake had to change.** The host's `WITNESS-READY <pid>`
   line is unreachable through LaunchServices (the process is detached; stdout
   is not connected), so readiness is now established by POLLING FOR THE WINDOW
   itself via the bundle identifier. That is the stronger signal anyway: the
   process exists well before the window server publishes it, and treating
   "process exists" as ready is precisely the race that reports -25204 as a
   product defect.

## 8. The AX tree can go DEGRADED for one app while the window is provably real

Found 2026-08-12 while building the Task 4 lie fixtures, and it cost the most
time of anything in Wave 8 because every signal points at the wrong subject.

`WitnessIntegrationTests` passed at **17:22:55** and failed at **18:04** with
`Sources/VerdictUIWitness/` byte-identical at HEAD (verified: `git status
--porcelain Sources/VerdictUIWitness/` empty, and the earlier green run is in
the same session's log). Nothing about the product changed between the two.

What the failure looks like from inside the reader:

| Probe | Result |
| --- | --- |
| `kAXWindowsAttribute` on the host app | status 0, array of **1** |
| role of that one element | **`AXApplication`** — not `AXWindow` |
| its children | an `AXApplication` with no geometry, and an `AXMenuBar` |
| `hostingContent(of:)` | finds no `AXHostingView`, no `AXGroup` |
| the anchor's `frame(of:)` | `nil` -> **`anchorUnreadable`** |

And what is true at the same instant, measured with three independent controls:

- The host **does** create a real window. Instrumenting `WitnessHost.run`
  printed `windowNumber=10183 visible=true screens=1 contentSize=(0,0,360,260)`.
- `CGWindowListCopyWindowInfo` **sees it on screen**: owner
  `VerdictUIWitnessHost`, name `VerdictUI Witness`, bounds 240x186, `layer 0`,
  `onscreen True`.
- A plain `NSWindow` (`windowNumber=10160`) and an `NSHostingView`-backed window
  (`windowNumber=10173`) both create and show normally from a throwaway binary
  in the same shell — so the window server itself is healthy.

So the window exists, is on screen, and is invisible to the accessibility server
*specifically for this process*. This is an OS-level state, not a product
defect, and it is not the `-25204` case of finding #7 either: the read
**succeeds** and returns a malformed tree rather than failing.

**The consequence for tests, which is the durable half.** There are now THREE
environment states a witness suite must tell apart, and only the first two were
modelled:

1. headless / no window server — skip
2. no Accessibility grant — skip
3. **the AX tree is degraded for this app while the window is real — must ALSO
   skip**, and nothing about `AXIsProcessTrusted()` distinguishes it (it stays
   `true` throughout, per finding #3)

Left unhandled, state 3 turns the honesty gate RED for the machine — the exact
failure `no.md` #15 names, on the one gate that must never be discounted. Both
`WitnessIntegrationTests` and `LieCatchTests` now discriminate it by catching
`anchorUnreadable` (and, in the lie suite, by a positive control that reads a
scenario known to be honest before asking the witness to judge a lie). The skip
names the state explicitly so a reader is not sent hunting a product bug.

**Suspected trigger, stated as a suspicion rather than a finding**: this session
launched and killed an unsigned generated `.app` bundle under the same bundle
identifier dozens of times. Four stale menu-bar-only windows from leaked hosts
were still in `CGWindowListCopyWindowInfo` when the degradation was noticed.
That was NOT tested by removing it — per `no.md` #31, a suspect that merely
correlates is not a cause until removing it changes the symptom, and killing the
strays did not restore the tree within this session. A fresh login session is
the documented recovery.
