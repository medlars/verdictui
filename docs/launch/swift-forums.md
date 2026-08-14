# Swift Forums post draft

> Draft for the 1.0.0 launch, for forums.swift.org → Related Projects.
> Not posted. A Swift-forums audience is the toughest one for this project:
> they know SwiftUI's internals and will ask about the Layout protocol
> immediately. Lead with mechanism, not benefit.

## Title

VerdictUI: verifying SwiftUI layouts in-process via the Layout protocol

## Body

I've released **VerdictUI** (MIT), a verification engine that gets a
ground-truth semantic tree out of SwiftUI without screenshots, a window server,
or Accessibility permission.

**The mechanism**, which is the part worth discussing here:

The core probe is a transparent `Layout` conformance. A custom `Layout` sees the
`ProposedViewSize` its parent offers *and* the size each subview returns, which
is strictly more than `GeometryReader` can observe — `GeometryReader` reports a
resolved frame and cannot tell you what was proposed, so it cannot distinguish
"this text chose one line" from "this text was given no room for two". The probe
forwards every proposal and placement unchanged, so inserting it does not alter
layout; it only records. Frames then travel up through a `PreferenceKey` stream
into a collector installed by a root modifier that owns the coordinate space.

That gets you a tree. Turning it into a verdict is a separate, platform-pure
kernel with no SwiftUI, AppKit or CoreGraphics import at all — it compiles
headless, and `Rect` is hand-rolled rather than a `CGRect` alias for exactly
that reason. Twelve lint rules run over the tree and produce findings that cite
node ids.

**Settling without sleeps.** The harness drives a `Clock` conformance the view
tree reads from the environment, so animations advance deterministically rather
than in wall-clock time. Quiescence is decided by draining the main queue,
checking recorder activity, comparing tree stability, and taking a census of
virtual-clock waiters. There is no `Thread.sleep` anywhere in the harness — a
test asserts that, and plants one to prove the detector fires.

**Rendering is windowless.** `NSHostingView` produces real layout frames with no
window server at all; I verified this under a sandbox that denies the
`mach_lookup` for the window server, with a positive control that gets
windowNumber 5945 normally and 0 + exit 1 sandboxed.

**Adoption** is a `@Verifiable` macro that copies your `body`, probes every
recognised element, and leaves your real `body` untouched (a member macro
cannot replace a member, and a second `body` would be a redeclaration error).
Manual probes compose with it.

Measured: **p50 48.52 ms** for a full act → settle → verdict cycle over 150
samples, p95 50.46 ms. Zero flake in 200 CLI runs.

**Where it does not reach**, since this audience will find these immediately:

- It cannot see whether the app launched, a permission dialog, real keyboard/IME
  input, or anything multi-window. Windowless in-process rendering buys the
  speed and costs exactly those. XCUITest keeps the outer loop.
- `isVisible` is currently always true: opacity and clipping are not observable
  from the layout pass. An external Accessibility-tree channel cross-validates
  and reports disagreement rather than resolving it.
- The macro only recognises a fixed set of element kinds; anything else passes
  through unprobed rather than being guessed at.

Two SwiftUI-specific findings that cost me sessions and might save you one:

1. **The environment writer nearest the content wins.** I had written the
   opposite in a doc comment and built a variant-sweep system on it; five axes
   including an explicit viewport produced byte-identical frames until I probed
   it directly.
2. **`dynamicTypeSize` is delivered but inert on macOS.** `Text` renders
   byte-identically at `.medium` and `.accessibility5` because macOS sizes text
   from `NSFont`. Any test keyed on that axis can never fail, and its failure
   would accuse the engine.

Also: `accessibilityReduceMotion` cannot be pinned — the `EnvironmentValues`
property is get-only, so there is no `WritableKeyPath`. I control animation with
`Transaction(animation: nil)` instead.

Repo: https://github.com/medlars/verdictui
Swift 6, macOS 13+, SwiftPM. Feedback on the `Layout` approach especially
welcome — if there is a supported way to observe opacity or clip state from
within the layout pass, I would like to hear it.

## Notes for posting

- Category: Related Projects.
- Expect scrutiny of the transparent-`Layout` claim. Be ready to state that the
  probe forwards proposals and placements unchanged and that snapshot tests pin
  the expansion.
- The `isVisible` limitation is the honest weak point. State it before anyone
  else does.
- Do not pitch. This audience responds to mechanism and measurement.
