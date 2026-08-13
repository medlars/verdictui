# 2026-018 — The pixel diff gates on channel magnitude, not on the differing-pixel count

**Status**: Accepted (2026-08-13)
**Wave**: 9, Task 3

## Context

Wave 9 Task 3 asks for an "ODiff-style perceptual compare (per-channel tolerance
+ anti-aliasing awareness)". The obvious reading is the shape general-purpose
image-diff tools ship: count the pixels that differ, and fail when the count
exceeds some fraction of the frame — commonly defaulted around 5%.

That shape was measured against this capture path before any assertion was
written, and it does not work here.

## Measurements (2026-08-13, windowless host at 1x)

| Change                          | Differing px (of 8000) | Max channel delta |
| ------------------------------- | ---------------------- | ----------------- |
| Two renders of one screen       | 0                      | 0                 |
| Border colour black → red       | 196 (2.45%)            | 255               |
| Border colour black → near-black| 196 (2.45%)            | 5                 |
| Text moved a whole point        | 649                    | 216               |
| Text offset by 0.37 pt          | 0                      | 0                 |
| Text offset by 0.50 pt          | 0                      | 0                 |

Two findings, both against the obvious design:

1. **A visible regression and an invisible one touch exactly the same pixels.**
   The count cannot separate them; only the magnitude can.
2. **Sub-pixel anti-aliasing jitter does not occur on this path.** Fractional
   offsets change nothing; a whole-point move changes a lot. This capture path
   snaps layout to the pixel grid.

## Decision

1. **`PixelTolerance.perChannel` carries the gate** — a pixel counts as
   differing when its worst channel delta exceeds the tolerance.
2. **`maxDifferingFraction` defaults to 0**, the deliberate opposite of the
   usual image-diff default. A 1-px border regression moves 2.45% of the frame,
   so a 5% area allowance would swallow the exact case this channel exists to
   catch. The swallow case is pinned as a NEGATIVE CONTROL, because "a 1-px
   change fails" is otherwise satisfied by a comparison that fails on anything.
3. **`perChannel` defaults to 2 and is documented as a ROUNDING ALLOWANCE**, not
   as anti-aliasing insurance. There is no AA shimmer here to absorb; there can
   be ±1 from 8-bit colour conversion. Writing the AA rationale would have been
   a confident explanation of something that never happens.
4. **`maxChannelDelta` is reported even on a PASS**, because it is the number
   that says how close a pass was.
5. **The heat map's alpha scales with the delta.** A flat mask would draw the
   two 196-pixel cases identically — the same blindness the count has.

## Consequences

- A caller with a genuinely noisy region must raise `maxDifferingFraction`
  explicitly and say why at the call site. Noise is a property of one scenario,
  not a global default.
- The comparison lives in the platform-pure kernel (it operates on RGBA planes,
  not image formats), so these rules are testable on a machine with no display.
  Decode and artifact writing live in `VerdictUIProbe`.
- If a future capture path DOES anti-alias sub-pixel movement (iOS, a windowed
  host, a non-integer scale), this ADR's measurements no longer describe it and
  the tolerance must be re-derived rather than inherited.

## Alternatives rejected

- **Area-fraction threshold as the primary gate** — measured to be blind to the
  distinction that matters.
- **Exact byte comparison as the default** — leaves no room for colour-conversion
  rounding; available as `PixelTolerance.exact` for callers who want it.
- **A flat heat mask** — cheaper, and cannot distinguish severity.

## Related

- `no.md` #48 (the full reasoning and measurements)
- ADR 2026-016 (the 1x pin, which is why sub-pixel jitter is absent)
- ADR 2026-017 (determinism, which must pass before a baseline is written)
