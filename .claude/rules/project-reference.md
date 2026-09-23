---
paths:
  - "Sources/**"
  - "Tests/**"
  - "scripts/**"
  - "docs/**"
  - "contracts/**"
  - "web/**"
  - ".github/**"
  - "Package.swift"
---
# VerdictUI — project reference

> Loaded only when a matching file is read (moved out of CLAUDE.md for CIS-7E05B3C2).

## Key Paths

| Item                       | Path                          |
| -------------------------- | ----------------------------- |
| Root                       | `~/Projects/VerdictUI/`       |
| PM                         | `scripts/verdictui-pm.py`     |
| Wave plan                  | `docs/implementation-plan.md` |
| Wave status (resume point) | `docs/wave-status.md`         |
| Business decisions         | `docs/business-decisions.md`  |
| SLOs                       | `docs/slo.md`                 |
| Runbook                    | `docs/runbook.md`             |
| Contracts                  | `contracts/`                  |
| File registry              | `docs/FILE_REGISTRY.md`       |

## Model

Recommended: **opus** — Swift-native product with deep framework internals (Layout protocol, macros, AttributeGraph adjacency); high-stakes design decisions per wave.
Switch with `/model opus` if current session model differs.

## Architecture

Three concentric verification loops (see `docs/implementation-plan.md` for the full wave plan):

1. **Inner loop (in-process, every edit)** — `VerdictUIProbe` instruments SwiftUI via public API only (Layout-protocol transparent probe, `PreferenceKey` frame streams, `.verdictProbe(id:)`); `VerdictUIKernel` turns the emitted semantic tree into a PASS/FAIL `Verdict` with evidence. Milliseconds, no pixels, no permissions.
2. **Middle loop (cross-validation, per scenario)** — external `AXUIElement` tree + real event injection + windowless pixel capture, reconciled against the in-process stream. Divergence _is_ the bug detector.
3. **Outer loop (thin E2E smoke)** — orchestrated XCUITest for OS-level truths only.

Target layout:

| Target                            | Purpose                                          | Constraint                                                                      |
| --------------------------------- | ------------------------------------------------ | ------------------------------------------------------------------------------- |
| `VerdictUIKernel`                 | Semantic tree, diff, lint rules, verdict schema  | **Platform-pure: no SwiftUI/AppKit imports** (PM `stage_architecture` enforces) |
| `VerdictUIProbe`                  | SwiftUI instrumentation runtime + oracle harness | Public SwiftUI API only — no private API in this target                         |
| `VerdictUIMacros` (Wave 4)        | `@Verifiable`, compile-time lint                 | SwiftSyntax                                                                     |
| `verdictui` CLI + MCP (Waves 6–7) | Agent-facing surface                             | Warm daemon, atomic act→diff                                                    |
