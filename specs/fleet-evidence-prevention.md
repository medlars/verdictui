# Fleet evidence prevention

Status: authorized by the owner's September 23 follow-up.
Tier: T3; three components across the existing hook, instruction store, shared PM,
and consumer configuration boundaries. No new service.

## Requirements

1. Reconnect VerdictUI in the actual Codex and Claude clients. A separate stdio
   probe is useful diagnosis, but does not prove an existing client refreshed.
2. Retain original prompts and recovered founding conversations with exact bytes,
   provenance, integrity receipts, and explicit missing/placeholder states.
3. Prevent an implemented/done status from silently dropping required clauses.
   Recover the specific notification requirement and verify its real outcome.
4. Enumerate the entire registered fleet. Missing declarations, unobserved
   targets, and incomplete coverage must remain visible and prevent a complete
   coverage claim. A framework demonstration cannot certify a consumer product.
5. Separate layout, paint, and behavior observations. Capturing a first baseline
   is not successful visual verification, and unavailable capture is not a pass.

## Existing mechanisms and decision

Inspected prompt logging, instruction capture, original-source retention,
InstructionStore status mutations, workflow evidence/export, VerdictUI edit
checks, and the shared visual comparison monitor. The current prompt hook has
one append-only log; InstructionStore permits freeform implemented claims; the
visual monitor returns an unskipped pass when it creates its first baseline.

| Option | Dependency and scope | Reversal | Cost |
| --- | --- | --- | --- |
| Hook-only checks | Client hooks parse closures; direct API writes remain uncovered | Revert hooks | Low; insufficient enforcement |
| Store contracts and shared evidence | Hooks retain sources; stores validate closure; shared PM observes coverage | Revert readers while retaining evidence | Moderate; selected |
| Independent per-project acceptance systems | Each project owns a separate gate and implementation | Roll back each project | High and prone to drift |

Use the second option with project-owned coverage declarations from the third.
Reuse existing workflow evidence and artifact verification; introduce no new
generic evidence database. Stored receipts establish consistency and provenance,
not cryptographic authority or proof that a human review was correct.

## Ownership and sequence

- Prompt lane: isolated claude-config checkout; improve log-user-prompt and add
  a private archive helper plus recovery/negative tests. Preserve rule-capture
  filtering and the existing legacy prompt log contract.
- Coverage lane: isolated pm-base checkout; repair visual-result semantics and
  add a registry census with separate layout/paint/behavior states and tests.
- Closure lane: isolated shared-libs checkout; source-bound clause contracts at
  actual InstructionStore/CTS mutation boundaries, including direct API paths.
- Integration: wire existing edit hooks and CEO aggregation, preserve provider
  settings and peer changes, register governing artifacts, run the live census,
  and reconcile recovered owner instructions without substituting summaries.
- MCP repair: fix the measured project runner startup failure, register the
  installed helper for Claude Code across projects, and verify actual clients.
  Codex UI access was explicitly denied by the computer-use tool; do not bypass.

## Acceptance

Tests must reject missing clauses, corrupt/stale receipts, a later failed attempt,
missing or empty coverage declarations, demonstration targets in consumer checks,
and an unreviewed first visual baseline. Preserve prompt bytes through concurrent
writes and verified restoration; malformed/placeholder input remains incomplete.
Every registry row appears in the census, including inaccessible/excluded roots.
Run focused tests after each change and relevant PM stages, then independent
security/performance review and final PM/CEO confirmation on published commits.

## Rollback and limits

Retain original archives and receipts. Reverse only this task's isolated commits
or additive configuration entries; never reset peer working copies. Missing
coverage is not repaired by weakening a gate or generating fictitious manifests.
Original founding dialogue has now been found in Remio; full pagination and
human-message comparison are complete; private exports have verified sizes and hashes. The notification clause belongs to
PanoMac and must be assessed against its later owner-selected alert surface.
