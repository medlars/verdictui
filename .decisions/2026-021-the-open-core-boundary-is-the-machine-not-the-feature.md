# 2026-021 — The open-core boundary is the MACHINE, not the feature — everything that runs on one developer's machine is MIT

**Status**: Accepted (2026-08-14)
**Wave**: 10, Task 6

## Context

`docs/business-decisions.md` recorded the monetisation strategy in the founding
session (2026-08-04) as a two-row table: engine open, "team workflow: baseline
management, CI integration, dashboards, cross-run analytics" paid. Wave 10 Task
6 asks for that boundary as an ADR before the repo goes public, because after
the MIT grant lands the line cannot be redrawn backwards — an MIT release is
irrevocable for the code it covers.

Reading the table against the shipped tree found the problem this ADR exists to
fix. **`BaselineStore` — which the strategy table names on the PAID side as
"baseline management" — has been in `Sources/VerdictUIKernel` since Wave 6**,
and the kernel is the most obviously-open component in the package. So on the
day of the public flip, the strategy document and the code disagree about
whether the product's flagship reserved feature is being given away.

The disagreement is not a leak. It is an **ambiguity in the word "baseline
management"**, which spans two entirely different things:

- `BaselineStore.update(scenario:tree:accepted:auditLog:)` — writes one JSON
  file under `verdict-baselines/`, guarded by the SD4 accept flag, appending the
  superseded hash to a local log. Single developer, single machine, no server,
  no account, no history beyond a text file.
- The thing a team pays for — baselines shared across a team, reviewed and
  approved by someone other than whoever changed the code, with history across
  runs, machines and branches.

Those share a noun and nothing else. A boundary drawn on the noun is
unenforceable: it makes a local file write look like the paid product, which
means either the free tier is crippled for no reason or the "paid" label is
quietly false. Both are worse than having no boundary written down, because a
recorded boundary nobody can apply gets cited as though it were applied.

## Decision

**The boundary is the MACHINE, not the feature.**

> Everything that runs entirely on one developer's machine, for that developer,
> is MIT. Everything that requires a second party — a server, an account, a
> shared store, another human's approval — is the reserved layer.

Applied to the tree as it exists today, this puts **all of it** on the open
side, deliberately and with nothing held back:

| Component | Licence | Why |
|---|---|---|
| `VerdictUIKernel` (semantic tree, diff, 12 rules, verdict schema, expectations DSL, `Baseline` comparison, `BaselineStore`) | MIT | Runs headless on one machine |
| `VerdictUIProbe` (instrumentation, oracle host, harness, sweeps, state machines, pixel channel) | MIT | Runs in the developer's own test process |
| `VerdictUIMacros` / `VerdictUIMacroSupport` (`@Verifiable`, `#VerdictScenario`) | MIT | Compile-time, local |
| `VerdictUIWitness` + `verdictui-witness-host` (AX cross-validation) | MIT | Local process, local window server |
| `verdictui` CLI, JSON-RPC daemon, MCP server | MIT | Local binary, local socket, local stdio |

And it reserves, for a layer **none of which exists today**:

| Reserved | Why it needs a second party |
|---|---|
| Baselines shared across a team, with review/approval by someone other than the author | A second human |
| Cross-run, cross-machine, cross-branch verdict history and analytics | A server that outlives one machine |
| Hosted dashboards | An account |
| A managed CI service running sweeps on our infrastructure | Our infrastructure |

Note what is NOT reserved: **CI integration**. The strategy table listed it as
paid, and that is now explicitly overturned — running `verdictui verify` in
someone's own GitHub Actions is a local binary invocation on a machine they rent.
Charging for it would mean shipping an engine that detects its own CI
environment and degrades, which is precisely the fail-open shape this codebase
spends its whole test discipline eliminating. It would also be trivially
defeated and would poison the adoption wedge the open engine exists to be.

## Consequences

**The reserved layer is a promise about the future, not a hole in the present.**
Nothing is withheld from this release, no feature is stubbed, and there is no
"community edition" degradation anywhere in the tree. That is the intended
outcome: the engine's whole strategic job is adoption (`no.md` #4 — all serious
competitors are free and closed dev CLIs get zero adoption), and a first release
that visibly holds something back forfeits that.

**The boundary is testable, which is the point of moving it off the feature
noun.** "Does this need a second party?" is a question about an artifact that
anyone can answer by reading it. "Is this baseline management?" is not.

**`docs/business-decisions.md` is corrected rather than left to drift.** Its
table now points here, because a strategy row that contradicts the shipped tree
is the kind of stale claim a future session inherits and acts on (fleet lessons
262/292 — a directive is a claim with a timestamp, and nothing reconciles it
against the code).

**Re-licensing later is not available.** MIT on the published commits is
permanent for those commits. If a future component genuinely belongs in the
reserved layer it must be authored there from the start, in a separate
repository — never moved out of this one.

## Alternatives considered

**Reserve `BaselineStore` and strip it before the flip.** Rejected: it is
650 lines of the CLI's most-used verb, its SD4 guard is one of the product's
better safety arguments, and removing it would make `verdictui baseline` a
paid-only command in a tool whose free tier is supposed to be the wedge. It also
fails the machine test outright — there is no second party anywhere in it.

**Dual-license the whole engine (MIT + commercial).** Rejected: dual licensing
buys nothing here. It exists to let companies avoid copyleft, and MIT has no
copyleft to avoid; it would add a CLA requirement that suppresses exactly the
community rule contributions the open engine is meant to attract.

**Draw no boundary and decide later.** Rejected: "later" is after the MIT grant
is published, at which point the decision has been made by default and cannot be
revisited for any code already out. Writing it down now costs one document;
deferring it costs the option.
