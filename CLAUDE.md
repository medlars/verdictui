@~/Projects/shared/rules.md
@no.md

# VerdictUI

SwiftUI verification engine that replaces the screenshot–wait–click–confirm cycle with in-process instrumentation, virtual-clock settling, and atomic act-and-observe verdicts.

## Quick Start

```bash
bash scripts/dev.sh                        # setup + build + test
python3.14 scripts/verdictui-pm.py --quick # health check
```

## Architecture

Three concentric verification loops (see `docs/implementation-plan.md` for the full wave plan):

1. **Inner loop (in-process, every edit)** — `VerdictUIProbe` instruments SwiftUI via public API only (Layout-protocol transparent probe, `PreferenceKey` frame streams, `.verdictProbe(id:)`); `VerdictUIKernel` turns the emitted semantic tree into a PASS/FAIL `Verdict` with evidence. Milliseconds, no pixels, no permissions.
2. **Middle loop (cross-validation, per scenario)** — external `AXUIElement` tree + real event injection + windowless pixel capture, reconciled against the in-process stream. Divergence *is* the bug detector.
3. **Outer loop (thin E2E smoke)** — orchestrated XCUITest for OS-level truths only.

Target layout:

| Target | Purpose | Constraint |
|--------|---------|------------|
| `VerdictUIKernel` | Semantic tree, diff, lint rules, verdict schema | **Platform-pure: no SwiftUI/AppKit imports** (PM `stage_architecture` enforces) |
| `VerdictUIProbe` | SwiftUI instrumentation runtime + oracle harness | Public SwiftUI API only — no private API in this target |
| `VerdictUIMacros` (Wave 4) | `@Verifiable`, compile-time lint | SwiftSyntax |
| `verdictui` CLI + MCP (Waves 6–7) | Agent-facing surface | Warm daemon, atomic act→diff |

## Key Paths

| Item | Path |
|------|------|
| Root | `~/Projects/VerdictUI/` |
| PM | `scripts/verdictui-pm.py` |
| Wave plan | `docs/implementation-plan.md` |
| SLOs | `docs/slo.md` |
| Runbook | `docs/runbook.md` |
| Contracts | `contracts/` |
| File registry | `docs/FILE_REGISTRY.md` |

## Canonical Implementations (SSoT)

| Concern | Canonical implementation | Location | Notes |
|---------|--------------------------|----------|-------|
| Semantic tree model | `SemanticNode` / `Rect` | `Sources/VerdictUIKernel/SemanticNode.swift` | Platform-pure; never duplicate a geometry type elsewhere |
| Verdict schema | `Verdict` / `Finding` | `Sources/VerdictUIKernel/Verdict.swift` | Every verification path terminates here |
| Frame probing | `.verdictProbe(id:)` + `VerdictFramesKey` | `Sources/VerdictUIProbe/VerdictProbe.swift` | Public-API instrumentation; Wave 2 adds the Layout-protocol probe |

## Model

Recommended: **opus** — Swift-native product with deep framework internals (Layout protocol, macros, AttributeGraph adjacency); high-stakes design decisions per wave.
Switch with `/model opus` if current session model differs.

## Rules

1. **Kernel purity** — `VerdictUIKernel` never imports SwiftUI/AppKit/CoreGraphics. The verdict engine must run headless anywhere.
2. **Public API first** — `VerdictUIProbe` uses only supported SwiftUI extension points. Private-API backends (e.g. `_viewDebugData`) live behind an explicit optional adapter target, never in the core path (see `no.md` #001).
3. **Every wave lands with tests alongside** — the product's whole thesis is verification; an untested wave is self-refuting.
4. **Evidence or it didn't happen** — a `Verdict` must cite node IDs and rule names; bare booleans are banned in the public API.
5. All cross-cutting rules from `~/Projects/shared/rules.md`.
