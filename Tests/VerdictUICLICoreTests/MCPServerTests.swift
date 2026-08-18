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

    /// Every served tool is documented in the published contract.
    ///
    /// `contracts/mcp-tools.md` is what a client author reads, and nothing
    /// previously compared it to the catalog — so a tool could ship served but
    /// undocumented (invisible to every consumer) or documented but unserved
    /// (`no.md` #34, where a runbook described a transport that did not exist).
    /// Both are silent, and both are the same defect: a published claim with no
    /// test behind it.
    ///
    /// Asserted in BOTH directions. Checking only "every tool is documented"
    /// would stay green against a doc listing tools nobody serves.
    func testEveryServedToolIsDocumentedAndEveryDocumentedToolIsServed() throws {
        let contract = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // VerdictUICLICoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("contracts/mcp-tools.md")
        let text = try String(contentsOf: contract, encoding: .utf8)

        // Headings are `### \`name(args)\`` — take the name up to `(` or the
        // closing backtick. `baseline_accept` is documented precisely as NOT
        // served, so it is excluded by the same heading that says so.
        var documented: Set<String> = []
        for line in text.split(separator: "\n") where line.hasPrefix("### `") {
            let body = line.dropFirst(5)
            let name = String(body.prefix { $0 != "(" && $0 != "`" })
            guard !line.contains("NOT SERVED") else { continue }
            documented.insert(name)
        }

        // The control: if the parse found nothing, every assertion below is
        // vacuously satisfiable and this test would pass against an empty doc.
        XCTAssertGreaterThan(
            documented.count, 3,
            "parsed \(documented.count) tool headings out of the contract — the parser is "
                + "broken, and every comparison below would be meaningless"
        )

        let served = Set(MCPServer.tools.map(\.name))

        XCTAssertEqual(
            served.subtracting(documented), [],
            "these tools are SERVED but absent from contracts/mcp-tools.md — a client author "
                + "reading the contract cannot discover them"
        )
        XCTAssertEqual(
            documented.subtracting(served), [],
            "these tools are DOCUMENTED but not served — a client following the contract "
                + "would call them and get 'unknown method'"
        )
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
