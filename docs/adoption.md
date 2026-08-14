# Adopting VerdictUI

This page is about getting a real view under verification. It is deliberately
ordered by what goes wrong most often, not by what is easiest to explain.

---

## Read this first: probe placement decides what gets measured

**A probe measures the view it is attached to, and getting that wrong fails
silently toward PASS.**

```swift
// WRONG — the probe is outside the frame, so it measures the FRAME.
Text(subtitle)
    .frame(width: 82)
    .verdictProbe("subtitle", role: .text, text: subtitle)

// RIGHT — the probe is inside, so it measures the TEXT.
Text(subtitle)
    .verdictProbe("subtitle", role: .text, text: subtitle)
    .frame(width: 82)
```

In the first spelling `intrinsicWidth` comes back equal to the constrained width
— 82 pt — because that is genuinely the width of the thing the probe wrapped.
Truncation is then invisible: the rule compares intrinsic against rendered and
they agree. In the second, `intrinsicWidth` is the 335 pt the text actually
wants, and the finding fires.

Both were verified against a real consumer view. The wrong placement produced a
clean PASS on text overflowing its frame by a factor of four.

The rule to carry: **attach the probe to the element, then apply layout
modifiers.** If a verdict looks suspiciously clean, check placement before
concluding the engine is wrong.

`@Verifiable` gets this right automatically — the walk attaches probes at the
element, beneath whatever chain the author wrote.

---

## Wiring the package (do this before the first probe)

Two targets need dependencies, and the second one is not obvious.

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/medlars/verdictui", from: "1.0.0")
],
targets: [
    // The target holding your VIEWS. `VerdictUIMacroSupport` is what provides
    // `@Verifiable`; take `VerdictUIProbe` instead (or as well) if you want
    // manual `.verdictProbe(id:)` without paying for SwiftSyntax.
    .target(
        name: "MyAppUI",
        dependencies: [
            .product(name: "VerdictUIMacroSupport", package: "VerdictUI")
        ]
    ),

    // The target holding your TESTS. All three, and the third is the one
    // everybody misses.
    .testTarget(
        name: "MyAppUITests",
        dependencies: [
            "MyAppUI",
            .product(name: "VerdictUIKernel", package: "VerdictUI"),   // Verdict, RuleEngine
            .product(name: "VerdictUIProbe", package: "VerdictUI"),    // OracleHost, VerdictScenario
            .product(name: "VerdictUIMacroSupport", package: "VerdictUI"),  // verdictProbing(_:)
        ]
    ),
]
```

**Why the test target needs `VerdictUIMacroSupport` too.** A scenario that renders
a `@Verifiable` view calls `verdictProbing(_:)`, and that function lives in
`VerdictUIMacroSupport` beside the macro rather than in `VerdictUIProbe`.
Depending only on Kernel + Probe — the intuitive choice for a target that merely
renders and asserts — fails with:

```text
error: cannot find 'verdictProbing' in scope
```

This is not hypothetical: it was the second of two build failures the Wave 10
fleet dogfood hit before a single assertion ran. `verdictProbing` is what routes
a `@Verifiable` view's **probed** content into a scenario — hand a scenario the
bare view and it renders the unprobed body, producing a tree with no probed node
and a `vacuous-verdict` (ADR 2026-009).

The split exists on purpose: `VerdictUIMacroSupport` drags in SwiftSyntax, the
heaviest build-time cost in the package, so a consumer wanting probes *without*
macros must be able to say so. See [Build-time cost](#build-time-cost).

### The smallest scenario that verifies a view

```swift
import VerdictUIKernel
import VerdictUIMacroSupport
import VerdictUIProbe
import XCTest

@testable import MyAppUI

private struct SettingsScenario: VerdictScenario {
    let name = "settings"

    @MainActor @ViewBuilder
    func body(state: ScenarioState) -> some View {
        verdictProbing(SettingsScreen())   // NOT `SettingsScreen()` on its own
    }
}

@MainActor
final class SettingsVerdictTests: XCTestCase {
    func testTheScreenIsClean() async throws {
        let host = OracleHost(
            scenario: SettingsScenario(),
            viewport: Size(width: 420, height: 400)
        )
        let tree = try await host.currentTree()
        let verdict = RuleEngine.run(
            rules: RuleEngine.standardRules,
            on: tree,
            context: .macOS(viewport: tree.frame, scenario: "settings")
        )

        XCTAssertEqual(
            verdict.status, .pass,
            "\(verdict.findings.map { "\($0.rule) on \($0.nodeID ?? "-")" })"
        )
    }
}
```

A worked example of exactly this, against a real app screen, is in
[`docs/dogfood/sagamail/`](dogfood/sagamail/) — including a control that proves
the engine can still FAIL, without which the assertion above is satisfied by an
engine that passes unconditionally.

---

## Three tiers

Pick per view, not per project. They mix freely in one file.

### Tier 1 — macro (the default)

Two tokens. Nothing else.

```swift
@Verifiable
struct SettingsRow: View {
    var body: some View {
        VStack {
            Text("Notifications")
            Button("Enable") { enable() }
        }
    }
}

enum Scenarios {
    #VerdictScenario("settings-row") {
        SettingsRow()
    }
}
```

That is a fully verifiable view: `Text` and `Button` are probed with derived ids
(`SettingsRow.text.0`, `SettingsRow.button.0`), roles, and their literal labels
forwarded as text.

Use it when the elements are ordinary SwiftUI and you have no opinion about ids.

**`#VerdictScenario` must be written at type scope** (inside an `enum`, as
above). That is a language rule, not a style choice: a declaration macro whose
generated type name comes from an author-written string must declare
`names: arbitrary`, and the compiler rejects arbitrary names at global scope.

### Tier 2 — manual probes

No macro. You write every probe.

```swift
struct CardRow: View {
    var body: some View {
        ZStack {
            surface.verdictProbe("card-surface", role: .container)
            pill.verdictProbe("card-pill", role: .container)
        }
        .verdictProbe("card-layer", role: .custom("zstack"))
    }
}
```

Use it when ids carry meaning — a baseline keys on them, a rule assertion names
them, a report is read by a human — or when a role is something the macro cannot
infer. `.custom("zstack")` above is what tells `SiblingOverlapRule` that two
intersecting frames are *declared* layering rather than a bug; no syntax-level
walk can know that.

The demo catalog is entirely tier 2, for exactly these reasons.

### Tier 3 — hybrid (common in practice)

`@Verifiable` for the bulk, explicit probes where you have an opinion.

```swift
@Verifiable
struct Toolbar: View {
    var body: some View {
        HStack {
            Text("Untitled")                       // → Toolbar.text.0
            Button(action: save) { Image("disk") }
                .verdictProbe("save", role: .button, text: "Save")
        }
    }
}
```

**An explicit probe always wins.** The walk sees one already on the chain and
leaves that position alone — it does not add a second id, and it does *not* stop
walking: everything nested inside is still probed.

This is also how you answer the unlabelled-control warning (below).

---

## Composition: nested `@Verifiable` views

A macro runs on syntax, before type checking, so a custom subview is opaque to
it — `MyRow()` could be anything. The walk does not guess a role for it, because
a wrong role is worse than an absent one (rules act on it).

Instead it hands the decision to the compiler. `MyRow()` becomes
`verdictProbing(MyRow())`, which has two overloads:

- the constrained one, for a type conforming to `VerifiableView` (which
  `@Verifiable` adds), renders that view's **probed** content;
- the passthrough, for everything else, renders it unchanged.

Resolution is at compile time, no reflection, and a non-verifiable view costs
nothing. So nested `@Verifiable` types compose, and a view that is not verifiable
simply renders normally.

**This is what makes the two tokens sufficient.** Before it existed, a
`@Verifiable` view rendered through a `#VerdictScenario` produced a tree with no
probed node at all — the generated member was never called by anything — and the
verdict came back `vacuous-verdict`.

---

## Compile-time diagnostics

### Duplicate explicit id → error

```swift
Text("a").verdictProbe("row", role: .text)
Text("b").verdictProbe("row", role: .text)   // error, reported here
```

Ids must be unique within a view. `TreeDiff` pairs nodes by id and a baseline
keys on it, so a collision silently merges two elements into one for every
consumer downstream. Reported at the *second* occurrence — the first is where the
id was legitimately introduced.

The kernel also catches this at runtime, via `DuplicateProbeIDRule`. The compile
-time check is strictly stronger: it sees every `@Verifiable` view on every
build, where a runtime rule only sees views someone remembered to write a
scenario for.

### Interactive element with no label → warning, with a fix-it

```swift
Button(action: save) { Image("gear") }   // warning
```

The id derives fine (`Row.button.0`). What is missing is the **label**: the only
literal in that expression belongs to the `Image`, so the probe carries no text.
The element can be located but not *named* — `TruncationRule` has nothing to
read, no assertion can reference the button by what it says, and a human reading
the verdict sees an anonymous control among several.

A warning rather than an error, because this is ordinary correct SwiftUI. It
renders, it is verifiable in every respect except its name, and refusing to
compile it would make `@Verifiable` reject working code.

The fix-it inserts a probe with an **empty** label for you to fill. It is empty
on purpose: the macro does not know what the button says, and a guessed label
("Button", the asset name) writes a plausible wrong name into the one field a
human reads to identify the control. An empty string is visibly incomplete; a
wrong one is not.

---

## Limitations

| Limitation | Why | What to do |
|---|---|---|
| Custom subviews are not probed directly | A macro sees spelling, not types; the role is unknowable | Annotate them `@Verifiable` too — they compose (above) |
| An element held in a `let` and used later is invisible | The walk probes expressions where they appear | Inline it, or probe by hand |
| Only seven element spellings are recognised (`Text`, `Button`, `Toggle`, `TextField`, `SecureField`, `Image`, `List`) | Each maps to a kernel role; guessing a role for an unknown type is worse than not probing | Probe by hand for anything else |
| Containers get no node of their own | `VStack`/`HStack` carry no semantics the rules read | Probe by hand if the container matters (e.g. `.custom("zstack")`) |
| `body` must be a single expression | A multi-statement body cannot be lifted and rewritten safely | Move statements into a computed property or subview; the macro reports this at the attachment site |
| Interpolated text is not forwarded | `Text("Hi \(name)")` has no value at expansion time | Probe by hand with the resolved string if a rule needs it |
| Generated ids are positional (`Row.text.0`) | Derived from a per-role counter over syntax order | Use explicit probes where an id must be stable across edits |
| `#VerdictScenario` only at type scope | The compiler rejects arbitrary names at global scope | Wrap in an `enum` |
| `isVisible` is always `true` | Opacity and clipping are not observable from the layout pass | Pending a later wave |
| Nested `verdictRoot` is unsupported | Preference reduction is first-writer-wins, so the inner viewport reaches the outer collector | Let `OracleHost` own the root |

---

## Migrating an existing view

1. **Add `@Verifiable`.** Build. If it reports the body is not a single
   expression, extract the statements first — that diagnostic is at the
   attachment site, not inside generated code.
2. **Add a `#VerdictScenario`** naming the view, inside an `enum`.
3. **Run it and read the tree**, not just the verdict. A PASS on an empty tree
   is caught by `vacuous-verdict`, but a PASS on a *partial* tree is not — check
   the elements you care about are actually in it.
4. **Answer the warnings.** Each unlabelled control is a place the verdict cannot
   name something a user can see.
5. **Add explicit probes** where ids need to be stable or roles need to be
   semantic. This is the move to tier 3, and it is normal.

Step 3 is the one people skip. The tree is the evidence; the verdict is a summary
of it.

---

## Build-time cost

Measured on this machine, cold (`rm -rf .build`) and back to back:

| Build | Time |
|---|---|
| `VerdictUIProbe` alone (no macros) | 24.03 s |
| `VerdictUIMacroSupport` alone | 20.71 s |
| Whole package | 29.44 s |

So adding macros to a consumer that already uses the probe costs about **5.4 s,
or +22%** — not the tripling the wave plan assumed when it made
`VerdictUIMacroSupport` a separate product.

Two things worth knowing about those numbers. The separate product is still
right: a consumer who wants probes without SwiftSyntax can depend on
`VerdictUIProbe` alone and pay none of it. And SwiftSyntax is **not** the
heaviest thing in this package — the macro product alone builds *faster* than
the probe alone, because the plugin builds for the host toolchain and never
links SwiftUI, while `VerdictUIProbe` pulls in SwiftUI and AppKit.

Absolute numbers are hardware- and cache-dependent; the ratio is the durable
part.
