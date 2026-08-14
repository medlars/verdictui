# 2026-020 — The witness window is readable without being visible

**Status:** Accepted (2026-08-14)

## Context

Wave 8's middle loop renders a scenario in a **real** `NSWindow` (`WitnessHost`) so an
external reader can see it through the accessibility server. That window is not
optional: measured 2026-08-12, a trusted, bundled process with an ordered-front window
is invisible to an AX reader (`-25204`) until the real AppKit event loop runs, and a
process cannot read its own AX tree at all (`-25208`). The window must exist, be ordered
front, and belong to a LaunchServices-registered app (`no.md` #42/#43).

Nothing said it had to be **visible to a person**. It was, and the owner reported it:
a titled "VerdictUI Witness" window flashing at the bottom-left of the screen 8–10 times
per run, each flash showing a different scenario — one window per witness test.

Measured 2026-08-14 from outside the host via `CGWindowListCopyWindowInfo`: one
on-screen entry, `alpha=1.0`, bounds `X=0 Y=784 360x292` on a 1728x1117 display.

**Twenty-two witness tests passed throughout.** Every one asked whether the AX server
could READ the window; none asked whether a person could SEE it. Readability and
visibility are independent properties of the same object, and the suite modelled one.

## Decision

1. `WitnessHost.run` sets **`window.alphaValue = 0`** before `makeKeyAndOrderFront`. The
   window server still assigns a windowNumber, still lists it as on-screen, and still
   publishes its AX tree — it composites nothing a person can see.
2. Visibility is asserted from **outside** the host, about its pid, by
   `WitnessHostProcess.compositedAlphas` reading `CGWindowListCopyWindowInfo`. The host
   is never asked to report on itself.
3. An **absent** window is a test FAILURE, not a pass. "Nothing is visible" is equally
   true of a host that published no window, which is the unreadable state the rest of the
   witness suite exists to catch.

## Alternatives considered

**An offscreen window origin.** This was the fix a previous session recorded, left
uncommitted as unverifiable. **Rejected on measurement — it cannot work.** `NSWindow`
constrains its frame to the visible screen: `origin: (-20000, -20000)` came back as
`(160, 800)`, fully on screen. Moving it after `orderFront` with `setFrameOrigin` does
move it, but AppKit clamps to keep part of a titled window reachable — it stops at
`x = -220` of a 260 pt window and `y = -79`, leaving a 40x41 pt fragment still flashing.
Even a bare `.zero` is pre-constrained, reporting `y = 41`. Implementing the recorded
sentence would have relocated the flash, not removed it. This is the decision's
load-bearing measurement: a clamped coordinate looks exactly like a fix that shipped.

**Withholding the window (or `.accessory` activation policy).** Rejected: it trades the
AX property this host exists for. `no.md` #42/#43 measured that an accessory app is not a
first-class AX citizen and that a window is what the server publishes.

**Reading `alphaValue` from inside the host.** Rejected as unfalsifiable. Measured: read
from inside, `CGWindowListCopyWindowInfo` returns nothing whether the window is visible
or hidden, because a shell-launched binary is not LaunchServices-registered — the same
mechanism `no.md` #43 records for AX. An instrument that gives the same answer in both
states is not an instrument (`no.md` #47).

## Consequences

- The witness runs invisibly; cross-validation behaviour is unchanged (775 Swift tests,
  0 failures, 0 skips — including all 23 witness tests, which is the evidence that
  readability survived).
- One new public API, `compositedAlphas`, whose vantage point (outside, by pid) is
  load-bearing and documented as such.
- The `?? 1.0` alpha default is the **fail-safe** direction: an unreadable alpha means
  "assume it draws", so the assertion fails rather than clearing a window. It is
  deliberately unpinned — `kCGWindowAlpha` is always present here, so flipping it is
  measurably invisible (verified: the guard test still passes at `?? 0.0`), and a test
  that cannot fail is not a test (`no.md` #12). Recorded, not falsely asserted.
- Pinned by `testTheWitnessWindowIsReadableWithoutBeingVisible` plus a mutation row,
  hand-verified NOTICED in both directions with a byte-identical restore.

## Rollback

Remove the single `window.alphaValue = 0` line in `WitnessHost.run`. The witness returns
to compositing at full opacity; nothing else depends on the value, and the guard test
fails immediately and by name, so the rollback cannot be silent. Do **not** substitute an
offscreen origin — see Alternatives.
