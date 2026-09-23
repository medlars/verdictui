# VerdictUI notarization

The desktop app and its bundled CLI helper are distributed as a signed,
notarized archive. Homebrew continues to compile the CLI from source; the Swift
package remains source code. Desktop signing does not grant Accessibility or
Screen Recording permission to the live-app adapter.

Use the Developer ID identity and `vohux-notary` keychain profile recorded in
[signing.md](signing.md). The desktop bundle ID is
`com.vohux.verdictui.workbench`, team `P6R899T379`.

1. Build with `VERDICTUI_SIGN_IDENTITY` set and
   `bash scripts/build-workbench.sh release`.
2. Archive the app with `ditto -c -k --keepParent dist/VerdictUI.app <archive>`.
3. Submit using `xcrun notarytool submit <archive> --keychain-profile vohux-notary --wait`.
   Require **Accepted**, and retain the submission ID and log.
4. Run `xcrun stapler staple dist/VerdictUI.app`, then
   `xcrun stapler validate dist/VerdictUI.app`,
   `codesign --verify --deep --strict dist/VerdictUI.app`, and
   `spctl --assess --type execute -vv dist/VerdictUI.app`.
5. Recreate the archive after stapling, record its SHA-256, and attach that archive
   to the matching GitHub release. Compare installed app/helper bytes with the
   verified artifact and run installed acceptance before declaring completion.

The procedure alone is not release evidence. Each release records the actual
notarization result, artifact hash and installed checks in its release evidence.
