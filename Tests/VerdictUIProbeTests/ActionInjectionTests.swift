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
    func testToggleActionUpdatesExternalControlBindingAndRenderedState() async throws {
        let model = ExternalToggleModel()
        let host = OracleHost(
            scenario: ExternalToggleScenario(model: model),
            viewport: Size(width: 280, height: 140)
        )
        let before = try await host.currentTree()
        let actions = host.actionableProbes
        print("EXTERNAL_BINDING before value=\(model.isExpanded) nodes=\(before.probeIDs.sorted()) actions=\(actions)")
        XCTAssertFalse(model.isExpanded)
        XCTAssertNotNil(before.node(withID: "external-collapsed"))
        XCTAssertNil(before.node(withID: "external-expanded"))
        XCTAssertTrue(actions["external-toggle"]?.contains("toggle") == true)

        let step = await Harness(host: host).perform(.toggle("external-toggle"))
        let after = try XCTUnwrap(step.after, "act must return an observed after-tree")
        print("EXTERNAL_BINDING after value=\(model.isExpanded) nodes=\(after.probeIDs.sorted()) status=\(step.status) settle=\(step.settle)")
        guard case .settled = step.settle else {
            XCTFail("external control did not settle: \(step.settle)")
            return
        }
        XCTAssertEqual(step.probeID, "external-toggle")
        XCTAssertNotNil(step.before.node(withID: "external-collapsed"))
        XCTAssertTrue(model.isExpanded, "discovered toggle must update the control's external model")
        XCTAssertNotNil(after.node(withID: "external-expanded"), "the actual view must render the changed model")
        XCTAssertNil(after.node(withID: "external-collapsed"), "the previous conditional content must disappear")
    }

    @MainActor
    func testExternalTextAndSliderWriteOnceAndRenderExactValues() async throws {
        let model = ExternalFieldsModel()
        let host = OracleHost(scenario: ExternalFieldsScenario(model: model),
                              viewport: Size(width: 320, height: 260))
        let before = try await host.currentTree()
        XCTAssertEqual(before.node(withID: "observed-text")?.text, "seed")
        XCTAssertEqual(before.node(withID: "observed-volume")?.text, "0.25")
        XCTAssertEqual(host.actionableProbes["external-text"], ["setText"])
        XCTAssertEqual(host.actionableProbes["external-slider"], ["setSlider"])
        let harness = Harness(host: host)
        let text = await harness.perform(.setText("external-text", "Ada"))
        XCTAssertEqual(model.text, "Ada")
        XCTAssertEqual(text.after?.node(withID: "observed-text")?.text, "Ada")
        XCTAssertEqual(model.textWrites, 1)
        XCTAssertEqual(model.volume, 0.25)
        XCTAssertEqual(model.sliderWrites, 0)
        let slider = await harness.perform(.setSlider("external-slider", 0.75))
        XCTAssertEqual(model.volume, 0.75)
        XCTAssertEqual(slider.after?.node(withID: "observed-volume")?.text, "0.75")
        XCTAssertEqual(model.sliderWrites, 1)
        XCTAssertEqual(model.textWrites, 1)
        XCTAssertEqual(slider.after?.node(withID: "observed-text")?.text, "Ada")
        XCTAssertEqual(model.sibling, "untouched")
    }

    @MainActor
    func testNoOpAndWrongTargetBindingsCannotSatisfyObservedOutcome() async throws {
        for fault in [ExternalFieldsModel.Fault.ignore, .wrongTarget] {
            let model = ExternalFieldsModel()
            model.fault = fault
            let host = OracleHost(scenario: ExternalFieldsScenario(model: model),
                                  viewport: Size(width: 320, height: 260))
            let step = await Harness(host: host).perform(.setText("external-text", "Ada"))
            let after = try XCTUnwrap(step.after)
            XCTAssertEqual(step.status, .pass, "this control demonstrates that lint alone cannot assert intent")
            XCTAssertEqual(model.textWrites, 1)
            XCTAssertEqual(model.text, "seed")
            XCTAssertEqual(after.node(withID: "observed-text")?.text, "seed")
            let accepted = model.text == "Ada" && after.node(withID: "observed-text")?.text == "Ada"
            XCTAssertFalse(accepted, "a delivered no-op/wrong-target action must fail outcome acceptance")
            XCTAssertEqual(model.sibling, fault == .wrongTarget ? "Ada" : "untouched")
        }
    }

    @MainActor
    func testExternalToggleReadsCurrentValueAndHostsRemainIndependent() async throws {
        let first = ExternalToggleModel()
        let second = ExternalToggleModel()
        let host = OracleHost(scenario: ExternalToggleScenario(model: first),
                              viewport: Size(width: 280, height: 140))
        let other = OracleHost(scenario: ExternalToggleScenario(model: second),
                               viewport: Size(width: 280, height: 140))
        _ = try await host.currentTree()
        first.isExpanded = true
        let externallyChanged = try await host.currentTree()
        XCTAssertNotNil(externallyChanged.node(withID: "external-expanded"))
        let step = await Harness(host: host).perform(.toggle("external-toggle"))
        XCTAssertFalse(first.isExpanded, "toggle must use the external value after a re-render, not its first seed")
        XCTAssertNotNil(step.after?.node(withID: "external-collapsed"))
        XCTAssertFalse(second.isExpanded)
        let untouched = try await other.currentTree()
        XCTAssertNotNil(untouched.node(withID: "external-collapsed"))
    }

    @MainActor
    func testRepeatedExternalActionsRetireHostStateAndModel() async throws {
        for _ in 0..<12 {
            weak var retiredHost: OracleHost?
            weak var retiredState: ScenarioState?
            weak var retiredModel: ExternalToggleModel?
            var model: ExternalToggleModel? = ExternalToggleModel()
            var host: OracleHost? = autoreleasepool {
                OracleHost(scenario: ExternalToggleScenario(model: model!),
                           viewport: Size(width: 280, height: 140))
            }
            retiredHost = host
            retiredState = host?.state
            retiredModel = model
            for index in 0..<4 {
                let step = await Harness(host: host!).perform(.toggle("external-toggle"))
                let expected = index % 2 == 0
                XCTAssertEqual(model?.isExpanded, expected)
                XCTAssertNotNil(step.after?.node(withID: expected ? "external-expanded" : "external-collapsed"))
            }
            autoreleasepool { host = nil; model = nil }
            XCTAssertNil(retiredHost)
            XCTAssertNil(retiredState)
            XCTAssertNil(retiredModel, "host retirement must release external binding captures")
        }
    }

    @MainActor
    func testRetainedPublicStateCannotRetainOrDriveRetiredHostControls() async throws {
        weak var retiredHost: OracleHost?
        weak var retiredModel: ExternalToggleModel?
        var model: ExternalToggleModel? = ExternalToggleModel()
        var host: OracleHost? = autoreleasepool {
            OracleHost(scenario: ExternalToggleScenario(model: model!),
                       viewport: Size(width: 280, height: 140))
        }
        _ = try await host!.currentTree()
        let state = host!.state
        retiredHost = host
        retiredModel = model
        autoreleasepool { host = nil; model = nil }
        XCTAssertNil(retiredHost)
        XCTAssertNil(retiredModel)
        XCTAssertNil(state.actionableProbes["external-toggle"])
        XCTAssertThrowsError(try ProbeAction.toggle("external-toggle").apply(to: state))
    }

    @MainActor
    func testImplicitMeasurementStateRetiresBeforeActualHost() async throws {
        let recorder = RegistrationStateRecorder()
        var model: ExternalToggleModel? = ExternalToggleModel()
        weak var retiredModel: ExternalToggleModel?
        retiredModel = model
        var host: OracleHost? = autoreleasepool {
            OracleHost(scenario: ExternalToggleScenario(model: model!, recorder: recorder))
        }
        _ = try await host!.currentTree()
        XCTAssertEqual(recorder.states.count, 2, "one measuring state and one actual host state")
        let measured = try XCTUnwrap(recorder.states.first)
        XCTAssertFalse(measured === host!.state)
        XCTAssertNil(measured.actionableProbes["external-toggle"])
        XCTAssertThrowsError(try ProbeAction.toggle("external-toggle").apply(to: measured))
        XCTAssertEqual(host!.actionableProbes["external-toggle"], ["tap", "toggle"])
        autoreleasepool { host = nil; model = nil }
        XCTAssertNil(retiredModel, "retained measuring and actual states must not retain retired controls")
        for state in recorder.states { XCTAssertNil(state.actionableProbes["external-toggle"]) }
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

    @MainActor
    func testApplyWorksWithoutAPriorCurrentTreeCall() async throws {
        // Registration must not depend on `onAppear` after `currentTree()` —
        // host init's layout pass + `apply`'s forced layout are enough.
        let host = OracleHost(
            scenario: ToggleLayoutScenario(isExpanded: false),
            viewport: ToggleLayoutScenario.recommendedViewport
        )
        try host.apply(.toggle(ToggleLayoutScenario.toggleProbeID))
        _ = await host.settle(timeout: .seconds(2))
        let tree = try await host.currentTree()
        XCTAssertNotNil(tree.node(withID: "advanced-detail"))
    }

    @MainActor
    func testToggleOnAStringBindingIsATypeMismatch() async throws {
        let host = OracleHost(
            scenario: EditableFieldsScenario(),
            viewport: Size(width: 280, height: 120)
        )
        _ = try await host.currentTree()
        XCTAssertThrowsError(try host.apply(.toggle("name-field"))) { error in
            guard let actionError = error as? ProbeActionError else {
                XCTFail("expected ProbeActionError, got \(error)")
                return
            }
            XCTAssertEqual(
                actionError,
                .typeMismatch(id: "name-field", expected: "bool")
            )
        }
    }
}

// MARK: - Fixtures

@MainActor
private final class ExternalToggleModel: ObservableObject {
    @Published var isExpanded = false
}

private struct ExternalToggleScenario: VerdictScenario {
    let name = "external-toggle-binding"
    let model: ExternalToggleModel
    var recorder: RegistrationStateRecorder? = nil

    func body(state: ScenarioState) -> some View {
        let _ = recorder?.record(state)
        ExternalToggleView(model: model)
    }
}

private struct ExternalToggleView: View {
    @ObservedObject var model: ExternalToggleModel

    var body: some View {
        let binding = $model.isExpanded
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Show external detail", isOn: binding)
                .frame(minHeight: 32)
                .verdictProbe("external-toggle", role: .toggle,
                              text: "Show external detail", action: .bool(binding))
            if model.isExpanded {
                Text("Expanded external detail")
                    .verdictProbe("external-expanded", role: .text, text: "Expanded external detail")
            } else {
                Text("Collapsed external detail")
                    .verdictProbe("external-collapsed", role: .text, text: "Collapsed external detail")
            }
        }
        .padding(12)
    }
}

@MainActor
private final class RegistrationStateRecorder {
    var states: [ScenarioState] = []
    func record(_ state: ScenarioState) {
        if !states.contains(where: { $0 === state }) { states.append(state) }
    }
}

@MainActor
private final class ExternalFieldsModel: ObservableObject {
    enum Fault { case none, ignore, wrongTarget }
    @Published var text = "seed"
    @Published var volume = 0.25
    @Published var sibling = "untouched"
    var textWrites = 0
    var sliderWrites = 0
    var fault = Fault.none
}

private struct ExternalFieldsScenario: VerdictScenario {
    let name = "external-fields"
    let model: ExternalFieldsModel
    func body(state: ScenarioState) -> some View { ExternalFieldsView(model: model) }
}

private struct ExternalFieldsView: View {
    @ObservedObject var model: ExternalFieldsModel
    var body: some View {
        let text = Binding(get: { model.text }, set: { value in
            model.textWrites += 1
            switch model.fault {
            case .none: model.text = value
            case .ignore: break
            case .wrongTarget: model.sibling = value
            }
        })
        let volume = Binding(get: { model.volume }, set: { value in
            model.sliderWrites += 1
            model.volume = value
        })
        VStack(spacing: 12) {
            TextField("Name", text: text)
                .frame(minHeight: 32)
                .verdictProbe("external-text", role: .textField, action: .text(text))
            Text(model.text).verdictProbe("observed-text", role: .text, text: model.text)
            Slider(value: volume, in: 0...1)
                .frame(minHeight: 32)
                .verdictProbe("external-slider", role: .slider, action: .slider(volume))
            Text(String(model.volume))
                .verdictProbe("observed-volume", role: .text, text: String(model.volume))
        }
        .padding(12)
    }
}

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
