@~/Projects/shared/rules.md
@no.md

# VerdictUI

SwiftUI verification engine that replaces the screenshot–wait–click–confirm cycle with in-process instrumentation, virtual-clock settling, and atomic act-and-observe verdicts.

## Quick Start

```bash
bash scripts/dev.sh                        # setup + build + test
python3.14 scripts/verdictui-pm.py --quick # health check
```

## Session Continuity (read this first, every session)

**Every session resumes the build from where the last one left off.** Protocol:

1. Read `docs/wave-status.md` — its "Next action" row is the first task. Cross-check against `git log --oneline -5`; if the file is stale (newer commits or uncommitted work), reconcile it from git evidence before continuing.
2. P0/P1 in `TODO.md` / open CIS issues preempt wave work; a non-Grade-A PM preempts everything.
   **Blockers carry `measured: YYYY-MM-DD` + `falsify: <command>` (DIR-036).** Do not inherit one:
   run the falsify command if the date is older than 7 days and re-stamp it either way. A blocker
   with neither field is unverified — measure before escalating. Wave 8 sat blocked for a week on
   "needs Accessibility permission, an owner action" that was never measured and was false; one
   probe retired it in under a minute (`no.md` #42).
3. Start working without asking what to do — announce in one line what is being resumed.
4. **Before the session ends**: update `docs/wave-status.md` (tasks done, precise next action, session-log line), commit, push. Leaving it stale breaks the next session's resume.

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

## Canonical Implementations (SSoT)

| Concern                    | Canonical implementation                 | Location                                     | Notes                                                                                      |
| -------------------------- | ---------------------------------------- | -------------------------------------------- | ------------------------------------------------------------------------------------------ |
| Semantic tree model        | `SemanticNode` / `Rect`                  | `Sources/VerdictUIKernel/SemanticNode.swift` | Platform-pure; never duplicate a geometry type elsewhere                                   |
| Verdict schema             | `Verdict` / `Finding`                    | `Sources/VerdictUIKernel/Verdict.swift`      | Every verification path terminates here                                                    |
| Frame probing              | `.verdictProbe(id:)` + `.verdictRoot(…)` | `Sources/VerdictUIProbe/VerdictProbe.swift`  | Public-API instrumentation; the root modifier owns the `verdict-root` coordinate space     |
| Layout negotiation capture | `ProbeLayout`                            | `Sources/VerdictUIProbe/ProbeLayout.swift`   | Sees proposals vs. results, which `GeometryReader` cannot; supplies `textMetrics`          |
| Probe records → tree       | `TreeAssembly.assemble`                  | `Sources/VerdictUIProbe/TreeAssembly.swift`  | The only place records become a `SemanticNode` tree                                        |
| Headless render + settle   | `OracleHost`, `LayoutSettle`             | `Sources/VerdictUIProbe/OracleHost.swift`    | Windowless `NSHostingView`; `LayoutSettle` is the reusable pump primitive Wave 3 builds on |
| Scenario definition        | `VerdictScenario`                        | `Sources/VerdictUIProbe/Scenario.swift`      | Injection point for variant sweeps                                                         |

## Model

Recommended: **opus** — Swift-native product with deep framework internals (Layout protocol, macros, AttributeGraph adjacency); high-stakes design decisions per wave.
Switch with `/model opus` if current session model differs.

## Rules

0. **Immaculate build (zero-warning policy)** — Swift compiles with `-warnings-as-errors` + complete strict concurrency (PM `stage_build`/`stage_test` and CI both enforce; `SWIFT_STRICT_FLAGS` in the PM and the CI workflow must stay in sync). Python stays ruff-clean, `ruff format --check`-clean, and pyright-clean. Never silence a warning to pass the gate — fix its cause or, for a true false positive, suppress narrowly with a written justification.
1. **Kernel purity** — `VerdictUIKernel` never imports SwiftUI/AppKit/CoreGraphics. The verdict engine must run headless anywhere.
2. **Public API first** — `VerdictUIProbe` uses only supported SwiftUI extension points. Private-API backends (e.g. `_viewDebugData`) live behind an explicit optional adapter target, never in the core path (see `no.md` #001).
3. **Every wave lands with tests alongside** — the product's whole thesis is verification; an untested wave is self-refuting.
4. **Evidence or it didn't happen** — a `Verdict` must cite node IDs and rule names; bare booleans are banned in the public API.
5. **Subagent-driven execution** — every implementer brief carries an explicit `Only modify: <files>. Do not touch any other file.` line, and the implementer checks `git diff --stat HEAD` against that scope before declaring done. Give each implementer its own git worktree; never build or edit in a tree another agent is working in (CIS-C0A083C5 — a shared worktree made a subagent's mutation window look like data loss, and cost an hour of misdiagnosis).
6. **Measure, don't assume** — read exit codes from a redirect (`cmd > /tmp/out 2>&1; echo $?`); a piped `$?` is the reader's status, not the command's. Assert on the runner's summary line and treat a _missing_ summary as failure — `swift test --filter` exits 0 when the filter matches nothing. Every new guard gets a row in `scripts/mutation-check.py`, which must stay N/N with byte-identical restores (PM `stage_mutations`). Never trust a closing report — a subagent's, a past session's, or your own — without re-running the claim. Verify the tree you are about to leave behind, not the one you tested ten minutes ago: after the final commit, `git status` must be clean and the suite must be green. An external write silently reverted two committed mutation node ids here, and the drift left no trace in the log.
7. **Contract changes move together** — any shape change to `Verdict`/`SemanticNode` bumps `SchemaVersion.current`, `contracts/verdict-schema.json`, and the regenerated fixtures in one commit; `contracts/validate-contracts.py` (PM `stage_contracts`) fails the drift.
8. All cross-cutting rules from `~/Projects/shared/rules.md`.
