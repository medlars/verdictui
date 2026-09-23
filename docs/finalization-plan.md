# VerdictUI finalization — 2026-09-23

Owner request: audit the implementation against the instructions and complete the
full saved plan, including real app verification and web/native acting.

## Measured starting point

Baseline: origin/main `5b443ee`. The canonical checkout has unrelated TODO edits
and remains untouched. Initial PM passed all implementation stages but failed
`stage_todo_review` because CTS-E47F57A8 (this unfinished Wave 11) is P0.
Installed parity was explicitly unmeasured: there was no release binary.

| Promise | Implementation before this task | Completion evidence required |
|---|---|---|
| Consumer SwiftUI scenarios through CLI/MCP | Manifest reader exists; default engine always uses demo registry; no CLICore product | Separate package's custom scenarios work through installed CLI and MCP; defect fails; malformed runner is exit 2 |
| Existing live macOS observation | inspect/judge/capture/sweep CLI exists; MCP absent | Same handler accessible through CLI, daemon and MCP |
| Native click/type/modifiers/drag | Partial AX actions and unchecked keystroke acknowledgement | Hidden fixture state changes; act returns observed delta/verdict; denied input is unavailable |
| Web verification and acting | Profile/browser lifecycle and CDP transport only | DOM snapshot assembly; trusted input; local login/task; 0/1/2 exits |
| Session isolation and secret hygiene | Profile lock groundwork | Two sessions cannot cross-attach; credentials absent from output/argv |
| Documentation and installed release | Stale README/status; old installed binaries | Accurate integration guide/contracts, complete PM, release identity and installed smoke |

Searches used registry/runner/delegation, CDP/DOMSnapshot/web, and
inspect/judge/AX/act spellings. Existing clean web and AppKit worktrees contain
already merged foundations. Reuse those foundations; no replacement driver.
Real consumers already use the library (LaunchGate, KastDrive, SagaMail) and
AppKit runner (PanoMac). No consumer checkout is modified by this task.

## Options and decision

| Option | Dependencies and blast radius | Reversibility | Cost |
|---|---|---|---|
| Runtime dynamic Swift plugin loading | CLI loads arbitrary consumer ABI; compiler version coupling | Hard: new plugin ABI | High ongoing compatibility cost |
| Consumer compiled runner, existing engine and transports | Export CLICore; registry injection and executable delegation; existing consumers opt in | Additive; remove config to roll back | Low; selected for scenario integration |
| External AX/CDP only | No consumer compilation; loses in-process layout evidence | Additive adapter targets | Necessary for live apps, insufficient for scenarios |

Decision: combine the second option for the fast inner loop and the existing
AX/CDP adapters for live products. Keep one daemon dispatch path for new live/web
verbs and retain the Verdict/SemanticNode schema. No invented equivalence between
an input being posted and the requested state having been observed.

## Execution and obligations

1. Isolated custom-runner lane: registry injection, fail-closed forwarding,
   separate-package example, subprocess regression tests.
2. Isolated web lane: browser session lifecycle, DOM assembly, trusted actions,
   bounded settling, credential references/redaction, local login and isolation.
3. Isolated native lane: shared PID-targeted input driver, AX paths, hidden
   fixture, observed changes and denied-input tests.
4. Integration lane: CLI/daemon/MCP contracts, act-observe reports, per-project
   daemon sockets, truthful docs, PM artifact gates and versioned release.
5. Focused tests per lane, merged full suite, mutation guard verification,
   external consumer and built-binary smoke, PM full and CEO aftermath.

Every new boundary validates inputs, bounds waits, preserves 0/1/2 semantics,
and excludes credentials from diagnostics. Existing user browser profiles and
running applications are never used as test fixtures. A missing measurement is
reported as unavailable, never as a passing observation.

## Desktop workbench — owner addition, 2026-09-23

The owner requested CleanMyMac-inspired visual polish and process animations,
and selected a desktop app with a web-rendered interface. This extends the
finalization scope; the CLI/API/MCP remain the verification engine.

Compared options: a browser dashboard needs a local HTTP service and browser
lifecycle; a native SwiftUI UI restricts the requested web styling; a small
AppKit/WKWebView shell bundles HTML/CSS/JavaScript without a new runtime or
network service. Select the shell. Use public WebKit APIs and existing Swift
products. Do not claim knowledge of CleanMyMac's implementation technology.

The workbench chooses local projects, edits explicit coverage declarations,
runs real checks, shows per-target progress and opens cited findings. A
verification lens is the visual signature: dimensional concentric glass rings
move only during an active run, then resolve to its measured outcome. The
surrounding sidebar and evidence list remain quiet and readable. Keyboard
navigation and reduced motion are first-class. No placeholder results or
manufactured progress percentages appear as real measurements.

Persist project selection/history in Application Support through the host;
never depend on WKWebView localStorage. Bundle assets locally. Deny external
page navigation and untrusted script messages. Serialize bridge data safely.
Cancellation must stop owned work and never convert an unfinished check to
PASS. Package the app alongside the installed CLI and verify the rendered UI
with measured element rectangles, keyboard flows and actual engine evidence.

## Release rollback

If artifact smoke regresses, retain the previous released binary and revert the
new version/formula. Adapter and runner support are additive; existing scenario
and AppKit products remain compatible. Profiles retain browser state and are not
deleted during rollback. Verify the previous release's CLI and MCP smoke before
replacing the new installation. Owner: current implementing session.

## Actual-site browser acceptance — release 1.1.2

Public Vohux pages exposed valid CDP cases absent from the original fixtures:
repeated pseudo-element layout rows and iframe owners with no layout boxes.
Both parser repairs now have genuine Chrome and mutation evidence. The restored
verdicts also exposed ordinary scroll content being compared with the wrong
viewport. The browser adapter must supply per-document scroll bounds and retain
CSS visibility for below-fold controls before the shared rules can be useful.

Use a web-only lint projection while preserving the complete actionable tree as
evidence. Separate parent and embedded document layout, retain owner boxes,
validate all measured extents and transformed coordinates, and keep actual input
coordinates tied to the real viewport. Test ordinary document and panel scrolling,
same/cross-origin frames, fixed controls and transformed containing blocks,
accessibility skip-link clipping/reveal, and genuinely displaced or clipped
negative controls. No global rule disable or fixture-only bypass is acceptable.
The permanent installed-artifact fixture now includes a pseudo overlay, hidden
frame and below-fold content and reproduces the missing semantics before repair.

The first real scrolling control also found mismatched CDP hit-test coordinates:
`getContentQuads` returns viewport coordinates, but `getNodeForLocation` requires
document coordinates. Add renderer scroll offsets only to the hit test; keep
actual mouse input and viewport bounds in viewport coordinates. Independent
review additionally confirmed three geometry false positives on the published
product page: BR line breaks, multiline text union boxes, and font ink extending
slightly beyond overflow-visible line boxes. Correct these from measured CSS and
text fragments, with actual overlap/clipping negative controls and original-node
citations. Preserve the vacuity guard across visible/hidden iframe-only pages.

Pre-push review identified quadratic pair growth when one long text node was
expanded into thousands of sibling fragments. Retain original node subjects,
refine candidate intersections with measured fragment sweeps, and enforce an
explicit work budget. Exhaustion must return unavailable, never a truncated
passing result. Deterministic operation counts and same-original fragment
controls cover both runtime bounds and the self-overlap false positive observed
on the actual product page.
