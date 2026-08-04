# VerdictUI — Signing

| Item | Value |
|------|-------|
| Team ID | `P6R899T379` |
| Bundle ID | `com.vohux.verdictui` (CLI/daemon, Wave 6+) |
| Notarization profile | `vohux-notary` (same keychain profile as fleet Swift apps) |

## Notes

- Waves 1–5 ship an SPM library only — no signing needed.
- Wave 6 (CLI + daemon binary) requires Developer ID signing + notarization before Homebrew distribution.
- The daemon needs **no** Accessibility/Screen Recording entitlements for the inner loop (in-process by design). The Wave 8 cross-validation harness is the only component that requests Accessibility permission, and it must degrade gracefully without it.
