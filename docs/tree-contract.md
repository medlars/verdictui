# The tree contract — judging UI from any language

`verdictui judge` runs the full rule library against a semantic tree **you**
produce. That makes every rule available to React, Flutter, Compose, or anything
else that can emit JSON — without VerdictUI rendering a pixel of it.

> **What this is not.** VerdictUI does not *render* non-Swift UI. Producing the
> tree is your job: a DOM walk, a Flutter semantics dump, a Compose hierarchy
> dump, an accessibility scrape. VerdictUI judges what it is handed. A tool that
> claimed to render everything and silently rendered nothing is exactly the
> failure this project exists to prevent, so the boundary is stated rather than
> blurred.
>
> The reason this works at all: `VerdictUIKernel` imports **only Foundation**.
> `Rect` is hand-rolled (`no.md` #5) precisely so the engine compiles anywhere,
> and every rule judges geometry and text metrics, not SwiftUI.

## Usage

```bash
verdictui judge tree.json                 # from a file
your-extractor | verdictui judge -        # from stdin
verdictui judge tree.json --summary       # human-readable instead of JSON
verdictui judge tree.json --name checkout-page --viewport-width 390
```

**Exit codes are three-valued and never conflated:**

| Code | Meaning |
| --- | --- |
| `0` | the UI passed |
| `1` | a verdict was produced and it FAILED |
| `2` | no verdict could be produced (unreadable tree, bad JSON) |

A pipeline that treats `1` and `2` alike turns an infrastructure fault into a
product defect, which is why they are separate.

## The shape

This is the exact wire form `verdictui render` emits, so a round trip is the
cheapest way to check your extractor: render a Swift scenario, read the JSON,
match it.

```json
{
  "id": "root",
  "role": "container",
  "frame": {"x": 0, "y": 0, "width": 390, "height": 844},
  "isVisible": true,
  "children": [
    {
      "id": "product-title",
      "role": "text",
      "frame": {"x": 8, "y": 8, "width": 120, "height": 20},
      "text": "Wireless Noise Cancelling Headphones",
      "textMetrics": {
        "intrinsicWidth": 310,
        "renderedLineCount": 1,
        "idealLineCount": 1
      },
      "children": []
    }
  ]
}
```

### Fields

| Field | Required | Meaning |
| --- | --- | --- |
| `id` | yes | Stable identifier. Findings cite it, baselines key on it. An empty id means *unprobed*, and a tree with no probed node is REFUSED as vacuous rather than passed. |
| `role` | yes | `container`, `text`, `button`, `toggle`, `image`, `list`, `listRow`, or `{"custom": "name"}`. Role decides which rules apply. |
| `frame` | yes | `x`, `y`, `width`, `height` in points, in the ROOT's coordinate space — not relative to the parent. |
| `children` | no | Defaults to empty. |
| `isVisible` | no | Defaults to `true`. |
| `text` | no | The rendered string, for `text`-ish roles. |
| `textMetrics` | no | Required for `TruncationRule` and `ExcessiveWrapRule` to say anything. |
| `structuralPath` | no | Emitted by the renderer; usable to cite unprobed nodes. |

### `textMetrics` — the field most likely to trip you

| Key | Meaning |
| --- | --- |
| `intrinsicWidth` | Width the text needs when proposed unlimited space. |
| `renderedLineCount` | Lines actually drawn inside the resolved frame. |
| `idealLineCount` | Lines the text wants when not line-limited. |

Horizontal truncation is `intrinsicWidth > frame.width` at one line; vertical
truncation is `renderedLineCount < idealLineCount`. Both keys are **required**
when `textMetrics` is present — omitting one is a decode error, not a default.
(Measured: writing `lineCount`/`lineLimit` from memory produced
`DecodingError.keyNotFound: 'renderedLineCount'`, which is how this table came
to exist.)

### Roles that change what is checked

- `container`, `list`, `listRow` are policed by `EmptyContainerRule` — a container
  whose children do not paint is reported as a blank region.
- `custom` means *the extractor could not classify this node*. Use it for a
  subtree you cannot see into; those are exempt from the container rules,
  because calling an unclassified node empty states more than the tree supports.

## Worked example

```bash
$ verdictui judge tree.json --summary
FAIL  judged-tree
  [error] truncation on 'product-title': 'product-title' needs 310 pt of width
          on one line but was given 120 pt
      → increase frame width to >= intrinsicWidth 310 pt, or allow wrapping
$ echo $?
1
```

Every finding carries a rule id, a node id, both measurements, and the edit that
fixes it — enough for an agent to act without a screenshot.

## Extractor checklist

1. Emit frames in the ROOT's coordinate space, not the parent's.
2. Give every node you want cited a stable `id`; leave it empty for scaffolding.
3. Include `textMetrics` for text, or truncation rules cannot fire and your
   verdict is quieter than it should be.
4. Pass `--viewport-width/--viewport-height` when the root frame is not the
   screen, or `OffscreenRule` judges against the wrong surface.
5. Verify your extractor against a KNOWN defect first. A tree that always passes
   may mean your UI is clean, or may mean your extractor emits nothing useful —
   those look identical from here, and only a deliberate failure separates them.
