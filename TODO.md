# VerdictUI TODO

## P0 — Blocking
<!-- none -->

## P1 — High Priority
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
- [ ] (P2) testwatch: add test for `check-pinned-actions` in `/Users/eiman/Projects/VerdictUI/.github/workflows/check-pinned-actions.yml` [live]
- [ ] (P2) testwatch: add test for `python-scripts` in `/Users/eiman/Projects/VerdictUI/.github/workflows/ci.yml` [live]
- [ ] (P2) testwatch: add test for `_check_todo_tracking` in `scripts/floor-check.py` [NONE]
- [ ] (P2) testwatch: add test for `_swift_runner` in `scripts/verdictui-pm.py` [NONE]
- [ ] (P2) testwatch: add test for `stage_ai_artifacts` in `scripts/verdictui-pm.py` [NONE]
- [ ] (P2) testwatch: add test for `stage_capabilitywatch` in `scripts/verdictui-pm.py` [NONE]
- [ ] (P2) testwatch: add test for `stage_cis_health` in `scripts/verdictui-pm.py` [NONE]
- [ ] (P2) testwatch: add test for `stage_codewatch` in `scripts/verdictui-pm.py` [NONE]
- [ ] (P2) testwatch: add test for `stage_issuewatch` in `scripts/verdictui-pm.py` [NONE]
- [ ] (P2) testwatch: add test for `stage_last20` in `scripts/verdictui-pm.py` [NONE]
- [ ] (P2) testwatch: add test for `stage_test` in `scripts/verdictui-pm.py` [NONE]
- [ ] (P2) testwatch: add test for `stage_test_alongside` in `scripts/verdictui-pm.py` [NONE]
- [ ] (P2) testwatch: add test for `stage_todo_review` in `scripts/verdictui-pm.py` [NONE]
<!-- /testwatch-gaps -->
