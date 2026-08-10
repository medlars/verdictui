# ADR 2026-008 — Scenario registration is a static list, not a runtime scan

**Date:** 2026-08-10
**Status:** Active
**Author:** Wave 4 Task 3 session (`#VerdictScenario`)

## Context

Wave 4 Task 3 needed `#VerdictScenario("name") { … }` to make a scenario
*discoverable by name* — Wave 6's `verdictui list` enumerates scenarios, and Wave 5
keys baselines on the same names. The implementation plan specified "registration into
a runtime `ScenarioRegistry` (static registration list; no runtime reflection)", which
names the conclusion without recording why the alternatives fail.

Two constraints turned out to be binding, and both came from the compiler rather than
from preference.

**`any VerdictScenario` cannot reach the harness.**
`OracleHost.init` is generic over `Scenario: VerdictScenario` precisely so the
scenario's `Body` type survives into the hosted view tree. The protocol has an
associated type, so an existential has no `Body` for the compiler to instantiate
`NSHostingView` with. A registry spelled `[any VerdictScenario]` therefore does not
compile against the harness it exists to feed. `DemoScenarioEntry` hit this
independently in Wave 2 and its doc comment records the same finding.

**Swift has no load-time hook a value type can register itself from.**
The registration pattern most people reach for — each scenario adds itself to a global
mutable registry from a type initializer — has no portable Swift spelling. There is no
`+load` equivalent for a struct.

## Decision

`ScenarioEntry` erases **construction**, not the scenario: it stores a
`@Sendable @MainActor` closure that builds the concrete scenario and hands it to the
generic initializer *inside its own generic context*, where the type is still known.
The entry itself is a plain struct, so a registry is an ordinary array.

`#VerdictScenario` generates that entry as a `verdictEntry` static on the scenario type.
The author names it in one list:

```swift
let registry = ScenarioRegistry([CheckoutScenario.verdictEntry])
```

`ScenarioRegistry` keeps duplicates rather than dropping them, and reports them through
`duplicateNames`. A name is a verdict's filing key and, from Wave 5, a baseline key — so
a silent drop makes one scenario's results vanish from a run with nothing anywhere
saying so. Reporting is also why the collision is not rejected at `init`: a tool that
cannot construct the registry cannot tell the author which names collided.

The macro is written at **type** scope. Its `names:` must be `arbitrary` because the
generated type name derives from an author-written string, and the compiler rejects
arbitrary names from a declaration macro at global scope outright:
`'declaration' macros are not allowed to introduce arbitrary names at global scope`.

## Alternatives considered

**Runtime reflection over loaded types.** Rejected on three counts, any one sufficient:
it breaks under dead-code stripping (the scenarios most worth verifying are the ones a
release build is most willing to strip); it makes "which scenarios exist" depend on link
order rather than on anything a human can read or diff; and it is slow in exactly the
warm-daemon path Wave 6 budgets at <20 ms marginal.

**A global mutable registry populated from type initializers.** No portable Swift
mechanism exists — see Context. Faking one through an ObjC-visible class hierarchy would
force every scenario to be a class, which contradicts the SwiftUI value-type grain.

**`[any VerdictScenario]`.** Does not compile against `OracleHost` — see Context. Erasing
at the host boundary instead (`AnyView` per scenario) would put an extra
layout-transparent node in every hosted tree for the sake of a loop, which is a
measurable change to the thing under verification.

**Rejecting duplicate names at `init`.** Rejected because it makes the failure
unreportable: the registry that would name the colliding scenarios is the one that
refused to be built.

## Consequences

- Registration costs one line per scenario. What it buys is that the set of scenarios is
  a **value** — readable, diffable, testable.
- A scenario that exists as a type but was never listed is genuinely absent from the
  registry. That cost is pinned by
  `testAnUnregisteredScenarioIsAbsentRatherThanQuietlyPresent`, so it reads as a
  deliberate tradeoff rather than a bug, and cannot be quietly "fixed" into reflection
  without this ADR being revisited.
- `#VerdictScenario` cannot be written at file scope. Consumers nest it in a type (an
  enum works) and alias if they want short call sites. Documented at the use site in
  `VerdictScenarioCompilationTests`.
- Wave 6's `verdictui list` reads `ScenarioRegistry.names`; Wave 5's baselines key on the
  same strings, and `duplicateNames` is the signal that two scenarios would collide on
  one baseline.

## Rollback

Delete `Sources/VerdictUIProbe/ScenarioRegistry.swift`, remove `VerdictScenarioMacro`
from `VerdictUIMacroPlugin.providingMacros` and the `VerdictScenario` declaration from
`Sources/VerdictUIMacroSupport/Verifiable.swift`, and drop the three scenario rows from
`scripts/mutation_catalog.py`. Scenarios then go back to hand-written `VerdictScenario`
conformances, which still work — the macro is additive and nothing in the kernel, probe
runtime or harness depends on it. `swift test -Xswiftc -warnings-as-errors` must report
zero failures and `python3.14 scripts/mutation-check.py --verify-targets` must report
every remaining target resolving to exactly one site.
