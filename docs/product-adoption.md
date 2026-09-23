# Product adoption and installed-artifact acceptance

Measured September 23, 2026. A library import, a registered manifest, an executable
runner, and a verified installed app are different evidence states. None implies
complete product coverage.

## Read-only fleet census

The census enumerated 80 non-hidden top-level directories under `~/Projects`,
searched Swift/JSON sources for `VerdictUIProbe`, `VerdictUIAppKit`,
`VerdictUIKernel`, and `PanoMacVerdictRunner`, and separately walked hidden
`.verdictui` directories for `config.json` and `checks.json`. It excluded build,
cache, dependency and hidden worktree directories. Top-level working copies such
as `Sentinel-drain-*` are reported as duplicates, not additional products.
LearnWatch archival JSON mentions were excluded from adoption counts.

| Product | Measured implementation | Installed CLI/background configuration | Coverage limit |
|---|---|---|---|
| SagaMail | `SagaMailSnapshotTests/VerdictUIRenderTests.swift` tests real avatar sizes with a planted fault. `SagaMailTests/VerdictUISettingsAuditTests.swift` renders the real Junk Mail tab and exercises persisted defaults. | `.verdictui/config.json` points to the **Swift XCTest source file**, not an executable. No `checks.json`. This is invalid for executable delegation. | One settings tab and avatars do not cover every tab/parameter, real accounts, installed compose behavior, or the owner's complete-app request. |
| LaunchGate | `Tests/LaunchGateTests/VerdictUIRenderTests.swift` covers onboarding titles, empty-state copy and planted faults. `VirtualRenderChecksTests.swift` also exists. | No project check/runner manifest found. | Real library tests exist; installed CLI or full live-app acceptance not demonstrated by those tests. |
| PanoMac | `Sources/VerdictRunner/main.swift` supplies `PanoMacVerdictRunner`, builds real controllers through `ScreenFactory`, derives subjects from `PanoMacScreen.allCases`, and includes a planted defect. | No project check manifest found. AppKit runner is invoked explicitly after building. | Source explicitly says controllers contain **no data** because async population does not run. Empty-state coverage cannot certify populated tables. |
| KastDrive | `Tests/KastDriveSnapshotTests/VerdictUIRenderTests.swift` tests a design-system sidebar row, squeezed control and planted defect. | No project check/runner manifest found. | Optional sibling-package tests, not whole installed File Provider/app coverage. |
| Sentinel | `app/Tests/SentinelSnapshotTests/VerdictUIRenderTests.swift` imports VerdictUI. | Canonical checkout has no manifest. The separate `Sentinel-drain-engine` working copy has `.verdictui/config.json` naming `.verdictui/run` and an onboarding runner; both were untracked at measurement time. | Working-copy integration is not evidence of publication in canonical Sentinel. Several other Sentinel working copies repeat the dependency. |
| Other searched product roots | No matching import/runner source found in this search. | No additional manifests found. | Search absence is not proof a product has no UI, no custom equivalent, or cannot be adopted. These products are **not measured**. |

The only four `config.json` paths found were canonical SagaMail, duplicate
`release-checklist-worktrees/SagaMail`, `Sentinel-drain-engine`, and VerdictUI's
own catalog. **Zero `checks.json` manifests** were found in the searched roots.
The VerdictUI catalog is the tool's self-test, not adoption by another product.
This is an observed checkout census, not a claim that all fleet projects or
external drives were scanned.

## Installed applications

Read-only `/Applications` inspection found SagaMail version `0.1.0`, build `1`,
with its executable present, and LaunchGate version/build `0.4.19`, with its
executable present. SagaMail had a running process from its installed bundle;
no installed LaunchGate process matched the same process-path query. These are
installation/process facts only. No accounts, messages, settings or installed
application state were mutated in this census. Bundle versions alone cannot
prove the installed binary matches current source.

## Reproducible artifact gate

```bash
python3.14 -m pytest Tests/test_product_smoke.py -q
python3.14 scripts/product-smoke.py --binary /absolute/path/to/verdictui
```

The smoke script runs the supplied executable through real CLI and interactive
MCP transports. It uses loopback web fixtures, temporary browser profiles and
synthetic credential references, and compiles the disposable transparent
AppKit/SwiftUI fixture. It asserts observed state, FAIL controls, unavailable
responses, browser isolation/persistence, cleanup on EOF/TERM, and unchanged
foreground application/global cursor. It also checks aggregate web/native
project manifests. Missing permissions or unavailable responses fail acceptance;
there is no silently skipped native lane.

A passing fixture gate proves the installed engine/transport can operate these
controlled subjects. It does **not** prove SagaMail's real account flows, every
settings parameter, LaunchGate's complete UI, or all-product adoption. Those
require project-owned target manifests, actual consumer runners and explicit
coverage inventories. Do not copy demonstration targets into those manifests
and report project coverage.

## Required adoption work

1. Replace SagaMail's nonexecutable manifest with a genuine consumer executable
   and retain honest coverage labels; audit all settings tabs/parameters against
   the installed app separately from synthetic controls.
2. Add project-owned checks for each actual product surface. Web targets need a
   reachable app URL and an expected rendered result. AppKit targets need their
   executable and real subject; SwiftUI targets need the consumer registry.
3. Keep read-only live checks distinct from actions that alter account state.
   The automatic edit hook runs configured checks; it cannot establish that all
   edited views were included.
4. Re-run this gate against the final installed binary, and each consumer's
   independent acceptance, before claiming full adoption. Record unconfigured,
   unavailable and incomplete products rather than treating them as clean.
