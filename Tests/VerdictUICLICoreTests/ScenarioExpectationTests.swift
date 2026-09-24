import Foundation
import SwiftUI
import VerdictUIKernel
import VerdictUIProbe
import XCTest

@testable import VerdictUICLICore

@MainActor
final class ScenarioExpectationTests: XCTestCase {
    private func engine(_ entries: [ScenarioEntry]) throws -> VerdictEngine {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("verdictui-expectations-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return VerdictEngine(
            registry: ScenarioRegistry(entries),
            baselines: BaselineStore.standard(root: root),
            allowsExternalWitness: false
        )
    }

    func testVerifyReportsMissingRequiredNodeInsteadOfFalsePass() async throws {
        let entry = ScenarioEntry(
            viewport: Size(width: 240, height: 100),
            expectations: [Expectation("required-support").text("Contact Support").onscreen]
        ) { RequiredSupportScenario() }
        let verdict = try await engine([entry]).verify(scenario: entry.name, includeTree: true)
        XCTAssertEqual(verdict.status, .fail)
        XCTAssertEqual(verdict.findings.filter { $0.rule == Expectation.id }.map(\.nodeID), ["required-support"])
        XCTAssertNotNil(verdict.tree?.node(withID: "observed-title"))
        XCTAssertNil(verdict.tree?.node(withID: "required-support"))
    }
}

private struct RequiredSupportScenario: VerdictScenario, Sendable {
    var name: String { "consumer-required-support" }

    func body(state _: ScenarioState) -> some View {
        Text("Welcome")
            .verdictProbe("observed-title", role: .text, text: "Welcome")
    }
}

extension ScenarioExpectationTests {
    func testDefaultEmptyAndRequestedRulesRemainUnchanged() async throws {
        let entry = ScenarioEntry(viewport: Size(width: 240, height: 100)) { RequiredSupportScenario() }
        XCTAssertEqual(entry.expectations.name, entry.name)
        XCTAssertTrue(entry.expectations.expectations.isEmpty)
        let subject = try engine([entry])
        let original = try await subject.render(scenario: entry.name)
        let verdict = try await subject.verify(scenario: entry.name)
        XCTAssertEqual(verdict.status, .pass)
        XCTAssertEqual(verdict.findings, RuleEngine.run(
            rules: RuleEngine.standardRules, on: original,
            context: .macOS(viewport: original.frame, scenario: entry.name)
        ).findings)
        let custom = try await subject.verify(scenario: entry.name, rules: [RequiredTitleRule()])
        XCTAssertEqual(custom.findings.map(\.rule), [RequiredTitleRule.id])
    }

    func testConsumerExpectationsSupplementRequestedRules() async throws {
        let entry = requiredEntry()
        let verdict = try await engine([entry]).verify(scenario: entry.name, rules: [RequiredTitleRule()])
        XCTAssertEqual(verdict.findings.map(\.rule), [RequiredTitleRule.id, Expectation.id])
        XCTAssertEqual(verdict.findings.map(\.nodeID), ["observed-title", "required-support"])
    }

    func testRenderAndPixelCaptureRemainObservationalWithMissingExpectation() async throws {
        let entry = requiredEntry()
        let subject = try engine([entry])
        let tree = try await subject.render(scenario: entry.name)
        XCTAssertNotNil(tree.node(withID: "observed-title"))
        XCTAssertNil(tree.node(withID: "required-support"))
        let pixels = try await subject.renderPixels(scenario: entry.name)
        XCTAssertNil(pixels.tree.node(withID: "required-support"))
        XCTAssertEqual(pixels.capture.pixelsWide, 240)
        XCTAssertEqual(pixels.capture.pixelsHigh, 100)
        XCTAssertFalse(pixels.capture.png.isEmpty)
    }

    func testPresentPredicatesAndSuppressionUseExistingDSL() async throws {
        let expectations = [Expectation("support").text("Contact Support")
            .width(.atLeast(Double.leastNonzeroMagnitude))
            .height(.atLeast(Double.leastNonzeroMagnitude)).onscreen]
        let entries = [
            ScenarioEntry(viewport: Size(width: 240, height: 100), expectations: expectations) {
                PresentSupportScenario(name: "correct", text: "Contact Support")
            },
            ScenarioEntry(viewport: Size(width: 240, height: 100), expectations: expectations) {
                PresentSupportScenario(name: "wrong", text: "Other")
            },
            ScenarioEntry(viewport: Size(width: 240, height: 100), expectations: expectations) {
                PresentSupportScenario(name: "suppressed", text: "Other", suppress: true)
            },
        ]
        let subject = try engine(entries)
        for (name, expectedStatus) in [("correct", Verdict.Status.pass), ("wrong", .fail), ("suppressed", .pass)] {
            let verdict = try await subject.verify(scenario: name, rules: [], includeTree: true)
            XCTAssertEqual(verdict.status, expectedStatus, name)
            let tree = try XCTUnwrap(verdict.tree)
            let entry = try XCTUnwrap(subject.registry.entry(named: name))
            XCTAssertEqual(verdict.findings, entry.expectations.evaluate(
                in: tree, context: .macOS(viewport: tree.frame, scenario: name)
            ))
        }
        // Non-finite and zero frames cannot be produced safely by a native view.
        // Evaluate the same compiled entry's DSL against explicit kernel input.
        let entry = entries[0]
        for width in [0.0, Double.nan, Double.infinity] {
            let node = SemanticNode(id: "support", role: .text,
                                    frame: Rect(x: 0, y: 0, width: width, height: 20), text: "Contact Support")
            let findings = entry.expectations.evaluate(in: node, context: .macOS(
                viewport: Rect(x: 0, y: 0, width: 240, height: 100), scenario: entry.name
            ))
            XCTAssertTrue(findings.contains { $0.rule == Expectation.id && $0.message.contains("wide") })
        }
    }

    func testActionExpectationsJudgeObservedAfterTreeAndPreserveDelta() async throws {
        for initiallyShown in [false, true] {
            let entry = ScenarioEntry(
                viewport: Size(width: 240, height: 140),
                expectations: [Expectation("required-support").text("Contact Support").onscreen]
            ) { ActionSupportScenario(initiallyShown: initiallyShown) }
            let step = try await engine([entry]).act(
                scenario: entry.name, action: .toggle("show-support"), rules: [], includeTree: true
            )
            XCTAssertEqual(step.before.node(withID: "required-support") != nil, initiallyShown)
            let after = try XCTUnwrap(step.after)
            XCTAssertEqual(after.node(withID: "required-support") != nil, !initiallyShown)
            XCTAssertEqual(step.verdict.tree, after)
            XCTAssertEqual(step.verdict.delta, step.delta)
            if initiallyShown {
                XCTAssertEqual(step.status, .fail)
                XCTAssertEqual(step.verdict.findings.map(\.nodeID), ["required-support"])
                XCTAssertTrue(step.delta.removed.contains { $0.leaf == "required-support" })
            } else {
                XCTAssertEqual(step.status, .pass, "A before-tree evaluation would falsely fail the successful reveal")
                XCTAssertTrue(step.verdict.findings.isEmpty)
                XCTAssertTrue(step.delta.added.contains { $0.node.id == "required-support" })
            }
            guard case .settled = step.settle else { return XCTFail("actual toggle did not settle") }
        }
    }

    func testSweepUsesEachObservedViewportForExpectations() async throws {
        let entry = ScenarioEntry(viewport: Size(width: 240, height: 100), expectations: [Expectation("support").onscreen]) {
            PresentSupportScenario(name: "sized", text: "Contact Support")
        }
        let subject = try engine([entry])
        let narrow = try await subject.render(scenario: entry.name, viewport: Size(width: 100, height: 100))
        let frame = try XCTUnwrap(narrow.node(withID: "support")).frame
        XCTAssertGreaterThanOrEqual(frame.x, 0, "Width, not a negative origin, must cause the planted overflow")
        XCTAssertGreaterThan(frame.maxX, narrow.frame.maxX)
        let report = try await subject.sweep(scenario: entry.name, variants: [
            Variant(viewport: Size(width: 240, height: 100)),
            Variant(viewport: Size(width: 100, height: 100)),
        ], rules: [])
        XCTAssertEqual(report.cells.count, 2)
        let large = try XCTUnwrap(report.cells[0].verdict)
        let small = try XCTUnwrap(report.cells[1].verdict)
        XCTAssertEqual(large.status, .pass)
        XCTAssertEqual(small.status, .fail)
        XCTAssertEqual(small.findings.map(\.rule), [Expectation.id])
        XCTAssertEqual(small.findings.map(\.nodeID), ["support"])
        XCTAssertTrue(small.scenario.contains("100x100"))
        XCTAssertTrue(report.cells.allSatisfy { $0.error == nil })
    }

    func testUnavailableObservationsAndRejectedActionsDoNotFabricateExpectations() async throws {
        let entry = requiredEntry()
        let subject = try engine([entry])
        do {
            _ = try await subject.verify(scenario: entry.name, deadline: 0)
            XCTFail("An unobserved screen must not produce a verdict")
        } catch let error as VerdictEngine.EngineError {
            guard case .renderFailed = error else { return XCTFail("unexpected error: \(error)") }
        }
        let noCapture = try await subject.act(scenario: entry.name, action: .tap("required-support"), deadline: 0)
        XCTAssertNil(noCapture.after)
        XCTAssertEqual(noCapture.verdict.findings.map(\.rule), [Harness.hostErrorRule])
        let rejected = try await subject.act(scenario: entry.name, action: .tap("required-support"))
        XCTAssertEqual(rejected.verdict.findings.map(\.rule), [Harness.actionErrorRule])
        let sweep = try await subject.sweep(scenario: entry.name, variants: [.baseline], deadline: 0)
        XCTAssertEqual(sweep.cells.count, 1)
        XCTAssertNil(sweep.cells[0].verdict)
        XCTAssertNotNil(sweep.cells[0].error)
    }

    func testMCPPipesRetainConsumerRegistryExpectationFailureAndUnavailable() async throws {
        let subject = try engine([requiredEntry(), ScenarioEntry(viewport: Size(width: 240, height: 100)) {
            PresentSupportScenario(name: "consumer-correct", text: "Contact Support")
        }])
        let replies = try await exchangeMCPFrames([
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_scenarios","arguments":{}}}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"verify","arguments":{"scenario":"consumer-required-support"}}}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"verify","arguments":{"scenario":"consumer-correct"}}}"#,
            #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"verify","arguments":{"scenario":"no-such-consumer"}}}"#,
        ], engine: subject)
        XCTAssertEqual(replies.count, 4)
        XCTAssertEqual(replies.compactMap { $0["id"] as? Int }, [1, 2, 3, 4])
        let values = try replies.map { reply -> [String: Any] in try XCTUnwrap(reply["result"] as? [String: Any]) }
        let texts = try values.map { result -> Data in
            let content = try XCTUnwrap(result["content"] as? [[String: Any]])
            return Data(try XCTUnwrap(content.first?["text"] as? String).utf8)
        }
        XCTAssertEqual(try JSONDecoder().decode([String].self, from: texts[0]), subject.scenarioNames)
        let failed = try JSONDecoder().decode(Verdict.self, from: texts[1])
        XCTAssertEqual(failed.status, .fail)
        XCTAssertEqual(failed.findings.filter { $0.rule == Expectation.id }.map(\.nodeID), ["required-support"])
        XCTAssertEqual(try JSONDecoder().decode(Verdict.self, from: texts[2]).status, .pass)
        XCTAssertEqual(values.compactMap { $0["isError"] as? Bool }, [false, false, false, true])
    }

    func testRealDaemonSocketRetainsConsumerExpectationFailureAndUnavailable() async throws {
        let subject = try engine([requiredEntry()])
        let path = "/tmp/vui-ex-\(UUID().uuidString.prefix(8)).sock"
        let transport = DaemonTransport(engine: subject, socketPath: path)
        let server = Task { try await transport.serve() }
        do {
            for _ in 0..<200 {
                if DaemonTransport.isLive(path: path) { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(DaemonTransport.isLive(path: path), "Owned daemon must bind before exchange")
            let listed = try await DaemonClient.send(DaemonRequest(method: "list"), socketPath: path)
            guard case .scenarios(let names) = listed.result else { throw TestFailure.invalidPayload }
            XCTAssertEqual(names, subject.scenarioNames)
            let response = try await DaemonClient.send(
                DaemonRequest(method: "verify", scenario: "consumer-required-support", id: "required"), socketPath: path
            )
            XCTAssertTrue(response.ok)
            XCTAssertEqual(response.id, "required")
            guard case .verdict(let verdict) = response.result else { throw TestFailure.invalidPayload }
            XCTAssertEqual(verdict.status, .fail)
            XCTAssertEqual(verdict.findings.filter { $0.rule == Expectation.id }.map(\.nodeID), ["required-support"])
            let unknown = try await DaemonClient.send(
                DaemonRequest(method: "verify", scenario: "no-such-consumer"), socketPath: path
            )
            XCTAssertFalse(unknown.ok)
            XCTAssertNil(unknown.result)
            XCTAssertNotNil(unknown.error)
        } catch {
            server.cancel()
            try await server.value
            throw error
        }
        server.cancel()
        try await server.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: path), "Owned socket must be retired")
    }

    private func requiredEntry() -> ScenarioEntry {
        ScenarioEntry(viewport: Size(width: 240, height: 100), expectations: [Expectation("required-support")]) {
            RequiredSupportScenario()
        }
    }

    private enum TestFailure: Error { case invalidPayload }
}

private struct RequiredTitleRule: LintRule {
    static let id = "test-title"
    func evaluate(_ root: SemanticNode, context: LintContext) -> [Finding] {
        [Finding(rule: Self.id, severity: .warning, nodeID: "observed-title", message: "caller rule ran")]
    }
}

private struct PresentSupportScenario: VerdictScenario, Sendable {
    let name: String
    let text: String
    var suppress = false

    func body(state _: ScenarioState) -> some View {
        GeometryReader { _ in
            Text(text).frame(width: 160, height: 24).fixedSize()
                .verdictProbe("support", role: .text, text: text,
                              attributes: suppress ? [LintContext.suppressionKey: .string(Expectation.id)] : [:])
        }
    }
}

private struct ActionSupportScenario: VerdictScenario, Sendable {
    let initiallyShown: Bool
    var name: String { "consumer-action-support" }
    func body(state: ScenarioState) -> some View {
        ActionSupportView(shown: state.boolBinding("show-support", default: initiallyShown))
    }
}

private struct ActionSupportView: View {
    @Binding var shown: Bool
    var body: some View {
        VStack {
            Toggle("Support", isOn: $shown)
                .verdictProbe("show-support", role: .toggle, action: .bool($shown))
            if shown {
                Text("Contact Support").verdictProbe("required-support", role: .text, text: "Contact Support")
            }
        }
    }
}
