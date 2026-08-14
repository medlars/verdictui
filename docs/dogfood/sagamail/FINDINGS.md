# Fleet dogfood — SagaMail notification settings

**Wave 10, Task 1.** Adopting VerdictUI into a real SagaMail screen, from
outside the engine's own package, to find out what adoption actually costs.

> **Why a reproduction rather than SagaMail's own tree.** SagaMail's working
> copy carries **293 uncommitted files on a WIP branch**
> (`wip/feature-tour-backup-20260728`). An edit there would mix into somebody
> else's in-flight work with no reviewable diff, which DIR-035 scopes to a
> ticket rather than a drive-by change. The screen reproduced here keeps every
> structural shape of `Sources/SagaMailUI/NotificationsSettingsTab.swift` —
> `Form`/`Section`, conditional content, `ForEach` pickers, `Toggle`, `Slider`,
> `HStack` — because those shapes are what the adoption exercises. Adoption in
> SagaMail's own tree is filed as **CTS-E4B92281**.
>
> **PanoMac was dropped as a dogfood target, and this is a measurement not a
> preference:** `grep -rl "import SwiftUI"` across the whole PanoMac repo
> returns **zero files** (11 `NSViewController`s under `Sources/UI/`). VerdictUI
> instruments SwiftUI through the `Layout` protocol, so there is nothing there
> to probe. DIR-202 already records PanoMac as 100% AppKit; this confirms it.

## What the dogfood found

Three findings, and **the engine did not survive first contact with a public
view** — which is the single best argument for having run it.

### 1. `@Verifiable` did not compile on any `public` view (P1, FIXED)

**The defect.** `VerifiableView` is a `public` protocol requiring
`verdictProbedContent`, and the macro emitted that member with **no access
modifier**, so it was internal. Swift refuses to satisfy a public protocol
requirement with an internal member, so every `public` view carrying
`@Verifiable` failed to build:

```
error: property 'verdictProbedContent' must be declared public because it
       matches a requirement in public protocol 'VerifiableView'
```

**Why it matters.** That is not an edge case — it is **every view a library
module exports**. SagaMail's UI lives in a `SagaMailUI` target, so the very
first screen anyone tried to adopt hit it. `@Verifiable` was unusable by its
primary audience.

**Why 775 tests never saw it.** Every macro fixture in the engine's test target
is internal, and most are nested inside an `XCTestCase`, where `public` is not
even expressible. The population was invisible *by construction* — the same
shape as `no.md` #29 (a suite complete about one property is blind to a second)
and lesson 342 (a suite built entirely from one input shape is green by
construction, and the shapes it omits are where the defects are).

**The fix.** `DeclGroupSyntax.verdictAccessLevelPrefix` mirrors the host type's
access level onto both generated members. Only `public` is mirrored:
widening a `private` view's members would export something the author
deliberately hid, so the safe direction is to emit nothing and let Swift's
default apply. Pinned by `Tests/VerdictUIMacroTests/PublicVerifiableViewTests.swift`
— **at file scope, because a type nested in an XCTestCase cannot be public**, so
a nested fixture would silently re-test the already-covered internal case — with
the internal spelling kept alongside as the control.

### 2. `verdictProbing` is unreachable from the obvious dependency set (docs)

A consumer's **test** target needs `VerdictUIMacroSupport`, not just
`VerdictUIKernel` + `VerdictUIProbe`. Wrapping a `@Verifiable` view in a
scenario calls `verdictProbing(_:)`, which lives in MacroSupport beside the
macro. Depending only on Kernel + Probe — the intuitive choice for a target that
merely renders and asserts — fails with `cannot find 'verdictProbing' in scope`.

Not an engine bug; a gap in `docs/adoption.md`, which shows the macro on a view
but never shows the test target that verifies it. Filed as **CTS-74D240DC**.

### 3. `tap-target` fires on every standard macOS `Toggle` (P2, calibration)

The adopted screen produced three findings at **error** severity:

```
tap-target on NotificationsSettingsScreen.toggle.0
tap-target on NotificationsSettingsScreen.toggle.1
tap-target on NotificationsSettingsScreen.toggle.2
```

Measured, rather than assumed:

| Node | Frame |
|---|---|
| `toggle.0` | 142.0 × **18.0** pt |
| `toggle.1` | 60.0 × **18.0** pt |
| `toggle.2` | 100.0 × **18.0** pt |

Against `minimumTapTarget` of 28 × 28 pt. The verdict is **arithmetically
correct**, and the interesting question is whether the *threshold* is.

An independent probe outside VerdictUI entirely settles it:

```swift
let v = NSHostingView(rootView: Toggle("Sound", isOn: .constant(true)))
v.layoutSubtreeIfNeeded()
print(v.fittingSize)      // (60.0, 18.0)
```

**A native SwiftUI macOS `Toggle` is 18 pt tall.** So the rule fires on
*correct, idiomatic SwiftUI written exactly as Apple ships it* — and its own doc
comment claims the opposite: "a firing rule means the control is genuinely below
the platform's documented floor." That sentence is false for the commonest
interactive control on the platform.

This is the `no.md` #25 shape, which that entry recorded as a severity
principle: an **error** on ordinary correct code is how a tool gets deleted
rather than fixed. A developer adopting VerdictUI on any settings screen in any
Mac app gets three red findings on their first run, all unactionable — the
suggested fix, `.frame(minHeight: 28)`, would make their app *non-standard*.

**Not fixed here, deliberately.** Recalibrating a rule's threshold is a
measurement exercise (`ContentOverlapRule` and `excessive-wrap` both set theirs
that way), and it needs a survey of macOS control metrics — `Toggle`, `Checkbox`,
`Stepper`, small-control variants — not a number picked to make this screen
green. Lowering the threshold to fit today's screen is exactly the silencer this
project forbids. Filed as **CTS-DB551166** with the measurements above.

The dogfood test therefore records the finding as expected rather than
pretending the screen is clean.

## What the adoption cost

| | |
|---|---|
| Lines added to the view | **1** (`@Verifiable`) |
| Lines added to make it verifiable | 8 (a `VerdictScenario` wrapper) |
| Package dependencies | 3 products, one of them non-obvious (finding 2) |
| Engine defects hit on the way | **2** (one P1 blocking, one docs) |
| Real findings about the screen | **3**, all true, all cited by node |

## Reproducing

```bash
cd docs/dogfood/sagamail
swift test
```

Five tests: the probed-tree claim, conditional-content coverage, both verdict
states, and a **control** that squeezes the viewport to 90 pt and requires the
engine to FAIL — without it, every PASS above is satisfied by an engine that
passes unconditionally.
