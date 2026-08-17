# Judging an AppKit product — headless, no screenshots

This page is for an AppKit/Swift developer who wants their product judged
**without taking snapshots, without Apple Automator, and without a running app**.

Everything below runs off-screen in a normal process: no window is ordered on
screen, no pixels are captured, and no permission is granted.

---

## Why this exists

Before this path, an AppKit product had **no** way in. Both documented on-ramps
were structurally closed, measured 2026-08-17:

| Route | Why it fails for AppKit |
| --- | --- |
| `verdictui inspect --pid` | Needs an `AXGroup` child as its coordinate anchor (`Sources/VerdictUIWitness/AXReader.swift:291`, `:299`) — a construct only a SwiftUI hosting view publishes. Finder (which has one) reads fine: exit 0, 1.47 MB tree. PanoMac and Notes: **exit 2**. Filed as CIS-C5D9A5E8. |
| `.verdictProbe(id:)` | Declared `extension View -> some View` — SwiftUI only. PanoMac has **zero** `import SwiftUI` and 11 `NSViewController`s. |

The engine itself never had that limit. `VerdictUIKernel` imports only
Foundation, `Rect` is hand-rolled (`no.md` #5), and every rule judges geometry
and text metrics — all of which an `NSView` carries natively. The only missing
piece was a **producer**, and that is what `VerdictUIAppKit` is.

---

## The 60-second version

```swift
// Package.swift — add the product to the target holding your views' tests,
// and to the runner target below.
.product(name: "VerdictUIAppKit", package: "VerdictUI")
```

```swift
// Sources/VerdictUIRunner/main.swift — the whole file.
import VerdictUIAppKit
import MyAppUI

AppKitTreeRunner.launch(subjects: [
    .controller("startup-manager") { StartupManagerViewController() },
    .controller("trust-scores", viewport: CGSize(width: 900, height: 600)) {
        TrustScoresViewController()
    },
])
```

```bash
swift build
verdictui appkit --runner .build/debug/VerdictUIRunner                       # list subjects
verdictui appkit --runner .build/debug/VerdictUIRunner --subject startup-manager --judge
```

Exit codes are the tool's usual three, never conflated: `0` passed, `1` a
verdict was produced and FAILED, `2` no verdict could be produced.

---

## Why a runner executable rather than "point the CLI at my app"

An `NSView` subclass exists **only inside the binary that compiled it**. It
cannot cross a process boundary, cannot be reconstructed from JSON, and cannot
be `dlopen`ed without coupling the installed `verdictui` binary to your exact
toolchain version.

So you compile a few-line executable that links `VerdictUIAppKit` and names your
screens; the CLI runs it and judges what it prints. No plugin ABI, no dynamic
loading, no version handshake. This is the same mechanism `ProjectScenarios`
already uses for SwiftUI scenarios.

The runner speaks two verbs and nothing else:

| Verb | Behaviour |
| --- | --- |
| `list` | Print every subject name, one per line. |
| `render <name>` | Print that subject's semantic tree as JSON on stdout. |

Its exit codes are `0` (produced) and `2` (could not produce). There is
deliberately **no** `1` — a runner produces trees, it does not judge, and
conflating "I could not build your view" with "your view is wrong" is exactly
what the three-valued contract exists to prevent.

---

## Using it as a library instead

The CLI is a convenience. The API is the product, and it works in an ordinary
XCTest with no subprocess at all:

```swift
import VerdictUIAppKit
import VerdictUIKernel
import XCTest

@testable import MyAppUI

@MainActor
final class StartupManagerVerdictTests: XCTestCase {
    func testTheScreenIsClean() throws {
        let tree = AppKitRenderer.tree(
            for: StartupManagerViewController(),
            viewport: CGSize(width: 720, height: 480)
        )
        let verdict = RuleEngine.run(
            rules: RuleEngine.standardRules,
            on: tree,
            context: .macOS(viewport: tree.frame, scenario: "startup-manager")
        )
        XCTAssertEqual(
            verdict.status, .pass,
            "\(verdict.findings.map { "\($0.rule) on \($0.nodeID ?? "-")" })"
        )
    }
}
```

`AppKitRenderer` is `@MainActor` because AppKit layout is main-thread-only —
`layoutSubtreeIfNeeded()` is what makes the frames real, and forcing that pass is
the entire job.

---

## Identity: you already set it

The SwiftUI path asks you to add `.verdictProbe("save-button")`. The AppKit path
asks for **nothing new** — it reads `view.identifier`
(`NSUserInterfaceItemIdentifier`), which Interface Builder writes and which
anyone doing UI testing already sets.

```swift
removeButton.identifier = NSUserInterfaceItemIdentifier("remove-button")
```

A view with no identifier still gets one, synthesized from its structural
position and prefixed `ak:` — for example `ak:root/button[1]`. The prefix is
load-bearing: it tells a reader at a glance that the identity is **derived**
rather than declared, and a derived id moves when siblings are reordered.

Without synthesized ids the whole tree would carry no id at all, and
`RuleEngine` refuses such a tree as `vacuous-verdict` — correctly, since an
AppKit codebase sets `identifier` on approximately none of its views.

**Set `identifier` on anything a finding should be able to name.** That is the
one piece of adoption work, and it is a one-line assignment per control.

---

## What is walked, and what is a leaf

**A platform control is a leaf.** Its own frame, role and text are reported; its
innards are not.

This is not tidiness — it is the difference between a usable verdict and noise.
AppKit assembles a control from private subviews you never wrote and cannot
change. `NSScrollView` alone contributes `_NSScrollViewContentBackgroundView`,
`NSScrollPocket`, `PocketMask`, `PocketBlur`, `NSHardPocketView`,
`BackdropView`, `NSBannerView`, `_NSBannerDecorationView` and several dimming
layers — all deliberately stacked on top of each other, because that is how a
scroll view is drawn.

Measured against PanoMac's real `StartupManagerViewController` layout:

| | Nodes | AppKit internals | Findings |
| --- | --- | --- | --- |
| Walking everything | 36 | 19 | **30**, none actionable |
| Platform controls as leaves | 5 | 0 | **2**, both real |

The 5 are the root, the title label, the scroll view, the table, and the status
label — which is precisely the screen the developer wrote.

Every one of those 30 was a `sibling-overlap` or `content-overlap` between two
private decoration layers. A real defect would have been invisible in the list.

This is the same argument `docs/adoption.md` makes for **tier 2b** — a view you
cannot edit is probed from the outside, and the verdict is a claim about the box
rather than its contents.

`NSScrollView` is the one deliberate exception: its `documentView` is *your*
content, is editable, and is exactly what you want judged. So the decoration is
skipped and the document is walked.

---

## Coordinates: two conversions happen for you

1. **Root space.** `SemanticNode.frame` is in the ROOT's coordinate space, not
   the parent's, per `docs/tree-contract.md`. The walk converts with
   `convert(_:to: root)`.
2. **Y-down.** AppKit's y axis points **up** from the bottom-left; the kernel and
   every SwiftUI-produced tree use y-**down** from the top-left, which is what
   `OffscreenRule` and `MisalignmentRule` assume. Emitting the raw AppKit y would
   put the top of the screen at the bottom and quietly invert every vertical
   judgement.

A root that is already flipped (`isFlipped == true`, common for custom document
views) is left alone.

---

## Role mapping

| AppKit class | Role |
| --- | --- |
| `NSPopUpButton` | `menu` (checked before `NSButton`, which it subclasses) |
| `NSButton` | `button` |
| `NSSwitch` | `toggle` |
| `NSSlider`, `NSStepper` | `slider` |
| `NSTextField` (editable) | `textField` |
| `NSTextField` (label) | `text` |
| `NSTextView` | `textField` |
| `NSImageView` | `image` |
| `NSTableView`, `NSOutlineView`, `NSCollectionView` | `list` |
| `NSTableRowView` | `listRow` |
| `NSTabView` | `tabBar` |
| `NSScrollView`, `NSStackView`, `NSClipView`, `NSBox`, `NSSplitView`, `NSVisualEffectView`, plain `NSView` | `container` |
| anything else | `custom("<ClassName>")` |

`NSTextField` is the one role that depends on **state** rather than class: the
same class is a label when not editable and an input when it is, and
`TapTargetRule` must not police a static label as though it were a control.

An unrecognised class becomes `custom(_:)` carrying its type name, never a
silent `container` — `EmptyContainerRule` polices containers, so an
unclassified node reported as one would be told it "renders nothing", stating
more than the tree supports.

---

## Text metrics

`TruncationRule` and `ExcessiveWrapRule` are **silent** without
`textMetrics`, so a producer that omits them is quieter than it should be —
which reads as a clean product.

| Field | Provenance |
| --- | --- |
| `intrinsicWidth` | **measured** — the width the attributed string occupies unconstrained. |
| `renderedLineCount` | **derived** — the frame's height in lines, capped by an explicit `maximumNumberOfLines`. |
| `idealLineCount` | **derived** — the lines the string wants at the frame's width, ignoring any cap. |

The string is measured with the view's **real font**, taken from
`attributedStringValue` / `attributedTitle` where present. Measuring with the
wrong font produces a plausible, wrong `intrinsicWidth` — and that is precisely
the number the truncation rule decides on, so it would be a silent measurement
error rather than a missing one.

Metrics are `nil` — deliberately, rather than guessed — when the role bears no
text, the text is empty, the text contains a hard line break (the single-line
denominator is then unknown), or the view cannot be measured. This is the same
honesty boundary `TreeAssembly.textMetrics` draws for the SwiftUI path.

---

## Verify your setup against a KNOWN defect first

A tree that always passes may mean your UI is clean, or may mean your producer
emits nothing useful — **those look identical from here**, and only a deliberate
failure separates them.

Add a subject with one real defect and confirm it FAILS:

```swift
final class DefectiveController: NSViewController {
    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 480))
        let title = NSTextField(labelWithString: "Startup Manager")
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        title.identifier = NSUserInterfaceItemIdentifier("title-label")
        title.maximumNumberOfLines = 1
        title.frame = NSRect(x: 16, y: 440, width: 60, height: 24)   // far too narrow
        container.addSubview(title)
        view = container
    }
}
```

```text
$ verdictui appkit --runner .build/debug/VerdictUIRunner \
      --subject startup-manager-defective --judge --summary
FAIL  startup-manager-defective
  [error] truncation on 'title-label': 'title-label' needs 141.374 pt of width
          on one line but was given 60 pt
      → increase frame width to >= intrinsicWidth 141.374 pt, or allow wrapping
$ echo $?
1
```

That is the measured output, not an illustration.

---

## Limitations

| Limitation | Why | What to do |
| --- | --- | --- |
| A platform control's internals are not judged | They are AppKit's, not yours, and produced 30 unactionable findings when walked | Judge your own composition; the control's own frame is still reported |
| Layers (`CALayer`) are invisible | The walk is over `NSView`, and a layer carries no semantic role | Probe the hosting view |
| `zIndex` is never set | AppKit has no declared z-order equivalent; subview order is the order | Reorder subviews, or suppress `sibling-overlap` on the node |
| Synthesized ids are positional | Derived from structural position, so they move when siblings are reordered | Set `view.identifier` where an id must be stable |
| A view needing live data renders empty | The runner builds the controller without your app's services | Inject fixture data in the subject's builder closure |
| Cells drawn by `NSCell` are not separate nodes | An `NSCell` is not an `NSView` and has no frame of its own in the hierarchy | Use view-based table views (`NSTableView` view-based mode) |

---

## Related

- `docs/tree-contract.md` — the wire shape, shared with every other producer.
- `docs/adoption.md` — the SwiftUI path, and the tier-2b argument this page reuses.
- CIS-C5D9A5E8 — the `inspect --pid` anchor gap that made this necessary.
