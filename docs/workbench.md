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

Final 1.1.2 acceptance: the publicly downloaded archive matched SHA-256
`d959e4ac3450a500ac81ac47400720a047a30991b6138f30fea7ab8d1062d32c`.
Its installed bundle passed strict signature, notarization-ticket and Gatekeeper
checks. The actual WKWebView window showed **Engine connected 1.1.2**, and saved
state was byte-identical before installation and after launch. Both its bundled
engine and the independently built Homebrew CLI passed the real native/browser
CLI/MCP artifact gate. Installed real-site, positioned-clipping, rich-editor and
resource-budget controls also passed; paint warnings remain explicit.

## Quiet native acceptance

`scripts/workbench-smoke.py` checks layout and event intent using a test bridge.
It does not certify the connected native application. The separate
`scripts/workbench-acceptance.py` launches the real packaged executable with
`--acceptance-config`; ordinary startup never enters this mode. Both paths use
the same host factory, bundled page, nonpersistent WKWebView and native bridge.
Acceptance creates no foreground window and does not activate the application,
use Accessibility, alter system motion preferences or touch normal user state.

Prepare current source-bound app and consumer artifacts explicitly with
`bash scripts/build-workbench-acceptance.sh debug`. Its
`dist/workbench-acceptance-inputs.json` supplies the three paths required below.
Cold preparation has a separate build budget; automatic checks never hide a
build inside their existing runtime deadline.

```sh
python3.14 scripts/workbench-acceptance.py \
  --app /absolute/VerdictUI.app \
  --consumer-runner /absolute/ConsumerScenarios \
  --consumer-build-receipt /absolute/consumer.json \
  --output /absolute/new-private-run-directory
```

The default native process budget is25seconds. Missing prebuilds, source drift,
unavailable rendering or a deadline produce unavailable, never a fallback demo.
The validator requires Pillow12.3.0. A real consumer scenario invokes the bundled
helper; web checks alone cannot prove that helper ran. The known passing/failing
consumer fixtures certify this integration, not any other fleet application's UI.

Required observations include connection, project selection, edited/saved
checks, actual consumer PASS and FAIL, running state, cancellation followed by a
terminal unavailable report, history, host recreation and measured DOM geometry.
Eight actual WKWebView PNGs cover connected, passing, failing, two running states,
history, compact760×600 and final1160×800 layouts. The emitted `final-tree.json`
contains observed DOM IDs, roles, bounds, visibility and text; it is not a
hand-authored success tree. Intrinsic text and comprehensive CSS paint semantics
are not invented where the DOM exporter cannot measure them.

`report.json` binds each artifact hash to `native-report.json`, the app/helper
and consumer build identities, and the complete phase set. The callable
`validate_report(report, run_root)` rechecks retained bytes without launching
the UI. Source admission must also rerun the canonical identity validators.
These are local integrity checks, not authenticated attestation of a reviewer.

DOM programmatic events exercise the real JavaScript/bridge/engine path but do
not establish trusted OS input, native menus/folder pickers, notification
delivery or Accessibility behavior. Motion evidence records both the CSS media
query and native OS preference. With reduced motion enabled, the required
behavior is no running animation; normal-motion progression remains unmeasured
in that run. PNG validity and layout behavior are distinct from independent
visual review, which must be bound to every reviewed image's exact hash.

The full PM workbench stage requires both the existing browser layout smoke
and this connected native workflow. CI retains native artifacts on success or
failure. Candidate results do not automatically certify an installed release.
