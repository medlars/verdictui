# Signing and desktop distribution

The source repo is private. The Homebrew CLI ships as a prebuilt universal
binary in the public assets-only repo `medlars/verdictui-releases`, and the
desktop app ships as a separate archive. Both require Developer ID signing and
notarization.

| Item | Value |
| --- | --- |
| Developer team | `P6R899T379` |
| Desktop bundle ID | `com.vohux.verdictui.workbench` |
| CLI signing identifier | `com.vohux.verdictui.cli` |
| Notarization keychain profile | `vohux-notary` |
| Public CLI assets | `medlars/verdictui-releases` |

## Homebrew CLI

`scripts/release.sh <X.Y.Z>` calls `scripts/package-cli-release.sh`, which
builds `verdictui` for arm64 and x86_64 with the checkout and home paths
prefix-mapped out, signs it with hardened runtime and timestamp, and zips
`verdictui-X.Y.Z/{verdictui,LICENSE}`. It then refuses the archive if it embeds
a `/Users/<name>` path or gitleaks flags anything, and requires notarization
status **Accepted**. A bare binary cannot be stapled, so Gatekeeper checks the
ticket online. The release script uploads the zip and its `.sha256`, re-measures
the sha256 from the served asset, and bumps the tap formula through
`scripts/bump-tap-formula.sh`. The assets repo's `asset-audit.yml` re-runs the
checksum, home-path and gitleaks scan on every published release.
`VERDICTUI_SIGN_IDENTITY` and `VERDICTUI_NOTARY_PROFILE` override the defaults.

## Desktop app

`bash scripts/build-workbench.sh release` builds the app, CLI helper and bundled
resources together. Development output is ad-hoc signed. Set
`VERDICTUI_SIGN_IDENTITY` to the installed Developer ID Application identity to
sign a distribution build with hardened runtime and timestamp. The script
verifies the resulting signature and matching helper version.

Create a zip with `bash scripts/package-desktop-zip.sh dist/VerdictUI.app <archive>`,
submit it with `xcrun notarytool submit <archive> --keychain-profile vohux-notary --wait`,
then staple and validate the app. Recreate the zip with the same script after
stapling. Publish only an accepted archive that the script verified and retain its
SHA-256 with the release. Do not archive with plain `ditto -c -k`: it stores
extended attributes as `._*` entries that break the signature when the zip is
extracted with `unzip` (v1.1.3, CIS-353E4881).

The in-process verification path needs no Accessibility or Screen Recording
permission. The live-app adapter measures its OS access; denied access remains
unavailable. Signing does not grant those permissions. The workbench loads only
its bundled file page and refuses remote navigation and bridge messages.
