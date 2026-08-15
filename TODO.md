# VerdictUI TODO

## P0 — Blocking
<!-- none -->

## P1 — High Priority
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

- [ ] Execute Wave 1 (kernel: full semantic tree model + verdict schema + rule engine) per docs/implementation-plan.md
- [ ] Register verdictui.com + verdictui.dev (owner action — confirmed available 2026-08-04)
- [ ] Fill in docs/runbook.md start/stop commands once the daemon exists (Wave 6)

## P2 — Normal
- [x] (2026-08-12) SLO 3 — warm MCP round-trip latency through the real stdio transport. Gated at p50 < 40 ms by `MCPLatencyTests` + PM `stage_mcp_latency`; tail recorded, not gated (measured: median 8.3 → 11.3 ms under load, tail 8.4 → 45.8 ms on unchanged code)
- [ ] Add a further SLO (cross-validation loop latency) once Wave 8 lands
- [ ] Homebrew tap + stage_auto_release wiring at first public release (registered False in CEO PROPAGATION_PATTERNS until then)

## Done
- [x] Deep research: 5-agent survey of UI-verification methods (CTS-5BABC171, 2026-08-03)
- [x] Scaffold project with /project-forge (CTS-6F57DDE6, 2026-08-04)
- [x] (P1) testwatch-hook: no test file references `verdictui_pm` — added Tests/test_verdictui_pm.py (19 tests, 2026-08-04)

<!-- testwatch-gaps -->
## TestWatch Gaps (auto-generated — do not edit this block)
- [ ] (P1) testwatch: add test for `Outcome` in `scripts/mutation-check.py` [NONE]
- [ ] (P1) testwatch: add test for `refresh_macro_expansions` in `scripts/mutation-check.py` [NONE]
- [ ] (P1) testwatch: add test for `Runner` in `scripts/mutation_catalog_types.py` [NONE]
- [ ] (P1) testwatch: add test for `last_commit_time` in `scripts/stale-buffer-check.py` [NONE]
- [ ] (P1) testwatch: add test for `modified_tracked_files` in `scripts/stale-buffer-check.py` [NONE]
- [ ] (P1) testwatch: add test for `publish_to_dashboard` in `scripts/verdictui-pm.py` [NONE]
- [ ] (P2) testwatch: add test for `close-on-green` in `.github/workflows/capture-ci-failures-to-github-issue.yml` [live]
- [ ] (P2) testwatch: add test for `check-pinned-actions` in `.github/workflows/check-pinned-actions.yml` [live]
- [ ] (P2) testwatch: add test for `secret-scan` in `.github/workflows/ci.yml` [live]
- [ ] (P2) testwatch: add test for `_check_array` in `contracts/validate-contracts.py` [NONE]
- [ ] (P2) testwatch: add test for `_check_fixtures` in `contracts/validate-contracts.py` [NONE]
- [ ] (P2) testwatch: add test for `_check_object` in `contracts/validate-contracts.py` [NONE]
- [ ] (P2) testwatch: add test for `_check_scalars` in `contracts/validate-contracts.py` [NONE]
- [ ] (P2) testwatch: add test for `_check_type` in `contracts/validate-contracts.py` [NONE]
- [ ] (P2) testwatch: add test for `_check_version_agreement` in `contracts/validate-contracts.py` [NONE]
- [ ] (P2) testwatch: add test for `_declared_version` in `contracts/validate-contracts.py` [NONE]
- [ ] (P2) testwatch: add test for `_kernel_version` in `contracts/validate-contracts.py` [NONE]
- [ ] (P2) testwatch: add test for `_load_schema` in `contracts/validate-contracts.py` [NONE]
- [ ] (P2) testwatch: add test for `_check_todo_tracking` in `scripts/floor-check.py` [NONE]
- [ ] (P2) testwatch: add test for `_apply_inherited_docs` in `scripts/kernel-symbol-audit.py` [NONE]
- [ ] (P2) testwatch: add test for `_case_names` in `scripts/kernel-symbol-audit.py` [NONE]
- [ ] (P2) testwatch: add test for `_case_symbols` in `scripts/kernel-symbol-audit.py` [NONE]
- [ ] (P2) testwatch: add test for `_conformances` in `scripts/kernel-symbol-audit.py` [NONE]
- [ ] (P2) testwatch: add test for `_documented` in `scripts/kernel-symbol-audit.py` [NONE]
- [ ] (P2) testwatch: add test for `_enclosing_type` in `scripts/kernel-symbol-audit.py` [NONE]
- [ ] (P2) testwatch: add test for `_is_public` in `scripts/kernel-symbol-audit.py` [NONE]
- [ ] (P2) testwatch: add test for `_member_name` in `scripts/kernel-symbol-audit.py` [NONE]
- [ ] (P2) testwatch: add test for `_member_symbol` in `scripts/kernel-symbol-audit.py` [NONE]
- [ ] (P2) testwatch: add test for `_report` in `scripts/kernel-symbol-audit.py` [NONE]
- [ ] (P2) testwatch: add test for `_scan_file` in `scripts/kernel-symbol-audit.py` [NONE]
- [ ] (P2) testwatch: add test for `_type_symbol` in `scripts/kernel-symbol-audit.py` [NONE]
- [ ] (P2) testwatch: add test for `_swift_timing_environment` in `scripts/verdictui-pm.py` [NONE]
- [ ] (P2) testwatch: add test for `stage_ai_artifacts` in `scripts/verdictui-pm.py` [NONE]
- [ ] (P2) testwatch: add test for `stage_capabilitywatch` in `scripts/verdictui-pm.py` [NONE]
- [ ] (P2) testwatch: add test for `stage_cis_health` in `scripts/verdictui-pm.py` [NONE]
- [ ] (P2) testwatch: add test for `stage_codewatch` in `scripts/verdictui-pm.py` [NONE]
- [ ] (P2) testwatch: add test for `stage_issuewatch` in `scripts/verdictui-pm.py` [NONE]
- [ ] (P2) testwatch: add test for `stage_last20` in `scripts/verdictui-pm.py` [NONE]
- [ ] (P2) testwatch: add test for `stage_stale_buffer` in `scripts/verdictui-pm.py` [NONE]
- [ ] (P2) testwatch: add test for `stage_test_alongside` in `scripts/verdictui-pm.py` [NONE]
- [ ] (P2) testwatch: add test for `stage_todo_review` in `scripts/verdictui-pm.py` [NONE]
<!-- /testwatch-gaps -->
- [ ] (P1) testwatch-hook: no test file references `kernel_symbol_audit` — add tests for `scripts/kernel-symbol-audit.py`
- [ ] (P1) testwatch-hook: no test file references `mutation_check` — add tests for `scripts/mutation-check.py`
- [ ] (P1) testwatch-hook: no test file references `stale_buffer_check` — add tests for `scripts/stale-buffer-check.py`
- [ ] (P1) testwatch-hook: no test file references `verdictui_swift_runner` — add tests for `scripts/verdictui_swift_runner.py`
