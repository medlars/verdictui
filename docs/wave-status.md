# VerdictUI — Wave Status (session continuity SSoT)

> **Purpose**: every new session resumes the build from this file — no re-planning,
> no asking "where were we". Read it at session start; update it before ending any
> session that changed code or completed a task. Keep entries terse and factual.
>
> Task numbers refer to `docs/implementation-plan.md` (the execution SSoT).
>
> **Historical detail** (session log, "Previously" rows, wave checklists, continuation
> notes): [`docs/archive/wave-status-history.md`](archive/wave-status-history.md).

## Current position

Cross-check against `git log --oneline -5`; if this file is stale, reconcile from git
evidence before continuing. Append dated session notes to the
[archive session log](archive/wave-status-history.md#session-log-newest-first-keep-last-10).

| Field | Value |
| --- | --- |
| Current wave | Framework PR52 `f6755c2` CI36192319360 is green: 1,347 native passes/26 skips, 779 Python passes/22 skips and 48 Workbench assertions. SagaMail draft PR45 `5a2935d7` CI36197556822 retains 183 render passes/73 unchanged failures, with all 56 focused checks and 353 Python cases passing. Six caption images change only inside declared text regions; all references unchanged. This is a saved partial finalization, not installed or fleet acceptance. |
| Next action | Resume CTS-CEB33F0B from the saved continuation prompt. Verify the final documentation PR state, then resolve actual remaining SagaMail Settings/Toolbar/action/render failures without weakening references. Installed/physical acceptance and rejected Codex settings inspection remain pending. Remeasure service ownership and active CIS-E9B81452 before any rollout; the old cf893 proposal is stale. Preserve durable `86286737` and canonical peer work. |
| Blockers (DIR-036) | **NONE.** The one open finding was CLOSED 2026-08-14: **CTS-75914181** (witness window flashing bottom-left) is fixed and verified — `WitnessHost` sets `alphaValue = 0`, so the window server still assigns a windowNumber, still lists it on-screen and still publishes its AX tree (`no.md` #42/#43 require exactly that) while compositing nothing. **The previously-recorded fix was falsified**: `NSWindow` constrains its frame to the visible screen, so `origin: (-20000, -20000)` measured back as `(160, 800)` fully on screen, and `setFrameOrigin` after `orderFront` still leaves a 40x41 pt sliver — see `no.md` #50, and do NOT retry an offscreen origin. **The blocker itself was also falsified by its own falsify command** (`swift test` returned 0 skips, so the instrument had been working all along); the degraded window-server state was plausibly caused by 8 orphaned PanoMac test hosts alive 1d+ and reparented to pid 1 — an unrelated project, ticketed as **CTS-8A34C940** per DIR-035 rather than touched. Every blocker recorded here MUST carry `measured:` and `falsify:`; run the falsify command before planning around any blocker older than 7 days and re-stamp it either way. |
| Health (recent) | **PM quick Grade A (100.0), exit 0** at the reconciled tip (main == origin/main; session commits `158ede5`..`012ac03`). **889 Swift + 441 Python tests PASS** (Python 373 → 441, +68 = the session's four new test files); **148/148 mutation targets** resolve including the new pyright-guard row (hand-verified NOTICED: witness ran red, byte-identical restore). Artifact-level E2E: cli_smoke exit codes 0/1/2, transport_smoke MCP handshake with 9 tools over real stdio (`isError:false` on a failing verdict), installed parity ok (12 subcommands, 2 copies), SLO 1 p50 **49.98ms** < 70, SLO 3 p50 **8.40ms** < 40, contracts 4/4 PASS, floor clean. **VerdictUI CIS: 0 open at every severity.** Two heavy runs were deferred mid-session by load 47 (the fixed ceo-watch daemon mid-sweep — the known false-P1 signature); this verdict was measured quiet. |
