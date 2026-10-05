# VerdictUI TODO

Completed rows (historical evidence) live in [`docs/archive/todo-completed.md`](docs/archive/todo-completed.md).


- [ ] (2026-09-25) Complete consumer visual acceptance. Four sheet widths are corrected and Calendar uses resolved fixture state. Shared Composing, AI and Templates content isolates initial inputs; original live wrappers remain for production. Calendar horizontal containment and supplied AI renders passed independent review. Toolbar selected-list and Settings chrome pixels remain unverified; original render failures/reference comparisons remain open. This is scoped consumer qualification, not whole-app acceptance.

- [ ] (P1/P2, 2026-09-25) Complete remaining preference isolation and helper-text visual qualification (CIS-83560756/F9D187B9). AI and Composing now have shared explicit-input content; existing legacy snapshot wrappers and other tabs still have live readers. Faint text also exists in references. Do not infer formal accessibility conformance or whole-screen coverage from limited raster review.

- [ ] (2026-09-25) Resolve the currently measured 73 SagaMail render mismatches. Correct full-image comparison changes the preceding 58-case set by +17/-2, without reference or threshold changes. Controlled retained-pixel analysis explains those transitions; missing historical passing images remain unavailable. Underlying rendering drift, installed acceptance and whole-app coverage remain separate open work.

- [ ] (2026-09-25) Qualify native Workbench motion with synchronized macOS/WebKit readings, media-change history, actual animation progress and noninterference observations. Add acceptance-only instrumentation in an exclusive source checkout; keep the signed `1a0d065` candidate and its original reduced-motion receipt unchanged. Any normal-motion claim requires observed native normal mode and advancing process animation; preferences, CSS and media queries must not be overridden to obtain a pass. Instrumentation and native helper witnesses are complete as recorded above. Both actual host modes still report reduced WebKit media against false NSWorkspace readings, with identical running frames; normal native animation remains unavailable.

- [ ] (2026-09-25) Expose in-process scenario act through the installed CLI as required by the common CLI/API/MCP contract. Existing act dispatch exists in MCP/daemon; CLI currently only enumerates actions. Add a thin command using the existing request/response, four typed verbs and three-valued exits, with actual binary positive/refusal controls. Do not duplicate the action engine or change its wire schema. Candidate f98340b4 is integrated as cffa742: 36 strict tests, 38 compiled-consumer controls and all 14 canonical mutations passed; combined fc14552 native and Python suites passed. Installed delivery remains open.
- [ ] (2026-09-25, CIS-8FAD7552) Repair or isolate the intermittent permitted late-browser-exit witness before final qualification. Actual quick PM at clean 2d476ef returned B92.7: one test failed with two missing-browser-exit.json assertions among 1,315 cases/26 skips. The automatic confirmation passed unchanged source; preserve both outcomes. Test-only retained diagnostics passed one targeted run with normal browser and wrapper exits; the original failure remains unexplained. The nine-test predecessor run also passed, using an intrusive signal-logging variant that is excluded from acceptance. A passive bounded exporter now retains sanitized diagnostics in ordinary XCTest output and attempts fixture cleanup even after archival failure. Six helper tests and 17 executed mutation guards pass with exact restores. Integrated clean `85ca7dc` genuine quick PM passed A100 across 24 stages with 1,321 native cases/26 skips and 722 Python passes/1 skip/11 subtest passes in 372.013s; three passive records appeared in ordinary XCTest output, with all observed processes retired. This subsequent qualification admits the diagnostic change, not a causal runtime fix. The original shutdown cause remains open. Preserve existing markers, assertions and 9s/10s/45s budgets; change production only after causal evidence. Separate from fixed file-origin-storage CIS-B1FB43A2. — TRACKED on CIS-8FAD7552 (owner witness-design decision); duplicate CIS-437810F5 closed 2026-10-03.
- [ ] (2026-09-24) Admit current source-bound layout/paint/behavior receipts for SagaMail and continue broader consumer adoption. Its three-state manifest and historical image review do not certify every tab, installed account flows, or the canonical fleet checkout. The latest canonical census still reports 150 entries without admissible visual evidence; this does not mean 150 applications are broken.
## P0 — Blocking
## P1 — High Priority

- [ ] (2026-09-23) Complete remaining Workbench acceptance. Its connected manifests and product-owned runner are delivered; signed candidate `1a0d065` has 138 browser checks, 48 quiet native assertions and nine original image reviews; Apple notarization, staple and extracted Gatekeeper acceptance passed. Bind any final package to its actual source and repeat relevant acceptance after production changes. Installed operation and native normal-motion rendering remain unmeasured. Retain per-attempt invalidation and independent paint review; never substitute demo coverage.

- [ ] (2026-09-23) Owner follow-up: prevent loss of original instruction sources, preserve clause-level completion evidence, and enforce honest adoption/rendering coverage across registered projects through shared existing governance mechanisms.
- [ ] (2026-09-23) Owner follow-up: complete installed PanoMac notification and visual acceptance. Source repair is merged with green CI; signed candidate warm delivery/dedup and cold click/reopen outcomes passed. The quiet installed-app verification remains pending; do not close the combined instruction from candidate evidence.
- [ ] Dedicated verdictui.com registration remains tracked as **CTS-962D387A**. The public documentation now ships on the existing Vohux site, so this is not a release blocker. No purchase was made. NS lookup remains empty; this alone does not prove registration availability. measured: 2026-09-23; falsify: `dig +short NS verdictui.com`.
## P2 — Normal
## Done
> **Note on the auto-generated block below (CTS-37F50C7D).** Regenerating it DISCARDS manual
> annotations, so a row closed with evidence silently reopens and the reason is deleted. Do not
> annotate inside it — the next regeneration destroys the edit. The `render` row is one such case:
> it was closed 2026-08-24 by commit `7050325` (verified on origin/main), covering all three
> branches in `TestCurrentLoad` / `TestContentionEvidenceNamesItsSubject`. That evidence survives in
> `docs/wave-status.md` (short resume page; full diary in
> `docs/archive/wave-status-history.md`), which the generator never rewrites. Treat a `[NONE]` row here as
> *unverified*, not *undone*, until checked against that file.

<!-- testwatch-gaps -->
## TestWatch Gaps (auto-generated — one row per module; a `- [x]` line is preserved verbatim)
- [x] (2026-09-23) TestWatch smoke-mixin NONE classification is stale: composition/reachability in `test_verdictui_pm_composition.py`; defect detection, installed-copy parity and real-product gates in `test_verdictui_pm.py` and `test_product_pm_stages.py`. Included in the 495-test passing PM Python suite. This does not claim exhaustive branch coverage.
- [x] (2026-09-23) TestWatch stages-mixin NONE classification is stale: `TestStageArchitecture.test_ui_import_in_kernel_fails`, `TestStageContracts.test_validator_failure_is_surfaced_not_swallowed`, and `TestStageWrappers.test_stage_demo_fails_on_an_empty_verdict_array` cover concrete failure behavior. Composition is also tested; all ran in the passing PM suite. This does not claim exhaustive branch coverage.
- [ ] (P2) testwatch: add tests for `_apply_inherited_docs`, `_case_names`, `_case_symbols`, `_conformances`, `_documented`, `_enclosing_type`, `_is_public`, `_member_name`, `_member_symbol`, `_report`, `_scan_file`, `_type_symbol` in `scripts/kernel-symbol-audit.py` [NONE] (12 untested)
- [ ] (P2) testwatch: add tests for `main` in `scripts/verdictui-pm.py` [NONE] (1 untested)
<!-- /testwatch-gaps -->
## CEO Audit (2026-08-30)

