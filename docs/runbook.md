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

The daemon keeps scenario hosts warm so a repeat verify pays only the
render. It answers newline-delimited JSON-RPC on a unix socket at
`~/.verdictui/daemon.sock` (a unix socket, not a TCP port, so filesystem
permissions answer the authorization question).

```bash
# Methods: ping, list, render, verify, sweep, baseline_diff
printf '{"method":"ping"}\n' | nc -U ~/.verdictui/daemon.sock
```

`ok` reports whether the daemon could LOOK, never what it saw — a FAILING
verdict is `ok: true`.

`baseline update` is deliberately NOT served over the socket. It replaces
the record of what a screen should be, and that stays a foreground command
a human runs and watches.

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
