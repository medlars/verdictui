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
→ {"id":1,"jsonrpc":"2.0","result":{"capabilities":{"tools":{}},"protocolVersion":"2024-11-05","serverInfo":{"name":"verdictui","version":"1.0"}}}
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

### `render(scenario)`

Returns the semantic tree. Wire form is `CompactTree` — parallel arrays plus a
parent index, with repeated strings interned.

Measured on the demo catalog: 362–839 B compact against 491–1448 B nested, all
inside the 2 KB budget. The format carries `textMetrics` and `structuralPath`
deliberately; dropping them made every tree fail its round trip, and worse,
`TruncationRule` reads `textMetrics` — a verdict computed from a lossy wire form
reports a clean screen for a clipped label.

`truncated: true` appears when a tree was cut to fit. It is named on the wire
rather than inferred, because a truncated tree that looks complete is a verdict
about a screen nobody saw all of.

### `verify(scenario, baseline?)`

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

### `sweep(scenario, variants?)`

One verdict per variant cell, plus a markdown rule × variant grid.

A cell that could not render carries `status: null` and an `error`, and makes
the whole sweep not-clean. "We could not look" must never read as "we looked and
it was fine".

### `baseline_diff(scenario)`

Findings only, no write.

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
