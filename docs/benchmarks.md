# VerdictUI — Benchmarks

> **Measured 2026-08-14** on an Apple Silicon Mac (macOS 26.6, Swift 6, release
> build). Every number below came from a command in this document; none is
> estimated, and where a number could not be measured honestly this report says
> so instead of printing one.
>
> Re-run with the commands in each section. Timings are wall-clock and will vary
> with machine and load — see [Reading these numbers](#reading-these-numbers).

## Summary

| | VerdictUI (MCP, warm) | VerdictUI (CLI, cold) | Screenshot cycle | XCUITest |
|---|---|---|---|---|
| Per-check wall clock | **~11 ms** | 90 ms | 140–160 ms *capture alone* | 286 ms *before the first assertion* |
| Agent tokens per check | **~100** (385 B JSON) | ~100 | **1 365–2 117** (vision) | ~100 (text), plus the wait |
| Flake over 100 runs | **0** | **0** | not measured (see below) | not measured (see below) |
| Answers "is this right?" | yes, with cited node + rule | yes | only if the model reads it correctly | yes, if you wrote the assertion |
| Answers "did the app launch?" | **no** | **no** | yes | **yes** |

The headline is not the wall clock; it is the **token cost and the citation**. A
screenshot costs an agent 1 365–2 117 vision tokens to look at a screen and
still yields a *description*. A VerdictUI verdict costs ~100 tokens and yields
`dismiss-button` violates `tap-target`, 18×18 pt against a 28×28 minimum, with
the fix. That is a 13–20x token reduction and a change of kind in the answer.

The wall-clock column is the *weaker* of the two claims and is presented as
such: 11 ms against 150 ms is real, but an agent's own inference latency dwarfs
both, so a developer will not feel it the way the token bill shows it.

## The five verification tasks

All five run against the demo scenarios shipped in this repo, so anyone can
reproduce them:

| # | Task | Scenario | VerdictUI verdict |
|---|---|---|---|
| 1 | Is the layout clean? | `demo-clean-settings` | PASS, exit 0 |
| 2 | Is a control large enough to tap? | `demo-undersized-tap-target` | FAIL `tap-target` on `dismiss-button` |
| 3 | Is a label truncated? | `demo-truncating-label` | FAIL, cited |
| 4 | Do two elements overlap? | `demo-overlapping-badges` | FAIL, cited |
| 5 | Is anything off-screen? | `demo-offscreen-button` | FAIL, cited |

## Wall clock

### Inner loop — in-process act → settle → verdict (SLO 1)

```bash
swift test --filter HarnessPerformanceTests
```

```
SLO1-PERFORM p50=48.52ms p95=50.46ms mean=48.41ms max=51.03ms n=150
```

**p50 48.52 ms, p95 50.46 ms over 150 samples.** This is the complete cycle:
apply an action, settle the virtual clock, assemble the semantic tree, run every
rule, produce a verdict. The p95/p50 spread of 1.04x is the interesting figure —
it is what "no sleeps anywhere in the harness" buys.

### Warm loop — through the real MCP stdio transport (SLO 3)

```bash
# 1 initialize + 25 verify calls through the shipped binary
bash docs/bench/mcp-batch.sh
```

```
MCP-BATCH replies=26 total=295.4ms per_call=11.36ms
MCP-BATCH replies=26 total=295.1ms per_call=11.35ms
MCP-BATCH replies=26 total=301.1ms per_call=11.58ms
MCP-BATCH replies=26 total=290.7ms per_call=11.18ms
MCP-BATCH replies=26 total=296.8ms per_call=11.41ms
```

**~295 ms for 26 framed JSON-RPC round trips including process start** — about
**11.4 ms per warm verify**, stable to ±0.2 ms across five consecutive runs.

Two notes on how this number was arrived at, because the first attempt was
wrong in the flattering direction. A single unrepeated run read 260 ms
(≈7 ms/call) and the script's own first invocation read 486 ms; **neither is the
figure** — the first is an unrepeated sample and the second is a cold-cache
outlier. Only running it five times separates the two. And 11.4 ms per call is
*higher* than the gated SLO 3 median of 9.24 ms because this measurement
amortises process start across the batch and includes the client-side shell
loop, whereas SLO 3 times the server's response alone. Both are honest; they
answer different questions.

### Cold loop — one CLI invocation per check

```bash
.build/release/verdictui verify demo-clean-settings
```

**90 ms** per run averaged over 100 sequential invocations (8.98 s total). The
gap between 90 ms and the warm 7 ms is process launch and package loading, which
is exactly why the daemon and MCP server exist.

## Token cost

This is the column that matters most for agent use, and it is the one where the
comparison is not close.

A verdict is JSON, measured directly:

```bash
.build/release/verdictui verify demo-clean-settings | wc -c            # 155
.build/release/verdictui verify demo-undersized-tap-target | wc -c     # 385
```

- **PASS verdict: 155 bytes.** ~40 tokens.
- **FAIL verdict with a complete finding: 385 bytes.** ~100 tokens, and it
  contains the node id, the rule, both measurements, the severity and a
  suggested fix.

A screenshot, measured on this machine with `screencapture`, is 3456×2234 and
1.74 MB. Resized to Anthropic's 1568 px longest edge and costed at the
documented `(w×h)/750`:

| Capture | Vision tokens |
|---|---|
| Full screen 3456×2234 | **2 117** |
| App window 1440×900 | **1 728** |
| App window 1280×800 | **1 365** |
| Small window 800×600 | 640 |

**A single screenshot costs 13–20x the tokens of a complete FAIL verdict**, and
after paying them the agent has an image it must interpret — it does not have
`dismiss-button is 18×18 pt against a 28×28 minimum`. A verification loop that
screenshots before and after an action pays that twice per step.

## Flake rate

The exit gate asks for flake over 100 runs, and both directions were measured,
because a flake rate taken only on the passing path proves half of what it
claims.

```bash
# passing direction
for i in $(seq 1 100); do .build/release/verdictui verify demo-clean-settings >/dev/null 2>&1; ...
# failing direction
for i in $(seq 1 100); do .build/release/verdictui verify demo-undersized-tap-target >/dev/null 2>&1; ...
```

| Direction | Result |
|---|---|
| `demo-clean-settings` | **100 PASS / 0 FAIL / 0 error** |
| `demo-undersized-tap-target` | **100 FAIL / 0 PASS / 0 error** |
| Cited evidence on the failing path | **100/100 identical** — `dismiss-button` / `tap-target` every time |

Zero flake in 200 runs. Evidence stability was checked separately from the exit
code deliberately: a rule that returned FAIL for a drifting reason would show a
stable exit code and unstable evidence, and only the second measurement can see
that.

**The screenshot and XCUITest flake columns are not filled in, and that is a
real gap rather than an omission.** Measuring them honestly needs a real app
under a real UI-test harness driven 100 times; this repo has no XCUITest target
(`grep XCUI Package.swift` → nothing), so any number printed here would be
invented. The published literature on XCUITest's `waitForQuiescence` is the
reason the idle-wait problem is worth solving at all, but citing someone else's
flake rate as though it were our measurement is exactly the fabrication this
project's test discipline exists to prevent.

## Where the other approaches win

An honest benchmark has a loss column. This one is not small.

### XCUITest wins on every OS-level truth

VerdictUI's inner loop renders SwiftUI windowlessly, in-process. That is what
makes it 48 ms and permission-free, and it is also what makes it **structurally
blind** to:

- whether the app **launches** at all
- system permission dialogs (camera, location, Accessibility)
- real keyboard and IME input, including dictation
- multi-window, Stage Manager, and Spaces behaviour
- anything involving a second process, or the Dock, or Finder integration

**The fixed cost XCUITest pays is real but so is what it buys.** Measured here:
launching a trivial system app (Calculator) and waiting until it is responsive
took a **median of 286 ms** across 5 runs (242–342 ms) — before a single
assertion, for the simplest possible app. A real app with a login screen is
seconds. VerdictUI does not pay that because it never launches anything, and
therefore never verifies anything about launching.

This is why the architecture keeps XCUITest as a thin outer smoke ring rather
than trying to replace it. Two tools, two questions.

### The screenshot cycle wins on "what does it actually look like"

A verdict says `truncated-text` on `title-label`. A screenshot shows you the
kerning, the colour that clashes, and the thing you did not think to write a
rule for. VerdictUI's answer to this is the pixel channel (Wave 9), which
diffs captured frames structurally — but a diff still only reports *change*, not
*ugliness*. For open-ended aesthetic judgement, a human or a vision model
looking at a picture is the right tool and this one is not.

### Both win when there is no instrumentation

VerdictUI requires the view under test to be reachable — via `@Verifiable`, a
manual probe, or a `#VerdictScenario`. A screenshot works on any app on the
screen, including one you did not write and cannot recompile. That generality is
real and VerdictUI trades it away deliberately for evidence.

## Reading these numbers

- **Timings are from one machine under light load.** The p50 is the number to
  compare across machines; the p95 moves 2x with contention on unchanged code,
  which is why the project gates medians and merely records tails
  (`no.md` #13/#15).
- **Token counts for images are computed from Anthropic's documented
  `(w×h)/750` formula after the 1568 px resize**, not from a live API response.
  The verdict-side counts are byte counts divided by ~3.9 B/token; both are
  approximations of the same order and the 13–20x ratio is robust to either.
- **The comparison is per-check, not per-task.** A real verification task is
  several checks, and the ratios compound.

## Reproducing everything

```bash
swift build -c release --product verdictui
swift test --filter HarnessPerformanceTests        # SLO 1
python3.14 scripts/verdictui-pm.py --quick         # gates SLO 1 + SLO 3 + SLO 4
bash docs/bench/mcp-batch.sh                       # warm MCP batch
bash docs/bench/flake-100.sh                       # both flake directions
```
