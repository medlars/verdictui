# Original instructions and implementation coverage

Audit date: 2026-09-23. The owner asked for the full saved plan and a review of
Claude conversations across projects. The archive search covered 531 matching
session files and 98 name-matched command-history entries. Human queued messages
were included and duplicate enqueue records removed. Assistant summaries and
tool output were not treated as original owner instructions.

The original August 3–4 founding conversation has now been recovered from
Remio's **Cursor** archive, alongside the August 17 PanoMac conversation and its
later alert-surface decision. The earlier search of Claude's surviving JSONLs
was incomplete across providers. Complete paginated exports were checked against
the archive's advertised bytes and lines, hashed, and retained privately:
9,837 lines / 1,197,042 bytes for the founding conversation. Displayed conversation
text is preserved; missing native tool payloads are not reconstructed.

Sources: [founding dialogue](http://127.0.0.1:17624/notes/mtno22ylun9rzhx6bqn),
[PanoMac original request](http://127.0.0.1:17624/notes/mtno1zoeisrnkdxwyho),
[later alert repair](http://127.0.0.1:17624/notes/mtno1zog97l0mfr2luc).
Injected summaries, repeated audit templates and assistant proposals remain
separate from original human instructions. The founding scope already included
web apps, real browser login, concurrent sessions and combined observation;
these were not new requirements introduced in September.

| Owner requirement | Recorded previously? | Finalization work and required evidence |
| --- | --- | --- |
| Check LaunchGate and other real products, not only demonstrations | Yes, but the installed entrypoint still used a fixed demo registry | Public consumer runner, automatic incremental build, external-package CLI/MCP checks with deliberate passing and failing controls |
| Installed tool, on demand and automatically after edits | Registered as INS-63190DA7; the old hook used the inherited working directory and only detected SwiftUI | Explicit project checks and corrected Swift/AppKit/web hook; no demo substitution |
| CLI, API and MCP access to the developer's own Swift/AppKit UI | Yes | Shared engine, custom runner and live native routes; actual subprocess acceptance |
| Notification-system repair combined with the virtual-rendering request | INS-2B146691 was marked implemented using documentation references | The original combined prompt came from PanoMac. Link rendering to INS-0105EE8B and the notification clause to CTS-804BF3B6 / INS-84CFAEB8. PanoMac uses its own banner/history by the later standing decision; current installed visual acceptance must be recorded separately from code presence. Keep the original combined source intact. |
| Both rendered scenarios and real running applications | Yes, explicitly confirmed in September | Keep both paths and test each independently |
| Invisible real browser login and task execution | Yes; Wave 11 was saved but only lifecycle/transport foundations existed | Trusted input, accessible names, expected outcomes, isolated persistent profiles, no screenshot dependency |
| Concurrent sessions without identity confusion or secret exposure | Yes | Profile ownership, actual multi-client checks, credential resolution and output/argv scans |
| SwiftUI and AppKit click/type/modifiers/drag with observed outcomes | Yes | One native driver, exact-window routing, real hidden fixtures, independent CLI/MCP acceptance |
| Full XCUITest-class reach | Broad request recorded; Wave 11's explicit goals cover input operations | App launch/termination and AX window/menu/dialog targeting use existing public mechanisms. Do not claim universal OS-dialog or cross-app equivalence without scenario evidence |
| Warm consumer rebuild and crash isolation | Implementation plan promised it, but the compiled host lacked a broker | Rebuild/restart disposable consumer process; failed builds cannot certify stale code; same connection must recover |
| Full installed SagaMail settings/account-aware testing and all-product adoption | Recorded in other project conversations; fixtures were not equivalent | Preserve a separate adoption census and consumer acceptance scope. A framework test does not certify every consumer screen or setting |
| Browser-quality feedback without screenshots | Registered as INS-402715D8 | Structured discover/act/observe feedback, multi-frame handling, named controls and outcome findings |
| Resume the build from the previous session | Direct founding message, line 1133 | AGENTS continuity protocol and wave-status must agree with current Git state |
| Immaculate build with minimal errors | Direct founding message, line 1175 | Strict compiler/concurrency and lint gates; unavailable tests cannot count as passing |
| Retain marketing decisions and the conversation for future reference | Direct founding message, line 1322 | Keep original private source and integrity receipts; business-decisions.md remains a labeled synthesis |
| Better designs and architecture where warranted | Current owner instruction | Reconsider mechanisms against the requirements; keep observed results as the acceptance boundary |
| CleanMyMac-inspired desktop UI with rich process motion, rendered with web technology | Added and explicitly selected in this session; registered as INS-FAE07628 | Bundled macOS workbench, real progress, editable checks and evidence; rendered and native bridge verification |

The principal failure was implementation and closure drift, not a lack of a
written broad vision. Several requirements existed in plans or registrations
while demo success, partial probes, or the presence of a hook stood in for
end-to-end product evidence. Release evidence must distinguish supported
capability, observed scenario coverage, and unavailable measurement.

Historical release acceptance: **v1.1.2 was published and installed** with a notarized,
stapled desktop archive and an updated Homebrew CLI. Both installed engines
passed real native/browser CLI/MCP acceptance, including wrong-login failure,
observed successful actions, session isolation, persistence, cleanup and secret
checks. The installed desktop showed **Engine connected 1.1.2** and preserved
saved state. INS-402715D8 and INS-FAE07628 now cite installed evidence.

The installed browser engine verified three public URLs with zero confirmed
errors: the homepage carried 114 warnings and each updated product page nine. Thirteen
controlled positioned-clipping, transform and editor cases passed. A real
10,000-line page passed; exhausted overlap work returned exit 2 without a
verdict. Paint uncertainty remains explicitly qualified in CLI, MCP guidance,
workbench results, badges and history. These results do not certify unmeasured
paint or complete consumer products. Earlier superseded candidates were not
published. Full PM passed Grade A (100), and the release source passed CI.

The September 23 follow-up publishes **v1.1.3** and excludes generated Swift
scratch directories from consumer source fingerprints without weakening source
invalidation or scan limits. The signed, notarized, stapled public archive and
installed desktop/helper were verified byte-for-byte; Homebrew is also 1.1.3.
The candidate passed native/browser acceptance. An installed-path rerun observed
global cursor movement, with unchanged foreground PID, so that run does not
establish the no-interference invariant. Retain this qualification until a quiet
installed run completes; source or artifact equality does not rewrite a receipt.

**The actual Codex MCP connection now exposes all 18 tools.** Calls through the
Codex tool interface listed scenarios, opened the published product page,
verified its visible 1.1.3 version with zero errors and nine layout warnings,
then closed the owned browser session and confirmed the session list was empty.
An incorrect text expectation also produced a cited FAIL, not a transport error.
The scenario catalog remains the framework's demonstration catalog; this is not
consumer adoption evidence. No Codex UI change or process interruption was used.
Claude's actual project health probe is connected. A fresh Claude client then
completed an actual `list_scenarios` call, advertising all 18 tools and returning
the six scenario names with no permission denial. This 53-second probe kept
normal hooks enabled and loaded the exact configured VerdictUI server entry in
isolation. The earlier 180-second session-start timeout remains retained as a
failed attempt; it does not supersede this observed successful tool call.

CTS-E47F57A8 records completed implementation; CTS-B70C5383 records completed
publication and installed acceptance. INS-0105EE8B cites real consumer surfaces. Fleet coverage
remains scoped by [product-adoption.md](product-adoption.md).

The installed background wrapper was also checked, not only the hook script:
17 supported file-extension edit cases reached an actual configured web check;
passing, failing and unavailable controls preserved the CLI result. These are
wrapper controls, not proof that the current Codex host dispatches an edit hook.
After activating the native patch adapter, a real Codex `apply_patch` edit in a
private declared web project produced no automatic attempt or coverage receipt.
Host dispatch remains unavailable; INS-63190DA7 also remains partial for
unconfigured product coverage.

## Automatic source preservation follow-up

Published Claude configuration PRs 59 and 60 were activated after exact-merge CI
passed. The shared Codex hook symlink, client settings, tracked peer contents and
staged entries were preserved. Installed controls passed (192 focused and 19
legacy tests). The later Git index differed in raw bytes; its reported entries
and flags remained identical after omitting stat-cache fields. No index was
restored or peer change overwritten.

A fresh Claude client with normal hooks connected to all 18 installed tools and
called `list_scenarios`. Its actual SessionEnd automatically recorded successful
boundary attempt `ee725261d24b403bba27435af8bc0780`, referencing archived event
`fa59a26d72454f5e9eec9ae4a76fcfbc`. The 721,659-byte transcript restored exactly
against its original (SHA-256
`268484e3ad2e82594bff2e8867f19fa4e912476ae4daee0b0294afbaf93d72a0`).
The private evidence is retained under AgentPromptArchive client receipts in
`claude-followup-boundaries-20260924/automatic-boundary-readback.json`.

Boundary starts and outcomes are now durable metadata. A started capture without
an outcome remains unavailable; later success cannot erase that gap. This proves
the observed client boundary, not that every historic or future session is
complete. Missing dispatch and missing original sources remain explicit states.
