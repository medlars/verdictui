import SwiftUI
import VerdictUIDemoScenarios
import VerdictUIKernel
import XCTest

@testable import VerdictUIProbe

/// Wave 3 Task 3: in-process ``ProbeAction`` against ``ScenarioState`` bindings.
final class ActionInjectionTests: XCTestCase {
    override func invokeTest() {
        autoreleasepool { super.invokeTest() }
    }

    @MainActor
    func testToggleActionExpandsToggleLayoutScenario() async throws {
        let host = OracleHost(
            scenario: ToggleLayoutScenario(isExpanded: false),
            viewport: ToggleLayoutScenario.recommendedViewport
        )
        let before = try await host.currentTree()
        XCTAssertNotNil(before.node(withID: "collapsed-summary"))
        XCTAssertNil(before.node(withID: "advanced-detail"))

        try host.apply(.toggle(ToggleLayoutScenario.toggleProbeID))
        let settle = await host.settle(timeout: .seconds(2))
        guard case .settled = settle else {
            XCTFail("settle after toggle failed: \(settle)")
            return
        }
        let after = try await host.currentTree()
        XCTAssertNotNil(after.node(withID: "advanced-detail"))
        XCTAssertNotNil(after.node(withID: "clear-cache-button"))
        XCTAssertNil(after.node(withID: "collapsed-summary"))

        let expected = try await OracleHost(
            scenario: ToggleLayoutScenario(isExpanded: true),
            viewport: ToggleLayoutScenario.recommendedViewport
        ).currentTree()
        XCTAssertEqual(
            Set(after.children.flatMap(\.probeIDs)),
            Set(expected.children.flatMap(\.probeIDs)),
            "post-action probe set should match the seeded expanded tree"
        )
    }

    @MainActor
    func testTapOnToggleAlsoFlipsTheBinding() async throws {
        let host = OracleHost(
            scenario: ToggleLayoutScenario(isExpanded: false),
            viewport: ToggleLayoutScenario.recommendedViewport
        )
        _ = try await host.currentTree()
        try host.apply(.tap(ToggleLayoutScenario.toggleProbeID))
        _ = await host.settle(timeout: .seconds(2))
        let tree = try await host.currentTree()
        XCTAssertNotNil(tree.node(withID: "advanced-detail"))
    }

    @MainActor
    func testUnknownProbeIDThrowsWithEvidence() async throws {
        let host = OracleHost(
            scenario: ToggleLayoutScenario(isExpanded: false),
            viewport: ToggleLayoutScenario.recommendedViewport
        )
        _ = try await host.currentTree()
        XCTAssertThrowsError(try host.apply(.toggle("no-such-probe"))) { error in
            guard let actionError = error as? ProbeActionError else {
                XCTFail("expected ProbeActionError, got \(error)")
                return
            }
            XCTAssertEqual(actionError, .unknownProbe("no-such-probe"))
            XCTAssertEqual(actionError.probeID, "no-such-probe")
            XCTAssertTrue(actionError.description.contains("no-such-probe"))
        }
    }

    @MainActor
    func testCustomActionMutatesScenarioState() async throws {
        let host = OracleHost(
            scenario: ToggleLayoutScenario(isExpanded: false),
            viewport: ToggleLayoutScenario.recommendedViewport
        )
        _ = try await host.currentTree()
        try host.apply(.custom(ToggleLayoutScenario.toggleProbeID) { state in
            let binding = state.boolBinding(ToggleLayoutScenario.toggleProbeID)
            binding.wrappedValue = true
        })
        _ = await host.settle(timeout: .seconds(2))
        let tree = try await host.currentTree()
        XCTAssertNotNil(tree.node(withID: "advanced-detail"))
    }

    @MainActor
    func testSetTextAndSliderBindings() async throws {
        let host = OracleHost(
            scenario: EditableFieldsScenario(),
            viewport: Size(width: 280, height: 120)
        )
        _ = try await host.currentTree()
        try host.apply(.setText("name-field", "Ada"))
        try host.apply(.setSlider("volume-slider", 0.75))
        _ = await host.settle(timeout: .seconds(2))
        XCTAssertEqual(host.state.stringBinding("name-field").wrappedValue, "Ada")
        XCTAssertEqual(host.state.doubleBinding("volume-slider").wrappedValue, 0.75, accuracy: 1e-9)
    }
}

// MARK: - Fixtures

private struct EditableFieldsScenario: VerdictScenario {
    var name: String { "wave3-editable-fields" }

    @MainActor
    func body(state: ScenarioState) -> some View {
        let text = state.stringBinding("name-field", default: "")
        let volume = state.doubleBinding("volume-slider", default: 0)
        VStack {
            TextField("Name", text: text)
                .verdictProbe("name-field", role: .textField, action: .text(text))
            Slider(value: volume, in: 0...1)
                .verdictProbe("volume-slider", role: .slider, action: .slider(volume))
        }
    }
}

private extension SemanticNode {
    /// Probe ids in this subtree (non-empty only).
    var probeIDs: [String] {
        let mine = id.isEmpty ? [] : [id]
        return mine + children.flatMap(\.probeIDs)
    }
}
