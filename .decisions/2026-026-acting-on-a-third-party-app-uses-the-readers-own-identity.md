# 2026-026 — Acting on a third-party app uses the reader's own identity

**Date:** 2026-08-17
**Status:** accepted
**Tags:** witness, accessibility, third-party

## Context

`AXReader.readTree(pid:)` observes an application VerdictUI did not write.
`AXReader.press` acts on one. They were added a day apart and searched
**different vocabularies and different subtrees**:

| | names an element | walks from |
|---|---|---|
| `readTree` | Value → Description → Title | the hosting content group |
| `press(named:)` | Title → Description → Value | the window |

So a name plainly visible in the tool's own output could be genuinely absent
from the press search. The natural workflow — read the tree, act on what you saw
— was exactly the one that failed, and the obvious conclusion from that failure
(*the press is broken*) sent a caller to debug the wrong half. Filed as
CIS-3DDA018A.

Neither half was wrong in isolation, and both had passing tests. The divergence
was invisible from either side because nothing exercised the round trip.

## Decision

**Acting on an element uses the identity the reader already assigns: the
structural path.** `press(pid:atPath:)` is the primary verb, exposed as
`verdictui inspect --press-path`; the command tries path **before** name,
because the path is what a caller who just read the tree actually holds.

Two supporting rules, both load-bearing:

1. **The path walk mirrors `SemanticNode.withAssignedStructuralPaths` exactly** —
   same anchor, same child order, same `role[index]` segments. A resolver that
   indexes differently from the assigner is a second implementation of one rule,
   and the two drift silently.
2. **The anchor is resolved once**, in `anchoredWindow()`, shared by reader and
   presser. Half the original defect was the two picking different anchors.

Each path segment's **role is checked**, not just its index, so a path that
resolves to a different element than it names fails loudly rather than pressing
the wrong control.

## Alternatives considered

- **Unify the two name lookups.** Rejected: it fixes the symptom and leaves the
  deeper problem, which is that a *name* is not an identity. Two controls can
  share one, and many elements have none at all — SwiftUI leaves `AXTitle` empty
  routinely. A workflow built on names is a coincidence that has not failed yet.
- **Return raw `AXUIElement` handles from `readTree`.** Rejected: it would make
  `SemanticNode` carry a live process-scoped pointer, breaking `Codable` (the
  tree is serialised to JSON for the CLI and MCP surfaces) and tying every
  consumer to the reader's process lifetime.
- **Keep `press(named:)` only and document the mismatch.** Rejected — documenting
  a trap is not removing it, and this trap costs a caller their diagnosis, not
  just their time.
- **Drop `press(named:)`.** Not done: a human typing a verb by hand wants a name,
  not a path. It remains as the convenience path, with the path form preferred.

## Consequences

- Read-then-press round-trips, proven end-to-end **through the shipped binary**:
  `inspect --pid` produced the tree, a `structuralPath` was taken from its own
  JSON, and `--press-path` on that value returned exit 0. An absent path exits 2.
- `elementNotFound` is now raised by both lookups, so its message names **name or
  path** — a message naming only one sends a caller to check the wrong thing.
- Two mutations guard this, not one: a resolver that never resolves, and one that
  ignores the index and presses the first child. The second is the more dangerous
  — it reports success while pressing something else.

## Rollback

Delete `press(pid:atPath:)`, `element(at:from:)`, `anchoredWindow()` and the
`--press-path` option; `press(pid:named:)` and `inspect --press` are untouched
and keep working. `ReadThenPressRoundTripTests` fails loudly on removal, which is
the intended signal rather than a silent regression.
