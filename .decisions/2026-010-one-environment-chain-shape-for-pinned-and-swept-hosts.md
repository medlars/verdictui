# 2026-010 — The host's environment chain has ONE shape; a sweep varies values, never structure

**Date**: 2026-08-11
**Status**: Accepted
**Wave**: 5, Task 4

## Context

`OracleHost` exists to make a verdict reproducible: it **pins** locale, colour
scheme, dynamic type and layout direction so a machine configured in Arabic, or
in dark mode, or with larger text, cannot change a tree. That pin is why Wave 2's
determinism proof holds.

Wave 5 Task 4 needs the exact opposite. A variant sweep renders one scenario
across a matrix of those same axes — "does the German string truncate at
accessibility text sizes?" is the question the feature exists to answer — so the
sweep must vary precisely what the host fixes.

The two requirements meet inside one modifier chain, and the order matters.

## Decision

`verdictPinnedEnvironment(overriding:)` takes an optional `Variant` and **always
writes every axis**. A pinned host and a swept host differ only in the VALUES
written; the modifier chain is structurally identical in both modes.

```swift
.environment(\.locale, overriding.map { Locale(identifier: $0.localeIdentifier) }
                       ?? OracleHost.pinnedLocale)
.environment(\.colorScheme,     overriding?.colorScheme     ?? .light)
.environment(\.dynamicTypeSize, overriding?.dynamicTypeSize ?? .medium)
.environment(\.layoutDirection, overriding?.layoutDirection ?? .leftToRight)
```

The variant's values win because they are written **here**, and no caller applies
anything closer to the content.

## Alternatives considered

### 1. Apply the variant OUTSIDE the pin (rejected — measured inert)

The first attempt, resting on a doc comment I wrote asserting that SwiftUI
resolves the environment "outermost-last". Measured: **five variants, including
an explicit 150×200 viewport, produced byte-identical frames.** Nothing moved.

A direct probe settles the precedence question. With two
`.environment(\.dynamicTypeSize,)` writes around one reader:

| Chain | Reader observes |
|---|---|
| inner `.medium`, outer `.accessibility5` | **medium** |
| inner `.accessibility5`, outer `.medium` | **accessibility5** |

The writer **nearest the content** wins — the reverse of what the comment
claimed, and of what two attempts were built on.

### 2. A `@ViewBuilder` branch: pin everything, or pin only what a variant cannot express (rejected — broke an unrelated Button)

Correct on precedence, and it made the sweep work. It also **broke a `Button`**:
`'Pay' never reached the tree`, while its sibling `Text` was fine.

A `@ViewBuilder` `if/else` wraps its subtree in `_ConditionalContent`, changing
view identity — and the Button's label did not survive it. Confirmed against a
**pristine worktree at HEAD**: 10/10 there, 9/10 with the branch.

Two earlier isolation attempts produced VOID measurements and are worth
recording, because both looked like evidence:

- `git stash` on one file of a compiling pair → the build failed, so exit 1 meant
  "does not compile", not "test fails".
- `git stash` with untracked files present → **stashed nothing**; the unchanged
  tree was read as the control.

## Consequences

- A sweep can vary any pinned axis, and `SweepTests` proves the variant reaches
  the render (mirroring moves `x` 0 → 204).
- An ordinary verify is byte-identical to what it was before sweeps existed: the
  `nil` variant writes exactly the previous pinned values.
- The 4 axes a `Variant` owns and the 3 it cannot express (display scale,
  calendar, time zone) live in ONE function, so a caller cannot pin six and
  override a seventh by accident.
- **`dynamicTypeSize` is inert on macOS** and is kept anyway. The environment
  delivers `accessibility5` — a reader prints it — but `Text` renders
  byte-identically (13×18 pt at `.body`), because macOS sizes text from `NSFont`
  rather than SwiftUI Dynamic Type. The axis is real on iOS, and removing it
  would silently delete the plan's "German string truncates at AX3" case. But a
  sweep varying only that axis on macOS produces cells that CANNOT disagree — a
  table of identical answers reading as clean. `SweepTests` is therefore keyed on
  `layoutDirection`, and the inertness is documented rather than asserted away.

## Rollback

Revert `verdictPinnedEnvironment` to its no-argument form and drop the `variant:`
parameter from `OracleHost.init`. Sweeps stop varying anything; ordinary verifies
are unaffected, since the `nil` path already writes the historical pinned values.

## The general rule this establishes

**A modifier chain that changes SHAPE between two modes is not two configurations
of one host — it is two hosts, and the difference surfaces somewhere unrelated to
what you were configuring.** Configure by value, never by structure.

Recorded as `no.md` #29.
