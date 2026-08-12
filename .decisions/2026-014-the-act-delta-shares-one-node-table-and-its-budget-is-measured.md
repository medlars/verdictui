# 2026-014 — The act delta shares one node table, and its budget is a measurement

**Status:** Accepted
**Date:** 2026-08-12
**Supersedes:** the implementation plan's "typical act delta ≤ 300 bytes" (Wave 7 Task 2)

## Context

Wave 7's `act` tool returns a `TreeDelta` rather than a tree, because act-then-observe
is the tightest loop an agent runs and a full tree per step is the token cost the
compact wire format exists to avoid. The plan budgeted a typical act delta at 300 B.

Measured on `ToggleLayoutScenario`'s toggle — 2 nodes added, 1 removed, 1 moved, the
SMALLEST structural act the demo catalog has — the raw `TreeDelta` serializes to
**702 B**. So a compaction was genuinely needed; the question was which one.

## Decision

**(a) Added subtrees share ONE flat node table across the whole delta**, in the same
parallel-array layout `CompactTree` uses (`nodeIDs`/`nodeRoles`/`nodeTexts`/
`nodeFrames`/`nodeParents`/`nodePaths`/`nodeMetrics`), with every path a run of
indices into one shared string table, `TextMetrics` flattened to a triple, and
**empty lists omitted entirely**.

**(b) The wire budget is 512 B for a structural act and 64 B for a non-structural
one**, replacing the plan's 300 B. Owner decision, 2026-08-12.

## Alternatives considered

**1. Reuse `CompactTree` per added subtree** — the obvious design, and it was BUILT
and MEASURED before being rejected: **735 B, larger than the 702 B raw form it
replaced.** `CompactTree` amortizes nine array keys across a whole tree, where they
cost nothing per node; an added node is typically a subtree of ONE, so each addition
paid all nine keys plus its own string table to describe a single node — roughly
280 B of envelope around 80 B of payload, and the per-addition table defeated the
shared one. A format excellent for its own subject can be worse than nothing one
level down, and the mismatch is invisible until the bytes are printed.

**2. Keep the 300 B budget and compress further.** Rejected on what the remaining
bytes ARE. After four rounds (702 → 735 → 598 → 511 → 498 B) roughly 400 B of a
structural act is content the verdict layer reads: `structuralPath` is what a finding
cites for a node with no probe id, and `TextMetrics` is what `TruncationRule` judges
against. Reaching 300 B requires dropping one of them, which makes unprobed added
nodes uncitable or blinds a lint rule — a real loss to satisfy a number.

**3. Keep 300 B and gate only non-structural acts.** Rejected: the gate would then
pass for every act that changes nothing and could never fail for the case the budget
exists to control (`no.md` #12's shape — an assertion satisfied by both the correct
and the broken implementation).

**4. Gate the whole `StepResultWire` at 1 KB instead of the delta.** Closer to what an
agent actually pays, but it drops the plan's delta-specific claim and lets a bloated
delta hide behind a small findings list. Recorded as a measurement (309–603 B), not
adopted as the gate.

## Consequences

- Two budgets are gated **separately**, because a single one covering both regimes
  would be met by the inert case alone: structural ≤ 512 B, inert ≤ 64 B.
- The structural test asserts the **RAW form is OVER budget** as a control. Without
  it, "the delta fits" is also satisfied by a format that saves nothing, and the whole
  compaction could be deleted with every test still green.
- The inert case is pinned by its own test (measured 2 B), because it is the
  commonest act in a real loop and the structural budget cannot see it. Omitting
  empty lists is what fixed it — before that it cost 170 B against 49 B raw.
- `expand()` treats its input as untrusted (it arrives over a socket from a process
  this one does not control) and refuses rather than crashes. Verified by fuzzing:
  100 hostile payloads — mismatched column lengths, negative and out-of-range
  indices, short frame arrays — all refused, zero traps.
- The general rule, recorded as `no.md` #41: **a wire format has a DISTRIBUTION, not
  a size.** Measure the whole vocabulary (structural, inert, error) before choosing a
  threshold, not the one fixture in front of you.
- This is the same discipline as ADR 2026-013 (SLO 3) and `no.md` #13/#15: a
  threshold moved to fit today's number is a silencer, but a threshold that was never
  a measurement is a guess, and replacing a guess with a measurement is not weakening
  a gate.

## Rollback

Revert `CompactDelta.swift`, `StepWire.swift`, the `act` case in `VerdictDaemon.handle`,
the `act` entry in `MCPServer.tools`, and `ActToolTests.swift`. `TreeDelta` itself is
untouched, and `Harness.perform` — which computes the delta — predates this work, so
the act loop reverts to being reachable only from a test target. No schema version
change is involved: `Verdict` and `SemanticNode` are unmodified, so `SchemaVersion`
stays at 1.0 and no contract fixture regenerates.
