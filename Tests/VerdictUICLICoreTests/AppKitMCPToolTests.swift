// The MCP half of the AppKit path: `judge_appkit`.
//
// An agent reaches VerdictUI through MCP, not through argv, so a capability
// that exists only as a CLI verb is invisible to the audience this product is
// built for. These tests pin the whole chain an agent traverses: the tool is
// ADVERTISED, it RESOLVES to a daemon method, that method ANSWERS, and the
// answer distinguishes "your UI is wrong" from "I could not look".
import Foundation
import VerdictUIDemoScenarios
import VerdictUIKernel
import XCTest

@testable import VerdictUICLICore

final class AppKitMCPToolTests: XCTestCase {

    private static let defectiveTree = """
        {"id":"root","role":"container",
         "frame":{"x":0,"y":0,"width":400,"height":200},
         "children":[
           {"id":"squeezed","role":"text",
            "frame":{"x":0,"y":0,"width":60,"height":20},
            "text":"a string far wider than sixty points allows",
            "textMetrics":{"intrinsicWidth":375,"renderedLineCount":1,"idealLineCount":1},
            "children":[]}]}
        """

    private static let cleanTree = """
        {"id":"root","role":"container",
         "frame":{"x":0,"y":0,"width":400,"height":200},
         "children":[
           {"id":"roomy","role":"text",
            "frame":{"x":0,"y":0,"width":380,"height":20},
            "text":"short",
            "textMetrics":{"intrinsicWidth":40,"renderedLineCount":1,"idealLineCount":1},
            "children":[]}]}
        """

    private func makeRunner(tree: String) throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("appkit-mcp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("runner")
        let script = """
            #!/bin/bash
            if [ "$1" = "list" ]; then echo "login-form"; exit 0; fi
            cat <<'TREE'
            \(tree)
            TREE
            """
        try script.write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: path.path)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return path.path
    }

    @MainActor
    private func engine() -> VerdictEngine {
        VerdictEngine(
            registry: DemoScenarios.registry,
            baselines: BaselineStore.standard(
                root: FileManager.default.temporaryDirectory
                    .appendingPathComponent("appkit-mcp-env-\(UUID().uuidString)")
            )
        )
    }

    // MARK: - The catalog

    func testTheToolIsAdvertised() {
        XCTAssertTrue(
            MCPServer.tools.contains { $0.name == "judge_appkit" },
            "advertised tools: \(MCPServer.tools.map(\.name))"
        )
    }

    /// An advertised tool that maps to nothing is the failure where a client
    /// sees a verb, calls it, and gets "unknown method".
    func testTheToolResolvesToADaemonMethod() {
        XCTAssertEqual(MCPServer.daemonMethod(for: "judge_appkit"), "judge_appkit")
    }

    /// The schema must REQUIRE the runner. Without it the tool is callable with
    /// no arguments at all, and the failure surfaces from two layers down as a
    /// path error about the empty string.
    func testTheSchemaRequiresARunnerAndNotAScenario() throws {
        let tool = try XCTUnwrap(MCPServer.tools.first { $0.name == "judge_appkit" })
        XCTAssertTrue(tool.inputSchema.required.contains("runner"))
        XCTAssertTrue(tool.inputSchema.properties.keys.contains("subject"))
        // `scenario` is the SwiftUI registry's concept. This tool drives a
        // consumer's own binary and has no registry, so requiring one would make
        // the catalog walk in MCPServerTests supply a name nothing reads.
        XCTAssertFalse(
            tool.inputSchema.required.contains("scenario"),
            "judge_appkit does not take a registry scenario"
        )
    }

    // MARK: - Dispatch

    @MainActor
    func testListingSubjectsThroughTheDaemon() async throws {
        let runner = try makeRunner(tree: Self.cleanTree)
        let response = await VerdictDaemon.handle(
            DaemonRequest(method: "judge_appkit", runner: runner),
            engine: engine()
        )

        XCTAssertTrue(response.ok, response.error ?? "")
        guard case .scenarios(let names)? = response.result else {
            return XCTFail("expected a subject list, got \(String(describing: response.result))")
        }
        XCTAssertEqual(names, ["login-form"])
    }

    /// A FAILING verdict is a SUCCESSFUL call: the tool did its job. `ok` reports
    /// whether the daemon could ANSWER, never what the answer was — an agent
    /// that conflated the two would retry a real defect as a transport fault.
    @MainActor
    func testADefectiveScreenAnswersOkWithAFailingVerdict() async throws {
        let runner = try makeRunner(tree: Self.defectiveTree)
        let response = await VerdictDaemon.handle(
            DaemonRequest(method: "judge_appkit", runner: runner, subject: "login-form"),
            engine: engine()
        )

        XCTAssertTrue(response.ok, "a failing verdict is not a transport failure")
        guard case .verdict(let verdict)? = response.result else {
            return XCTFail("expected a verdict, got \(String(describing: response.result))")
        }
        XCTAssertEqual(verdict.status, .fail)
        XCTAssertTrue(
            verdict.findings.contains { $0.rule == "truncation" && $0.nodeID == "squeezed" },
            "\(verdict.findings.map { "\($0.rule)/\($0.nodeID)" })"
        )
    }

    /// The control. Without it, "the tool reports findings" is satisfied by an
    /// implementation that reports findings on everything.
    @MainActor
    func testACleanScreenAnswersOkWithAPassingVerdict() async throws {
        let runner = try makeRunner(tree: Self.cleanTree)
        let response = await VerdictDaemon.handle(
            DaemonRequest(method: "judge_appkit", runner: runner, subject: "login-form"),
            engine: engine()
        )

        XCTAssertTrue(response.ok, response.error ?? "")
        guard case .verdict(let verdict)? = response.result else {
            return XCTFail("expected a verdict, got \(String(describing: response.result))")
        }
        XCTAssertEqual(verdict.status, .pass, "\(verdict.findings.map(\.rule))")
    }

    /// A missing runner is `ok: false` — the daemon could not look. It must NOT
    /// come back as a failing verdict, which an agent reads as "your UI is
    /// wrong" and would act on by editing correct code.
    @MainActor
    func testAMissingRunnerIsATransportFailureRatherThanAVerdict() async throws {
        let response = await VerdictDaemon.handle(
            DaemonRequest(
                method: "judge_appkit", runner: "/nonexistent/nope", subject: "login-form"),
            engine: engine()
        )

        XCTAssertFalse(response.ok)
        XCTAssertNil(response.result)
        XCTAssertTrue(
            response.error?.contains("not an executable file") == true,
            response.error ?? "no error message"
        )
    }

    /// Calling the method with no runner at all must be refused HERE, with a
    /// message naming the missing argument — not two layers down as a path error
    /// about the empty string.
    @MainActor
    func testOmittingTheRunnerIsRefusedByName() async throws {
        let response = await VerdictDaemon.handle(
            DaemonRequest(method: "judge_appkit"),
            engine: engine()
        )

        XCTAssertFalse(response.ok)
        XCTAssertTrue(
            response.error?.contains("runner") == true,
            response.error ?? "no error message"
        )
    }

    // MARK: - Through the real transport

    /// The whole chain an agent actually traverses: a JSON-RPC `tools/call`
    /// frame in, a reply out. `MCPServerTests` walks the catalog, but a tool
    /// that dispatches correctly and cannot be CALLED over the wire is the
    /// `no.md` #34 shape — a documented protocol against a server nothing reads.
    @MainActor
    func testTheToolAnswersOverTheJSONRPCTransport() async throws {
        let runner = try makeRunner(tree: Self.defectiveTree)
        let transport = MCPTransport(engine: engine())

        let request = """
            {"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"judge_appkit",\
            "arguments":{"runner":"\(runner)","subject":"login-form"}}}
            """
        let answered = await transport.answer(Data(request.utf8))
        let reply = try XCTUnwrap(answered)
        let text = try XCTUnwrap(String(data: reply, encoding: .utf8))

        // The tool COULD answer, so isError is false even though the verdict
        // inside it fails.
        XCTAssertFalse(text.contains("\"isError\":true"), text)
        XCTAssertTrue(text.contains("truncation"), text)
    }
}
