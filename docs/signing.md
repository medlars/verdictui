# Signing and desktop distribution

The source-built Homebrew CLI is compiled on the user's machine. Published
prebuilt desktop downloads require Developer ID signing and notarization.

| Item | Value |
| --- | --- |
| Developer team | `P6R899T379` |
| Desktop bundle ID | `com.vohux.verdictui.workbench` |
| Notarization keychain profile | `vohux-notary` |

`bash scripts/build-workbench.sh release` builds the app, CLI helper and bundled
resources together. Development output is ad-hoc signed. Set
`VERDICTUI_SIGN_IDENTITY` to the installed Developer ID Application identity to
sign a distribution build with hardened runtime and timestamp. The script
verifies the resulting signature and matching helper version.

Create a zip with `ditto -c -k --keepParent dist/VerdictUI.app <archive>`, submit
it with `xcrun notarytool submit <archive> --keychain-profile vohux-notary --wait`,
then staple and validate the app. Recreate the zip after stapling. Publish only
an accepted, signature-verified archive and retain its SHA-256 with the release.

The in-process verification path needs no Accessibility or Screen Recording
permission. The live-app adapter measures its OS access; denied access remains
unavailable. Signing does not grant those permissions. The workbench loads only
its bundled file page and refuses remote navigation and bridge messages.
