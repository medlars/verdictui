import Foundation
import VerdictUIDemoScenarios
import VerdictUIKernel
import VerdictUIWeb
import XCTest
@testable import VerdictUICLICore

/// Protocol fixtures exercise real process/JSON-RPC dispatch, not UI rendering.
final class WebMCPToolTests: XCTestCase {
    private func fixture(fault: Bool) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("web-consumer-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".verdictui"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        func node(_ id: String, depth: Int, x: Double, children: [SemanticNode] = []) -> SemanticNode {
            SemanticNode(id: id, role: depth == 0 ? .container : .button,
                frame: depth == 0 ? Rect(x: 0, y: 0, width: 800, height: 600) : Rect(x: x, y: 30, width: 100, height: 50),
                attributes: ["web.tag": .string(depth == 0 ? "body" : "button"), "web.frame": .string("main"),
                    "web.domDepth": .number(Double(depth)), "web.position": .string("static"),
                    "web.overflowX": .string("visible"), "web.overflowY": .string("visible"),
                    "web.interactionMeasured": .bool(false), "web.isClickable": .bool(depth > 0),
                    "web.isFocusable": .bool(depth > 0), "web.hasInteractiveAncestor": .bool(false)], children: children)
        }
        let tree = node("root", depth: 0, x: 0, children: [node("save", depth: 1, x: 20), node("cancel", depth: 1, x: fault ? 40 : 200)])
        try JSONEncoder().encode(tree).write(to: root.appendingPathComponent("tree.json"))
        let runner = root.appendingPathComponent("runner")
        try "#!/bin/sh\n[ \"$1\" = render ] && [ \"$2\" = owned ] || exit 7\ncat \"$(dirname \"$0\")/tree.json\"\n".write(to: runner, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: runner.path)
        return root
    }
    @MainActor private func engine(_ root: URL) -> VerdictEngine {
        VerdictEngine(registry: DemoScenarios.registry, baselines: BaselineStore.standard(root: root))
    }
    func testCatalogRequiresBothArgumentsAndResolves() throws {
        let tool = try XCTUnwrap(MCPServer.tools.first { $0.name == "judge_web" })
        XCTAssertEqual(Set(tool.inputSchema.required), ["runner", "subject"])
        XCTAssertEqual(MCPServer.daemonMethod(for: tool.name), "judge_web")
    }
    @MainActor func testRealMCPAndProjectCheckAgreeOnPassAndFail() async throws {
        for fault in [false, true] {
            let root = try fixture(fault: fault), runner = root.appendingPathComponent("runner")
            let request: [String: Any] = ["jsonrpc": "2.0", "id": 7, "method": "tools/call", "params": ["name": "judge_web", "arguments": ["runner": runner.path, "subject": "owned"]]]
            let transport = MCPTransport(engine: engine(root))
            let answered = await transport.answer(try JSONSerialization.data(withJSONObject: request))
            let response = try XCTUnwrap(answered)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: response) as? [String: Any])
            let result = try XCTUnwrap(body["result"] as? [String: Any])
            XCTAssertNotEqual(result["isError"] as? Bool, true)
            let content = try XCTUnwrap(result["content"] as? [[String: Any]])
            let text = try XCTUnwrap(content.first?["text"] as? String)
            let verdict = try JSONDecoder().decode(Verdict.self, from: Data(text.utf8))
            XCTAssertEqual(verdict.status, fault ? .fail : .pass)
            try JSONSerialization.data(withJSONObject: ["checks": [["name": "owned", "kind": "web", "runner": runner.path, "subject": "owned"]]]).write(to: root.appendingPathComponent(".verdictui/checks.json"))
            let report = await ProjectCheckRuntime.run(root: root, executable: runner, sessions: WebSessionManager(root: root.appendingPathComponent("sessions")))
            XCTAssertEqual(report.status, fault ? "fail" : "pass")
            XCTAssertEqual(report.checks.first?.verdict?.findings, verdict.findings)
        }
    }
    @MainActor func testMissingMalformedOrNonzeroRunnerIsUnavailable() async throws {
        let root = try fixture(fault: false), runner = root.appendingPathComponent("runner")
        for request in [DaemonRequest(method: "judge_web"), DaemonRequest(method: "judge_web", runner: runner.path),
                        DaemonRequest(method: "judge_web", runner: "/nonexistent/runner", subject: "owned"),
                        DaemonRequest(method: "judge_web", runner: runner.path, subject: "wrong")] {
            let response = await VerdictDaemon.handle(request, engine: engine(root))
            XCTAssertFalse(response.ok)
        }
        try Data("{}".utf8).write(to: root.appendingPathComponent("tree.json"))
        let malformed = await VerdictDaemon.handle(DaemonRequest(method: "judge_web", runner: runner.path, subject: "owned"), engine: engine(root))
        XCTAssertFalse(malformed.ok)
        XCTAssertNil(malformed.result)
    }
    @MainActor func testExplicitWebJudgeCommandKeepsExitSemantics() async throws {
        for fault in [false, true] {
            let root = try fixture(fault: fault)
            let output = CapturedOutput()
            let environment = CommandEnvironment(engine: engine(root), output: output, pixelArtifactRoot: root)
            let code = await JudgeCommand(treePath: root.appendingPathComponent("tree.json").path,
                scenarioName: "owned", webObserved: true).run(environment, pretty: false, summary: false)
            XCTAssertEqual(code, fault ? .verdictFailed : .pass)
            let verdict = try JSONDecoder().decode(Verdict.self, from: Data(output.standardOutput.utf8))
            XCTAssertEqual(verdict.status, fault ? .fail : .pass)
        }
    }

}
