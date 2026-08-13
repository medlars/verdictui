# 2026-015 — The witness mirrors the probe channel's layout, and frames on the SwiftUI side

**Status:** Accepted (2026-08-12)

## Context

Wave 8's middle loop renders one scenario in TWO hosts and reconciles the results:
`OracleHost` (windowless, in-process, the fast channel) and `WitnessHost` (a real
window, read out-of-process through the accessibility server). Any disagreement
becomes a finding.

That makes the two harnesses' layout a **contract**, not an implementation detail.
If they lay content out differently, every node differs by the same offset and the
reconciler reports a separate frame disagreement for each one — blaming the UI under
test for a difference between the two harnesses.

It went unnoticed through Wave 8 Tasks 1–2 because the demo scenarios' content
nearly fills its viewport. The minimal lie fixtures (Task 4) exposed it: the
**honest control** — a scenario that lies about nothing, whose entire purpose is to
produce no finding — failed with two invented disagreements:

```
'root' width differs by 187 pt   — probe 0,0 260x120,   accessibility 0,0 73x50
'honest-label' x differs by 93.5 — probe 109.5,51 41x18, accessibility 16,16.25 41x17.5
```

## Decision

1. **`WitnessHost` applies the same frame modifier `OracleHost` applies**, on the
   **SwiftUI side**: `content.frame(width:height:)`, bare, so alignment is the
   default `.center`.
2. The witness does **not** choose its own layout convention. Where the two could
   differ, the probe channel wins — it is what every baseline was recorded against.

## Alternatives considered

**Size the NSView instead** (`autoresizingMask = [.width, .height]`, or assigning
`hosting.frame`). Tried first, and **rejected on measurement**: a direct probe showed
both approaches give the hosting view an NSView frame of 260×120, but `fittingSize` —
which is what the accessibility server publishes — reads **73×49.5** under
autoresizing versus **260×120** under the SwiftUI frame. AX reports the *content's*
size, not the view's bounds, so an NSView-side fix changes nothing a witness can see.
This is the decision's load-bearing measurement: the two approaches look
interchangeable and are not.

**Pin the witness `.topLeading`.** Rejected: self-consistent and wrong. `OracleHost`
applies a bare `.frame(width:height:)` whose default alignment is `.center`, so a
`.topLeading` witness disagrees with the channel it exists to check — measured at
x=109.5 (probe) against x=16 (witness) for the same label. A witness that is
internally tidy and externally wrong is worse than one that is obviously broken.

**Wrap the content in an extra container to control placement.** Rejected: an extra
layer changes what the hosting view publishes, and the AX hosting group then reports
no geometry at all (`anchorUnreadable`) — trading a constant offset for a witness
that cannot read the window. Measured during the same session.

**Loosen the reconciler's tolerance until the offset fits.** Rejected outright. The
offset is ~93–187 pt; a tolerance that swallows it swallows every real defect the
rule exists to catch. A threshold moved to silence a failure is a silencer
(SE Principle 11), and the number was never wrong — the harness was.

## Consequences

- The honesty suite is **green against a live witness**, not skipped: 4/4, all three
  planted lies caught, honest control silent.
- `WitnessHost` now has a documented obligation to track `OracleHost`'s layout. If
  `OracleHost`'s frame modifier or alignment ever changes, the witness must change
  with it — the honest control is what will notice, since it fails the moment the two
  disagree.
- The general rule this establishes: **when two channels are compared against each
  other, everything they share is a contract.** Neither may pick a convention
  unilaterally, and the one with recorded history is authoritative.

## Rollback

Revert `Sources/VerdictUIWitness/WitnessHost.swift` to constructing
`NSHostingView(rootView: content)` with no frame. The honesty suite's honest control
(`LieCatchTests.testTheHonestControlProducesNoReconciliationFinding`) will fail
immediately with the invented disagreements above, which is the intended signal —
cross-validation is unusable in that state, so the rollback is only a diagnostic step,
never a shipping configuration.
