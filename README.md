# VerdictUI

**UI verification for your own SwiftUI, AppKit and web products.**

VerdictUI turns measured UI state into PASS or FAIL findings with node IDs and
rule names. A target that cannot be inspected is **unavailable**, never a pass.
Use the macOS workbench, CLI, Swift API or MCP server.

The workbench is a native macOS app with a bundled web interface: choose a
project, declare its checks, watch actual progress and inspect the evidence.
Process animation follows the engine's work; history is stored locally by the
host. No remote web service or account is required.

## Install

```sh
brew install medlars/tap/verdictui
# Build the CLI from source:
swift build -c release --product verdictui
# Build the desktop app with its matching CLI:
bash scripts/build-workbench.sh release
open dist/VerdictUI.app
```

Download published desktop builds from [GitHub releases](https://github.com/medlars/verdictui/releases).
macOS 13 or later is required. Browser checks use an installed compatible Chrome
or Chromium browser. Live native checks depend on the target's Accessibility
support and the operating system's permissions.

## Verify a real project

Create `.verdictui/checks.json` in that project's folder, or edit checks in the
workbench. This example checks a page and its expected visible text:

```json
{"checks":[{"name":"Dashboard","kind":"web","url":"http://127.0.0.1:3000","expectText":"Dashboard"}]}
```

```sh
verdictui check --project /path/to/your/project --pretty
# 0: all declared checks passed; 1: a measured failure; 2: unavailable coverage
```

Checks can name custom SwiftUI scenarios, AppKit runner subjects, web pages or
running macOS application PIDs. An absent or empty declaration cannot certify a
project. A passing run covers its declared checks; it does not imply that every
screen, account or setting has been tested.

For SwiftUI, compile your views into a small runner using the public
`VerdictUICLICore` and `VerdictUIProbe` products. Declare that executable and its
build product in `.verdictui/config.json`. The launcher builds it and serves its
registry through the existing CLI, daemon and MCP protocol. Long-running
consumer sessions rebuild and restart their disposable host when source changes;
a compiler error refuses stale results. Follow the [integration guide](docs/integration.md)
and the separate [consumer package](examples/ConsumerApp).

Without a consumer manifest, `verdictui list` exposes explicitly named demo
scenarios. **Those demos are examples, not coverage of your application.**

## Observe and act

```sh
verdictui web open https://example.com --profile research
verdictui web render --profile research
verdictui web verify --profile research --expect-text 'Example Domain'
verdictui web close --profile research

verdictui live inspect --pid 12345
verdictui live verify --pid 12345 --expect-text 'Settings'
```

Use node IDs from `web render` or paths from `live inspect` for actions. Browser
sessions own separate persistent profiles. Native input targets a specific
process/window without moving the global pointer. Expected text verifies the
observed outcome; posting an input alone is not proof that the intended task
succeeded. See [browser operation](docs/web.md), [native input](docs/native-acting.md)
and the [MCP contract](contracts/mcp-tools.md).

## Connect an agent

```json
{"mcpServers":{"verdictui":{"command":"/absolute/path/to/verdictui","args":["mcp"]}}}
```

The server provides scenario discovery/render/verify/actions, layout sweeps,
baselines and capture, plus `live_inspect`, `live_verify`, `live_act` and
`web_list`, `web_open`, `web_render`, `web_verify`, `web_act`, `web_close`.
Set the client's working directory to your consumer project to use its custom
registry. [The integration guide](docs/integration.md) covers explicit project
routing and warm rebuilds.

## Architecture and evidence

| Path | What it measures | What it needs |
| --- | --- | --- |
| In-process SwiftUI | Probed layout, text metrics, semantic state, variant sweeps | Consumer scenario runner and probes or `@Verifiable` |
| AppKit runner | An app's own view hierarchy and declared subjects | Consumer runner linked to `VerdictUIAppKit` |
| Live macOS | Actual Accessibility tree and observed input outcomes | Running or launched app and available OS access |
| Headless browser | Rendered DOM/layout, accessible controls and trusted input outcomes | Owned Chrome session |
| Cross-validation | Disagreement between instrumented and external evidence | A corresponding witness; demo witness cannot certify custom views |

`VerdictUIKernel` remains platform-pure. It imports no SwiftUI, AppKit or
CoreGraphics. Every verification adapter converges on the same verdict schema.
Semantic rules detect declared problems; they do not judge aesthetic quality or
promise universal XCUITest equivalence. Pixels remain an optional evidence path.
Historical timing measurements are scoped in [benchmarks](docs/benchmarks.md);
there is no universal latency claim across these different paths.

## Develop and verify

```sh
bash scripts/dev.sh
swift test -Xswiftc -warnings-as-errors -Xswiftc -strict-concurrency=complete
python3.14 scripts/verdictui-pm.py --full
python3.14 scripts/product-smoke.py --help
```

The full PM includes separate-package consumer and real built-binary product
checks. Mutation witnesses deliberately break guards and require a named test
to notice. Browser and native fixtures assert their actual observed state;
environment-dependent skips remain unmeasured.

## Documentation

- [Desktop workbench](docs/workbench.md) and [visual design](docs/workbench-design.md)
- [Consumer integration](docs/integration.md), [probe adoption](docs/adoption.md) and [AppKit](docs/appkit.md)
- [Original instruction coverage](docs/instruction-coverage.md) and [consumer adoption census](docs/product-adoption.md)
- [Runbook](docs/runbook.md), [SLOs](docs/slo.md), [signing](docs/signing.md) and [rollback](docs/rollback.md)
- [Architecture decisions](.decisions/INDEX.md) and [measured exclusions](no.md)

MIT. See [LICENSE](LICENSE) and [the machine-boundary decision](.decisions/2026-021-the-open-core-boundary-is-the-machine-not-the-feature.md).
