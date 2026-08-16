# 2026-025 — `judge` takes a tree rather than rendering foreign UI

**Status:** Accepted
**Date:** 2026-08-16

## Context

The owner asked that VerdictUI "check the UI render of swift and other
languages." Taken literally that reads as a request to render React, Flutter or
web UI — which `no.md` #3 deliberately deferred, on the reasoning that web
engines already exist free (CDP/Playwright) and SwiftUI is the differentiated
wedge.

Measuring first changed the question. `VerdictUIKernel` imports **only
Foundation**: `Rect` is hand-rolled precisely so the kernel compiles anywhere
(`no.md` #5), every rule judges geometry and text metrics rather than SwiftUI,
and `SemanticNode` already conforms to `Codable` (`SemanticNode.swift:359`). So
the rule library was never Swift-bound. What was missing was a way to hand it a
tree: every existing verb (`render`, `verify`, `sweep`, `baseline`) renders a
registered SwiftUI scenario first, and there was no entry point accepting one
from outside.

## Decision

Add `verdictui judge <file|->`, which decodes a caller-supplied `SemanticNode`
from JSON and runs `RuleEngine.standardRules` against it.

The boundary is stated explicitly in the CLI help, `docs/tree-contract.md`, and
the commit message: **VerdictUI does not render non-Swift UI.** Producing the
tree is the caller's job — a DOM walk, a Flutter semantics dump, a Compose
hierarchy dump, an accessibility scrape. VerdictUI judges what it is handed.

Exit codes stay three-valued and are not collapsed: `0` passed, `1` a verdict
was produced and FAILED, `2` no verdict could be produced (unreadable tree).
A pipeline that conflates 1 and 2 turns an infrastructure fault into a product
defect.

## Alternatives considered

1. **Build a web/DOM adapter (CDP or Playwright).** Rejected: it is the thing
   `no.md` #3 deferred and the reasoning has not changed — free engines already
   cover it, and it would divert the wedge. It is also far larger than the gap
   actually required; the kernel needed a door, not a renderer.

2. **Claim the existing verbs already cover other languages.** Rejected as
   false. Every one of them renders SwiftUI first. Saying otherwise would be
   exactly the fabrication this product exists to refuse.

3. **Say no, and record the limit.** Rejected because it is not the real limit.
   Measurement showed the engine was already language-agnostic, so refusing
   would have described a constraint that does not exist.

4. **Ship `judge` without a documented tree contract.** Rejected on evidence
   from building it: writing the tests, `TextMetrics` was spelled from memory as
   `lineCount`/`lineLimit` and produced
   `DecodingError.keyNotFound: 'renderedLineCount'`. A foreign producer hits
   that on its first attempt, so the contract doc ships with the verb, marks
   those keys required rather than defaulted, and its worked example was run
   verbatim to confirm the output and exit code it claims.

## Consequences

- Every rule becomes available to any language that can emit the tree shape,
  with no rendering work and no new dependency.
- The verb is honest about what it does not do, which keeps the `no.md` #3
  deferral intact rather than quietly eroding it.
- The tree shape becomes a published contract. Changing `SemanticNode`'s wire
  form is now a consumer-visible break, governed by the existing rule that a
  shape change bumps `SchemaVersion.current` and the contract fixtures together.
- `judge` does not need a scenario registry, so it is unaffected by the
  catalog-scoping limit tracked in CTS-99986645 — it works from any directory,
  in any project, today.

## Rollback

Delete `JudgeCommand` from `Commands.swift`, remove `Judge` from the
`subcommands:` array in `CommandLineInterface.swift`, delete
`JudgeCommandTests.swift` and `docs/tree-contract.md`, and drop their
`FILE_REGISTRY.md` rows. Nothing else depends on it: the verb is additive, adds
no dependency, and no existing command calls into it. The kernel is untouched.
