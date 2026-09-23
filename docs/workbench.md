# Desktop workbench

VerdictUI.app bundles a local HTML/CSS/JavaScript interface inside AppKit and
WKWebView, together with the matching CLI. It does not start a web server or
load a remote application. The native host owns project selection, execution,
cancellation and saved history.

Choose **Open a project**, then use **Checks** to declare the exact targets.
Save before running. The verification view shows actual per-check progress,
terminal outcomes and cited findings. **History** stores the latest 20 runs and
lets you inspect their results. The current run is serialized; changing projects
or editing configuration is disabled while it runs.

| Check | Required fields | Setup |
| --- | --- | --- |
| SwiftUI scenario | Scenario name | A consumer runner in `.verdictui/config.json`; see integration guide |
| Web page | Page URL | Compatible installed browser; optional expected visible text |
| AppKit subject | Runner executable and subject name | Runner emits a SemanticNode from `render <subject>` |
| Running macOS app | Process ID | Available Accessibility tree; optional surface and expected text |

A result covers these declarations only. Empty, invalid or unreachable checks
produce unavailable coverage. Cancellation waits for owned work to stop and
leaves unfinished checks unverified. No synthetic result is inserted into a
shipping project or its history.

When a browser check has no confirmed layout error but contains a
`web-paint-unverified` finding, the result says **Layout checked · Paint
unverified**, the check badge carries the qualification, and history says
**paint review**. Review the cited nodes before treating the page as visually
verified. A confirmed error still produces **Needs attention**.

The moving verification lens is active only while the engine reports work.
Reduced-motion preferences replace the animation with a static indicator and
text progress. Controls are keyboard accessible; standard macOS editing
shortcuts are supported.

Project declarations live in `<project>/.verdictui/checks.json`. Selected
projects and history live in
`~/Library/Application Support/VerdictUI/workbench/state.json`, with user-only
permissions. WKWebView localStorage is not used. History can contain observed
UI labels and findings; it stays on this machine.

## Install 1.1.2

Download the [signed and notarized Apple Silicon app](https://github.com/medlars/verdictui/releases/download/v1.1.2/VerdictUI-1.1.2-macos-arm64.zip)
from the [release](https://github.com/medlars/verdictui/releases/tag/v1.1.2).
The app targets macOS 13 or later. Its bundled engine needs no separate CLI
installation. Browser checks require Chrome or Chromium.

The independent Homebrew CLI is source-built and requires Xcode 16.0 or later.

## Build and package

```sh
bash scripts/build-workbench.sh debug
bash scripts/build-workbench.sh release
```

Both commands produce `dist/VerdictUI.app` with a matching CLI and bundled
resources, and verify its code signature. Development signing is ad hoc;
release signing and notarization are described in [signing.md](signing.md).
The CLI remains independently installable through Homebrew.

## Measured acceptance, 2026-09-23

The actual packaged WKWebView app opened a local project and ran a real Chrome
check against an independently served page. Its observed states were PASS,
FAIL after saving a deliberately absent expected text (finding
`web-expectation`, node `web/root`), then unavailable after cancellation.
All three appeared in host-persisted history. Browser-engine rendering tests
cover animation, reduced motion, keyboard input, bridge actions, evidence
rendering, sibling geometry and narrow layouts. Synthetic bridge fixtures in
those tests are test apparatus, not installed product coverage.


Native packaging acceptance (2026-09-23): the signed 1.1.0 workbench opened its
bundled page, restored saved project/check/history state after relaunch, replaced
field content with Command-A, saved through the host, and produced a real web
PASS. Cancelling an observed active run produced unavailable with “Cancelled
before verification completed”; history retained PASS, FAIL and unavailable
entries. Browser geometry/motion checks are separately recorded by the rendered
smoke gate. These observations do not substitute for final installed-artifact
hash and signature verification.
