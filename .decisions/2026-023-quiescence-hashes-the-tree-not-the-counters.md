# 2026-023 — Quiescence hashes the TREE, not the counters that describe it

**Status**: Accepted (2026-08-14)
**Wave**: 10 (found while triaging a CI failure)

## Context

`Quiescence.progressToken` is the single signal `LayoutSettle` uses to decide
that a screen has stopped moving. Everything downstream rests on it: `settle()`
returns `.settled` when the token holds still across two checks and a 30 ms
floor, and every verdict is produced from the tree read after that decision.

Until now the token hashed four quantities, and **every one of them was a
count**:

```swift
hasher.combine(sink.updateCount)
hasher.combine(sink.recorder.measurements.count)
hasher.combine(sink.recorder.placements.count)
hasher.combine(pendingWaiters)
```

A layout can change without changing any of them. A box alternating between
10 pt and 40 pt wide delivers the *same number* of measurements and the *same
number* of placements on every pass — only the values differ. So the token went
constant while the screen oscillated.

Measured 2026-08-14 by instrumenting both sides at once: the probed box read
**40 → 10 → 40 → 10** on consecutive `currentTree()` reads while the token
reported **one identical value for seven consecutive checks**, and `settle()`
returned `.settled(after: 0.036 s)`.

This is the exact failure mode the whole product exists to prevent — a
verification signal reporting PASS about something it cannot see. It surfaced
only because a hostile test's own flakiness dragged the investigation into the
token, which is a poor way to find a defect in the engine's central signal.

## Decision

**The progress token folds the tree's CONTENT, depth-first**, via a new
`Quiescence.combine(_:into:)`: node id, role, frame geometry (x, y, width,
height), text, and `isVisible`, recursed over children. The counts stay — they
are cheap and they catch changes the content hash would miss, such as a
re-delivery that happens to produce an identical tree.

Two sub-decisions, both deliberate:

1. **`SemanticNode` does NOT gain a `Hashable` conformance.** The obvious
   implementation is `hasher.combine(sink.latestTree)`, and it is rejected: a
   kernel type's conformances are its published contract (ADR 2026-022), so
   widening one for a probe-side caller adds public API surface for an internal
   need. The fold lives in `Quiescence`, where the requirement is.

2. **The recursion is unbounded, unlike `AXReader`'s.** `no.md` #44 records a
   segfault from walking an `AXUIElement` tree without a depth bound, so the
   asymmetry deserves stating: that tree is a **graph the window server owns**
   and may contain cycles, while this one is assembled by our own probe from a
   finite view hierarchy. Nothing here crosses a trust boundary. If the probe
   ever ingests a foreign tree, this needs a bound.

## Consequences

**Settle is now sensitive to a class of movement it was blind to.** Any
animation or layout loop that preserves node *counts* while changing geometry —
which is most of them, since SwiftUI reuses the same view identities — is now
observable.

**It costs a tree walk per pump iteration**, at `pumpInterval` = 5 ms. The full
suite is unchanged at 784 tests / 0 failures and SLO 1 still gates at p50 70 ms,
so the cost is inside the noise on the trees this engine renders. If a very
large tree ever makes this measurable, the fix is to hash a bounded digest of
the tree rather than to go back to counting.

**It did not fix the flake that led here.** `testOscillatingLayoutTimesOut-
WithDeltaEvidence` still intermittently reports settled, because its fixture
drives oscillation from a `Timer` on the main RunLoop and `settle()` saturates
that actor. That is a separate defect in the *fixture*, tracked as
**CTS-6C1078DD** with three measured dead ends recorded so the next session does
not repeat them. Shipping this fix without closing that flake is deliberate: the
engine defect is real and independently worth fixing, and conflating the two is
how a genuine finding gets reverted along with a failed fixture experiment.

## Alternatives considered

**Increase `requiredAgreeingChecks` from 2 to 3+.** Rejected: it makes the race
narrower without making the signal correct. A strictly alternating tree with a
constant token defeats any number of agreeing checks, because the token never
disagrees with itself.

**Compare the previous and current `SemanticNode` trees with `==` instead of
hashing.** `SemanticNode` is already `Equatable`, so this would work and would
avoid hash collisions entirely. Rejected because the token is an `Int` by
contract — `progressToken` returns `Int?` and `nil` carries the distinct meaning
"cannot judge" (a waiter is pending, or no tree exists yet). Changing the return
type to make equality possible would ripple through `Quiescence`, `LayoutSettle`
and `OracleHost` for no behavioural gain: a 64-bit hash collision between two
consecutive layout states is not a risk worth restructuring three types for.
