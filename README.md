# VerdictUI

**Stop screenshotting your SwiftUI app to find out whether it's right.**

VerdictUI makes SwiftUI testify about itself. Instead of the
screenshot–wait–click–confirm cycle, it emits a ground-truth semantic tree
during the layout pass and turns it into a machine-readable verdict with cited
evidence — in about 48 ms, with no window server, no permissions, and no sleeps.

```console
$ verdictui verify demo-undersized-tap-target
{
  "status": "FAIL",
  "findings": [{
    "rule": "tap-target",
    "nodeID": "dismiss-button",
    "severity": "error",
    "message": "'dismiss-button' is 18 x 18 pt, below the 28 x 28 pt minimum hit size",
    "suggestion": "grow the control or add .frame(minWidth: 28, minHeight: 28)"
  }],
  "schemaVersion": "1.1"
}
```

385 bytes. A screenshot of the same screen costs an agent
[1 365–2 117 vision tokens](docs/benchmarks.md#token-cost) — and yields a
picture it still has to interpret.

## Why

AI agents and developers verify SwiftUI work by screenshotting, sleeping,
clicking, and screenshotting again. It is slow, flaky, permission-gated, and
blind between frames. XCUITest's idle-wait is documented-broken; SwiftUI has no
`pumpAndSettle`.

So the loop is not "look at the screen and guess". It is **act, settle, and get
a verdict that names the node and the rule.**

## Install

```bash
brew install medlars/tap/verdictui        # once the tap is published
# or
git clone https://github.com/medlars/verdictui && cd verdictui
swift build -c release --product verdictui
```

Add the engine to a package:

```swift
.package(url: "https://github.com/medlars/verdictui", from: "1.0.0")
// then depend on "VerdictUIProbe", and "VerdictUIMacroSupport" for @Verifiable
```

## Use it from an agent

VerdictUI ships an MCP server, which is the point of the whole thing — an agent
asks for a verdict instead of a screenshot.

```json
{ "mcpServers": { "verdictui": { "command": "/path/to/verdictui", "args": ["mcp"] } } }
```

Seven tools: `list_scenarios`, `render`, `verify`, `act`, `focus`, `sweep`,
`baseline_diff`. Warm round trip ≈ 11 ms.

## Use it from Swift

```swift
import VerdictUIMacroSupport

@Verifiable
struct SettingsRow: View {
    @State private var enabled = true

    var body: some View {
        HStack {
            Text("Notifications")
            Spacer()
            Toggle("", isOn: $enabled)
        }
    }
}
```

That is the whole adoption cost. The macro probes the view's elements; the
kernel does the rest. Manual probes (`.verdictProbe(id:)`) are available where
you want control, and the two compose — see [docs/adoption.md](docs/adoption.md).

## How it works

Three concentric loops, fast to slow, each keeping the one above it honest:

| Loop | Mechanism | Speed | Answers |
|---|---|---|---|
| **Inner** (every edit) | In-process Layout-protocol probes + virtual-clock settling | ~48 ms | Is the layout right? |
| **Middle** (per scenario) | Accessibility tree + real events + windowless pixel diff, reconciled against the inner tree | ~1 s | Is the fast channel lying? |
| **Outer** (release) | Thin orchestrated XCUITest | minutes | Does it launch? Do permissions work? |

**Divergence between the loops is itself the bug detector.** When the
in-process tree and the AX witness disagree, that disagreement is reported
rather than resolved in favour of whichever is convenient.

## What it does not do

An honest list, because a verification tool that oversells is worse than none:

- **It cannot tell you the app launched.** The inner loop renders windowlessly
  and never starts a process. That is XCUITest's job and VerdictUI keeps it.
- **It cannot judge aesthetics.** It reports `truncated-text` on `title-label`;
  it has no opinion about your kerning.
- **It requires instrumentation.** A screenshot works on any app on screen.
  VerdictUI needs the view to be reachable, and trades that generality for
  evidence.

Full numbers, including the columns where the other approaches win, are in
[docs/benchmarks.md](docs/benchmarks.md).

## Verify your own app

```bash
verdictui list                            # scenarios discovered
verdictui verify <scenario>               # exit 0 pass, 1 fail, 2 no verdict possible
verdictui verify <scenario> --cross-validate   # reconcile against the AX witness
verdictui sweep <scenario>                # locales x type sizes x colour schemes
verdictui baseline <scenario> --accept    # record what "correct" looks like
```

Exit codes are three-valued on purpose: a tool that reports "not passing" for
both a broken layout and an unreadable scenario forces callers to treat
infrastructure faults as product defects.

## Project health

```bash
bash scripts/dev.sh                          # setup + build + test
swift test -Xswiftc -warnings-as-errors      # the suite as CI runs it
python3.14 scripts/verdictui-pm.py --quick   # Grade A expected
```

775 Swift + 267 Python tests, zero warnings under `-warnings-as-errors`,
113 mutation guards, 4 SLOs gated in the pipeline.

## Layout

- `Sources/VerdictUIKernel` — semantic tree, 12 rules, verdict schema
  (platform-pure: no SwiftUI, no AppKit, no CoreGraphics)
- `Sources/VerdictUIProbe` — instrumentation runtime, oracle host, harness,
  sweeps, pixel channel
- `Sources/VerdictUIMacros` — `@Verifiable`, `#VerdictScenario`
- `Sources/VerdictUIWitness` — the AX cross-validation channel
- `Sources/VerdictUICLICore` — CLI, JSON-RPC daemon, MCP server

## Documentation

| | |
|---|---|
| [Adoption guide](docs/adoption.md) | Three tiers, migration, macro limitations |
| [Benchmarks](docs/benchmarks.md) | Measured numbers, with the loss column |
| [SLOs](docs/slo.md) | The four gated service levels |
| [Runbook](docs/runbook.md) | Operating the CLI, daemon and MCP server |
| [`no.md`](no.md) | What we deliberately did *not* do, and what was measured |
| [`.decisions/`](.decisions/INDEX.md) | Architecture decision records |

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). The short version: thresholds are
measured rather than chosen, every guard carries a mutation row, and a green
test suite is not evidence about the shipped artifact — run the binary.

## Licence

MIT — see [LICENSE](LICENSE). Everything that runs on one developer's machine is
open, permanently; see [ADR 2026-021](.decisions/2026-021-the-open-core-boundary-is-the-machine-not-the-feature.md)
for where the line falls and why it is drawn on the machine rather than the
feature.
