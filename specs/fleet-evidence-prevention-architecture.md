# Architecture: fleet-evidence-prevention

Status: authorized
Tier: T3 (files=30 estimated, boundary crossings=6, new surfaces=2 data contracts)

## Context

The owner requested actual MCP reconnection and fleet-wide prevention. Searches
for prompt/transcript/archive, instruction/status/completion, and visual/capture/
baseline found existing mechanisms with missing acceptance boundaries. Original
Cursor and Claude conversations were recovered through Remio. The stock project
MCP manifest referenced an absent release launcher instead of a consumer host.

## Structure rules applied

Adapters retain original input; stores enforce clause completion; shared evidence
readers validate artifacts; CEO reports every registry row. No project imports
another project. Python 3.14 and existing Swift targets remain the runtime.
No service, external subscription, or blanket permission change is added.
Behavioral negative controls accompany each new guard. Source census observed both domain and adapter layers: 63 modules, 648 edges,
zero cross-project imports/cycles/layer violations, zero unparseable files.
Globs: domain VerdictUIKernel; adapters VerdictUI*Runner and VerdictUICLICore.

## Needs + obligations

Exact-byte retention, source attribution, concurrent safe publication, private
permissions, clinical exclusions, bounded execution and visible unavailable
states. A local checksum proves integrity relative to a receipt, not reviewer
identity or human semantic correctness. New APIs require input validation and
structured results. Restoration must reproduce original bytes. Published config
must survive absent build output through an explicit build product.

## Fleet consultation

Examined Claude/Codex hooks, InstructionStore/CTS, workflow_inputs/evidence/export,
shared visual monitor, CEO registry, VerdictUI consumers and PanoMac alerts.
Fleet UI census: registered=150 (128 projects + 22 non_pm), additional_roots=6, unavailable=150 at baseline.
Every row remains visible; missing declaration does not establish UI absence.

## Options table

See fleet-evidence-prevention.md: hook-only closure (low cost, direct API gap),
store contracts plus shared observers (selected, cross-repo but reversible), and
independent project acceptance systems (high ongoing cost, local ownership).

## Decision + ADR id

.decisions/2026-09-23-fleet-evidence.md

## Blueprint

### Files to create

Private prompt archive adapter; clause-completion validator; UI evidence reader
and CEO adapter; focused negative-control tests; dedicated VerdictUI project host.
Exact paths and interfaces are in fleet-evidence-prevention-steps.json.

### Files to modify

Existing prompt/edit hooks, InstructionStore/CTS mutation APIs, visual monitor,
CEO report/aftermath/propagation, package metadata, project config and audit docs.
PanoMac's measured warm-delivery defect is owned in a separate isolated checkout.

### Build order

S1/S2/S3/S5 independently, S4 after S3; S6 independently. Review, focused tests,
consumer gates, publication and installed observations follow implementation.

## Test plan

Named tests in steps.json; baseline creation, empty/corrupt/stale/latest-failed
artifacts, lost clauses and provider/source confusion must all fail acceptance.
Project MCP test copies the actual launcher outside the repository and requires
initialize, tools/list (18 tools), and list_scenarios from the explicit host.
Full original exports are checked against advertised line/byte counts and hashes.

## Rollback

Trigger: regression at a consumer boundary. Owner: current implementing task.
Revert only isolated commits and additive registrations; restore verified app
artifact if installed acceptance fails. Preserve archives and receipts. Validate
rollback with the same previously passing consumer command; no destructive reset
or peer working-tree change is permitted. Scoped Git diffs are inspected before
publication so reversal paths are known.

## Open questions

Current Codex session reconnect is constrained by a denied Codex UI operation;
use supported MCP connection APIs and report actual catalog state. Fleet adoption
is not complete merely because prevention readers are installed. PanoMac's
installed notification repair needs rendered acceptance after publication.

### Import census — `/Users/eiman/Projects/.worktrees/verdictui-fleet-evidence`

`census: modules=63 edges=648 cross_project=0 cycles=0 layer_violations=0 layers_observed=true (observed) unparseable=0`

| kind | module | detail |
|---|---|---|
| — | — | no violations |

**Swift targets:** verdictui-witness-host -> [VerdictUIDemoScenarios, VerdictUIKernel, VerdictUIProbe, VerdictUIWitness], verdictui -> [VerdictUICLICore], VerdictUIWorkbenchCoreTests -> [VerdictUICLICore, VerdictUIWorkbenchCore], VerdictUIWorkbenchCore -> [VerdictUICLICore, VerdictUIWeb], VerdictUIWorkbench -> [VerdictUIWorkbenchCore], VerdictUIWitnessTests -> [VerdictUIDemoScenarios, VerdictUIKernel, VerdictUIProbe, VerdictUIWitness], VerdictUIWitness -> [VerdictUIKernel], VerdictUIWebTests -> [VerdictUIKernel, VerdictUIWeb], VerdictUIWeb -> [VerdictUIKernel], VerdictUIProjectRunner -> [VerdictUICLICore, VerdictUIDemoScenarios], VerdictUIProbeTests -> [VerdictUIDemoScenarios, VerdictUIProbe], VerdictUIProbe -> [VerdictUIKernel], VerdictUIMacros -> [], VerdictUIMacroTests -> [VerdictUIMacroSupport, VerdictUIMacros], VerdictUIMacroSupport -> [VerdictUIKernel, VerdictUIMacros, VerdictUIProbe], VerdictUIKernelTests -> [VerdictUIKernel], VerdictUIKernel -> [], VerdictUIDemoScenariosTests -> [VerdictUIDemoScenarios], VerdictUIDemoScenarios -> [VerdictUIKernel, VerdictUIProbe], VerdictUIDemo -> [VerdictUIDemoScenarios, VerdictUIKernel, VerdictUIProbe], VerdictUICLICoreTests -> [VerdictUICLICore, VerdictUIDemoScenarios], VerdictUICLICore -> [VerdictUIDemoScenarios, VerdictUIKernel, VerdictUIProbe, VerdictUIWeb, VerdictUIWitness], VerdictUIAppKitTests -> [VerdictUIAppKit, VerdictUIKernel], VerdictUIAppKit -> [VerdictUIKernel], AppKitRunnerExample -> [VerdictUIAppKit]

