# VerdictUI — Ship Readiness

> Project-floor pointer (updated 2026-09-29). **Release 1.1.0** is published and
> installed; use the links below for current scope—not the pre-1.0 scaffold list.

| Field | Value |
|-------|-------|
| app_type | Swift SPM (library, CLI/daemon/MCP, desktop workbench) |
| bundle_id | com.vohux.verdictui |
| distribution | GitHub ([MIT](../LICENSE)) + Homebrew tap + notarized desktop archive |
| release_checkpoint | [wave-status.md](wave-status.md) |

## Where release truth lives

- [goals.md](goals.md) — current milestone and 1.1 acceptance checks
- [roadmap.md](roadmap.md) — phase state (Wave 10 / 11 / workbench shipped in 1.1.0)
- [instruction-coverage.md](instruction-coverage.md) — owner scope and remaining product work
- [product-adoption.md](product-adoption.md) — per-consumer screen/account coverage

## Shipped in 1.1.0 (not open blockers)

- MIT license committed at repo root
- Signed and notarized CLI/daemon and desktop workbench ([signing.md](signing.md))
- Public documentation on the existing Vohux site (dedicated `verdictui.com` is optional; see [business-decisions.md](business-decisions.md))

## Continuing work (adoption and supervision, not “pre-ship”)

Consumer dogfood, fleet census gaps, and PM/CI gates are tracked in
[wave-status.md](wave-status.md) and [TODO.md](../TODO.md). Run
`python3.14 scripts/verdictui-pm.py` for the supervision gate.
