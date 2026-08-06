# VerdictUI TODO

## P0 — Blocking
<!-- none -->

## P1 — High Priority
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
- [ ] Add second SLO (cross-validation loop latency) once Wave 8 lands
- [ ] Homebrew tap + stage_auto_release wiring at first public release (registered False in CEO PROPAGATION_PATTERNS until then)

## Done
- [x] Deep research: 5-agent survey of UI-verification methods (CTS-5BABC171, 2026-08-03)
- [x] Scaffold project with /project-forge (CTS-6F57DDE6, 2026-08-04)
- [x] (P1) testwatch-hook: no test file references `verdictui_pm` — added Tests/test_verdictui_pm.py (19 tests, 2026-08-04)

<!-- testwatch-gaps -->
## TestWatch Gaps (auto-generated — do not edit this block)
- [ ] (P1) testwatch: add test for `SchemaError` in `contracts/validate-contracts.py` [NONE]
- [ ] (P1) testwatch: add test for `display` in `scripts/kernel-symbol-audit.py` [NONE]
- [ ] (P1) testwatch: add test for `total_gaps` in `scripts/kernel-symbol-audit.py` [NONE]
- [ ] (P1) testwatch: add test for `Outcome` in `scripts/mutation-check.py` [NONE]
- [ ] (P1) testwatch: add test for `Runner` in `scripts/mutation-check.py` [NONE]
- [ ] (P2) testwatch: add test for `check-pinned-actions` in `/Users/eiman/Projects/VerdictUI/.github/workflows/check-pinned-actions.yml` [live]
- [ ] (P2) testwatch: add test for `python-scripts` in `/Users/eiman/Projects/VerdictUI/.github/workflows/ci.yml` [live]
- [ ] (P2) testwatch: add test for `secret-scan` in `/Users/eiman/Projects/VerdictUI/.github/workflows/ci.yml` [live]
- [ ] (P2) testwatch: add test for `swift` in `/Users/eiman/Projects/VerdictUI/.github/workflows/ci.yml` [live]
- [ ] (P2) testwatch: add test for `_check_array` in `contracts/validate-contracts.py` [NONE]
- [ ] (P2) testwatch: add test for `_check_fixtures` in `contracts/validate-contracts.py` [NONE]
- [ ] (P2) testwatch: add test for `_check_object` in `contracts/validate-contracts.py` [NONE]
- [ ] (P2) testwatch: add test for `_check_scalars` in `contracts/validate-contracts.py` [NONE]
<!-- 28 more gaps — run `testwatch report` to see all -->
<!-- /testwatch-gaps -->
- [ ] (P1) testwatch-hook: no test file references `kernel_symbol_audit` — add tests for `scripts/kernel-symbol-audit.py`
- [ ] (P1) testwatch-hook: no test file references `mutation_check` — add tests for `scripts/mutation-check.py`
