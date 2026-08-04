# VerdictUI — Goals

> **Updated**: 2026-08-04 after each shipped spec or milestone.
> Link back here: `/spec` ships → update this file.

## Why This Project Exists

Developers and AI agents verify SwiftUI work through a screenshot→wait→click→wait→confirm cycle that is slow (model round trips + arbitrary sleeps), flaky (XCUITest idle-wait is documented-broken on Xcode 15/16 + Sonoma/Sequoia), permission-gated, and blind to everything between frames. Deep research (2026-08-03, CTS-5BABC171) established that every load-bearing mechanism for a better way exists but is unassembled: preference-key state tracking (SwiftLens, dormant), macro injection (Embrace), offscreen geometry oracles (blog-post technique), and no one ships SwiftUI's missing `pumpAndSettle`, a layout-lint verdict layer, or in-process/external cross-validation. VerdictUI assembles and completes that stack as one product: in-process instrumentation emits a ground-truth semantic tree; a platform-pure kernel renders PASS/FAIL verdicts with evidence; agents get an atomic act-and-observe loop with no screenshots in the hot path.

## Current Milestone: Wave 1 — Kernel

**Goal**: The verdict engine is complete and platform-pure: full semantic tree model, tree diffing, the first 6 lint rules, and the JSON verdict/evidence schema — all headless-testable.
**Criteria**:
- [ ] `SemanticNode` supports role vocabulary, text metrics, visibility, and stable identity across renders
- [ ] `TreeDiff` produces added/removed/changed node sets between two trees
- [ ] Lint rules: sibling-overlap, zero-size, off-screen, truncation (given text metrics), tap-target-minimum, duplicate-probe-id
- [ ] `Verdict` JSON schema versioned and documented in `contracts/`
- [ ] 100% of kernel public API covered by XCTest; `swift test` green
**Target**: First Opus 5 execution session after scaffold

## Completed Milestones

| Milestone | Shipped | What changed |
|-----------|---------|--------------|
| Wave 0 — scaffold | 2026-08-04 | Project created via /project-forge; buildable package with seed kernel+probe; wave plan written |

## Non-Goals (what this project will NOT do)

- Replace XCUITest for OS-level end-to-end truths (launch, permissions dialogs, real keyboard) — VerdictUI orchestrates a thin outer smoke layer instead
- Web backend before the SwiftUI backend is proven (contract is platform-agnostic; implementation is deferred — no.md #003)
- Private SwiftUI API in the core path (no.md #001)
- Visual aesthetic judgment ("does it look good") — VerdictUI proves correctness properties, not taste
