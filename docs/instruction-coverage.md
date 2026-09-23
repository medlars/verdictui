# Original instructions and implementation coverage

Audit date: 2026-09-23. The owner asked for the full saved plan and a review of
Claude conversations across projects. The archive search covered 531 matching
session files and 98 name-matched command-history entries. Human queued messages
were included and duplicate enqueue records removed. Assistant summaries and
tool output were not treated as original owner instructions.

The original August founding transcripts were not recovered in the searched
archives. Their surviving command-history prompts and project decisions are
leads, not equivalent to complete original conversations. A follow-up read of all
198 surviving August 3–4 history prompts across 27 session IDs did not recover
the founding instructions; one ambiguous pasted prompt retained only a content
hash. The detailed private
source ledger stays outside this public repository.

| Owner requirement | Recorded previously? | Finalization work and required evidence |
| --- | --- | --- |
| Check LaunchGate and other real products, not only demonstrations | Yes, but the installed entrypoint still used a fixed demo registry | Public consumer runner, automatic incremental build, external-package CLI/MCP checks with deliberate passing and failing controls |
| Installed tool, on demand and automatically after edits | Registered as INS-63190DA7; the old hook used the inherited working directory and only detected SwiftUI | Explicit project checks and corrected Swift/AppKit/web hook; no demo substitution |
| CLI, API and MCP access to the developer's own Swift/AppKit UI | Yes | Shared engine, custom runner and live native routes; actual subprocess acceptance |
| Notification-system repair combined with the virtual-rendering request | INS-2B146691 was marked implemented using documentation references | Rendering is now verified independently. The separate notification clause has no recovered specific defect or repair evidence; the combined record is corrected to partial rather than assuming it was fixed. |
| Both rendered scenarios and real running applications | Yes, explicitly confirmed in September | Keep both paths and test each independently |
| Invisible real browser login and task execution | Yes; Wave 11 was saved but only lifecycle/transport foundations existed | Trusted input, accessible names, expected outcomes, isolated persistent profiles, no screenshot dependency |
| Concurrent sessions without identity confusion or secret exposure | Yes | Profile ownership, actual multi-client checks, credential resolution and output/argv scans |
| SwiftUI and AppKit click/type/modifiers/drag with observed outcomes | Yes | One native driver, exact-window routing, real hidden fixtures, independent CLI/MCP acceptance |
| Full XCUITest-class reach | Broad request recorded; Wave 11's explicit goals cover input operations | App launch/termination and AX window/menu/dialog targeting use existing public mechanisms. Do not claim universal OS-dialog or cross-app equivalence without scenario evidence |
| Warm consumer rebuild and crash isolation | Implementation plan promised it, but the compiled host lacked a broker | Rebuild/restart disposable consumer process; failed builds cannot certify stale code; same connection must recover |
| Full installed SagaMail settings/account-aware testing and all-product adoption | Recorded in other project conversations; fixtures were not equivalent | Preserve a separate adoption census and consumer acceptance scope. A framework test does not certify every consumer screen or setting |
| Browser-quality feedback without screenshots | Registered as INS-402715D8 | Structured discover/act/observe feedback, multi-frame handling, named controls and outcome findings |
| Better designs and architecture where warranted | Current owner instruction | Reconsider mechanisms against the requirements; keep observed results as the acceptance boundary |
| CleanMyMac-inspired desktop UI with rich process motion, rendered with web technology | Added and explicitly selected in this session; registered as INS-FAE07628 | Bundled macOS workbench, real progress, editable checks and evidence; rendered and native bridge verification |

The principal failure was implementation and closure drift, not a lack of a
written broad vision. Several requirements existed in plans or registrations
while demo success, partial probes, or the presence of a hook stood in for
end-to-end product evidence. Release evidence must distinguish supported
capability, observed scenario coverage, and unavailable measurement.

Release reconciliation: v1.1.1 is published with a notarized desktop archive and
updated Homebrew CLI. Both installed binaries passed the controlled native/browser
CLI/MCP artifact gate. Additional public-site checks then exposed valid Chrome
snapshot cases that the browser parser rejected. The browser instruction
INS-402715D8 remains partial pending installed real-site acceptance.
CTS-E47F57A8 was reopened, then closed with verified implementation and notarized
candidate evidence; required publication and installed upgrades continue as
CTS-B70C5383. The earlier 1.1.2 candidate verified both public product-page URLs with zero
errors and eight warnings and passed 10,000-line/work-budget controls. Further
homepage adjudication exposed false inline-union and SVG reports plus unresolved
presentation-layer paint, so that candidate is superseded. Measured border
fragments and conservative paint classification are being integrated, with an
explicit paint-unverified qualification in CLI, MCP documentation and desktop
results. Final rebuild and installed release gates remain open. INS-FAE07628 cites delivered desktop
evidence; INS-0105EE8B cites the real consumer surfaces. Fleet coverage remains
scoped by [product-adoption.md](product-adoption.md).

The installed background wrapper was also checked, not only the hook script:
17 supported file-extension edit cases reached an actual configured web check;
passing, failing and unavailable controls preserved the CLI result. This proves
dispatch and configured-target execution, not automatic discovery of all Swift
or AppKit views. INS-63190DA7 remains partial for unconfigured product coverage.
