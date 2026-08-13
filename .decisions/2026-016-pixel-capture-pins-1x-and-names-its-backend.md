# 2026-016 — The pixel capture pins 1x itself, and every capture names its backend

**Status**: Accepted (2026-08-12)
**Wave**: 9, Task 1

## Context

Wave 9 adds a pixel channel for the questions geometry cannot answer — gradients,
shadows, image content, font rendering. The implementation plan specified it as:

> windowless `NSHostingView.cacheDisplay` (matches Wave 2 host, scale pinned 1.0)
> + `ImageRenderer` alternate backend (flag) — document divergence between the
> two backends honestly.

That sentence names a mechanism and a property together, which reads as one
instruction. Measuring the named API first (2026-08-12) showed the property is
not the mechanism's:

| Backend | Pixels for a 120x80 view | PNG bytes |
| --- | --- | --- |
| `bitmapImageRepForCachingDisplay(in:)` | **240x160** | 2463 |
| `ImageRenderer` at `scale = 1` | 120x80 | 1228 |

The AppKit convenience answers at the **device backing scale** — 2x on any
Retina display. Determinism itself was verified across three separate process
launches (identical FNV hash), so the instability risk is the scale, not the
renderer.

## Decision

1. **Construct the `NSBitmapImageRep` explicitly at one pixel per point** rather
   than asking the view for a caching rep. `OracleHost.pixelScale = 1.0` is
   enforced by the capture, not inherited from the display.
2. **Keep both backends**, and record which one produced each capture in
   `PixelCapture.backend`. A baseline is comparable only to a capture from the
   same backend.
3. **Assert the divergence in a test** rather than only documenting it.

## Alternatives considered

- **Follow the plan literally (use the caching rep).** Rejected: baselines become
  machine-specific, so a diff against a 1x host reports a hardware difference as
  a UI regression — a verification tool accusing correct code, which is the
  fastest way to lose a reader's trust.
- **Ship only `ImageRenderer`,** which honours `scale` natively. Rejected: it
  re-evaluates the view rather than reading the hosted one, so pixels and the
  semantic tree would describe two independent layout passes that may have
  settled differently.
- **Document the divergence in a doc comment only,** as the plan says. Rejected:
  a doc comment is a claim with no instrument behind it. If the backends ever
  converge, the comment silently becomes false; a test fails loudly.

## Consequences

- A baseline captured on any machine is comparable to one captured on any other,
  including a CI runner with no display.
- Cross-backend comparison is refusable rather than silently wrong, because the
  backend travels with the capture.
- `PixelCapture` carries a content hash, which Task 5's render cache keys on.
- Anyone changing `pixelScale` breaks `testCaptureIsPinnedToOnePixelPerPoint`
  (negative-controlled: the AppKit convenience fails 4 tests reading
  "400 is not equal to 200 - width must be points, not device pixels") and the
  mutation row "the pixel capture stops pinning 1x and follows the device scale".

## Rollback

Revert `Sources/VerdictUIProbe/PixelCapture.swift`, the `renderHostedView` /
`makeImageRenderer` accessors in `OracleHost.swift`, and the mutation row. No
persisted artifact depends on it yet — pixel baselines are not written until
Task 4, so nothing on disk becomes unreadable.

## See also

- `no.md` #46 — the general rule (a plan line naming an API and a property is two claims)
- Fleet lesson 364
