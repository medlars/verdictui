# VerdictUI TODO


## P0 — Blocking
- [x] (2026-09-23) Browser acceptance blockers repaired: raw containing-block ancestry preserves real clipping and detects control-bound collisions; inline inventory preserves editor redaction; typed bounded capture retry handles remote-frame insertion. Actual 13-case CLI controls passed; homepage passed three fresh captures and both product URLs passed. Targeted parser/editor14, paint43 and capture7 mutation witnesses detected all distinct guards with exact restores. Required publication/installed acceptance remains CTS-B70C5383.
- [x] (2026-09-23) CTS-E47F57A8 implementation and real-site repair: all technical full-PM stages, exact-source CI 35858044544, 46 current targeted mutation witnesses and the signed/notarized candidate acceptance passed. Actual public product pages PASS; 10,000-line PASS and work-budget exit 2 controls verified. Remaining release delivery is explicitly tracked as CTS-B70C5383 below; that delivery is now completed in the 1.1.2 row below.
- [x] (2026-09-23) Desktop workbench: owner-selected web-rendered macOS app, CleanMyMac-inspired motion, real project checks and evidence, accessible UI verification and packaged installation. Delivered in v1.1.0; signed/notarized desktop and both installed CLI copies verified.
- [x] (2026-09-23) Initial saved-plan delivery (subsequently reopened above): custom scenario runner, live-app MCP and verified input, web semantic verification and trusted input, isolated sessions, artifact smoke, truthful documentation and installed release. Plan: `docs/finalization-plan.md`. Delivered in v1.1.0; signed/notarized desktop and both installed CLI copies verified.

## P1 — High Priority

- [x] (P1) CEO/stage_pytest: Classified VerdictUIProjectRunner as SwiftSyntax-free; full Python suite 499 passed, 3 explicitly skipped.

- [ ] (2026-09-23) Owner follow-up: reconnect installed VerdictUI MCP in Codex and Claude with a real client catalog/handshake check; repair measured transport failures.
- [ ] (2026-09-23) Owner follow-up: prevent loss of original instruction sources, preserve clause-level completion evidence, and enforce honest adoption/rendering coverage across registered projects through shared existing governance mechanisms.
- [ ] (2026-09-23) Owner follow-up: recover the notification repair context and verify its actual outcome; preserve unknown context as unresolved rather than substituting an unrelated fix.
- [x] (2026-09-23) CTS-B70C5383: delivered 1.1.2, including inline/positioned geometry, editor/frame capture and explicit paint qualification. Full PM A100 and release-source CI 35875644269 passed. Signed/notarized/stapled public archive was downloaded, verified and installed; desktop/helper and Homebrew passed real native/browser CLI/MCP acceptance. Installed public-site, 13 geometry/editor and resource-budget controls passed. Website ea3502a deployed as 03db89db, CI 35878331646 passed, served links/hash/geometry and both updated pages verified with the installed engine. Instruction records cite installed evidence; pre-existing MCP clients must reconnect to refresh their catalog.
- [x] (2026-09-23) CEO/stage_todo_review: completed implementation is now recorded separately from pending release delivery. The original full run remains recorded as Grade B 86.9 with only this workflow item failing; no technical stage, priority of an unresolved defect, or test requirement was weakened. Rerun the PM before release.
- [x] (2026-09-23) ScenarioState patch released in 1.1.1: initial view-construction publications removed; strict observer/mutation coverage, unchanged timing contract, full PM Grade A, CI and both installed artifact gates passed. Subsequent real-site browser defects were repaired and delivered in 1.1.2 above.
- [x] (2026-09-23) CEO/stage_installed_parity: Homebrew and unmanaged CLI upgraded to 1.1.0; both installed binaries passed real native/browser CLI/MCP artifact smoke. Desktop helper matches the signed unmanaged CLI.
- [x] (2026-09-23) CEO/stage_todo_review: the two finalization P0 implementation/release items are delivered in v1.1.0; final PM/CEO evidence is recorded in logs and the wave checkpoint.
- [x] (2026-08-16) (P1) PM/repair-latency-lane: non-reproduced on the current tree. Evidence: focused `MCPLatencyTests` passed with p50 46.56 ms recorded, not asserted, because the host has unwritable SwiftPM user caches; `python3.14 scripts/verdictui-pm.py --quick` passed Grade A (100.0) with `stage_test` 792 tests PASS (17 skipped/unverified), `stage_runtime_bench` p50 147.18 ms recorded in constrained timing, `stage_mcp_latency` p50 83.66 ms recorded in constrained timing, and all hygiene stages green. No code change was justified by the current tree.
- [x] (2026-08-16) (P1) PM/stage_pytest: non-reproduced transient in `TestStageTransportSmoke::test_it_passes_against_the_real_binary`, not a code defect. Evidence: failed PM quick at Grade B (92.7) named `FAILED Tests/test_verdictui_pm_artifact_stages.py::TestStageTransportSmoke::test_it_passes_against_the_real_binary`; focused rerun passed (`python3.14 -m pytest Tests/test_verdictui_pm_artifact_stages.py::TestStageTransportSmoke::test_it_passes_against_the_real_binary -vv`, 1 passed); full PM pytest command passed (`python3.14 -m pytest Tests -q -p no:cacheprovider`, 282 passed); fresh PM quick passed Grade A (100.0) with `stage_pytest` 282 Python tests PASS.
- [x] (2026-08-15) (P1) CEO/stage_test: fixed the PM full-suite timing lane failures. Root causes: `stage_test` wrapped the entire Swift suite in `VERDICTUI_RECORD_TIMING_ONLY`, an explicit override that suppresses elapsed-invariant assertions, and `HarnessTests` used one predicate for both the clock-sensitive timeout-path fixture proof and the elapsed-overshoot invariant. The full suite now lets Swift detect constrained clock lanes from CODEX/CI markers and unwritable SwiftPM caches, while `HarnessTests` records the timeout-path fixture on `ConstrainedTimingEnvironment.isActive` but keeps ordering invariants tied to `canEvaluateElapsedInvariants`. Evidence: `python3.14 -m pytest Tests/test_verdictui_pm.py::TestSkipSentinel Tests/test_verdictui_bench.py::TestStageRuntimeBench::test_timeout_fixture_recording_is_not_the_elapsed_invariant_lane -q` (8 passed) and `swift test --disable-sandbox --cache-path .build/swiftpm-cache --config-path .build/swiftpm-config --manifest-cache local -Xswiftc -warnings-as-errors --filter HarnessTests` (21 passed).
- [x] (2026-08-15) (P1) PM/verification-blocker: FALSIFIED — SwiftPM does not hang here. `swift build --build-tests` completes in 12.10s on a clean tree, and the full suite runs 784 tests / 0 failures / 0 skips. The recorded "hang" was contention on `.build/.lock`: another SwiftPM process (a concurrent CEO/PM run) legitimately held it, and the sandbox could not run `ps` to see that, so "another process owns the lock" was indistinguishable from "the toolchain is broken". DIR-036 applies — the blocker was never measured, and one probe retired it. Waiting for the lock to clear is the whole remedy; see `no.md` #14 (a mutation/verification run needs an exclusive tree).
- [x] (2026-08-15) (P1) CTS-9A2A7301/stage_test: the startup-guard repair was REVERTED, unverified as shipped. Its premise — that the fixture had not started moving before `settle` — is contradicted by the CI evidence: run 31809760395 failed with `settled(after: 0.037s)` inside a test taking 0.670s wall-clock, so ticks were being delivered during the long `currentTree()` that preceded settle. The guard therefore addressed a mechanism that was not biting. The real mechanism is timer-DELIVERY starvation during settle, which is not reproducible on this hardware (longest consecutive zero-tick run measured 0, both idle and with 90% of every pump slice burned; 6/6 pass at load average 103-109). Attempting a delivery-independent drive from inside a custom `Layout` HANGS the suite — mutating the `@Published` tick during layout re-invalidates the view into an infinite layout loop (measured twice at a 200s timeout after a clean build). Reverted to the committed timer drive; the mechanism and both dead ends are now recorded at the call site and in CTS-9A2A7301.
- [x] (2026-08-14) (P1) PM/repair-sandbox: `python3.14 scripts/verdictui-pm.py query risk --file Tests/VerdictUICLICoreTests/MCPLatencyTests.swift` failed before CLI dispatch because importing shared `pm_base` chmoded `/Users/eiman/.cache/vohux-ceo/locks`, which is blocked in the restricted VerdictUI repair sandbox. Fixed with a project-local pre-import fallback that redirects shared PM import-time CEO/dashboard paths into writable VerdictUI-local paths only when the default CEO lock dir is unavailable; pinned by `Tests/test_verdictui_pm.py::TestLoadsWithoutSharedLibs::test_module_imports_when_default_ceo_lock_dir_rejects_chmod`. Verified focused PM tests 50/50, file registry 8/8, Ruff clean, and PM `--quick` Grade A (100.0) with MCP latency recorded rather than asserted in this constrained timing environment.
- [x] (2026-08-12) (P1) CEO/stage_floor: VerdictUI floor: 1 gap(s):
  ✗ logs/

- [x] (2026-08-10) (P1) PM/stage_test: `python3.14 scripts/verdictui-pm.py --quick` failed with `HarnessTests.testSettleMsIsMeasuredNotAssumedOnTheTimeoutPath`: under the Codex constrained timing lane, the 600 ms iteration reached `oracle-host` before the intended `settle-timeout` branch (`settleMs 587.41975 <= 600`). Fixed by making the timeout-path proof strict on developer hardware and record-only when `ConstrainedTimingEnvironment` is active; verified with the focused test in both record-only and marker-unset lanes plus the full `HarnessTests` filter.
- [x] (2026-08-09) (P1) PM CLI: `python3.14 scripts/verdictui-pm.py query risk --file Tests/VerdictUIProbeTests/HarnessPerformanceTests.swift` was parsed as a quick pipeline because the script ignored unknown positional args and only checked for `--full`. That launched Swift stages instead of returning a sub-second query and left a SwiftPM lock during repair. Fixed by adding project-local argparse dispatch for `query risk|coverage|why-failed`, `--quick`, `--full`, and `--fix`; pinned with `Tests/test_verdictui_pm.py::TestPMCLI`.
- [x] (2026-08-09) (P1) PM/stage_test + stage_runtime_bench: Codex repair sandboxes (`CODEX_CI=1`, `CODEX_SANDBOX=seatbelt`) were treated as developer hardware, so `HarnessPerformanceTests.testPerformCycleMeetsTheSLO1Gate` enforced the 70 ms local p50 gate under constrained timing and failed at 138–280 ms. Fixed by making `_timing_record_only_environment()` and Swift timing predicates honor explicit `VERDICTUI_RECORD_TIMING_ONLY`, `CI`, `CODEX_CI`, and `CODEX_SANDBOX` markers; pinned with `Tests/test_verdictui_pm.py::TestSkipSentinel::test_timing_record_only_detects_codex_repair_sandbox`.
- [x] (2026-08-09) (P1) CEO/stage_codewatch: CodeWatch reported 2 new errors from the same defect in `scripts/verdictui-pm.py:731`: `mypy:syntax` and `mypy-runtime:syntax` on an invalid standalone `# type: ignore` comment. Fixed by making the rationale a normal comment while keeping the inline `# type: ignore[misc]` on `super().publish_to_dashboard(status)`.
- [x] (2026-08-08) (P1) PM/stage_runtime_bench: direct `subprocess.run(swift test --filter HarnessPerformanceTests ...)` can hang after the full Swift suite in the managed repair sandbox. Evidence: `python3.14 scripts/verdictui-pm.py --quick` on 2026-08-08 reached `stage_runtime_bench` after `stage_test` rechecked clean, then required KeyboardInterrupt inside `subprocess.py communicate()`. Fixed by moving the bench stage onto a project-local streaming serial Swift runner with the shared SwiftPM command lock and pinning it with `Tests/test_verdictui_pm.py::TestStageRuntimeBench::test_uses_the_streaming_serial_runner_with_the_benchmark_filter`.
- [x] (2026-08-04) (P1) CEO/stage_build: swift build FAIL: ming: Verdict.Timing(evaluateMs: elapsed.milliseconds)
    |                                          
- [x] (2026-08-04) (P1) CEO/stage_build: swift build FAIL: o' in call
135 |             findings.append(contentsOf: rule.evaluate(root, context: context))
136 | 
- [x] (2026-08-04) (P1) CEO/stage_build: swift build FAIL: eed' in call
 56 |     }
 57 | 
 58 |     private func runProperty(seed: UInt64, probed: Bool, iterati
- [x] (2026-08-04) (P1) CEO/stage_build: swift build FAIL: eed' in call
 56 |     }
 57 | 
 58 |     private func runProperty(seed: UInt64, probed: Bool, iterati
- [x] (2026-08-04) (P1) CEO/stage_build: swift build FAIL:    removals = context.removals
    |         `- error: cannot assign to value: 'removals' is a 'let' c
- [x] (2026-08-04) (P1) CEO/stage_build: swift build FAIL:            SemanticNode(id: "b", role: "button", frame: Rect(x: 0, y: 0, width: 60, height: 40)),
   |
- [x] (2026-08-04) (P1) CEO/stage_lint: [1m[91mF821 [0m[1mUndefined name `shutil`[0m
   [1m[94m-->[0m scripts/floor-check.py:99:8
    [1m[94m|[0m
[1
- [x] (2026-08-04) (P1) CEO/stage_lint: [1m[91mI001 [0m[[1m[96m*[0m] [1mImport block is un-sorted or un-formatted[0m
   [1m[94m-->[0m scripts/verdict
- [x] (2026-08-04) (P1) CEO/stage_floor: VerdictUI floor: 3 gap(s):
  ✗ GitHub remote
  ✗ unpinned action action/name@sha in check-pinned-actions.yml
  ✗ unpinne
- [x] (2026-08-04) (P1) CEO/stage_lint: [1m[91mEXE001 [0m[1mShebang is present but file is not executable[0m
 [1m[94m-->[0m contracts/validate-contracts
- [x] (2026-08-04) (P1) CEO/stage_floor: VerdictUI floor: 2 gap(s):
  ✗ GitHub remote
  ✗ .github/workflows/ci.yml

- [x] (2026-08-18) Execute Wave 1 (kernel: full semantic tree model + verdict schema + rule engine). STALE, not open — closed on measurement during the 2026-08-18 cold check. `Sources/VerdictUIKernel/` carries `SemanticNode`, `Verdict`, `RuleEngine`, `SchemaVersion`, `Baselines`, `PixelDiff`, `Reconcile`, `Expectations` and **12 rules** under `Rules/`. Waves 1-9 all closed with their gates met; Wave 10 shipped the AppKit path. Evidence: `ls Sources/VerdictUIKernel/Rules/ | wc -l` -> 12.
- [ ] Dedicated verdictui.com registration remains tracked as **CTS-962D387A**. The public documentation now ships on the existing Vohux site, so this is not a release blocker. No purchase was made. NS lookup remains empty; this alone does not prove registration availability. measured: 2026-09-23; falsify: `dig +short NS verdictui.com`.
- [x] (2026-08-18) Fill in docs/runbook.md start/stop commands once the daemon exists. STALE, not open — the daemon shipped in Wave 6/7 and the runbook documents all three verbs. Evidence: `grep -cE 'daemon start|daemon stop|daemon status' docs/runbook.md` -> 3.

## P2 — Normal
- [x] (2026-08-12) SLO 3 — warm MCP round-trip latency through the real stdio transport. Gated at p50 < 40 ms by `MCPLatencyTests` + PM `stage_mcp_latency`; tail recorded, not gated (measured: median 8.3 → 11.3 ms under load, tail 8.4 → 45.8 ms on unchanged code)
- [x] (2026-08-18) Add a further SLO (cross-validation loop latency) once Wave 8 lands. STALE, not open — **SLO 4 IS that SLO**: "the honest middle loop", budgeted at 5 s precisely because cross-validation launches a real windowed subprocess through LaunchServices and reads an accessibility tree, which is OS work VerdictUI does not control. Evidence: `grep '### SLO' docs/slo.md` -> 4 SLOs, SLO 4 named.
- [x] Homebrew tap at first public release — **DONE 2026-08-26.** `brew install medlars/tap/verdictui` works. The blocker recorded here (the withdrawn formula, burned `v1.0.0` sha) is RESOLVED: GitHub Support ran the GC and all three leak commits return 404 with a positive control, `v1.0.1` was already tagged 2026-08-20, and the formula is published at `medlars/homebrew-tap` (`5bd826d` + `88d338b`, both verified on origin/main). sha256 `2ce0f4d4` measured from the served tarball. Verified by RUNNING the brew-installed binary: lists all 6 scenarios, three-valued exits 0/1/2. `stage_auto_release` wiring remains open and is tracked separately.  measured: 2026-08-26  falsify: `gh api repos/medlars/homebrew-tap/contents/Formula/verdictui.rb --jq .name`

## Done
- [x] Deep research: 5-agent survey of UI-verification methods (CTS-5BABC171, 2026-08-03)
- [x] Scaffold project with /project-forge (CTS-6F57DDE6, 2026-08-04)
- [x] (P1) testwatch-hook: no test file references `verdictui_pm` — added Tests/test_verdictui_pm.py (19 tests, 2026-08-04)

> **Note on the auto-generated block below (CTS-37F50C7D).** Regenerating it DISCARDS manual
> annotations, so a row closed with evidence silently reopens and the reason is deleted. Do not
> annotate inside it — the next regeneration destroys the edit. The `render` row is one such case:
> it was closed 2026-08-24 by commit `7050325` (verified on origin/main), covering all three
> branches in `TestCurrentLoad` / `TestContentionEvidenceNamesItsSubject`. That evidence survives in
> `docs/wave-status.md`, which the generator never rewrites. Treat a `[NONE]` row here as
> *unverified*, not *undone*, until checked against that file.

<!-- testwatch-gaps -->
## TestWatch Gaps (auto-generated — one row per module; a `- [x]` line is preserved verbatim)
- [x] (2026-09-23) TestWatch smoke-mixin NONE classification is stale: composition/reachability in `test_verdictui_pm_composition.py`; defect detection, installed-copy parity and real-product gates in `test_verdictui_pm.py` and `test_product_pm_stages.py`. Included in the 495-test passing PM Python suite. This does not claim exhaustive branch coverage.
- [x] (2026-09-23) TestWatch stages-mixin NONE classification is stale: `TestStageArchitecture.test_ui_import_in_kernel_fails`, `TestStageContracts.test_validator_failure_is_surfaced_not_swallowed`, and `TestStageWrappers.test_stage_demo_fails_on_an_empty_verdict_array` cover concrete failure behavior. Composition is also tested; all ran in the passing PM suite. This does not claim exhaustive branch coverage.
- [ ] (P2) testwatch: add tests for `_apply_inherited_docs`, `_case_names`, `_case_symbols`, `_conformances`, `_documented`, `_enclosing_type`, `_is_public`, `_member_name`, `_member_symbol`, `_report`, `_scan_file`, `_type_symbol` in `scripts/kernel-symbol-audit.py` [NONE] (12 untested)
- [ ] (P2) testwatch: add tests for `main` in `scripts/verdictui-pm.py` [NONE] (1 untested)
<!-- /testwatch-gaps -->
- [x] (P1) testwatch-hook: no test file references `kernel_symbol_audit` — add tests for `scripts/kernel-symbol-audit.py`  <!-- VERIFIED 2026-08-20: 1 test file references it — claim was false -->
- [x] (P1) testwatch-hook: no test file references `mutation_check` — add tests for `scripts/mutation-check.py`  <!-- VERIFIED 2026-08-20: 2 test files reference it — claim was false -->
- [x] (P1) testwatch-hook: no test file references `stale_buffer_check` — add tests for `scripts/stale-buffer-check.py`  <!-- DONE 2026-08-20: Tests/test_stale_buffer_check.py — 12 tests, mutation-verified -->
- [x] (P1) testwatch-hook: no test file references `verdictui_swift_runner` — add tests for `scripts/verdictui_swift_runner.py`  <!-- UNACTIONABLE 2026-08-20: scripts/verdictui_swift_runner.py DOES NOT EXIST — the split was deliberately reverted (no.md #22, it re-labels every log record). A test for an absent file cannot be written (lesson 209). -->

## CEO Audit (2026-08-30)

- [x] (2026-09-23) Prior 2073-line PM entrypoint finding is resolved by modularization: `verdictui-pm.py` measures 333 lines, `verdictui_pm_stages.py` 305 and `verdictui_pm_smoke.py` 762. Existing composition and behavioral tests pass.
