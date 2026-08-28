# VerdictUI MCP tools — contract

> **STATUS: SERVABLE.** `verdictui mcp` speaks this protocol over stdio, and
> `stage_transport_smoke` drives the built binary to prove it — a library test
> cannot see a process that refuses to start, and for a whole wave this catalog
> was green while nothing read stdin at all (`no.md` #34).
>
> Wave 7. Every tool below is served by `VerdictDaemon.handle`, so the CLI, the
> daemon and the MCP surface cannot disagree about what `verify` means. A second
> implementation is how three surfaces drift into three answers.
>
> **On the shapes below.** They are the shapes that go over the wire, verified
> against raw JSON rather than through a round trip. Swift's synthesized enum
> encoding once wrapped every payload in a positional `_0` key while this file
> documented the unwrapped form, and every test agreed with the code because
> they all decoded with the same `Codable` that encoded it.

## The contract that governs every tool

**`ok` reports whether the engine could LOOK, never what it saw.** A tool call
that returns a FAILING verdict is `ok: true` — the question was answered. A tool
call naming a scenario that does not exist is `ok: false`. An agent that
conflated the two would open a bug against a screen the tool never rendered.

This is the same three-valued contract the CLI spells as exit codes:

| CLI exit | MCP shape | Means |
|---|---|---|
| 0 | `ok: true`, verdict `PASS` | the screen is right |
| 1 | `ok: true`, verdict `FAIL` | the screen is wrong, findings cite rule + node |
| 2 | `ok: false`, `error` set | no verdict was produced; says nothing about any UI |

## The handshake

`initialize` is the first message of every real session, and it carries `params`:

```json
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"probe","version":"1"}}}
→ {"id":1,"jsonrpc":"2.0","result":{"capabilities":{"tools":{}},"protocolVersion":"2024-11-05","serverInfo":{"name":"verdictui","version":"1.1"}}}
```

**`params` is free-form per method and must decode leniently.** It is typed here
for `tools/call`, but `initialize` fills it with an entirely different shape. A
strict decode rejects the ENVELOPE, so the message never reaches its handler and
the server answers every real client's opening message with a parse error — which
is exactly what shipped until 2026-08-12, behind a suite whose handshake test sent
`initialize` with no `params` key at all, the one spelling that happens to decode.
`MCPTransportTests.testTheHandshakeARealClientSendsIsAnswered` pins the real form.

`notifications/initialized` follows and **must not be answered** — it has no `id`,
and a reply to it is a protocol error that presents as a server that never
finished starting.

## Tools

### `list_scenarios`

No arguments. Returns every scenario name the registry holds.

```json
{"method": "list"}
→ {"ok": true, "result": {"scenarios": ["demo-clean-settings", "demo-offscreen-button", …]}}
```

### `render(scenario, pixels?)`

Returns the semantic tree. Wire form is `CompactTree` — parallel arrays plus a
parent index, with repeated strings interned.

With `pixels: true` the reply also carries a rendered image — as a **path**,
never as bytes. The keys are `image` (filesystem path), `pixelsWide`,
`pixelsHigh`, `backend`, `contentHash` and `cacheHit`, alongside the same
compact `tree`. A base64 PNG would cost more than every other field of every
other tool combined, while a path costs a few dozen bytes and an agent that
wants to look can open it. Verified against the shipped binary: a 360×260
capture of `demo-clean-settings` reports its path in a payload smaller than the
image itself.

Pixels are the exception path. Ask for them only when the semantic tree cannot
answer the question — colour, gradient, shadow, glyph rendering — because every
geometric question is answered better, and with node ids, by `verify`.

Measured on the demo catalog: 362–839 B compact against 491–1448 B nested, all
inside the 2 KB budget. The format carries `textMetrics` and `structuralPath`
deliberately; dropping them made every tree fail its round trip, and worse,
`TruncationRule` reads `textMetrics` — a verdict computed from a lossy wire form
reports a clean screen for a clipped label.

`truncated: true` appears when a tree was cut to fit. It is named on the wire
rather than inferred, because a truncated tree that looks complete is a verdict
about a screen nobody saw all of. Use `focus` to see what was cut.

### `focus(scenario, node_path)`

The follow-up verb for `truncated: true`. Returns the subtree rooted at one
node, in the same `CompactTree` wire form — so an agent expands the part it
cares about instead of re-rendering the whole screen at a bigger budget.

```json
{"method": "focus", "scenario": "demo-clean-settings", "nodePath": "button-row"}
→ {"ok": true, "result": {"tree": {"ids": ["button-row", "cancel-button", "save-button"],
                                   "parents": [-1, 0, 0], …}}}
```

`node_path` is a `structuralPath` **or** a probe id — both, because a verdict
cites whichever identity a node has, and accepting only one would leave half the
nodes an agent can SEE unreachable by the verb that exists to reach them.

The focused node is the ROOT of what comes back (`parents[0] == -1`). An unknown
path is `ok: false` with the path quoted, never an empty tree: an empty tree
reads as "that node has no children" rather than "that node does not exist", and
an agent would act on a screen it never saw.

### `verify(scenario, baseline?, cross_validate?)`

`cross_validate: true` also reconciles the in-process tree against the
platform's accessibility tree — an independent channel that catches a probe
misreporting what it renders. It needs a windowed session and an Accessibility
grant on the launching process; when it cannot run, the verdict carries a
`cross-validation-skipped` **warning** naming the reason rather than passing
more quietly. `timing.crossValidateMs` is populated whenever it was ATTEMPTED,
including on the failing path — absent means it was never requested.

Renders, judges, returns a `Verdict`. Every finding cites `rule` and `nodeID`;
bare booleans are banned from this API by CLAUDE.md rule 4.

```json
{"method": "verify", "scenario": "demo-offscreen-button"}
→ {"ok": true, "result": {"verdict": {"status": "FAIL", "findings": [
     {"rule": "offscreen", "nodeID": "apply-button",
      "message": "'apply-button' is visible but sits entirely outside the 320 x 200 pt viewport…",
      "suggestion": "move it inside the viewport, or hide it while it is off-screen…"}]}}}
```

With `baseline: true` the recorded baseline is compared too, and drift findings
are ADDED to the lint verdict rather than replacing it: drift and a rule
violation are different claims, and a screen can be both unchanged since the
last accept and wrong.

### `act(scenario, action, probe, text?, value?, include_tree?)`

Capture, act, settle, capture, diff, lint — one call. This is the tightest loop
an agent runs, so the response carries the DELTA rather than the tree.

`action` is one of `tap`, `toggle`, `setText`, `setSlider`. `setText` requires
`text` and `setSlider` requires `value`; a missing payload is REFUSED rather
than defaulted, because an empty string types nothing into the field and then
reports a verdict about a screen the caller never asked for.

Verbatim from the shipped binary (`verdictui mcp`, the `text` payload of the
tool result), reformatted only by line breaks:

```json
{"delta": {
   "added": [{"index": 1, "node": 0, "path": [0,1]}, {"index": 2, "node": 1, "path": [0,5]}],
   "moved": [{"from": [50,72,260,28], "path": [0,9], "to": [50,51,260,28]}],
   "removed": [[0,8]],
   "nodeIDs": [1,5], "nodeRoles": [2,6], "nodeTexts": [3,-1],
   "nodeFrames": [50,91,119,16, 50,119,140,30],
   "nodeParents": [-1,-1], "nodePaths": [4,7],
   "nodeMetrics": [119,1,1, -1,-1,-1],
   "strings": ["$root","advanced-detail","text","Cache size: 512 MB","root/text[1]",
               "clear-cache-button","button","root/button[2]","collapsed-summary",
               "advanced-toggle"]},
 "elapsedMs": 51.1385, "findings": [], "probe": "advanced-toggle",
 "settled": true, "status": "PASS"}
```

**Reading a delta.** Every path is a run of indices into `strings`, so `[0,1]`
is `$root/advanced-detail`. Added nodes live in one flat table shared by all
additions: node `i` has id `strings[nodeIDs[i]]` (`-1` = unprobed), role
`strings[nodeRoles[i]]`, frame `nodeFrames[i*4..<i*4+4]`, and metrics
`nodeMetrics[i*3..<i*3+3]` as `intrinsicWidth, renderedLineCount,
idealLineCount` (all `-1` when the probe reported none). `nodeParents[i] == -1`
marks an addition root.

**An empty list is OMITTED, not spelled.** Above, `changed` is absent because
nothing changed. An act that alters nothing structurally therefore answers
`"delta":{}` — 2 bytes.

**`settled` is a separate claim from `status`.** A timed-out settle says the
observation may be incomplete; a FAIL says the layout is wrong. An agent that
read the first as the second would go and fix the wrong thing.

**A FAIL is a successful call.** An act against a probe that does not exist
returns `isError: false` with `status: FAIL` and a finding citing the probe —
the request was understood, and the answer is that the UI has no such control:

```json
{"delta": {}, "elapsedMs": 5.794084, "probe": "no-such-probe",
 "settled": true, "status": "FAIL",
 "findings": [{"rule": "probe-action", "severity": "error", "nodeID": "no-such-probe",
   "message": "no action binding registered for probe id 'no-such-probe'",
   "suggestion": "Register a compatible binding with .verdictProbe(..., action:) for this probe id."}]}
```

An UNPARSEABLE act — an unknown verb, a `setText` with no `text` — is a refusal
instead (`ok: false` on the socket, `isError: true` over MCP), because that is a
statement about the request rather than about the UI.

#### Wire budget

Measured on the demo catalog, compact against raw:

| Act | Census | Compact | Raw |
| --- | --- | --- | --- |
| toggle expand | added 2, removed 1, moved 1 | **498 B** | 702 B |
| toggle collapse | added 1, removed 2, moved 1 | **419 B** | 544 B |
| inert tap | nothing changed | **2 B** | 49 B |
| unknown probe | nothing changed | **2 B** | 49 B |

Gated at **512 B for a structural act** and **64 B for a non-structural one**
(`ActToolTests`). The plan's original figure was 300 B, written before anything
could be measured, and it is unreachable for any act that changes the tree: an
act adding two nodes must name them, their roles, their text and their
structural paths, which is ~400 B of the 498 — content, not envelope. Four
rounds of compaction took it from 702 B to 498 B and could go no further without
dropping information the verdict layer reads. Owner decision 2026-08-12; the
reasoning is `no.md` #41.

`include_tree: true` adds the whole after-tree as a `CompactTree` under `tree`.
Off by default — an agent in an act loop wants what changed, and the after-tree
is reconstructible: replaying the delta onto the before-tree reproduces it
exactly, which `ActToolTests` asserts against a real act.

### `actions(scenario)`

Which probes accept an act, and which verbs each accepts. Call it BEFORE `act`.

```json
{"advanced-toggle": ["tap", "toggle"]}
```

The result is an object keyed by probe id. **A probe absent from the map is not
actionable** — there is no `false` entry, because on a real screen most probes
are not drivable and paying to say so per node is the distribution error
`no.md` #41 records for the compact tree.

The reason this tool exists is that `role` cannot answer the question. A role is
a claim about what a node IS; actionability is a claim about what the harness
can DRIVE, and a probe may carry `role: "toggle"` with no binding behind it —
`act` then refuses it, correctly. Without `actions`, a caller discovers
actionability only by being refused.

Verbs are the ones that will be ACCEPTED, not the storage's name: a bool binding
reports `["tap", "toggle"]` because a tap on a bool with no separate handler
falls through to a toggle.

An empty object `{}` means the scenario binds no actions at all — a real answer,
not a failure.

### `sweep(scenario, variants?)`

One verdict per variant cell, plus a markdown rule × variant grid.

A cell that could not render carries `status: null` and an `error`, and makes
the whole sweep not-clean. "We could not look" must never read as "we looked and
it was fine".

### `baseline_diff(scenario)`

Findings only, no write.

### `judge_appkit(runner, subject?, include_tree?)`

Judge an AppKit/Swift screen headlessly — no screenshot, no Automator, no
running app and no visible window.

Unlike every other tool here it takes **`runner`, not `scenario`**: it drives a
small executable the *developer* builds (a few lines linking `VerdictUIAppKit`
that names their `NSViewController`s), so there is no registry entry to name.
It lays the view out off-screen and judges the resulting tree with the same
rules every other verb uses.

Omit `subject` to list the screens the runner exposes. `include_tree` returns
the semantic tree instead of a verdict, off by default because a full tree per
call is the token cost that makes an agent loop unaffordable.

**A FAILING verdict is a SUCCESSFUL call.** `isError` is set only when the
runner could not be run or did not emit a tree — the same
could-not-look / looked-and-it-failed distinction the CLI's exit codes draw.

### `baseline_accept` — DELIBERATELY NOT SERVED

The daemon and the MCP surface do not expose it, and `DaemonTests` asserts the
absence so adding it means deleting a test and saying why.

Accepting a baseline REPLACES the record of what a screen should look like — the
single destructive operation in the product. A long-running socket-reachable
process driven by an agent is the wrong place for it. `verdictui baseline
--update --accept` stays a foreground command a human runs and watches, which
prints the delta before writing and logs the superseded content's SHA-256 to
`logs/baseline-audit.log`.

The plan's Wave 7 task list names `baseline_accept(scenario, confirm: true)` as
an MCP tool with a confirmation flag. That was reconsidered against SD4: a
`confirm: true` field is a flag an agent can set as easily as omit, so it is a
speed bump rather than a gate, and the thing it guards is unrecoverable. The
exit-gate item "destructive baseline-accept requires explicit confirm" is met
more strongly by not offering the verb at all.
