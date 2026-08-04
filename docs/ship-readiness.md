# VerdictUI — Ship Readiness

> Seeded at scaffold (2026-08-04). Run `/product-ship prep` to expand into the
> full phased checklist before the first public release (Wave 10).

| Field | Value |
|-------|-------|
| app_type | swift (SPM library → CLI/daemon at Wave 6) |
| bundle_id | com.vohux.verdictui |
| distribution | GitHub (MIT) + Homebrew tap (Wave 10) |
| first_release_gate | Wave 10 exit criteria in docs/implementation-plan.md |

## Pre-ship blockers (tracked ahead of /product-ship prep)

- [ ] Wave 10 dogfood complete on SagaMail + PanoMac
- [ ] SLO 1 (<100 ms inner loop) measured and met
- [ ] LICENSE file (MIT) committed
- [ ] Signing + notarization for CLI/daemon binary (docs/signing.md)
- [ ] verdictui.com registered and docs site live
