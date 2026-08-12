import Foundation
import VerdictUIDemoScenarios
import VerdictUIKernel
import VerdictUIProbe
import XCTest

@testable import VerdictUICLICore

/// The MCP tool catalog and its dispatch.
///
/// The catalog is the product's advertised surface, so the questions worth
/// asking are about AGREEMENT: does every tool a client can see resolve to a
/// method something actually serves, and does the destructive verb stay absent.
final class MCPServerTests: XCTestCase {
    override func invokeTest() {
        autoreleasepool { super.invokeTest() }
    }

    /// A tool advertised but not served is the worst failure this surface has:
    /// a client sees a verb, calls it, and gets "unknown method".
    @MainActor
    func testEveryAdvertisedToolResolvesToADaemonMethodThatAnswers() async throws {
        let engine = VerdictEngine(
            registry: DemoScenarios.registry,
            baselines: BaselineStore.standard(
                root: URL(fileURLWithPath: NSTemporaryDirectory())
            )
        )

        for tool in MCPServer.tools {
            let method = try XCTUnwrap(
                MCPServer.daemonMethod(for: tool.name),
                "tool '\(tool.name)' is advertised but maps to no daemon method"
            )

            // A scenario is supplied for every tool that declares one required,
            // so "unknown method" cannot hide behind a missing-argument error.
            let response = await VerdictDaemon.handle(
                DaemonRequest(
                    method: method,
                    scenario: tool.inputSchema.required.contains("scenario")
                        ? CleanSettingsScenario.scenarioName
                        : nil
                ),
                engine: engine
            )

            XCTAssertNotEqual(
                response.error,
                "unknown method '\(method)'",
                "tool '\(tool.name)' maps to '\(method)', which the daemon does not serve"
            )
        }
    }

    /// The destructive verb is absent, asserted rather than merely documented.
    func testNoToolAcceptsABaseline() {
        let names = MCPServer.tools.map(\.name)

        for forbidden in ["baseline_accept", "baseline_update", "accept_baseline"] {
            XCTAssertFalse(
                names.contains(forbidden),
                "'\(forbidden)' is advertised. Accepting a baseline REPLACES the record of "
                    + "what a screen should look like, and a `confirm: true` argument is a "
                    + "boolean an agent sets as easily as it omits — a speed bump, not a gate. "
                    + "If this is being added deliberately, delete this test and say why."
            )
        }

        // The control: the read-only baseline verb IS present, so "no baseline
        // tool" is not satisfied by a catalog that dropped baselines entirely.
        XCTAssertTrue(names.contains("baseline_diff"), "the read-only diff must still be offered")
    }

    /// Every tool's schema names the arguments its method actually needs.
    func testToolsRequiringAScenarioSaySoInTheirSchema() {
        for tool in MCPServer.tools {
            let method = MCPServer.daemonMethod(for: tool.name)
            // Read from the dispatcher's own set rather than restating it: a
            // hand-copied list here is a second implementation of one rule, and
            // it went stale the moment `act` was added — the schema and the
            // dispatcher then disagreed about what a client must send, which is
            // exactly the divergence this test exists to catch.
            let methodNeedsScenario = VerdictDaemon.methodsNeedingAScenario
                .contains(method ?? "")

            XCTAssertEqual(
                tool.inputSchema.required.contains("scenario"),
                methodNeedsScenario,
                "tool '\(tool.name)' declares required=\(tool.inputSchema.required) but its "
                    + "method '\(method ?? "nil")' "
                    + (methodNeedsScenario ? "needs" : "does not need")
                    + " a scenario — a client following the schema would call it wrongly"
            )
        }
    }

    /// The catalog encodes as the JSON an MCP client expects.
    func testTheCatalogEncodesAsValidToolDescriptors() throws {
        let data = try VerdictOutput.encoder(pretty: false).encode(MCPServer.tools)
        let decoded = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        let objects = try XCTUnwrap(decoded)

        XCTAssertEqual(objects.count, MCPServer.tools.count)
        for object in objects {
            XCTAssertNotNil(object["name"])
            XCTAssertNotNil(object["description"])
            let schema = try XCTUnwrap(object["inputSchema"] as? [String: Any])
            XCTAssertEqual(schema["type"] as? String, "object")
        }
    }
}
