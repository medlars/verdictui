import Foundation
import VerdictUIDemoScenarios
import VerdictUIKernel
import XCTest

@testable import VerdictUICLICore

/// Drives the real MCP loop over pipes.
///
/// The loop is where the framing bugs live — partial frames, notifications that
/// must not be answered, ids echoed in the wrong shape — and none of that is
/// reachable from a test that only calls the catalog. `MCPServerTests` covers
/// what the tools ARE; this covers what happens on the wire.
@available(macOS 13, *)
@MainActor
final class MCPTransportTests: XCTestCase {
    @MainActor
    private func engine() -> VerdictEngine {
        VerdictEngine(
            registry: DemoScenarios.registry,
            baselines: BaselineStore.standard(
                root: URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("verdictui-mcp-\(UUID().uuidString)")
            )
        )
    }

    /// Feed `lines` through the real `serve` loop and collect the replies.
    ///
    /// Runs the loop against genuine `FileHandle` pipes rather than calling
    /// `answer` directly, because the loop's own framing is the subject: a test
    /// that called `answer` per line would pass against a `serve` that never
    /// split on newlines at all.
    @MainActor
    private func exchange(
        _ lines: [String],
        seedBaselineFor scenario: String? = nil
    ) async throws -> [[String: Any]] {
        let input = Pipe()
        let output = Pipe()
        let verdictEngine = engine()

        if let scenario {
            let tree = try await verdictEngine.render(scenario: scenario)
            try verdictEngine.baselines.update(scenario: scenario, tree: tree, accepted: false)
        }

        let payload = Data(lines.map { $0 + "\n" }.joined().utf8)
        input.fileHandleForWriting.write(payload)
        try input.fileHandleForWriting.close()

        await MCPTransport(engine: verdictEngine)
            .serve(input: input.fileHandleForReading, output: output.fileHandleForWriting)
        try output.fileHandleForWriting.close()

        let data = output.fileHandleForReading.readDataToEndOfFile()
        return
            String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) }
            .compactMap { $0 as? [String: Any] }
    }

    // MARK: - Handshake

    func testInitializeReportsTheProtocolAndServerIdentity() async throws {
        let replies = try await exchange([#"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#])

        XCTAssertEqual(replies.count, 1)
        let result = try XCTUnwrap(replies[0]["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, MCPTransport.protocolVersion)
        let info = try XCTUnwrap(result["serverInfo"] as? [String: Any])
        XCTAssertEqual(info["name"] as? String, "verdictui")
        XCTAssertEqual(info["version"] as? String, SchemaVersion.current)
    }

    /// The handshake a REAL client sends, params and all.
    ///
    /// The test above passes `initialize` with no `params` key, which is the one
    /// spelling that happens to decode: `MCPRequest.params` was typed as the
    /// `tools/call`-specific `MCPCallParams`, whose `name` is non-optional, so a
    /// present-but-differently-shaped `params` failed to decode the ENVELOPE and
    /// the message never reached the `initialize` handler at all. Every client in
    /// existence sends `protocolVersion`/`capabilities`/`clientInfo` here, so the
    /// server answered the first message of every real session with a parse error
    /// while its own suite reported the handshake working.
    ///
    /// The `tools/list` after it is the control: it carries no params at all, so
    /// a server that had stopped answering everything could not pass this.
    func testTheHandshakeARealClientSendsIsAnswered() async throws {
        let replies = try await exchange([
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"probe","version":"1"}}}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
        ])

        XCTAssertEqual(replies.count, 2)
        XCTAssertNil(
            replies[0]["error"],
            "the first message of every real MCP session carries params; rejecting it means no "
                + "client can complete a handshake: \(replies[0])"
        )
        let result = try XCTUnwrap(replies[0]["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, MCPTransport.protocolVersion)
        XCTAssertNotNil(replies[1]["result"], "control: a paramless request still answers")
    }

    /// A notification — no `id` — must produce NO reply.
    ///
    /// MCP clients send `notifications/initialized` during handshake. A server
    /// that answers it puts an unexpected message on the wire, which strict
    /// clients treat as a protocol error and which presents to a user as "the
    /// server never finished starting". The `tools/list` after it is the
    /// control: without it, a `serve` that wrote nothing at all would pass.
    func testANotificationIsNotAnswered() async throws {
        let replies = try await exchange([
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":7,"method":"tools/list"}"#,
        ])

        XCTAssertEqual(
            replies.count,
            1,
            "exactly one reply: the notification is owed none, the request is owed one"
        )
        XCTAssertEqual(replies[0]["id"] as? Int, 7)
    }

    /// The catalog reaches the wire intact.
    func testToolsListReturnsTheWholeCatalog() async throws {
        let replies = try await exchange([#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#])

        let result = try XCTUnwrap(replies[0]["result"] as? [String: Any])
        let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])
        XCTAssertEqual(
            Set(tools.compactMap { $0["name"] as? String }),
            Set(MCPServer.tools.map(\.name)),
            "every advertised tool must arrive on the wire"
        )
        for tool in tools {
            XCTAssertNotNil(
                tool["inputSchema"],
                "MCP requires an inputSchema per tool: \(tool["name"] ?? "?")"
            )
        }
    }

    // MARK: - Tool calls

    /// A FAILING verdict is a SUCCESSFUL call.
    ///
    /// The single most important assertion in this file. `isError` reports
    /// whether the tool could ANSWER, never what the answer was — an agent that
    /// conflated them would retry a real layout defect as a transport fault and
    /// report an outage as a UI bug. Paired with the passing scenario below so
    /// "isError is false" cannot be satisfied by a server that never sets it.
    func testAFailingVerdictIsNotAnError() async throws {
        let replies = try await exchange([
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":"#
                + #"{"name":"verify","arguments":{"scenario":"demo-offscreen-button"}}}"#
        ])

        let result = try XCTUnwrap(replies[0]["result"] as? [String: Any])
        XCTAssertEqual(
            result["isError"] as? Bool,
            false,
            "the tool answered — the UI being wrong is the ANSWER, not a failure to produce one"
        )
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        XCTAssertTrue(
            text.contains("offscreen"),
            "the verdict must carry the finding that failed it: \(text)"
        )
    }

    /// An unrenderable scenario IS an error — the other half of the contract.
    func testAnUnknownScenarioIsReportedAsAToolError() async throws {
        let replies = try await exchange([
            #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":"#
                + #"{"name":"verify","arguments":{"scenario":"no-such-scenario"}}}"#
        ])

        let result = try XCTUnwrap(replies[0]["result"] as? [String: Any])
        XCTAssertEqual(
            result["isError"] as? Bool,
            true,
            "no verdict could be produced, so the tool could not answer"
        )
        XCTAssertNil(
            replies[0]["error"],
            "a well-formed call that failed is a TOOL error, not a JSON-RPC error — "
                + "reporting it as protocol-level tells the agent its own message was malformed"
        )
    }

    func testAnUnknownToolIsReportedAsAToolError() async throws {
        let replies = try await exchange([
            #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"drop_database"}}"#
        ])

        let result = try XCTUnwrap(replies[0]["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
    }

    /// Every advertised tool actually runs over the transport.
    ///
    /// `MCPServerTests` proves each tool NAMES a daemon method; this proves the
    /// method answers when driven through the wire. A catalog whose entries
    /// resolve to methods that then fail is the same defect one layer down.
    func testEveryAdvertisedToolAnswersOverTheWire() async throws {
        // Argument values are looked up per REQUIRED name, so a tool that gains
        // a required argument fails HERE — at the lookup — rather than silently
        // being driven with a partial call that the tool then rejects for its
        // own reasons. `act` needs a probe that exists on the scenario used, so
        // it is driven against the toggle rather than the clean settings screen.
        let valuesByName: [String: String] = [
            "scenario": #""demo-toggle-layout""#,
            "action": #""toggle""#,
            "probe": #""advanced-toggle""#,
        ]

        for tool in MCPServer.tools {
            var pairs: [String] = []
            for name in tool.inputSchema.required.sorted() {
                let value = try XCTUnwrap(
                    valuesByName[name],
                    "\(tool.name) requires '\(name)', which this test has no value for — add "
                        + "one rather than dropping the argument, or the tool is driven with a "
                        + "call it was always going to refuse"
                )
                pairs.append(#""\#(name)":\#(value)"#)
            }
            let arguments =
                pairs.isEmpty ? "" : #","arguments":{"# + pairs.joined(separator: ",") + "}"
            let replies = try await exchange(
                [
                    #"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":"#
                        + #"{"name":"\#(tool.name)"\#(arguments)}}"#
                ],
                seedBaselineFor: tool.name == "baseline_diff"
                    ? ToggleLayoutScenario.scenarioName : nil
            )

            let result = try XCTUnwrap(
                replies.first?["result"] as? [String: Any],
                "\(tool.name) produced no result"
            )
            XCTAssertEqual(
                result["isError"] as? Bool,
                false,
                "\(tool.name) could not answer: \(result["content"] ?? "no content")"
            )
        }
    }

    // MARK: - Framing

    /// A request id echoes back in the SHAPE it arrived in.
    ///
    /// JSON-RPC allows a string or a number, and a client that sent `3` cannot
    /// match a reply carrying `"3"` — so it hangs waiting for a response it
    /// already received.
    func testAStringIdEchoesAsAStringAndANumberAsANumber() async throws {
        let replies = try await exchange([
            #"{"jsonrpc":"2.0","id":"abc","method":"ping"}"#,
            #"{"jsonrpc":"2.0","id":42,"method":"ping"}"#,
        ])

        XCTAssertEqual(replies.count, 2)
        XCTAssertEqual(replies[0]["id"] as? String, "abc")
        XCTAssertNil(replies[0]["id"] as? Int, "a string id must not arrive as a number")
        XCTAssertEqual(replies[1]["id"] as? Int, 42)
        XCTAssertNil(replies[1]["id"] as? String, "a numeric id must not arrive as a string")
    }

    /// Several requests in one write are answered in order.
    func testMultipleFramesInOneWriteAreEachAnswered() async throws {
        let replies = try await exchange([
            #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"ping"}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"ping"}"#,
        ])

        XCTAssertEqual(replies.compactMap { $0["id"] as? Int }, [1, 2, 3])
    }

    /// Malformed JSON gets a parse error, not silence.
    ///
    /// Silence is indistinguishable from a hung server, and that is the one
    /// diagnosis a client cannot make from the outside.
    func testMalformedJSONIsAnsweredWithAParseError() async throws {
        let replies = try await exchange(["this is not json"])

        let error = try XCTUnwrap(replies.first?["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32700, "JSON-RPC's parse-error code")
    }

    /// A blank line is skipped rather than answered.
    func testBlankLinesAreIgnored() async throws {
        let replies = try await exchange(["", #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#, ""])

        XCTAssertEqual(replies.count, 1, "only the real request is owed a reply")
    }

    /// A tree arrives in the COMPACT form.
    ///
    /// `CompactTree` exists because a full `SemanticNode` tree costs several
    /// times an agent's per-message budget, and the transport is the only place
    /// that saving can be applied. Asserted on a structural key rather than a
    /// byte count so it cannot pass by rendering nothing.
    func testARenderedTreeUsesTheCompactWireForm() async throws {
        let replies = try await exchange([
            #"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":"#
                + #"{"name":"render","arguments":{"scenario":"demo-clean-settings"}}}"#
        ])

        let result = try XCTUnwrap(replies[0]["result"] as? [String: Any])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        let tree = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        )

        XCTAssertNotNil(
            tree["parents"],
            "the compact form is parallel arrays plus a parent index; got keys "
                + "\(tree.keys.sorted())"
        )
    }
}
