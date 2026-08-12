# 2026-011 — Three-valued exit codes, and no destructive verb over a socket

**Date**: 2026-08-11
**Status**: Accepted
**Wave**: 6 (CLI + daemon), 7 (MCP surface)

## Context

Wave 6 puts the engine behind a command line, and Wave 7 behind an MCP tool
catalog. Both surfaces have to answer two questions that look like one:

1. **Is the UI wrong?** — the verdict.
2. **Could we look at all?** — whether a verdict was produced.

They also both expose `baseline`, and accepting a baseline REPLACES the record of
what a screen is supposed to look like. It is the only destructive operation in
the product: every other verb reads.

The plan's Wave 7 task list names `baseline_accept(scenario, confirm: true)` as
an MCP tool, with the `confirm` flag as the SD4 destructive-action guard.

## Decision

**Exit codes are three-valued, not two.**

| Code | Meaning |
|---|---|
| `0` | the verdict passed |
| `1` | a verdict was produced and it FAILED — the UI is wrong |
| `2` | no verdict could be produced — says nothing about any UI |

The daemon and MCP surfaces carry the same distinction as `ok`, which reports
whether the engine could LOOK, never what it saw: a response carrying a FAILING
verdict is `ok: true`, while an unknown scenario is `ok: false`.

**`baseline accept` is not served over the daemon socket and is not an MCP
tool.** It exists only as a foreground CLI command a human runs and watches:
`verdictui baseline <scenario> --update --accept`.

## Alternatives considered

**Two-valued exit codes (0 = pass, non-zero = anything else).** Conventional, and
what most tools do. Rejected because it forces every caller to treat an
infrastructure fault as a product defect: a CI job that opens a bug on non-zero
would file "this screen is broken" for a scenario name typo, a missing baseline,
or a settle that timed out. The engine already refuses this conflation
internally — an unrenderable sweep cell is recorded as *unmeasured* rather than
as a pass or a fail — and a two-valued exit would discard that distinction at the
last hop.

**`baseline_accept` with a `confirm: true` argument**, as the plan specifies.
Rejected on the grounds SD4 is actually protecting: a boolean an agent sets as
easily as it omits is a speed bump, not a gate. The parameter makes the call one
token longer and stops nothing, while the thing it guards is unrecoverable — the
superseded baseline is gone, and every subsequent verdict is a statement about
whatever the code last happened to do. A gate that cannot fail is worse than no
gate, because it looks like protection.

**Serving `baseline update` over the socket with a confirmation round-trip.**
Rejected as more machinery for the same weakness: a client that can send the
first message can send the second.

## Consequences

- Callers must handle three codes. `docs/runbook.md` states the contract, and the
  exit-gate item "destructive baseline-accept requires explicit confirm" is met
  more strongly by the verb's absence than by a flag.
- An agent that needs a baseline accepted must ask a human. That is the intended
  cost; it is the one operation where a human in the loop is the feature.
- `MCPServerTests.testNoToolAcceptsABaseline` and
  `DaemonTests.testTheDaemonRefusesToUpdateBaselines` assert the absence, each
  with a read-only control (`baseline_diff` must still be offered) so "no
  baseline tool" cannot be satisfied by a catalog that dropped baselines
  entirely. Adding the verb therefore means deleting a test and saying why.
- `stage_cli_smoke` asserts all three codes against the built binary, so a
  regression that collapses 2 into 1 fails the PM rather than silently
  re-teaching callers the wrong contract.

## Rollback

Both halves are additive and independently reversible.

- Exit codes: `ExitCode.couldNotVerify` is a single enum case in
  `VerdictOutput.swift`; mapping it to `.verdictFailed` in `CommandRunner.run`
  restores two-valued behaviour. `stage_cli_smoke`'s expectation table and
  `CLIBinarySmokeTests.testTheDocumentedExitCodesAreWhatTheBinaryReturns` would
  need updating in the same commit — which is the point: the contract cannot
  change silently.
- The destructive verb: adding a `baseline_accept` case to
  `VerdictDaemon.handle` plus a `MCPTool` entry restores it. The two tests named
  above fail until deleted, forcing the reasoning into a commit message.
