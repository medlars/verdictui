# File Registry — VerdictUI

> Single source of truth for all source files. Update when adding, moving, or archiving files.
> Last updated: 2026-08-04

## Source Files

| File | Purpose | Status | Added |
|------|---------|--------|-------|
| `Package.swift` | SPM manifest — kernel + probe targets, strict concurrency | Active | 2026-08-04 |
| `Sources/VerdictUIKernel/SemanticNode.swift` | Semantic tree: `Role`, `AttributeValue`, `TextMetrics`, `SemanticNode`, `Rect`/`Size` geometry | Active | 2026-08-04 |
| `Sources/VerdictUIKernel/TreeDiff.swift` | `NodePath`, `TreeDelta` and its four categories, `TreeDiff.compute`/`apply` | Active | 2026-08-04 |
| `Sources/VerdictUIKernel/RuleEngine.swift` | `LintRule` protocol, `LintContext` (viewport, minimums, suppression), `RuleEngine.run` | Active | 2026-08-04 |
| `Sources/VerdictUIKernel/Rules/DuplicateProbeIDRule.swift` | Rule `duplicate-probe-id` — a probe id used twice breaks diffing and act-targeting | Active | 2026-08-04 |
| `Sources/VerdictUIKernel/Rules/ZeroSizeRule.swift` | Rule `zero-size` — visible node with an empty frame | Active | 2026-08-04 |
| `Sources/VerdictUIKernel/Rules/SiblingOverlapRule.swift` | Rule `sibling-overlap` — intersecting siblings without declared layering | Active | 2026-08-04 |
| `Sources/VerdictUIKernel/Rules/OffscreenRule.swift` | Rule `offscreen` — visible node entirely outside the viewport | Active | 2026-08-04 |
| `Sources/VerdictUIKernel/Rules/TruncationRule.swift` | Rule `truncation` — clipped lines or a one-line text denied its intrinsic width | Active | 2026-08-04 |
| `Sources/VerdictUIKernel/Rules/TapTargetRule.swift` | Rule `tap-target` — interactive node below the platform hit minimum | Active | 2026-08-04 |
| `Sources/VerdictUIKernel/Verdict.swift` | `Verdict` envelope (status/findings/tree/delta/timing) + `Finding`, custom `Codable` | Active | 2026-08-04 |
| `Sources/VerdictUIKernel/SchemaVersion.swift` | Wire-format version and the major/minor compatibility contract | Active | 2026-08-04 |
| `Sources/VerdictUIProbe/VerdictProbe.swift` | `.verdictProbe(id:)` modifier + VerdictFramesKey preference | Active | 2026-08-04 |
| `Tests/VerdictUIKernelTests/SemanticNodeTests.swift` | Roles, attributes, structural paths, node Codable | Active | 2026-08-04 |
| `Tests/VerdictUIKernelTests/TreeDiffTests.swift` | Diff categories, path encoding, apply/replay | Active | 2026-08-04 |
| `Tests/VerdictUIKernelTests/TreeDiffPropertyTests.swift` | Property test: random mutations must replay exactly | Active | 2026-08-04 |
| `Tests/VerdictUIKernelTests/RuleEngineTests.swift` | Engine determinism, suppression, severity overrides, timing | Active | 2026-08-04 |
| `Tests/VerdictUIKernelTests/RulesTests.swift` | Per-rule edge cases for all six rules | Active | 2026-08-04 |
| `Tests/VerdictUIKernelTests/VerdictTests.swift` | Verdict status derivation and JSON round-trip | Active | 2026-08-04 |
| `Tests/VerdictUIKernelTests/VerdictEnvelopeTests.swift` | Envelope encoding: timestamp form, `tree`/`delta`/`timing` presence and omission | Active | 2026-08-04 |
| `Tests/VerdictUIKernelTests/SchemaVersionTests.swift` | `SchemaVersion` parsing and compatibility rules | Active | 2026-08-04 |
| `Tests/VerdictUIKernelTests/SchemaCompatibilityTests.swift` | Decoder refuses a foreign schema major, accepts a newer minor | Active | 2026-08-04 |
| `Tests/VerdictUIKernelTests/ContractFixtureTests.swift` | Generates and pins `contracts/fixtures/` to the real encoder output | Active | 2026-08-04 |
| `Tests/VerdictUIKernelTests/KernelDocumentationTests.swift` | Pins `docs/kernel.md` to the code: messages, severities, thresholds, role table | Active | 2026-08-04 |
| `Tests/VerdictUIProbeTests/VerdictUIProbeTests.swift` | Probe: preference-key merge + modifier smoke tests | Active | 2026-08-04 |
| `Tests/test_verdictui_pm.py` | Python tests for PM stages, floor-check, and the contract validator | Active | 2026-08-04 |
| `Tests/test_kernel_symbol_audit.py` | Python tests for the kernel public-surface audit | Active | 2026-08-04 |
| `Tests/__init__.py` | Python package marker for pytest collection | Active | 2026-08-04 |
| `pyproject.toml` | Fleet tooling config (ruff/mypy/pyright/pytest) — no [project] section | Active | 2026-08-04 |
| `docs/kernel.md` | Kernel reference: role vocabulary, rule catalog, diff and schema reference | Active | 2026-08-04 |
| `docs/wave-status.md` | Session-continuity SSoT — resume point, wave checklist, session log | Active | 2026-08-04 |
| `docs/business-decisions.md` | Business/marketing decision history — founding Q&A, open-core model, naming | Active | 2026-08-04 |
| `scripts/verdictui-pm.py` | Project Manager (build/test/floor/contracts/architecture/governance stages) | Active | 2026-08-04 |
| `scripts/floor-check.py` | Floor compliance audit | Active | 2026-08-04 |
| `scripts/kernel-symbol-audit.py` | Exit-gate checker: every public kernel symbol documented and mentioned by a test | Active | 2026-08-04 |
| `scripts/dev.sh` | One-command setup + build + test | Active | 2026-08-04 |
| `contracts/verdict-schema.json` | Pinned verdict wire format (v1.0) | Active | 2026-08-04 |
| `contracts/validate-contracts.py` | Contract gate: schema integrity, version agreement, fixture round-trip | Active | 2026-08-04 |
| `contracts/fixtures/verdict-pass.json` | Generated fixture — clean verdict, pins the field-omission contract | Active | 2026-08-04 |
| `contracts/fixtures/verdict-fail.json` | Generated fixture — every optional field populated at once | Active | 2026-08-04 |

## Archived / Removed

| File | Reason | Removed |
|------|--------|---------|
| `Tests/VerdictUIKernelTests/VerdictUIKernelTests.swift` | Split into per-area suites (SemanticNode/TreeDiff/RuleEngine/Rules/Verdict) during Wave 1 | 2026-08-04 |
