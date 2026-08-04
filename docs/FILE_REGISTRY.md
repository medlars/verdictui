# File Registry — VerdictUI

> Single source of truth for all source files. Update when adding, moving, or archiving files.
> Last updated: 2026-08-04

## Source Files

| File | Purpose | Status | Added |
|------|---------|--------|-------|
| `Package.swift` | SPM manifest — kernel + probe targets | Active | 2026-08-04 |
| `Sources/VerdictUIKernel/SemanticNode.swift` | Platform-pure semantic tree + Rect geometry | Active | 2026-08-04 |
| `Sources/VerdictUIKernel/Verdict.swift` | Verdict/Finding schema + seed lint rule (sibling-overlap) | Active | 2026-08-04 |
| `Sources/VerdictUIProbe/VerdictProbe.swift` | `.verdictProbe(id:)` modifier + VerdictFramesKey preference | Active | 2026-08-04 |
| `Tests/VerdictUIKernelTests/VerdictUIKernelTests.swift` | Kernel: lint + verdict + JSON round-trip tests | Active | 2026-08-04 |
| `Tests/VerdictUIProbeTests/VerdictUIProbeTests.swift` | Probe: preference-key merge + modifier smoke tests | Active | 2026-08-04 |
| `Tests/test_verdictui_pm.py` | Python tests for PM stages, floor-check, contracts stub | Active | 2026-08-04 |
| `Tests/__init__.py` | Python package marker for pytest collection | Active | 2026-08-04 |
| `pyproject.toml` | Fleet tooling config (ruff/mypy/pyright/pytest) — no [project] section | Active | 2026-08-04 |
| `docs/wave-status.md` | Session-continuity SSoT — resume point, wave checklist, session log | Active | 2026-08-04 |
| `docs/business-decisions.md` | Business/marketing decision history — founding Q&A, open-core model, naming | Active | 2026-08-04 |
| `scripts/verdictui-pm.py` | Project Manager (build/test/floor/governance stages) | Active | 2026-08-04 |
| `scripts/floor-check.py` | Floor compliance audit | Active | 2026-08-04 |
| `scripts/dev.sh` | One-command setup + build + test | Active | 2026-08-04 |
| `contracts/validate-contracts.py` | Contract validation stub (verdict JSON schema pinned Wave 1) | Active | 2026-08-04 |

## Archived / Removed

| File | Reason | Removed |
|------|--------|---------|
| *(none)* | | |
