# 2026-009 — Macros compose through a compile-time overload, not reflection

**Date**: 2026-08-10
**Status**: Accepted
**Wave**: 4, Task 6

## Context

Wave 4's exit gate states the wave's headline adoption claim:

> A previously unprobed demo view gains full verification by adding exactly two
> tokens (`@Verifiable`, `#VerdictScenario`).

Writing the test for that claim falsified it. Measured 2026-08-10: an unadorned
view carrying `@Verifiable`, rendered through a `#VerdictScenario`, produced a
tree with **no probed node at all** and a verdict of `vacuous-verdict`.

The mechanism was simple and total. `@Verifiable` generates
`verdictProbedBody(into:)`, and **nothing ever called it**. `#VerdictScenario`
probes the statements it can see; its body here was `UnadornedSettingsRow(...)`,
an opaque custom view, which the walk correctly declines to probe — a macro runs
on syntax, before type checking, so it cannot know what a custom type renders,
and a guessed role is worse than none because rules act on it. So the scenario
rendered the view's ordinary `body`, the generated member sat unreachable, and
the composition the gate names produced an empty tree.

This was not a small bug. It is the exact false-green shape the product exists to
prevent, sitting in the wave's own headline feature, and it had been documented
as working in three doc comments.

## Decision

`@Verifiable` additionally:

1. generates `verdictProbedContent` — the probed body with **no root installed**;
2. conforms the type to a new `VerifiableView` protocol (via `@attached(extension)`).

`BodyProbeWalk` wraps every opaque view construction in `verdictProbing(_:)`,
which has two overloads:

```swift
func verdictProbing<V: VerifiableView>(_ view: V) -> some View { view.verdictProbedContent }
func verdictProbing<V: View>(_ view: V) -> some View { view }
```

Swift resolves these at **compile time** on whether the concrete type conforms.
A conforming view renders its probed content; anything else renders unchanged.

## Alternatives considered

**A runtime type check** (`if let v = view as? any VerifiableView`). Rejected:
the walk wraps *every* unrecognised call, so a non-verifiable view would pay an
existential cast on every render, and the associated-type requirement makes the
opened existential awkward to render. The answer is knowable statically; paying
for it dynamically is a worse version of the same thing.

**Requiring the author to write `.verdictProbedBody(into:)` themselves.**
Rejected: that is a *third* token, which falsifies the exit gate rather than
satisfying it.

**Documenting the limitation and leaving the claim unmet.** Rejected. The claim
is the wave's stated reason to exist, and Task 6's deliverable is the adoption
guide — documenting a broken headline feature is worse than the bug, because it
converts a defect into a promise.

## Why no root in `verdictProbedContent`

Nesting `verdictRoot` inside another `verdictRoot` is unsupported: preference
reduction is depth-first and the viewport is first-writer-wins, so the inner
root's viewport reaches the outer collector, which then measures every frame —
including `OffscreenRule`'s reference rectangle — against the wrong rectangle.

A view rendered inside a scenario is already under `OracleHost`'s root. It needs
the probed content and nothing else, which is why this is a second generated
member rather than a reuse of the first.

## Scope of the wrapping

`verdictProbing(_:)` is applied only to a capitalised initialiser call with no
view-builder closure and no modifier chain. Each exclusion is load-bearing:

- **A closure means a container.** Its children were already walked and probed;
  wrapping the container would hide real probes behind a call that returns the
  subtree unchanged for a non-conforming type — trading probes for a maybe.
- **A lowercase callee** is a function, not a type construction, so there is no
  nominal type to check conformance on.
- **A modifier chain** must keep the probed content *inside* the modifiers the
  author wrote, since the frame a rule measures is the modified one.

## Consequences

- The two-token claim is now true and asserted by `TwoTokenAdoptionTests`,
  including a source-level guard that the fixture view stays unadorned — without
  it, "exactly two tokens" is unenforced and the fixture could drift into being
  hand-instrumented while the suite stayed green.
- Nineteen expansion snapshots changed, additively: the new member and the
  conformance extension.
- `testANestedCustomViewIsLeftOpaque…` was renamed to
  `…IsDeferredToTheCompiler…`. The old name described behaviour that no longer
  exists — the view still gets no probe of its own, but "left opaque" is now
  wrong about what happens instead.
- A consumer who never uses `#VerdictScenario` is unaffected; `verdictProbing`
  only appears where the walk meets an opaque view.

## Verification

- `TwoTokenAdoptionTests` — 3 tests: the verdict is non-vacuous, both elements'
  text reaches the kernel, and the fixture carries no VerdictUI spelling other
  than the attribute. All three observed RED before the fix (`vacuous-verdict`,
  empty tree) and green after.
- Full suite 412 → 415 tests, 0 failures, zero warnings under
  `-warnings-as-errors`.
