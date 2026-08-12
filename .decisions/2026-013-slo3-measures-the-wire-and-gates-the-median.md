# 2026-013 — SLO 3 measures the wire, and gates the median

**Status**: Accepted (2026-08-12)

## Context

Wave 7's exit gate asks for "MCP tools respond < 100 ms warm (measured through the
actual stdio transport)". SLO 1 already measures latency — but it times
`Harness.perform` **inside the test process**, and an agent never calls `perform`.
It writes a JSON frame to a pipe and waits for one back. Process boundary, framing,
JSON coding and pipe scheduling all sit between the two figures, and none of that
appears in an in-process timing.

So a tool can meet SLO 1 and still be slow to every caller, and no existing signal
would say so. This is `no.md` #32's principle applied to latency rather than
correctness: a suite verifies code and cannot see the artifact that ships.

A second question came with it. `no.md` #13 and #15 already established, on SLO 1,
that the tail is not gateable — p95 moves 56.7 → 106.7 ms purely with contention
while the median stays put. The tempting move was to inherit that conclusion.

## Decision

**Measure the artifact.** `MCPLatencyTests` spawns the BUILT `verdictui mcp` binary
and times a full client round trip — write, server work, read — over real pipes.
PM `stage_mcp_latency` gates what it measured.

**Gate the median at 40 ms; record the tail.** The lane was re-derived on THIS
metric rather than inherited, and the measurement justified it independently
(release binary, 60 samples after 5 warm-ups, three runs each):

| | p50 | p95 |
|---|---|---|
| idle | 8.30 / 8.29 / 8.29 ms | 8.52 / 8.67 / 8.44 ms |
| under 8 spinning cores | 10.05 / 10.33 / 11.30 ms | 11.91 / 12.01 / **45.82** ms |

The median degrades honestly and stays bounded; the tail swings 5x on unchanged
code because one descheduled sample moves it. The budget is 40 ms — ~4x the idle
median, clear of the loaded one — so it fails on a regression rather than on a bad
afternoon, while sitting far inside the published 100 ms product target.

The first live PM run printed `p95 23.57ms` against a 10.25 ms idle tail, which
vindicated the choice within the hour.

## Alternatives considered

**Reuse SLO 1 and call the gate satisfied.** Rejected: it answers a different
question. It is also the failure this project keeps finding — a check that reads a
proxy instead of its subject.

**Gate p95, since the plan's budget is stated as p95 < 100 ms.** Rejected on
measurement: a p95 gate fails for a busy neighbour, and a gate that fails for the
environment teaches its reader to discount it (`no.md` #15). The published target
stays 100 ms p95 and is RECORDED; the enforced number is the median.

**Inherit SLO 1's lane decision without re-measuring.** Rejected as method: a
conclusion that is right for one metric can be wrong for another, and inheriting it
would leave the threshold unjustified for the metric it governs.

**Copy `ConstrainedTimingEnvironment` into the CLI test target.** Rejected — it is
the type extracted precisely because three timing suites had drifted (`no.md` #17).
It moved down into the `VerdictUIProbe` library both test targets already depend on.
Same reasoning made `_parse_slo_line` shared by both SLO stages: two copies are two
places to weaken, and weakening either alone leaves the other's tests green.

## Consequences

- A third SLO to keep honest, at ~2 s per PM run.
- The gated budget lives in two languages (`MCPLatencyTests.warmP50BudgetMs` and
  `SLO3_MCP_P50_BUDGET_MS`); `test_the_gated_budget_agrees_with_the_swift_test`
  pins them together, because neither language can read the other's constant.
- Everything proving the benchmark RAN — sample count, finiteness, and a `result`
  rather than an `error` on every reply — is asserted in EVERY lane, including
  record-only hosts. An error reply is fast for the wrong reason; without that
  assertion a server that had stopped rendering would post the best numbers the
  suite has ever seen.

## Rollback

Remove `stage_mcp_latency` from `define_stages` and delete the SLO 3 row from
`docs/slo.md`. `MCPLatencyTests` can stay — it is self-contained and skips when the
binary is not built. No other stage reads `SLO3_MCP_*`, and `_parse_slo_line`
remains correct for SLO 1 alone.
