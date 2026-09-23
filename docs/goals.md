# VerdictUI — Goals

> **Updated**: 2026-09-23 against implementation and release acceptance.
> Link back here: `/spec` ships → update this file.

## Why This Project Exists

Developers and AI agents verify SwiftUI work through a screenshot→wait→click→wait→confirm cycle that is slow (model round trips + arbitrary sleeps), flaky (XCUITest idle-wait is documented-broken on Xcode 15/16 + Sonoma/Sequoia), permission-gated, and blind to everything between frames. Deep research (2026-08-03, CTS-5BABC171) established that every load-bearing mechanism for a better way exists but is unassembled: preference-key state tracking (SwiftLens, dormant), macro injection (Embrace), offscreen geometry oracles (blog-post technique), and no one ships SwiftUI's missing `pumpAndSettle`, a layout-lint verdict layer, or in-process/external cross-validation. VerdictUI assembles and completes that stack as one product: in-process instrumentation emits a ground-truth semantic tree; a platform-pure kernel renders PASS/FAIL verdicts with evidence; agents get an atomic act-and-observe loop with no screenshots in the hot path.

## Current milestone: 1.1 real-product verification and desktop release

The engine now accepts external Swift consumer registries, AppKit runners,
live macOS subjects and isolated browser sessions through CLI/MCP. The desktop
workbench bundles the same engine behind a local web-rendered interface with
editable project checks, measured results, history and cancellation.

Release acceptance: complete the full PM, external consumer rebuild/recovery,
real native/browser artifact smoke, two-engine rendered workbench checks,
notarized app publication and installed CLI/app parity. See
[wave-status.md](wave-status.md) for current measured completion and
[instruction-coverage.md](instruction-coverage.md) for the recovered owner scope.

## Implemented milestones

| Milestone | Evidence |
| --- | --- |
| Kernel, public SwiftUI probing and settling | Platform-pure semantic tree/verdict contract and rule tests |
| Macros, scenarios, CLI, daemon and MCP | Expansion/runtime/transport tests and public consumer runner |
| Accessibility reconciliation and deterministic pixel paths | Witness and pixel regression suites; unavailable OS measurements remain explicit |
| AppKit rendering and native input | Shared native driver and real hidden AppKit/SwiftUI fixture acceptance |
| Browser observation and trusted input | DOM assembly, credential references, owned profile sessions, real login/task controls |
| Desktop workbench | Bundled WKWebView UI, real checks, evidence, persistence and cancellation |

## Boundaries

- A successful engine fixture does not certify every screen of a consumer app.
  Consumer manifests and screen/account coverage are tracked separately in
  [product-adoption.md](product-adoption.md).
- OS access remains permission-honest. Unsupported or unreadable subjects are
  unavailable, not passing.
- The core uses public APIs and keeps the kernel independent of UI frameworks.
- Layout evidence and expectations verify correctness; aesthetic judgment still
  requires a rendered review.
- Hosted baseline/team services remain outside this release.
