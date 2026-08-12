# Dogfood session — the first real usage is the acceptance test

> Wave 7 exit gate, item 1: *"End-to-end agent session documented: edit → verify
> FAIL (evidence cited) → fix → verify PASS, no screenshots involved."*
>
> Captured 2026-08-12 against `.build/debug/verdictui` built from the commit this
> file lands in. Every command below was run; every output is pasted verbatim, not
> reconstructed. Timestamps in the JSON are the real ones.

## What this proves, and what it does not

It proves the loop the product exists for closes **without a screenshot, a
window server, or a human looking at a screen**: a layout defect is introduced by
an ordinary source edit, named by the engine with the rule and node that caught
it, fixed from the engine's own suggestion, and confirmed gone.

It does not prove anything about a real third-party app. The subject is
`demo-clean-settings`, this repo's false-positive guard — chosen deliberately,
because a scenario that *starts* clean is the only one where a new finding can be
attributed to the edit rather than to a defect that was already there.

## 0. Baseline — the screen is right

```console
$ .build/debug/verdictui verify demo-clean-settings; echo "exit=$?"
{"findings":[],"scenario":"demo-clean-settings","schemaVersion":"1.0","status":"PASS","timestamp":"2026-08-12T04:38:53Z","timing":{"evaluateMs":0.258417}}
exit=0
```

Exit 0, zero findings. This is the control: without it, the FAIL below would be
evidence that the scenario is broken, not that the edit broke it.

## 1. The edit — a plausible one, not a strawman

In `Sources/VerdictUIDemoScenarios/CleanSettingsScenario.swift`, the Save button's
height stops deriving from the shared `buttonSize` and takes a literal instead:

```diff
                 Button("Save") {}
                     .buttonStyle(.plain)
-                    .frame(width: Self.buttonSize.width, height: Self.buttonSize.height)
+                    .frame(width: Self.buttonSize.width, height: 24)
                     .verdictProbe("save-button", role: .button, text: "Save")
```

This is the shape of the defect that motivates the product. It compiles, it
raises no warning under `-warnings-as-errors`, it looks *tidier* than what it
replaced, and on screen it is a button four points shorter than its neighbour —
which is to say, invisible to review and invisible to every existing test. The
only thing wrong with it is that 24 pt is below the macOS 28 pt minimum hit
target, so the control becomes measurably harder to click for anyone without a
steady hand.

## 2. Verify → FAIL, with the evidence cited

```console
$ swift build --product verdictui   # BUILD=0
$ .build/debug/verdictui verify demo-clean-settings; echo "exit=$?"
exit=1
```

```json
{
  "findings": [
    {
      "message": "'save-button' is 96 x 24 pt, below the 28 x 28 pt minimum hit size",
      "nodeID": "save-button",
      "rule": "tap-target",
      "severity": "error",
      "suggestion": "grow the control or add .frame(minWidth: 28, minHeight: 28)"
    }
  ],
  "scenario": "demo-clean-settings",
  "schemaVersion": "1.0",
  "status": "FAIL",
  "timestamp": "2026-08-12T04:39:47Z",
  "timing": {"evaluateMs": 0.323542}
}
```

Read what an agent receives here, because this is the product:

- **`nodeID: "save-button"`** — *which* element, by the id the author wrote. Not
  "an element near the bottom right".
- **`rule: "tap-target"`** — *why* it is wrong, as a named rule that can be looked
  up, suppressed, or argued with.
- **the measurement, both sides** — `96 x 24` against `28 x 28`. The agent does
  not have to trust the verdict; it can check the arithmetic.
- **`suggestion`** — the edit to make, in the API the author is already using.
- **`exit=1`** — a verdict was produced and it FAILED. Distinct from exit 2, which
  means no verdict could be produced and therefore says nothing about any UI.

`evaluateMs: 0.32`. No screenshot was taken, no window was opened, and nothing
was clicked.

## 3. The same failure through the MCP surface

The CLI is for humans. An agent reaches the engine over stdio, and it must get
the same answer — a second implementation is how three surfaces drift into three
answers:

```console
$ printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"claude-code","version":"1"}}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"verify","arguments":{"scenario":"demo-clean-settings"}}}' \
  | .build/debug/verdictui mcp
```

Two replies for three messages — the notification is owed none. The tool result:

```
isError: false
{"findings":[{"message":"'save-button' is 96 x 24 pt, below the 28 x 28 pt minimum hit size",
  "nodeID":"save-button","rule":"tap-target","severity":"error",
  "suggestion":"grow the control or add .frame(minWidth: 28, minHeight: 28)"}],
 "scenario":"demo-clean-settings","status":"FAIL", …}
```

**`isError: false` carrying a FAILING verdict** is the contract, not a bug. The
tool could look, and it answered; the answer is that the screen is wrong. A
server that set `isError: true` here would teach an agent to retry a real UI
defect as though it were a transport fault, and to open an infrastructure ticket
about a button.

## 4. Fix from the suggestion, verify → PASS

The suggestion names the fix; reverting the height to the shared constant is the
same thing said in this file's own vocabulary:

```diff
-                    .frame(width: Self.buttonSize.width, height: 24)
+                    .frame(width: Self.buttonSize.width, height: Self.buttonSize.height)
```

```console
$ swift build --product verdictui   # BUILD=0
$ .build/debug/verdictui verify demo-clean-settings; echo "exit=$?"
{"findings":[],"scenario":"demo-clean-settings","schemaVersion":"1.0","status":"PASS","timestamp":"2026-08-12T04:41:08Z","timing":{"evaluateMs":0.235458}}
exit=0

$ git diff --stat Sources/VerdictUIDemoScenarios/CleanSettingsScenario.swift
(no output — the file is byte-identical to where it started)
```

The empty `git diff --stat` matters as much as the PASS. It shows the session
left nothing behind: the transcript is a record of a defect that was planted,
caught, and removed, not of a scenario quietly reshaped until it agreed.

## 5. What the defect cost to find

| | Screenshot loop | This session |
|---|---|---|
| Artifacts a human must look at | 2+ (before/after) | 0 |
| What identifies the element | a position in an image | `save-button` |
| What identifies the defect | a human noticing | `tap-target`, with both measurements |
| Engine time | — | 0.32 ms |
| Permissions required | screen recording | none |

## Warm latency, measured through the real stdio transport

The gate asks for MCP tools under 100 ms warm. Measured on this same binary, one
long-lived `verdictui mcp` process, request/response round trip timed from the
client side (30 samples after 3 warm-up calls):

| Tool | p50 | p95 |
|---|---|---|
| `verify` (renders + judges) | **9.61 ms** | **10.25 ms** |
| `list_scenarios` | 0.08 ms | 0.23 ms |

`verify` is the expensive one because it actually renders the scenario; it sits
an order of magnitude inside the budget. These are client-observed round trips
through pipes, not internal timings — the number an agent would experience.

## A defect this session found, which no test could

The handshake above is written the way a real client sends it, with
`protocolVersion`/`capabilities`/`clientInfo` in `params`. That is not decoration.
When this session first drove the shipped binary, the **first message of every
real MCP session was answered with a parse error**:

```json
{"error":{"code":-32700,"message":"parse error: DecodingError.keyNotFound: Key 'name' not found …"},"jsonrpc":"2.0"}
```

`MCPRequest.params` was typed as the `tools/call`-specific `MCPCallParams`, whose
`name` is non-optional, so a `params` block of any other shape failed to decode
the **envelope** — the message never reached the `initialize` handler, which was
correct and unreachable. Every client in existence would have failed to connect.

The suite did not see it because its handshake test sends `initialize` with **no
`params` key at all**, the one spelling that happens to decode. That is `no.md`
#35's lesson again — a test that builds its input in Swift tests the pair, never
the wire — and it was found in the only way it could be: **by sending real bytes
to the shipped binary**. Fixed by decoding `params` leniently, and pinned by
`MCPTransportTests.testTheHandshakeARealClientSendsIsAnswered`, whose paramless
`tools/list` control means a server that stopped answering everything cannot pass
it.

## Not covered here

The plan's Wave 7 also names an `act` tool returning a `TreeDelta` under a 300 B
budget. It is **unbuilt** — `tools/list` returns exactly `list_scenarios`,
`render`, `verify`, `sweep`, `baseline_diff`, and `contracts/mcp-tools.md`
documents no `act` either, so the catalog, the contract and the CLI agree and
only the plan names it. The delta budget consequently has no subject to measure.
Tracked as **CTS-D47CCD1D**. The tree half of the budget *is* enforced —
`CompactTreeTests.testEveryDemoTreeFitsTheWireBudget`, measured 362–839 B against
2048 B.
