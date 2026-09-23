# Use your own SwiftUI scenarios from the CLI or MCP

The installed `verdictui` executable cannot discover Swift types inside another
application. Compile a small executable that links your views and supplies their
scenarios to `VerdictUIRunner`. The CLI, daemon and MCP server then use that
registry through the same command handlers; no copied server is required.

`examples/ConsumerApp` is a separate Swift package demonstrating the complete
boundary. Its two scenarios are independent of VerdictUI's demo catalog: one
passes and one deliberately fails the tap-target rule.

```sh
cd examples/ConsumerApp
/path/to/verdictui list
/path/to/verdictui verify consumer-settings   # exit 0
/path/to/verdictui verify consumer-fault      # exit 1, consumer-save evidence
/path/to/verdictui verify missing            # exit 2
```

Add `VerdictUICLICore` and `VerdictUIProbe` as products of your VerdictUI package
dependency. Your executable's entrypoint supplies its registry:

```swift
import VerdictUICLICore
import VerdictUIProbe

@main
struct MyScenarios {
    static func main() async {
        await VerdictUIRunner.main(registry: ScenarioRegistry([
            ScenarioEntry { MySettingsScenario() }
        ]))
    }
}
```

Create `.verdictui/config.json` in your package root:

```json
{"runner": ".build/debug/MyScenarios", "buildProduct": "MyScenarios"}
```

With `buildProduct`, the launcher runs `swift build --package-path <root>
--product=<name> --configuration=debug --jobs 2` before each scenario invocation.
SwiftPM rebuilds only changed dependencies; unchanged invocations use its cache.
Set `configuration` to `release` and point `runner` at the release executable to
use that build. Compiler output goes to stderr, preserving JSON and MCP stdout.
A failed build refuses any old executable; a build exceeding 300 seconds is
terminated and returns exit 2. When launched through the installed tool, MCP and
`daemon start` keep a stable broker process and run the consumer in a disposable
child. Before each request the broker checks project sources/resources, package
configuration and the runner build product. A changed generation stops the old
child, rebuilds incrementally, and initializes a fresh child before answering.
A compile failure returns structured unavailable evidence; the old executable
is never used to answer that request. Unchanged requests reuse the warm child.

If a child dies, the affected request receives unavailable evidence and the next
request starts a new child. Actions are never automatically replayed: input may
have reached the old process before it died. Source changes during a request
also discard its result as unavailable. The public Unix socket/MCP process stays
alive. `daemon stop` and `status` do not require a successful consumer build.
Changing the runner's path requires restarting the broker.

A restarted child loses its in-memory scenario state and owned web sessions.
Previously open web profiles must be reopened; unknown sessions return explicit
unavailable results. Persistent profile files and project baselines remain on
disk. No dynamic library is unloaded in-process.

Omit `buildProduct` for a runner built by Xcode or another build pipeline; then
you own rebuilding it before verification. A missing, nonexecutable or malformed
runner declaration produces exit 2. A
runner that delegates back to the launcher is rejected instead of recursing.
One-shot commands use process replacement. Long-lived MCP/daemon commands use
the broker; compiler output remains on stderr and protocol stdout stays framed.
EOF or termination shuts down its child.
VerdictUI's own repository uses `VerdictUIProjectRunner`, an explicit host for
its self-test registry. Pointing its manifest back to the stock `verdictui`
launcher caused installed MCP clients to fail initialization in a clean checkout.
These self-test scenarios remain tool-development evidence, not consumer coverage.
Invocations from a subdirectory resolve the nearest ancestor manifest and run
with that project root as the working directory. Baselines and pixel artifacts
therefore stay with the declaring project.

For MCP with rebuild monitoring, configure the installed executable and your
client's working-directory setting to the project root. A client that cannot
set a working directory can use a small project-owned wrapper that changes to
that root and executes `verdictui mcp`.

After upgrading the installed executable, reconnect an already-open MCP client.
Replacing the file does not replace a running stdio server or refresh the
client's cached tool catalog. A fresh 1.1.2 connection exposes 18 tools,
including `web_open`, `web_act`, `live_inspect`, `live_verify`, and `live_act`.
An older nine-tool catalog is not evidence that those installed capabilities
are absent. Do not terminate other sessions to refresh one client's connection.

Direct consumer executable configuration is also supported, but deliberately
bypasses the launcher broker and requires an explicit restart after rebuilding:

```json
{"mcpServers":{"my-app":{"command":"/absolute/project/.build/debug/MyScenarios","args":["mcp"]}}}
```

For clients supporting a working directory, the installed `verdictui mcp` with
its working directory set to your project also delegates. Direct executable
configuration should supply `root:` to `VerdictUIRunner.main` when the client
starts outside the project, so persisted artifacts have a stable location.

Each custom registry gets a stable project-specific daemon socket. An explicit
`--socket` overrides it. A consumer's custom registry is independent of the demo
catalog, and `list_scenarios`, `render`, `verify`, `act`, `actions`, `focus`,
`sweep` and `baseline_diff` share that registry. Custom scenarios need their own
action bindings to support `act`; declaring a button role alone is not one.
The external demo witness cannot cross-validate custom scenarios; request only
the inner verification loop until a consumer witness is configured.

Commands that operate on external inputs (`web`, `inspect`, `capture`, `judge`,
`appkit`, and live-app `sweep`) use the installed CLI directly and do not depend
on a scenario runner. With no manifest, scenario commands still expose the
explicitly labelled demonstration catalog. Those fixtures are not coverage of
the application in the current directory.


Verify consumer rebuilds and crash isolation against the actual launcher:

```bash
python3.14 examples/ConsumerApp/verify-integration.py /absolute/verdictui --reload
```

The gate creates a separate package, changes real Swift code while keeping the
same MCP and daemon process, expects a new FAIL verdict, kills only that
broker's child, introduces a compile error to prove stale results are refused,
and repairs the source to recover a PASS. It never mutates another project's
working copy.

Consumer source scanning streams 64 KiB chunks, with a 256 MiB total-input,
100,000-entry, and 10-second limit per scan. Exceeding a limit is unavailable.
Generated build/cache trees (including dist, build, DerivedData, Pods and app
bundles) are excluded; source files and resources remain content-hashed.
