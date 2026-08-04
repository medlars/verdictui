# VerdictUI — Wave Status (session continuity SSoT)

> **Purpose**: every new session resumes the build from this file — no re-planning,
> no asking "where were we". Read it at session start; update it before ending any
> session that changed code or completed a task. Keep entries terse and factual.
>
> Task numbers refer to `docs/implementation-plan.md` (the execution SSoT).

## Current position

| Field | Value |
|-------|-------|
| Current wave | **Wave 1 — Kernel: the verdict engine — COMPLETE** (exit gate green, evidence below) |
| Wave task in progress | none — Wave 1 Tasks 1–6 all closed |
| Next action | Start **Wave 2 — the layout probe** (`docs/implementation-plan.md`, `## Wave 2`). The kernel contract is frozen: Wave 2 fills `textMetrics` and `structuralPath` from a real SwiftUI layout pass rather than changing their shape |
| Last session ended | 2026-08-04 10:55 |
| Health at last session end | PM quick Grade A (100.0), all 14 stages PASS, `swift build` clean under `-warnings-as-errors`, 157 Swift tests (155 kernel) + 75 Python tests green, kernel purity intact, 0 open P0/P1 CIS |

## Wave 1 task checklist (from implementation-plan.md)

- [x] Task 1 — Extend `SemanticNode`: Role enum, `attributes`, `isVisible`, `zIndex`, `TextMetrics`, `structuralPath` — commit 9c38d60
- [x] Task 2 — `TreeDiff.swift`: compute TreeDelta (added/removed/moved/changed), id-first matching, property test — commit 0d80c3b
- [x] Task 3 — `RuleEngine.swift`: `LintRule` protocol, `LintContext`, `RuleEngine.run` — commit a7a9e8c
- [x] Task 4 — Six rules under `Rules/`: SiblingOverlap, ZeroSize, Offscreen, Truncation, TapTarget, DuplicateProbeID — commit 5b8df5e
- [x] Task 5 — Verdict schema v1: `SchemaVersion.swift`, `Verdict` envelope, `contracts/verdict-schema.json`; verification half landed as `SchemaVersionTests`/`VerdictEnvelopeTests`/`SchemaCompatibilityTests`, generated `contracts/fixtures/`, and a `validate-contracts.py` that checks schema integrity + version agreement + fixture round-trip — commits 618a0fc, 36e7e42, 5d77474, fc20c20
- [x] Task 6 — `docs/kernel.md`: role vocabulary, rule catalog (a real failure example and suppression path per rule), diff and schema reference — pinned to the source by `KernelDocumentationTests`

### Wave 1 exit gate (all must pass before Wave 2)

- [x] `swift test --filter VerdictUIKernelTests` green; ≥ 30 kernel tests incl. one property-style diff test — **154 kernel tests, 0 failures**; `TreeDiffPropertyTests` mutates random trees and asserts the delta replays exactly
- [x] Every public kernel symbol has a doc comment + at least one test — `python3.14 scripts/kernel-symbol-audit.py` → *"Audited 214 public kernel symbols (12 documented by an inherited protocol requirement) / PASS: every public kernel symbol is documented and mentioned by a kernel test"*
- [x] `contracts/validate-contracts.py` → PASS (schema round-trip) — 4 PASS lines: schema integrity, version agreement on 1.0, and both fixtures round-tripping
- [x] PM `stage_architecture` green (kernel purity intact) — *"VerdictUIKernel platform-pure (no UI imports)"*
- [x] PM quick Grade A; FILE_REGISTRY + CHANGELOG updated — **Grade A (100.0)**, all 14 stages PASS; `docs/FILE_REGISTRY.md` and `CHANGELOG.md` rewritten for the Wave 1 surface

## Completed waves

| Wave | Completed | Evidence |
|------|-----------|----------|
| Wave 0 — Scaffold | 2026-08-04 | Grade A PM, floor 0 gaps, CI green, 6 Swift + 19 Python tests, all scaffold CIS issues closed |
| Wave 1 — Kernel: the verdict engine | 2026-08-04 | Grade A PM (14/14 stages), 157 Swift + 75 Python tests, 214 public kernel symbols with 0 doc/test gaps, contract gate green, kernel platform-pure |

## Known gaps carried into Wave 2

- PM-plumbing test gaps are filed as P2 CIS (`stage_test`, `stage_todo_review`, `stage_codewatch`, `stage_issuewatch`, `stage_capabilitywatch`, `stage_cis_health`, `stage_ai_artifacts`, `stage_last20`, `stage_test_alongside`, `_swift_runner`, `floor-check._check_todo_tracking`). They are thin delegations to shared-libs; deliberately not covered in Wave 1 because the wave's subject is the kernel, and a test that asserts "we call shared-libs" pins an implementation detail rather than a behaviour.
- `docs/runbook.md` start/stop commands wait on the Wave 6 daemon (CIS-BE05E561); the second SLO waits on Wave 8 (CIS-61F66A61); domain registration is an owner action (CIS-B424D1B0).

## Session log (newest first, keep last ~10)

- **2026-08-04 11:35** — **Wave 1 exit gate independently re-verified**, and one hole closed. Re-ran every gate from a `swift package clean` rather than trusting the closing report: zero warnings under `-warnings-as-errors`, 156 Swift tests, 75 Python tests, contract gate green on 4 checks, symbol audit clean on 214 symbols — all matching what was claimed, each with a real exit code rather than a piped one. Then spot-checked the strongest claim, that `docs/kernel.md` "cannot drift into confident inaccuracy", by mutating the tap-target row from `28` to `32`: all nine documentation tests still passed, because the threshold test searched the *whole document* for "28" and the number also appears in the prose and the quoted finding message. So the authoritative table could say anything. Fixed in `273ccd8` (CIS-6C683AA4): thresholds are now read row-scoped through `tableRows`, as the role table already was, and a new test whitelists every backticked `` `N` × `N` pt `` dimension on the page against what `LintContext` actually installs, which closes the prose half that no test covered. Mutation-verified both directions with byte-identical restores. Swift tests 156 → 157. **Lesson worth keeping: a documentation gate that greps the whole file proves the number exists somewhere, not that the sentence claiming it is true.**

- **2026-08-04 10:55** — **Wave 1 closed.** Finished Task 5's verification half and all of Task 6. (a) Built `scripts/kernel-symbol-audit.py` so the "every public symbol documented and tested" gate is mechanical rather than eyeballed; it found real gaps, which were filled — including tightening `SchemaVersion.major(of:)` to reject `"1.2.3"`-shaped strings its own doc comment already promised to reject, and making `Role`/`NodePath` refuse empty values on both encode and decode so the Swift types and `verdict-schema.json` agree in both directions (CIS-16944A45). (b) `validate-contracts.py` went from "the schema parses" to three fail-closed checks: schema integrity, agreement between the schema and `SchemaVersion.current`, and a round-trip of encoder-generated fixtures. `jsonschema` was rejected deliberately — this repo is never pip-installed (ADR 2026-003), so the import would make validation conditional on the host, and a validator that skips its work still prints PASS; instead the implemented draft-2020-12 subset is paired with an unsupported-keyword guard that fails the run if the schema outgrows it. (c) The fixtures are generated by `ContractFixtureTests`, never hand-edited, because a stale fixture validates happily while proving nothing. (d) `docs/kernel.md` is pinned to the code by `KernelDocumentationTests`: every quoted finding message, severity, threshold, and role-table cell is produced by running the real rule. Every guard added this session was mutation-verified — removing it fails a named test, and each source was restored byte-identically. Python tests 19 → 75; Swift 108 → 156. Grade A.
- **2026-08-04 09:15** — Wave 1 Tasks 1–4 committed by the kernel-build agent, which then died on a PING timeout mid-Task 5, leaving uncommitted work and a **red suite**. Two real test defects fixed: (a) `testRunIsDeterministicAcrossRepeatedEvaluations` compared whole `Verdict`s, so Task 5's new measured `timing.evaluateMs` made it fail by construction — it now compares the *decided* part and a new sibling test asserts `evaluateMs` is populated, so normalising it away cannot hide a regression; `timestamp` was excluded too, since whole-second truncation made it flake across a second boundary. (b) `test_validate_contracts_stub_exits_zero` asserted `SKIP`, correct only while no schema existed — it broke the moment Task 5 added the file it was waiting for, and now asserts the real PASS branch. Both fixes mutation-verified (shuffled findings and dropped timing each fail the intended test). Green: 105 Swift + 19 Python, PM Grade A.
- **2026-08-04 03:55** — Founding business/marketing Q&A recorded as `docs/business-decisions.md` (market gap, open-core model, naming/domains, XCUITest/web scope decisions).
- **2026-08-04 03:45** — Immaculate-build bar enforced: strict concurrency in Package.swift, `-warnings-as-errors` in PM + CI (SWIFT_STRICT_FLAGS), `ruff format --check` + pytest + gitleaks secret-scan jobs in CI, shutil.which root-fixes for B607, grype scan clean. Entire CIS detector backlog resolved (fixed or suppressed with rationale) — only todo_md backlog rows remain.
- **2026-08-04 03:10** — Session continuity wiring: this file created; skill resume protocol added. All P0/P1 CIS closed; PM Grade A.
- **2026-08-04 02:00** — Scaffold debt cleared: pyright extraPaths fix, executables chmod'd, CodeWatch baseline seeded, 19-test PM suite added, CI green.
- **2026-08-04 00:30** — Project scaffolded via /project-forge; 10-wave implementation plan written; registrations complete.
