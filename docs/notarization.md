# VerdictUI — Notarization

## Status

Nothing is notarized today, and nothing needs to be. VerdictUI ships as a
**source-built Homebrew formula** (the tap runs `swift build`) plus an SPM library,
so there is no signed binary bundle to submit. `scripts/release.sh` states the same
premise in its header, and it is the whole release procedure.

## When this becomes required

Wave 6 (CLI + daemon binary) is the point where a prebuilt binary could be
distributed. That binary must be signed with the Developer ID Application identity
and notarized before it is offered through Homebrew or any download. The identifiers
are recorded in `docs/signing.md`:

| Item | Value |
|------|-------|
| Team ID | `P6R899T379` |
| Bundle ID | `com.vohux.verdictui` (CLI/daemon, Wave 6+) |
| Notarization keychain profile | `vohux-notary` |

## Procedure to follow at that point

1. Build the release binary and sign it with `codesign --options runtime --timestamp`.
2. Submit the archive with `xcrun notarytool submit <archive> --keychain-profile vohux-notary --wait`.
3. Staple the ticket where the format allows it (`xcrun stapler staple`), then verify
   with `spctl --assess --type execute -vv` and `codesign -dvvv`.
4. Compare the notarized binary's SHA-256 with the one installed on the owner's
   machine before calling the release done (fleet DIR-042).

Until a binary is distributed, this document records the requirement rather than
evidence of a completed notarization.
