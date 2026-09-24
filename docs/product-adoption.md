# Product adoption and installed-artifact acceptance

Updated September 24, 2026. A library import, a registered manifest, an executable
runner, and a verified installed app are different evidence states. None implies
complete product coverage.

## Registry coverage census

The follow-up census reads every row of `shared/pm-registry.json`, including
missing roots, projects without PM scripts, and additional registered roots.
At the September 23 measurement it contained **150 rows (128 PM projects and 22 non-PM entries) plus six additional
roots**. The latest bounded observer reported **150 unavailable** in 0.15 seconds.
The earlier 149-unavailable/one-excluded report had an incorrect exclusion:
PM Base serves the real CEO dashboard. Published PR 223 corrected its policy and
instructions; those three files are active in the canonical checkout with peer
files, HEAD and raw index preserved. The dashboard now declares
`ceo-fleet-dashboard`; its layout, paint and behavior remain unavailable until
current evidence exists. These are evidence states, not failing products and
not an assertion that the other projects have no UI.
The smaller directory search below is historical implementation evidence.

The shared `ui_coverage` reader requires project-owned `.verdictui/coverage.json`
and `checks.json`, then independently validates layout, paint and behavior
receipts. Evidence is bound to current source, declarations, declared surfaces,
and the latest started attempt. A new run invalidates a former passing receipt.
Paint additionally requires an actual PNG/JPEG and a review of that image.
Explicit exclusions need a project policy and reason; absence of a target cannot
create an exclusion. Even complete receipts certify only the declared surfaces.

The CEO's `--ui-coverage` command returns the complete inventory and exits 2 for
missing/partial evidence, 1 for observed failure. Normal reports expose this
separately from build grades; aftermath preserves it in the signed record.
Project adoption remains incomplete until actual project observations satisfy
these contracts. A census or installed safeguard is not adoption completion.

The reporting guard was published in pm-base PR 219 and activated as a narrow
overlay in the canonical shared library, preserving its existing peer edits,
Git index and HEAD. Fresh canonical imports and 215 focused checks passed.
This does not claim that the canonical mixed checkout equals the complete
published PM Base release or that already-running processes reloaded it.
The later completion and dashboard guard is published in PR 222. On September
24, all five existing CEO LaunchAgents were restored on qualified commit
`0f48e38` after its clean-source full PM passed A100. Their arguments and calendar
schedules were preserved. The running watcher explicitly reported 150 unavailable
projects and withheld UI completion; the three scheduled jobs remained idle.
Live dashboard checks passed at 1440px and 390px, including exact API-to-DOM
coverage text, column alignment and overflow checks. Review of the four actual
images exposed a separate watcher-status parsing defect: a stamped PID lock was
displayed as stopped. That repair and final paint acceptance remain pending.

## Actual client and consumer checks

The actual Codex MCP connection exposed 18 tools and successfully observed the
published VerdictUI 1.1.3 page, with zero errors and nine layout warnings. Its
owned browser session was closed and the empty session list verified. This
establishes client connectivity and semantic page observation, not paint quality
or fleet adoption.

A compiled PanoMac consumer runner, built beside the actual VerdictUI source,
was also called through the Codex `judge_appkit` tool. Eight empty controller
surfaces passed, two reported layout errors, and the planted truncation defect
failed as intended. Measured native alignment rectangles explain the two
apparent errors: decorative popup/button bounds extend outside their logical
layout rectangles. The renderer correction and its genuine-defect controls are
being verified separately. These empty-state results do not cover populated
tables, async data, installed application behavior or paint.

## SagaMail source adoption checkpoint — September 24

PR43 is merged as `dc35111a`, preserving the qualified `3a9c6b5a` tree.
The executable `SagaMailVerdictRunner` and project-owned manifests replace the
earlier source-file configuration. They render the real Junk Mail settings tab
at 700 × 900 points in three declared states, with UUID-named synthetic defaults.
The offscreen negative control renders the same tab and is excluded from normal
checks. Standard preferences and the installed application were not changed.

Six native tests and six actual CLI/MCP controls passed locally. Hosted CI
`36040668168` passed with all six settings tests observed executing; the
self-hosted render lane also passed. Two dispatch-only GUI jobs were skipped.
A fresh-HOME, tracked-only CI-shape probe passed 84 source checks and 30 website
checks. The unrestricted Python suite was deliberately not run because its live
fixtures access Keychain, localhost message state and the installed application.

Both reviewers inspected all three original PNGs from source `4d7ff8eb`:
the controls align, conditional content matches the settings, and probed bounds
stay inside the viewport. A minor existing empty divider row remains recorded.
Those images retain their original source identity. Broader tabs, live clicks,
other sizes/themes, real accounts and installed application behavior are not
covered. The canonical fleet reader still requires current admitted receipts.

The earlier cold build exceeded the default 300-second budget; the explicit
first build took 424.92 seconds. The new source candidate adds a validated
per-project `buildTimeoutSeconds` with the same 300-second default and an
1,800-second ceiling. SagaMail source `d8cda99d` selects 900 seconds. Fresh tracked
consumer clones with no initial build directory completed CLI in 525.54 seconds
and MCP in 505.24 seconds using VerdictUI `9bd283c`. Both exposed SagaMail's own
registry and distinguished the normal view from the real offscreen negative
control. Seven warm CLI/MCP controls also passed. Shared package-download caches
may have existed; this is not a claim of an entirely cold machine.

Independent review checked the raw outputs, all sixteen artifact bindings, the
frozen CLI hash and both source pins. The first CLI evidence producer failed
while decoding compiler diagnostics after the actual command had succeeded;
that failed receipt remains intact. A separate reconciliation and subsequent
controls establish the consumer result. These are source-candidate results;
installed 1.1.3 and the earlier signed 1.1.4 archive have not gained this feature.

Current layout and paint admission is being refreshed after the final consumer
documentation commit. Behavior remains unavailable: these preset view states
do not exercise actual user actions. See SagaMail's `docs/verdictui-adoption.md`
for reproduction and the complete evidence boundary.

## Earlier read-only directory census

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

1. Admit current layout and paint receipts for SagaMail's three-state consumer,
   publish its verified cold-build configuration, and audit remaining settings and
   installed account flows separately from synthetic controls.
2. Add project-owned checks for each actual product surface. Web targets need a
   reachable app URL and an expected rendered result. AppKit targets need their
   executable and real subject; SwiftUI targets need the consumer registry.
3. Keep read-only live checks distinct from actions that alter account state.
   The automatic edit hook runs configured checks; it cannot establish that all
   edited views were included.
4. Re-run this gate against the final installed binary, and each consumer's
   independent acceptance, before claiming full adoption. Record unconfigured,
   unavailable and incomplete products rather than treating them as clean.

## Workbench adoption follow-up

The Workbench now declares `workbench-connected-workflow` in project-owned
checks and coverage manifests. Its runner drives the actual packaged WKWebView,
bridge and helper against freshly compiled private consumers. CLI/API/MCP share
the explicit web-tree judge, including a real consumer runner; a native AppKit
judge is not substituted for DOM rules. The source catalog now has 19 tools,
including `judge_web`; the currently installed 1.1.3 clients still have 18.

The integrated editor and resource repair passed 138 Python contracts and
the PM Workbench stage (138 browser assertions in two engines, 48 native
observations across 10 phases). The worker candidate also passed independent
review of all nine native PNGs. Compiled renderer checks retain their runner
and subject when renamed or saved; the loaded WKWebView page must match the
verified packaged resource path. The integrated release must retain its own
fresh observation and image review after final source changes before admission.
The launch-owned guardian repair has actual native/browser and compiled-consumer
owner-death controls, with unrelated sentinel processes left alive. These controls
cover inherited process groups. A real SwiftPM manifest demonstrated that a child
can create a separate group and escape that boundary; CIS-4F278A0F remains open.
Credential helpers and graceful consumer reload have separate controls: ordinary
cancellation alone does not establish crash cleanup or persisted browser state.

This scope covers project selection, editing and saving checks, actual consumer
PASS/FAIL, running state, cancellation, history and reload. It does not certify
OS file pickers, notifications, window management, other products or every
possible state. Native captures measured the owner's enabled reduced-motion
preference; normal native motion remains unmeasured. See
[workbench-adoption.md](workbench-adoption.md) for reproducible admission.

## Runner reliability follow-up

The legacy AppKit runner could deadlock while reading stdout before a full stderr
pipe. It now uses the same bounded command boundary as project checks, retaining
separate failure diagnostics and enforcing an aggregate output budget. A real CLI
fixture distinguishes the old blocking behavior from the repaired result. Running
file sizes are measured through retained descriptors: Foundation URL metadata
was observed to cache the initial size and miss later output growth. The held
producer, timeout, cancellation and mutation controls establish these specific
behaviors; they do not replace final integrated or installed-artifact acceptance.

Credential helpers share the launch-owned guardian. Normal consumer shutdown
drains pending launches and open sessions concurrently and allows browser storage
to flush; genuine protocol/build failures retain short escalation. Failed session
retirement propagates through lookup/open and remains owned when listing omits
an unavailable session. A later close can therefore retry cleanup. These guards
are covered by explicit crash, delayed persistence and failed-retirement controls.
MCP initialization identifies the software release separately from the verdict
schema; the candidate reports1.1.4, while its wire schema remains1.1.
