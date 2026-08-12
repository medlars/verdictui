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
