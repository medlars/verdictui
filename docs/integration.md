# Use your own SwiftUI scenarios from the CLI or MCP

The installed `verdictui` executable cannot discover Swift types inside another
application. Compile a small executable that links your views and supplies their
scenarios to `VerdictUIRunner`. The CLI, daemon and MCP server then use that
registry through the same command handlers; no copied server is required.

`examples/ConsumerApp` is a separate Swift package demonstrating the complete
boundary. Its two scenarios are independent of VerdictUI's demo catalog: one
passes and one deliberately fails the tap-target rule.

```sh
swift build --package-path examples/ConsumerApp --product ConsumerScenarios --jobs 2
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
{"runner": ".build/debug/MyScenarios"}
```

Build the runner before invoking the installed CLI. Rebuild it when the views or
scenarios change. VerdictUI does not silently rebuild or load Swift dynamic
libraries; the executable is the version of your application being measured.
A missing, nonexecutable or malformed runner declaration produces exit 2. A
runner that delegates back to the launcher is rejected instead of recursing.
The launcher inherits stdin/stdout/stderr and uses process replacement, so MCP
framing, exit codes and termination signals reach the actual scenario runner.
Invocations from a subdirectory resolve the nearest ancestor manifest and run
with that project root as the working directory. Baselines and pixel artifacts
therefore stay with the declaring project.

For MCP, configure the consumer executable directly (absolute paths are best):

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
