# VerdictUI — Runbook

## Start / Stop

```bash
# Build the CLI (swift test does NOT build executable products)
swift build --product verdictui -Xswiftc -warnings-as-errors

# One-shot verification — no daemon needed
.build/debug/verdictui list
.build/debug/verdictui verify demo-clean-settings --summary
```

Exit codes are three-valued and the third is load-bearing:

| Code | Meaning |
|---|---|
| 0 | the verdict passed |
| 1 | a verdict was produced and FAILED — the UI is wrong |
| 2 | no verdict could be produced — says nothing about any UI |

Never treat 2 as a product defect: it means the tool could not look.

### Daemon

Keeps scenario hosts warm so a repeat verify pays only the render. Answers
newline-delimited JSON-RPC on a unix socket at `~/.verdictui/daemon.sock` — a
unix socket rather than a TCP port, so filesystem permissions answer the
authorization question rather than an auth layer this project would have to
write and get right.

```bash
verdictui daemon start            # foreground; readiness line goes to stderr
verdictui daemon status           # {"running":true,"socket":"…"}
verdictui daemon stop

printf '%s\n' '{"method":"ping","id":"a"}' | nc -U ~/.verdictui/daemon.sock
# → {"id":"a","ok":true,"result":{"pong":"1.0"}}
```

Several frames may be pipelined on one connection; each is answered in order.

`status` probes by CONNECTING, never by checking the socket file exists — a
daemon killed without unwinding leaves the file behind, and a status that read
the filesystem would report a dead daemon as running for as long as that file
survived it. For the same reason a leftover file does not block a restart, while
a LIVE listener is refused as `addressInUse`.

`ok` reports whether the daemon could LOOK, never what it saw — a FAILING
verdict is `ok: true`.

`baseline update` is deliberately NOT served over the socket. It replaces
the record of what a screen should be, and that stays a foreground command
a human runs and watches.

### MCP server

Speaks MCP over stdio, which is what an MCP client expects. Every tool routes
into the same `VerdictDaemon.handle` the CLI and the socket use, so the three
surfaces cannot disagree about what `verify` means.

```bash
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | verdictui mcp
# → the 7-tool catalog: list_scenarios, render, verify, focus, act, sweep, baseline_diff
```

`isError` reports whether the tool COULD ANSWER, never what the answer was: a
scenario whose layout is broken comes back `isError: false` carrying a FAILING
verdict. An agent that conflated the two would retry a real defect as though it
were a transport fault.

Trees are returned in the compact wire form (parallel arrays plus a parent
index, strings interned) — see `contracts/mcp-tools.md`.

Both transports are covered by `stage_transport_smoke`, which drives the built
binary as a subprocess. A library test cannot see a process that refuses to
start (`no.md` #32), and for a whole wave the method surfaces here were green
while nothing bound a socket at all (`no.md` #34).

#### Registering it with an editor

`.mcp.json` at the repo root registers the server for **this project only** —
scoping matters, because a fleet-wide registration would launch this binary in
every session:

```json
{
  "mcpServers": {
    "verdictui": {
      "type": "stdio",
      "command": "<absolute path to this repo>/.build/release/verdictui",
      "args": ["mcp"]
    }
  }
}
```

The `command` must be absolute — an MCP client does not resolve it against the
project directory. Read the live value out of the file rather than copying it
from here, where it would go stale silently:

```bash
python3.14 -c "import json;print(json.load(open('.mcp.json'))['mcpServers']['verdictui']['command'])"
```

It points at the **release** binary, so it survives the debug builds a working
session churns through. Build it once with:

```bash
swift build -c release --product verdictui
```

`.build/` is gitignored and `swift package clean` removes it, so the path can go
stale with no edit to the config and no signal anywhere — an editor reports only
that the server failed to start. Two gates in `Tests/test_verdictui_gates.py`
close that: the args must name a subcommand the CLI declares, and the path must
exist and be executable. Both skip on a checkout where nothing has been built,
because "could not observe" is not "observed and broken".

Verify the registration end to end by driving the exact binary the config names:

```bash
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"probe","version":"1"}}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  | .build/release/verdictui mcp
# → handshake result with serverInfo, then the 7-tool catalog
```

Send the handshake **with its params**, as above. `initialize` with no `params`
key is the one spelling that decodes even when the envelope is broken, so it
cannot tell a working server from one no client can connect to (`no.md` #37).

## Baselines (destructive — read before running)

```bash
verdictui baseline <scenario> --update            # create a FIRST baseline
verdictui baseline <scenario>                     # diff only, writes nothing
verdictui baseline <scenario> --update --accept   # REPLACE an existing one
```

Order matters, and the exit codes were verified by running each line: a
`baseline <scenario>` diff against a scenario with NO recorded baseline exits
**2**, not 0 — "there is no baseline" is a could-not-verify, not a clean diff.
Create one first.

Replacing prints the delta to stderr before writing and appends the
superseded content's SHA-256 to `logs/baseline-audit.log`. Creating a first
baseline needs no `--accept`: a gate that fires on both branches teaches
users to pass the flag reflexively.

To see what was destroyed:

```bash
cat logs/baseline-audit.log
```

## Cross-validation and the Accessibility grant

Cross-validation runs the external witness: a windowed host process whose
`AXUIElement` tree is read and reconciled against the in-process probe tree. It
needs Accessibility permission — but **the grant is not on VerdictUI**.

Accessibility trust is **inherited from the launching process**, so what must be
trusted is whatever runs `verdictui`: Terminal, iTerm2, Xcode, or the CI agent.
An unsigned binary built seconds earlier reads a live cross-process window tree
with no grant of its own (measured 2026-08-12). Granting "VerdictUI" itself is
not a step, and looking for it in the permission list is a dead end.

Grant it to the launching app:

```
System Settings → Privacy & Security → Accessibility → enable your terminal
```

Then confirm — the flag is necessary but **not sufficient**, so confirm by
reading rather than by checking a box:

```bash
swift test --filter WitnessIntegrationTests   # skips loudly if the grant is missing
```

### Why a missing grant never produces a quieter PASS

A verify that asked for cross-validation and could not run it returns a verdict
carrying a `cross-validation-skipped` **warning finding** naming the reason —
never an ordinary PASS, and never a thrown error. The distinction matters in
both directions: a silent PASS would read as "both channels agree" when one
channel never ran, and a thrown error would exit 2 ("no verdict could be
produced") when the in-process verdict is perfectly producible.

The decision is driven by **the read failing**, not by `AXIsProcessTrusted()`.
That flag returned `true` in every failing case measured
(`docs/wave8-ax-findings.md` §3): it reports what was granted, never what is
reachable, so a witness gating on it proceeds confidently onto an empty tree —
and an empty tree is indistinguishable from a scenario that renders nothing.

| Reason in the finding | What to do |
|---|---|
| `no Accessibility permission` | grant it to the launching terminal (above) |
| `published no accessibility-visible window (AXError -25204)` | the host was launched off the GUI session; it must go through LaunchServices, not fork/exec (`no.md` #43) |
| `the witness host process is unavailable` | `swift build` did not produce `verdictui-witness-host` |
| `published no geometry for its hosting group` | the window was read but has no anchor; treat as a witness defect, not a UI one |

## Health Check

```bash
python3.14 scripts/verdictui-pm.py --quick    # Grade A required
```

## Known Failure Modes

| Symptom | Cause | Fix |
|---|---|---|
| `Asynchronous root command needs availability annotation` | the root command reached through a sync `main()` | `@main` in a file NOT named `main.swift` (no.md #32) |
| PM reports `INCONCLUSIVE — runner killed by SIGKILL` | the machine was loaded; the run was terminated, not failed | re-run on an unloaded machine; this is NOT a test regression |
| mutation sweep prints UNNOTICED for a working guard | something wrote to the tree mid-run | run it in the foreground on an exclusive tree (no.md #14/#21) |
| a mutation row scores INCONCLUSIVE | its `new` does not compile, or its test filter matches nothing | keep every binding live (no.md #31); re-point the filter after any test-file split (no.md #33) |
