# The VerdictUI kernel

`VerdictUIKernel` is the part of VerdictUI that decides whether a UI is correct. It
defines three things and nothing else:

1. **The semantic tree** (`SemanticNode`) — what a probe reports about a rendered
   view hierarchy.
2. **The rule engine** (`LintRule`, `LintContext`, `RuleEngine`) — how a tree
   becomes findings.
3. **The verdict** (`Verdict`, `SchemaVersion`, `TreeDelta`) — the wire format every
   consumer reads: the CLI, the MCP server, and agents.

The kernel is **platform-pure**: it imports `Foundation` and nothing else. No
SwiftUI, AppKit, CoreGraphics, or UIKit — the PM's `stage_architecture` fails the
build if one appears. A verifier coupled to the render stack it judges cannot be
trusted about that stack, and purity is also what lets the same kernel judge a web
tree in Wave 10 without a rewrite.

Everything below is checked against the source by
`Tests/VerdictUIKernelTests/KernelDocumentationTests.swift`: every quoted finding
message, severity, threshold, and suppression path in this file is produced by
running the real rule and then looked up here. A reworded message fails that test
rather than leaving this page quietly wrong.

---

## 1. The semantic tree

### `SemanticNode`

| Field | Type | Meaning |
|-------|------|---------|
| `id` | `String` | Probe-supplied identifier. Empty for an unprobed node. |
| `role` | `Role` | Semantic role — see the vocabulary below. |
| `frame` | `Rect` | Resolved frame in the layout coordinate space, in points. |
| `text` | `String?` | Rendered string for text-bearing nodes. |
| `attributes` | `[String: AttributeValue]` | Role-specific data (toggle state, slider value) and directives such as suppression. |
| `isVisible` | `Bool` | False when the node is transparent or clipped away. Defaults to true. |
| `zIndex` | `Double?` | Explicit paint order, when the layout declared one. |
| `textMetrics` | `TextMetrics?` | `intrinsicWidth`, `renderedLineCount`, `idealLineCount`. Attached by the Wave 2 layout probe to text-rendering nodes. |
| `structuralPath` | `String` | Parent-chain path, e.g. `root/container[0]/text[2]`. |
| `children` | `[SemanticNode]` | Children in layout order. |

Two derived values matter for everything downstream:

- **`identity`** — the probe `id` when present, otherwise the last component of
  `structuralPath`, prefixed `@` so the two namespaces cannot collide. This is what
  `TreeDiff` matches on.
- **`evidenceLabel`** — how a finding names the node: the `id`, or the
  `structuralPath` when unprobed. Evidence always points somewhere.

Decoding is deliberately lenient: only `id`, `role`, and `frame` are required, so an
older or hand-written fixture still loads with documented defaults (`isVisible`
true, no attributes, no children, empty structural path).

### Role vocabulary

The case list mirrors SwiftUI's accessibility role vocabulary, so Wave 8's
cross-validation channel can map an in-process role onto the `AXUIElement` role of
the same element 1:1. Anything the probe cannot classify becomes `custom(_:)`
carrying the raw string, never a silent `container` — an unclassified element must
stay visible in the tree instead of disappearing into a default.

| Wire identifier | SwiftUI source | Interactive | Text-bearing |
|-----------------|----------------|-------------|--------------|
| `container` | `VStack`, `HStack`, `ZStack`, `Group` | no | no |
| `text` | `Text`, `Label` title | no | **yes** |
| `button` | `Button`, `Link` | **yes** | **yes** |
| `toggle` | `Toggle` | **yes** | no |
| `slider` | `Slider`, `Stepper` | **yes** | no |
| `textField` | `TextField`, `SecureField`, `TextEditor` | **yes** | **yes** |
| `image` | `Image`, `AsyncImage` | no | no |
| `list` | `List`, `Table`, `ForEach` host | no | no |
| `listRow` | one row inside a `list` | no | no |
| `navigation` | `NavigationStack` bar, toolbar | no | no |
| `tabBar` | `TabView` bar | no | no |
| `menu` | `Menu`, context menu, `Picker` popup | **yes** | no |
| `spacer` | `Spacer` — occupies space, renders nothing | no | no |
| *(any other string)* | `custom(String)` — unclassified | no | no |

The two columns are load-bearing, not descriptive:

- **Interactive** is exactly the set `tap-target` polices. `listRow` is excluded on
  purpose — rows are row-height-sized by the platform, so measuring them against a
  tap minimum produces noise rather than defects.
- **Text-bearing** is the set that can carry glyphs, which decides `zero-size`
  severity.

One round-trip caveat: `Role.custom("button")` decodes back as `Role.button`. A
probe must not mint custom roles that collide with the known vocabulary. An *empty*
role identifier is rejected on both encode and decode, matching the schema's
`minLength: 1` — a nameless role is not a role.

### `AttributeValue`

Three primitive cases only: `string`, `number`, `bool`, each encoded as a bare JSON
scalar. This is a deliberate ceiling, recorded as a Wave 1 risk: nested attribute
structures would let probes smuggle arbitrary shapes across the contract, and every
rule would then have to defend against them. When a rule genuinely needs structure,
the answer is a typed field on `SemanticNode`, not a richer attribute.

---

## 2. The rule engine

```swift
public protocol LintRule: Sendable {
    static var id: String { get }
    func evaluate(_ root: SemanticNode, context: LintContext) -> [Finding]
}
```

A rule is a pure function from a tree to findings: no state, no I/O, no clock, no
tree mutation. Rules are `Sendable` value types so the Wave 6 daemon can hold one
rule set and evaluate trees concurrently.

`RuleEngine.standardRules` is the Wave 1 library **in evaluation order**:

1. `duplicate-probe-id`
2. `zero-size`
3. `sibling-overlap`
4. `offscreen`
5. `truncation`
6. `tap-target`

`duplicate-probe-id` runs first because an id collision undermines the evidence
every other rule produces about the same tree.

`RuleEngine.run(rules:on:context:includeTree:)` evaluates the rules and packages the
findings as a `Verdict`. Findings are ordered by rule, then by the rule's own
traversal order (preorder over `flattened()`), so the evidence is byte-stable for a
given tree — a prerequisite for baselines and for diffing verdicts between runs.
`timestamp` and `timing.evaluateMs` are wall-clock facts and are therefore the only
parts of a verdict that vary between identical runs. `includeTree` is off by
default: the tree dwarfs the findings and the MCP surface pays per token.

### `LintContext`

| Field | Default | Used by |
|-------|---------|---------|
| `scenario` | `"unnamed"` | recorded in the verdict |
| `viewport` | *(required)* | `offscreen` |
| `minimumTapTarget` | `28` × `28` pt (`macOSMinimumTapTarget`) | `tap-target` |
| `truncationTolerance` | `0.5` pt | `truncation` |
| `severityOverrides` | `[:]` | every rule |
| `disabledRules` | `[]` | `RuleEngine.run` |

Two convenience constructors set the platform minimum: `LintContext.macOS(viewport:scenario:)`
uses the macOS pointer minimum of `28` × `28` pt, and `LintContext.touch(viewport:scenario:)`
uses the `44` × `44` pt touch minimum. The macOS default is the permissive one on
purpose: measuring a mouse-driven UI against a finger target produces noise, and a
rule that cries wolf gets switched off.

### Suppression, three levels

Every rule builds its findings through `context.makeFinding(...)`, so suppression
and severity overrides cannot be forgotten by a new rule.

1. **Per node** — set `attributes["verdict.suppress"]` on the node the finding is
   attached to:
   - `.bool(true)` or `.string("*")` suppresses every rule on that node;
   - `.string("tap-target,truncation")` suppresses just those (comma-separated,
     whitespace-trimmed);
   - `.bool(false)` suppresses nothing.
2. **Per run** — `context.disabledRules = ["offscreen"]` skips the rule entirely; it
   is never evaluated.
3. **Severity** — `context.severityOverrides = ["tap-target": .warning]` keeps the
   finding but stops it failing the verdict.

A rule with no suppression path is a rule people disable wholesale, which is how a
lint library loses its users. Note which node carries the attribute: it is the node
named in the finding's `nodeID`, which for `sibling-overlap` is the *later* sibling
and for `duplicate-probe-id` is the *first* occurrence of the colliding id.

---

## 3. Rule catalog

| Rule | Severity | Fires when |
|------|----------|------------|
| `duplicate-probe-id` | error | the same non-empty probe `id` appears more than once in a tree |
| `zero-size` | error for text-bearing and interactive roles, warning otherwise | a visible node has an empty frame |
| `sibling-overlap` | error | two visible, non-empty sibling frames intersect without declared layering |
| `content-overlap` | error | leaf content under two different parents intersects without declared layering |
| `offscreen` | error | a visible, non-empty frame lies entirely outside the viewport |
| `truncation` | error | text rendered fewer lines than it wanted, or a one-line text was given less width than it needs |
| `tap-target` | error | a visible interactive node is smaller than `minimumTapTarget` in either dimension |

### `duplicate-probe-id`

An infrastructure rule, not a layout one. Duplicate ids break the two mechanisms the
product rests on: `TreeDiff` degrades that sibling group to positional matching, so
a delta stops describing identity, and act-targeting (`tap("save-button")`, Wave 3)
cannot say which element it meant.

One finding per colliding id, attached to the **first** occurrence, ids reported in
sorted order for a stable wire format. Unprobed nodes (empty `id`) are never
compared — their identity comes from `structuralPath`.

Two buttons, both `id: "save"`:

```text
probe id 'save' appears 2 times — tree diffing falls back to positional matching and act-targeting becomes ambiguous
give each .verdictProbe a unique id, e.g. by suffixing the collection index
```

**Suppress**: `verdict.suppress` on the first node carrying the duplicate id, or
`disabledRules`.

### `zero-size`

The classic "my view disappeared" bug: the element exists in the hierarchy but was
proposed zero space. Invisible nodes are skipped — hidden scaffolding is not a
defect. Exempt by role: `spacer` (a zero-size spacer is a legitimate layout outcome)
and any role identifier prefixed `verdict.`, which is VerdictUI's own probe
scaffolding and is deliberately sizeless.

Severity depends on what was lost. Text-bearing and interactive roles are errors —
content or a control the user cannot see or reach. Everything else is a warning,
since an empty container may simply have no content this time.

A visible `text` node `title` with a `0` × `0` frame:

```text
'title' is visible but its frame is 0 x 0 pt
give it a non-zero frame, hide it while it has no size, or report it as Role.spacer if it is layout-only
```

**Suppress**: `verdict.suppress` on the empty node, report it as `Role.spacer`, or
`disabledRules`.

### `sibling-overlap`

Fires when two visible, non-empty sibling frames intersect. Deliberate layering is
recognised two ways, so a `ZStack` badge over an avatar is not a defect:

- either sibling declares a `zIndex` — an explicit paint order is a statement of
  intent; or
- the parent's role identifier is `zstack` (case-insensitively), which is how a
  probe may label a layering container.

The finding is attached to the later sibling and reports the size of the
intersection. A `badge` over an `avatar` with no declared layering:

```text
'badge' overlaps sibling 'avatar' by 16 x 16 pt
give the siblings disjoint frames, or declare the layering with .zIndex() so the overlap reads as intentional
```

**Suppress**: `verdict.suppress` on the later sibling, declare `.zIndex()` on
either, label the parent `zstack`, or `disabledRules`.

### `content-overlap`

Fires when two pieces of **leaf content** under **different parents** intersect by
more than 0.5 pt. This is the gap `sibling-overlap` cannot see: a `Text` that
outgrows its row and covers the next row's text has no common parent whose layout
could resolve it, so the sibling-scoped rule is blind to it by construction.

Three structural relationships are deliberately silent, because each is ordinary
layout rather than a defect:

- a node and its own ancestors — every child overlaps its parent;
- direct siblings — already `sibling-overlap`'s jurisdiction, so reporting them
  here would bill one defect twice;
- containers themselves — two overlapping rows whose content is disjoint is a
  background band or a grouped header.

Layering is honoured as in `sibling-overlap`, but along the whole ancestor path
rather than at a single node: a `zIndex` anywhere on either path, or a shared
`zstack` ancestor, reads as a deliberate paint order. A first row's title
overflowing a 24 pt row into the second row's title:

```text
'second-title' overlaps 'first-title' by 200 x 16 pt — the two have different parents, so no single container's layout can resolve it
give the containing rows enough height for their content, or truncate the overflowing content so it stays inside its row
```

**Suppress**: `verdict.suppress` on the lower node, declare `.zIndex()` on either
path, or `disabledRules`.

### `offscreen`

Fires when a visible, non-empty frame lies **entirely** outside `context.viewport`.
Partial overlap is not reported: content clipped at a viewport edge is normal for
scrollable and animating layouts, and judging it belongs to the dedicated
`ClippedContentRule` in Wave 5. `spacer` is exempt — a spacer pushed past the edge
carries no content.

A `sidebar` at x = 360 in a 320 × 240 pt viewport:

```text
'sidebar' is visible but sits entirely outside the 320 x 240 pt viewport (frame origin 360, 0)
move it inside the viewport, or hide it while it is off-screen so the tree matches what renders
```

**Suppress**: `verdict.suppress` on the off-screen node, mark it `isVisible: false`
while it is parked off-screen, or `disabledRules`.

### `truncation`

Needs `textMetrics`, which the Wave 2 layout probe attaches by measuring the same
text twice — once unconstrained (`intrinsicWidth`, `idealLineCount`), once at the
real proposal (`renderedLineCount`). Nodes without metrics are skipped rather than
guessed at; a rule that speculates is a rule people stop believing.

Two distinct defects:

1. **Vertical truncation** — `renderedLineCount < idealLineCount`.
2. **Single-line clipping** — `idealLineCount <= 1` and
   `frame.width + truncationTolerance < intrinsicWidth`. The `0.5` pt tolerance
   absorbs sub-pixel layout rounding so a 0.001 pt shortfall is not a defect.

Multi-line text narrower than its intrinsic width is *wrapping*, not truncation, and
is deliberately not reported — that case is the single largest source of false
positives in layout linting.

A one-line `title` needing 212 pt in a 120 pt frame:

```text
'title' needs 212 pt of width on one line but was given 120 pt
increase frame width to >= intrinsicWidth 212 pt, or allow wrapping
```

**Suppress**: `verdict.suppress` on the text node, or `disabledRules`. Widening the
tolerance is not a suppression path — it changes what counts as a defect everywhere.

### `tap-target`

Fires when a visible interactive node with a non-empty frame is smaller than
`context.minimumTapTarget` in either dimension. Empty frames are left to `zero-size`
so one defect produces one finding. Because the default threshold is the permissive
macOS pointer minimum, a firing rule means the control is genuinely below the
platform's documented floor; use `LintContext.touch(viewport:scenario:)` to police
`44` × `44` pt instead.

A `close` button measuring 24 × 18 pt:

```text
'close' is 24 x 18 pt, below the 28 x 28 pt minimum hit size
grow the control or add .frame(minWidth: 28, minHeight: 28)
```

**Suppress**: `verdict.suppress` on the control, `severityOverrides` to demote it,
or `disabledRules`.

---

## 4. Tree diff

`TreeDiff.compute(before:after:)` returns a `TreeDelta` with four categories:

| Category | Element | Meaning |
|----------|---------|---------|
| `added` | `NodeAddition` (`path`, `index`, `node`) | present only in the after-tree, carrying the whole added subtree |
| `removed` | `NodePath` | present only in the before-tree; the whole subtree is gone |
| `moved` | `NodeMove` (`path`, `from`, `to`) | a matched node whose frame changed |
| `changed` | `NodeChange` (`path`, `changes`) | a matched node whose non-geometric fields changed |

Completeness is the point: `TreeDiff.apply(_:to:)` replays a delta onto the
before-tree and reproduces the after-tree exactly. That invariant is what lets the
act→observe loop ship a delta instead of a full tree.

**Paths.** A `NodePath` is the chain of sibling-local identities from the root,
encoded as a JSON *array* rather than a joined string because a structural-path
segment may itself contain `/`. The root segment is the fixed string `$root`, not the
root's identity, so giving the root a probe id does not re-key every path in the
tree. An empty path is rejected on both encode and decode (`minItems: 1`).

**Matching** is id-first: probe `id`, then `structuralPath` component, then sibling
index. It is O(n) — one dictionary of segments per parent, no tree-edit-distance
search.

**Change keys** use a flat dotted vocabulary: `id`, `role`, `text`, `isVisible`,
`zIndex`, `structuralPath`, `childIndex`, `textMetrics.<component>`, and
`attributes.<name>`. On an `AttributeChange`, a `nil` `before` or `after` means the
field was absent on that side. Frame changes are always reported as `moved`, never
as a change key.

**Deliberate scope limits:**

- A node whose parent changed is reported as a removal plus an addition, not a
  relocation. Structure therefore always replays exactly, and an explicit
  `relocated` category can arrive later without breaking the wire format.
- Duplicate identities among siblings — which `duplicate-probe-id` reports as an
  error — make that parent's children match positionally instead.
- `childIndex` is emitted only when the surviving siblings' relative order actually
  changed. An insertion that merely shifts later siblings is not a reorder.

---

## 5. The verdict schema

Pinned by `contracts/verdict-schema.json`. Current version: **1.0**.

### Envelope

| Field | Required | Type | Notes |
|-------|----------|------|-------|
| `schemaVersion` | yes | `"1.0"` | always `SchemaVersion.current` on encode |
| `scenario` | yes | string | name of the scenario that produced the verdict |
| `timestamp` | yes | string | ISO-8601 UTC at whole-second precision, e.g. `2026-08-04T09:20:31Z` |
| `status` | yes | `"PASS"` \| `"FAIL"` | uppercase so a shell can grep it |
| `findings` | yes | array | empty for a clean verdict |
| `tree` | no | `semanticNode` | present only when the caller asked for it |
| `delta` | no | `treeDelta` | present only for act-and-observe steps |
| `timing` | yes | object | `settleMs`, `evaluateMs`, both optional numbers |

A `Finding` carries `rule`, `severity` (`error` or `warning`), `nodeID`, `message`,
and an optional `suggestion` — the machine-actionable repair hint that turns a
verdict into an edit an agent can make without guessing.

**`status` is derived, never asserted.** `Verdict.Status.derived(from:)` is the only
place it is computed — any `error` finding makes the verdict a `FAIL` — and the
decoder throws if a payload's `status` contradicts its own `findings`. A verdict that
can lie about its own headline is worse than no verdict.

**Absent means absent.** Optional fields are omitted from the JSON, never emitted as
`null`. The payload crosses a token-metered MCP surface, so `"tree": null` is pure
cost. `contracts/fixtures/verdict-pass.json` exists to pin exactly this.

```json
{
  "findings" : [

  ],
  "scenario" : "settings-pane-clean",
  "schemaVersion" : "1.0",
  "status" : "PASS",
  "timestamp" : "2026-08-04T09:20:31Z",
  "timing" : {
    "evaluateMs" : 0.42
  }
}
```

### Versioning

`SchemaVersion` states the compatibility contract:

- **Major** bumps on a breaking change — a removed or renamed field, a narrowed
  type, a changed meaning. A consumer pinned to an older major must refuse the
  payload rather than guess, so `Verdict.init(from:)` throws when
  `SchemaVersion.isCompatible(_:)` is false.
- **Minor** bumps on an additive change — a new optional field. Older consumers keep
  working by ignoring what they do not know, which is why `isCompatible(_:)` compares
  only majors and a *newer minor* is accepted.
- A malformed version string is never compatible. `SchemaVersion.major(of:)` accepts
  only `major` or `major.minor` shapes; reading `"1.2.3"` as major 1 would accept a
  payload built to a versioning scheme this kernel does not know.

### How the contract is enforced

`contracts/validate-contracts.py` runs three fail-closed checks, and the PM runs it
as `stage_contracts`:

1. **Schema integrity** — the schema parses, every `$ref` resolves, and it uses only
   keywords the validator implements. A keyword it cannot enforce fails the run
   rather than being skipped.
2. **Version agreement** — the schema's declared version matches
   `SchemaVersion.current` in the Swift source, and the `$id` URL carries the same
   version.
3. **Fixture round-trip** — every payload in `contracts/fixtures/` validates against
   the schema. `verdict-pass.json` covers the omission contract; `verdict-fail.json`
   populates every optional field at once.

The fixtures are **generated**, not hand-written: `ContractFixtureTests` regenerates
them from `Verdict.encode(to:)` and fails if the committed bytes differ, because a
stale fixture would validate happily while proving nothing about the code. To change
the wire format on purpose:

```bash
VERDICTUI_WRITE_FIXTURES=1 swift test --filter ContractFixtureTests
python3.14 contracts/validate-contracts.py
```

Then review the fixture diff as what it is — a change to a published contract.

---

## 6. Trust levels (inner loop vs middle loop)

VerdictUI has two ways to act on a UI. They are not interchangeable, and a PASS
from one is not evidence the other would agree.

| Level | Mechanism | What it proves | What it does not prove |
|-------|-----------|----------------|------------------------|
| **Inner loop** (Wave 3) | `ProbeAction` mutates `ScenarioState` bindings registered at `.verdictProbe(..., action:)` sites — in-process, no events, no Accessibility permission | The scenario's own state → layout → semantic tree → rules path is consistent | That a real click/key would hit the same control, or that AppKit/AX agree with the probe |
| **Middle loop** (Wave 8) | Real `CGEvent` / `AXUIElement` actions + external AX tree, reconciled against the in-process stream | The probe is not lying about what the OS exposes; hit-testing and AX roles match | Nothing about OS-level truths that only XCUITest can see (outer loop) |

The inner loop is the product's fast channel. Divergence in the middle loop is the
bug detector. An agent that only calls `ProbeAction` is trusting instrumentation;
an agent that also cross-validates is trusting less.
