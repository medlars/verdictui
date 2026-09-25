import AppKit
import Combine
import Observation
import SwiftUI
import VerdictUIKernel
import XCTest

@testable import VerdictUIProbe

/// What a scenario author is promised: write a name and a body, hand it to
/// ``OracleHost``, get a tree back — and never touch the sink, the coordinate
/// space, or the environment.
///
/// State belongs to one host across renders. Initial binding registration is
/// silent during body evaluation; later writes and actions notify observers.
final class ScenarioTests: XCTestCase {
    /// Every test here builds an AppKit view hierarchy, and `swift test` has no
    /// window-server run loop to drain the autorelease pool between tests. Without
    /// this the hosted hierarchies accumulate until the suite wedges at 0% CPU,
    /// each test still passing in isolation.
    override func invokeTest() {
        autoreleasepool { super.invokeTest() }
    }

    // MARK: - Rendering

    @MainActor
    func testAScenarioBodyRendersThroughTheHost() async throws {
        let host = OracleHost(scenario: GreetingScenario(), viewport: Size(width: 200, height: 80))
        let tree = try await host.currentTree()

        // The author applied `.verdictProbe` and nothing else; the tree, the root
        // frame and the root-space coordinates all came from the host.
        let label = try XCTUnwrap(
            tree.node(withID: "greeting"),
            "the scenario's probed view never reached the tree"
        )
        XCTAssertEqual(label.role, .text)
        XCTAssertEqual(label.text, "Hello")
        XCTAssertEqual(tree.frame, Rect(x: 0, y: 0, width: 200, height: 80))
        XCTAssertGreaterThan(label.frame.width, 0, "the probed label measured as zero width")
        XCTAssertNotNil(
            label.textMetrics,
            "a text probe below the host's root must reach the recorder the host installed"
        )
    }

    @MainActor
    func testTheScenarioNameRoundTripsThroughTheHost() async throws {
        let scenario = GreetingScenario()
        let host = OracleHost(scenario: scenario, viewport: Size(width: 200, height: 80))

        XCTAssertEqual(host.scenarioName, scenario.name)
        XCTAssertEqual(host.scenarioName, "greeting-screen")

        // The name is what a verdict is filed under, so it has to survive into the
        // context the kernel is handed — unmangled.
        let tree = try await host.currentTree()
        let context = LintContext.macOS(viewport: tree.frame, scenario: host.scenarioName)
        XCTAssertEqual(context.scenario, "greeting-screen")
    }

    // MARK: - ScenarioState

    /// Factories run inside body(state:); seeding a value must not invalidate
    /// the view whose first evaluation is already reading that value.
    @MainActor
    func testInitialBindingSeedsDoNotPublishChanges() {
        let state = ScenarioState()
        var notifications = 0
        let subscription = state.objectWillChange.sink { notifications += 1 }
        defer { subscription.cancel() }

        XCTAssertTrue(state.boolBinding("bool", default: true).wrappedValue)
        XCTAssertEqual(notifications, 0, "initial bool seed published during rendering")
        XCTAssertEqual(state.stringBinding("text", default: "seed").wrappedValue, "seed")
        XCTAssertEqual(notifications, 0, "initial text seed published during rendering")
        XCTAssertEqual(state.doubleBinding("slider", default: 0.25).wrappedValue, 0.25)
        XCTAssertEqual(notifications, 0, "initial slider seed published during rendering")

        XCTAssertTrue(state.boolBinding("bool", default: false).wrappedValue)
        XCTAssertEqual(state.stringBinding("text", default: "replacement").wrappedValue, "seed")
        XCTAssertEqual(state.doubleBinding("slider", default: 0.75).wrappedValue, 0.25)
        XCTAssertEqual(notifications, 0, "reading existing bindings must not publish or reseed")
    }

    @MainActor
    func testInitialProbeRegistrationsDoNotPublishChanges() {
        let state = ScenarioState()
        var notifications = 0
        let subscription = state.objectWillChange.sink { notifications += 1 }
        defer { subscription.cancel() }

        state.register(probeID: "bool", action: .bool(.constant(true)))
        XCTAssertEqual(notifications, 0, "initial bool registration published during rendering")
        state.register(probeID: "text", action: .text(.constant("seed")))
        XCTAssertEqual(notifications, 0, "initial text registration published during rendering")
        state.register(probeID: "slider", action: .slider(.constant(0.25)))
        XCTAssertEqual(notifications, 0, "initial slider registration published during rendering")

        state.register(probeID: "bool", action: .bool(.constant(false)))
        state.register(probeID: "text", action: .text(.constant("replacement")))
        state.register(probeID: "slider", action: .slider(.constant(0.75)))
        // Registration now keeps current operations, not a copied seed. It still
        // must not write to a target or invalidate SwiftUI during evaluation.
        XCTAssertEqual(state.actionableProbes["bool"], ["tap", "toggle"])
        XCTAssertEqual(state.actionableProbes["text"], ["setText"])
        XCTAssertEqual(state.actionableProbes["slider"], ["setSlider"])
        XCTAssertEqual(notifications, 0, "re-registering must not publish during rendering")
    }

    @MainActor
    func testBindingWritesStillPublishChanges() {
        let state = ScenarioState()
        let bool = state.boolBinding("bool")
        let text = state.stringBinding("text")
        let slider = state.doubleBinding("slider")
        var notifications = 0
        let subscription = state.objectWillChange.sink { notifications += 1 }
        defer { subscription.cancel() }

        bool.wrappedValue = true
        XCTAssertEqual(notifications, 1)
        XCTAssertTrue(bool.wrappedValue)
        text.wrappedValue = "changed"
        XCTAssertEqual(notifications, 2)
        XCTAssertEqual(text.wrappedValue, "changed")
        slider.wrappedValue = 0.75
        XCTAssertEqual(notifications, 3)
        XCTAssertEqual(slider.wrappedValue, 0.75)
    }

    @MainActor
    func testProbeActionMutationsStillPublishChanges() throws {
        let state = ScenarioState()
        var bool = false
        var text = "seed"
        var slider = 0.25
        state.register(probeID: "bool", action: .bool(Binding(get: { bool }, set: { bool = $0 })))
        state.register(probeID: "text", action: .text(Binding(get: { text }, set: { text = $0 })))
        state.register(probeID: "slider", action: .slider(Binding(get: { slider }, set: { slider = $0 })))
        var tapCount = 0
        state.registerTap("button") { tapCount += 1 }
        var notifications = 0
        let subscription = state.objectWillChange.sink { notifications += 1 }
        defer { subscription.cancel() }

        try ProbeAction.toggle("bool").apply(to: state)
        XCTAssertEqual(notifications, 1)
        XCTAssertTrue(bool)
        try ProbeAction.setText("text", "changed").apply(to: state)
        XCTAssertEqual(notifications, 2)
        XCTAssertEqual(text, "changed")
        try ProbeAction.setSlider("slider", 0.75).apply(to: state)
        XCTAssertEqual(notifications, 3)
        XCTAssertEqual(slider, 0.75)
        try ProbeAction.tap("button").apply(to: state)
        XCTAssertEqual(notifications, 4)
        XCTAssertEqual(tapCount, 1)
    }

    @MainActor
    func testRegisteringTypedOperationsDoesNotInvokeAnySetter() {
        let state = ScenarioState()
        var writes = 0
        for _ in 0..<2 {
            state.register(probeID: "bool", action: .bool(Binding(get: { true }, set: { _ in writes += 1 })))
            state.register(probeID: "text", action: .text(Binding(get: { "seed" }, set: { _ in writes += 1 })))
            state.register(probeID: "slider", action: .slider(Binding(get: { 0.25 }, set: { _ in writes += 1 })))
        }
        XCTAssertEqual(writes, 0, "registration must not write even an unchanged value during rendering")
    }

    @MainActor
    func testMissingRecordsRefuseAndConstantsRemainUnchanged() throws {
        let state = ScenarioState()
        XCTAssertThrowsError(try ProbeAction.toggle("missing").apply(to: state)) { error in
            XCTAssertEqual(error as? ProbeActionError, .unknownProbe("missing"))
        }
        let constant = Binding.constant(false)
        state.register(probeID: "constant", action: .bool(constant))
        try ProbeAction.toggle("constant").apply(to: state)
        XCTAssertFalse(constant.wrappedValue, "dispatch cannot manufacture a successful constant write")
        try ProbeAction.toggle("constant").apply(to: state)
        XCTAssertFalse(constant.wrappedValue)
    }

    @MainActor
    func testRetiredSiteTokenCannotRetainALateCallback() {
        let state = ScenarioState()
        let token = ScenarioState.SiteToken()
        state.registerSite(probeID: "old", token: token, action: .tap {})
        state.admitSites(["old": [token]])
        state.admitSites([:])
        var target: RegistrationLifetimeTarget? = RegistrationLifetimeTarget()
        weak var retired: RegistrationLifetimeTarget?
        retired = target
        if let target {
            state.registerSite(probeID: "old", token: token, action: .tap { target.count += 1 })
        }
        target = nil
        XCTAssertNil(retired, "a late retired-token registration must not keep its captured owner alive")
    }

    @MainActor
    func testRetiredStateCannotRetainFreshSiteCallbacks() {
        let state = ScenarioState()
        state.retireSites()
        let token = ScenarioState.SiteToken()
        var target: RegistrationLifetimeTarget? = RegistrationLifetimeTarget()
        weak var retired: RegistrationLifetimeTarget?
        retired = target
        if let target {
            state.registerSite(probeID: "late", token: token, action: .tap { target.count += 1 })
        }
        target = nil
        XCTAssertNil(retired)
        withExtendedLifetime(token) {}
    }

    @MainActor
    func testAmbiguousSiteTokensCannotDispatchEitherOwner() {
        let state = ScenarioState()
        let first = ScenarioState.SiteToken()
        let second = ScenarioState.SiteToken()
        var calls = 0
        state.registerSite(probeID: "duplicate", token: first, action: .tap { calls += 1 })
        state.registerSite(probeID: "duplicate", token: second, action: .tap { calls += 10 })
        state.admitSites(["duplicate": [first, second]])
        XCTAssertNil(state.actionableProbes["duplicate"])
        XCTAssertThrowsError(try ProbeAction.tap("duplicate").apply(to: state))
        XCTAssertEqual(calls, 0)
        // Whichever element Set.first chooses, neither duplicate may gain
        // authority. Repeat with both leases already admitted in turn.
        let otherState = ScenarioState()
        let admitted = ScenarioState.SiteToken()
        let pending = ScenarioState.SiteToken()
        otherState.registerSite(probeID: "duplicate", token: admitted, action: .tap { calls += 1 })
        otherState.admitSites(["duplicate": [admitted]])
        otherState.registerSite(probeID: "duplicate", token: pending, action: .tap { calls += 10 })
        otherState.admitSites(["duplicate": [admitted, pending]])
        XCTAssertThrowsError(try ProbeAction.tap("duplicate").apply(to: otherState))
        XCTAssertEqual(calls, 0)
    }

    @MainActor
    func testUndeliveredLeaseDoesNotRetainItsTargetAfterModifierRelease() {
        let state = ScenarioState()
        var token: ScenarioState.SiteToken? = ScenarioState.SiteToken()
        weak var retiredToken: ScenarioState.SiteToken?
        retiredToken = token
        var target: RegistrationLifetimeTarget? = RegistrationLifetimeTarget()
        weak var retiredTarget: RegistrationLifetimeTarget?
        retiredTarget = target
        if let target {
            state.registerSite(probeID: "pending", token: token!, action: .tap { target.count += 1 })
        }
        target = nil
        XCTAssertNotNil(retiredTarget)
        token = nil
        XCTAssertNil(retiredToken)
        XCTAssertNil(retiredTarget)
        XCTAssertThrowsError(try ProbeAction.tap("pending").apply(to: state))
    }

    @MainActor
    func testSupersededUndeliveredLeaseReleasesItsTargetAndCannotReturn() throws {
        let state = ScenarioState()
        let old = ScenarioState.SiteToken()
        let current = ScenarioState.SiteToken()
        var target: RegistrationLifetimeTarget? = RegistrationLifetimeTarget()
        weak var retired: RegistrationLifetimeTarget?
        retired = target
        if let target { state.registerSite(probeID: "same", token: old, action: .tap { target.count += 1 }) }
        target = nil
        var currentCalls = 0
        state.registerSite(probeID: "same", token: current, action: .tap { currentCalls += 1 })
        XCTAssertNil(retired)
        state.admitSites(["same": [current]])
        state.admitSites(["same": [old]])
        try ProbeAction.tap("same").apply(to: state)
        XCTAssertEqual(currentCalls, 1)
    }

    @MainActor
    func testSiteLeaseCannotTransferBetweenHostsOrProbeIDs() throws {
        let first = ScenarioState()
        let second = ScenarioState()
        let token = ScenarioState.SiteToken()
        var originalCalls = 0
        var otherCalls = 0
        first.registerSite(probeID: "original", token: token, action: .tap { originalCalls += 1 })
        first.admitSites(["original": [token]])
        second.registerSite(probeID: "original", token: token, action: .tap { otherCalls += 1 })
        second.admitSites(["original": [token]])
        XCTAssertThrowsError(try ProbeAction.tap("original").apply(to: second))
        first.registerSite(probeID: "other", token: token, action: .tap { otherCalls += 1 })
        first.admitSites(["original": [token], "other": [token]])
        XCTAssertThrowsError(try ProbeAction.tap("other").apply(to: first))
        try ProbeAction.tap("original").apply(to: first)
        XCTAssertEqual(originalCalls, 1)
        XCTAssertEqual(otherCalls, 0)
    }

    @MainActor
    func testRetirementClearsRetainedPendingLeaseAndNeverRevealsDurableFallback() {
        let state = ScenarioState()
        let token = ScenarioState.SiteToken()
        var target: RegistrationLifetimeTarget? = RegistrationLifetimeTarget()
        weak var retiredTarget: RegistrationLifetimeTarget?
        retiredTarget = target
        if let target {
            state.registerSite(probeID: "pending", token: token, action: .tap { target.count += 1 })
        }
        var fallbackCalls = 0
        state.registerTap("pending") { fallbackCalls += 1 }
        target = nil
        state.retireSites()
        XCTAssertNil(retiredTarget, "even a still-retained undelivered lease must release its binding")
        XCTAssertThrowsError(try ProbeAction.tap("pending").apply(to: state))
        XCTAssertEqual(fallbackCalls, 0)
        XCTAssertTrue(state.actionableProbes.isEmpty)
        withExtendedLifetime(token) {}
    }

    @MainActor
    func testOlderPreferenceCannotRetireAnUndeliveredReplacement() throws {
        let state = ScenarioState()
        let old = ScenarioState.SiteToken()
        let replacement = ScenarioState.SiteToken()
        var oldCalls = 0
        var replacementCalls = 0
        state.registerSite(probeID: "same", token: old, action: .tap { oldCalls += 1 })
        state.admitSites(["same": [old]])
        state.registerSite(probeID: "same", token: replacement, action: .tap { replacementCalls += 1 })
        // A delivery already in flight may still describe the previous render.
        state.admitSites(["same": [old]])
        state.admitSites(["same": [replacement]])
        XCTAssertEqual(state.actionableProbes["same"], ["tap"])
        try ProbeAction.tap("same").apply(to: state)
        XCTAssertEqual(replacementCalls, 1)
        XCTAssertEqual(oldCalls, 0)
    }

    @MainActor
    func testAdmittedOwnerRefreshCannotDisplacePendingReplacement() throws {
        let state = ScenarioState()
        let old = ScenarioState.SiteToken()
        let replacement = ScenarioState.SiteToken()
        var oldCalls = 0
        var replacementCalls = 0
        state.registerSite(probeID: "same", token: old, action: .tap { oldCalls += 1 })
        state.admitSites(["same": [old]])
        state.registerSite(probeID: "same", token: replacement, action: .tap { replacementCalls += 1 })
        state.registerSite(probeID: "same", token: old, action: .tap { oldCalls += 10 })
        state.admitSites(["same": [replacement]])
        try ProbeAction.tap("same").apply(to: state)
        XCTAssertEqual(replacementCalls, 1)
        XCTAssertEqual(oldCalls, 0)
    }

    @MainActor
    func testLongLivedStateDoesNotAccumulateRetiredSiteMetadata() {
        let state = ScenarioState()
        func churn() {
            let token = ScenarioState.SiteToken()
            state.registerSite(probeID: "same", token: token, action: .tap {})
            state.admitSites(["same": [token]])
            state.admitSites([:])
        }
        churn()
        let first = retainedCollectionEntries(state)
        for _ in 0..<1_000 { churn() }
        let after = retainedCollectionEntries(state)
        print("site-churn entries after1=\(first) after1001=\(after)")
        XCTAssertLessThanOrEqual(after, first, "one stable ID must not retain per-incarnation history")
    }

    @MainActor
    func testPermanentSiteRetirementReleasesAllAdmissionMetadata() {
        let state = ScenarioState()
        for index in 0..<100 {
            let id = "site-\(index)"
            let token = ScenarioState.SiteToken()
            state.registerSite(probeID: id, token: token, action: .tap {})
            state.admitSites([id: [token]])
        }
        state.retireSites()
        let entries = retainedCollectionEntries(state)
        print("site-retirement retained entries=\(entries)")
        XCTAssertEqual(entries, 0, "permanently disabled admission needs no identity history")
    }

    // Inspect retained collection size rather than process RSS: allocator caches
    // cannot hide linear identity growth or make this deterministic check flaky.
    private func retainedCollectionEntries(_ state: ScenarioState) -> Int {
        Mirror(reflecting: state).children.reduce(0) { total, child in
            let value = Mirror(reflecting: child.value)
            return total + ([.dictionary, .set].contains(value.displayStyle) ? value.children.count : 0)
        }
    }

    @MainActor
    func testFactoryBindingsOutliveStateWithoutRetainingIt() throws {
        var state: ScenarioState? = ScenarioState()
        weak var retired: ScenarioState?
        retired = state
        let bool = state!.boolBinding("bool", default: true)
        let text = state!.stringBinding("text", default: "seed")
        let slider = state!.doubleBinding("slider", default: 0.25)
        state!.register(probeID: "bool", action: .bool(bool))
        state!.register(probeID: "text", action: .text(text))
        state!.register(probeID: "slider", action: .slider(slider))
        state = nil
        XCTAssertNil(retired, "a registered factory binding must not form a state cycle")
        XCTAssertTrue(bool.wrappedValue)
        XCTAssertEqual(text.wrappedValue, "seed")
        XCTAssertEqual(slider.wrappedValue, 0.25)
        bool.wrappedValue = false
        text.wrappedValue = "retained cell"
        slider.wrappedValue = 0.75
        XCTAssertFalse(bool.wrappedValue)
        XCTAssertEqual(text.wrappedValue, "retained cell")
        XCTAssertEqual(slider.wrappedValue, 0.75)
    }

    @MainActor
    func testFactoryActionPublishesExactlyOnce() throws {
        let state = ScenarioState()
        let binding = state.boolBinding("toggle")
        state.register(probeID: "toggle", action: .bool(binding))
        var notifications = 0
        let subscription = state.objectWillChange.sink { notifications += 1 }
        defer { subscription.cancel() }
        try ProbeAction.toggle("toggle").apply(to: state)
        XCTAssertTrue(binding.wrappedValue)
        XCTAssertEqual(notifications, 1)
        binding.wrappedValue = false
        XCTAssertEqual(notifications, 2)
    }

    @MainActor
    func testManualRegistrationReplacesTargetAndTypeWithoutWritingDuringRegistration() throws {
        let state = ScenarioState()
        var old = false
        var current = true
        var text = "seed"
        state.register(probeID: "same", action: .bool(Binding(get: { old }, set: { old = $0 })))
        state.register(probeID: "same", action: .bool(Binding(get: { current }, set: { current = $0 })))
        XCTAssertTrue(current)
        try ProbeAction.toggle("same").apply(to: state)
        XCTAssertFalse(current, "toggle must read the latest external value")
        XCTAssertFalse(old, "the superseded target must not be changed")
        state.register(probeID: "same", action: .text(Binding(get: { text }, set: { text = $0 })))
        XCTAssertEqual(state.actionableProbes["same"], ["setText"])
        XCTAssertThrowsError(try ProbeAction.toggle("same").apply(to: state))
        try ProbeAction.setText("same", "changed").apply(to: state)
        XCTAssertEqual(text, "changed")
        XCTAssertFalse(current)
    }

    @MainActor
    func testSiteOwnershipRefusesFallbackAndLateTokensCannotReplaceNewOwner() throws {
        let state = ScenarioState()
        let factory = state.boolBinding("same")
        var manual = 0
        var old = 0
        var current = 0
        state.registerTap("same") { manual += 1 }
        let oldToken = ScenarioState.SiteToken()
        let currentToken = ScenarioState.SiteToken()
        state.registerSite(probeID: "same", token: oldToken, action: .tap { old += 1 })
        XCTAssertNil(state.actionableProbes["same"], "site ownership fences durable records before admission")
        XCTAssertThrowsError(try ProbeAction.tap("same").apply(to: state))
        state.admitSites(["same": [oldToken]])
        try ProbeAction.tap("same").apply(to: state)
        XCTAssertEqual(old, 1)
        state.registerSite(probeID: "same", token: currentToken, action: .tap { current += 1 })
        state.admitSites(["same": [currentToken]])
        state.registerSite(probeID: "same", token: oldToken, action: .tap { old += 100 })
        state.admitSites(["same": [oldToken]])
        try ProbeAction.tap("same").apply(to: state)
        XCTAssertEqual(current, 1, "late old-token updates must not overwrite or revoke the current owner")
        XCTAssertEqual(old, 1)
        state.admitSites([:])
        XCTAssertNil(state.actionableProbes["same"])
        XCTAssertThrowsError(try ProbeAction.tap("same").apply(to: state))
        XCTAssertThrowsError(try ProbeAction.toggle("same").apply(to: state))
        XCTAssertEqual(manual, 0)
        XCTAssertFalse(factory.wrappedValue)
    }

    @MainActor
    func testSiteCallbackRefreshReplacesTypeAndRetirementCannotBeReactivated() throws {
        let state = ScenarioState()
        let token = ScenarioState.SiteToken()
        var bool = false
        var text = "seed"
        state.registerSite(probeID: "same", token: token,
                           action: .bool(Binding(get: { bool }, set: { bool = $0 })))
        state.admitSites(["same": [token]])
        state.registerSite(probeID: "same", token: token,
                           action: .text(Binding(get: { text }, set: { text = $0 })))
        XCTAssertEqual(state.actionableProbes["same"], ["setText"])
        XCTAssertThrowsError(try ProbeAction.toggle("same").apply(to: state))
        try ProbeAction.setText("same", "changed").apply(to: state)
        XCTAssertFalse(bool)
        XCTAssertEqual(text, "changed")
        state.retireSites()
        state.registerSite(probeID: "same", token: ScenarioState.SiteToken(), action: .tap { text = "late" })
        state.admitSites(["same": [token]])
        XCTAssertNil(state.actionableProbes["same"])
        XCTAssertThrowsError(try ProbeAction.tap("same").apply(to: state))
        XCTAssertEqual(text, "changed")
    }

    /// The body is handed a state, the tree it produces varies on that state, and
    /// each host owns its own instance.
    ///
    /// "Varies on the state" is meant literally: the probed attribute below is
    /// computed from the `ScenarioState` the body received — `true` when it is the
    /// first instance the witness ever saw, `false` otherwise — so the two hosts
    /// produce two different trees for the same scenario value, and the only thing
    /// that differed between them was the state.
    ///
    /// One host owning one state is the guarantee Wave 3 needs: an action that
    /// mutates a binding registered at a probe site must reach the same object the
    /// next body evaluation reads. Two hosts sharing one would be worse than
    /// useless — a verdict for scenario A could be changed by acting on scenario B.
    @MainActor
    func testEachHostHandsItsBodyItsOwnScenarioState() async throws {
        let witness = StateWitness()
        let viewport = Size(width: 120, height: 60)

        let first = OracleHost(scenario: WitnessScenario(witness: witness), viewport: viewport)
        let firstTree = try await first.currentTree()
        XCTAssertEqual(
            try Self.attribute("is-first-state", of: "witness", in: firstTree),
            .bool(true),
            "the first host's body did not receive the first state the witness saw"
        )

        let second = OracleHost(scenario: WitnessScenario(witness: witness), viewport: viewport)
        let secondTree = try await second.currentTree()
        XCTAssertEqual(
            try Self.attribute("is-first-state", of: "witness", in: secondTree),
            .bool(false),
            "the second host reused the first host's ScenarioState"
        )

        XCTAssertEqual(witness.evaluations, 2, "each host must evaluate the body exactly once here")
        XCTAssertEqual(
            witness.distinctInstances,
            2,
            "two hosts must own two states, not share one"
        )
        XCTAssertNotEqual(
            firstTree,
            secondTree,
            "the trees are identical, so nothing in this test actually varied on the state"
        )
    }

    /// The other direction of the same guarantee, and the one Wave 3 actually
    /// leans on: *within* one host, every re-evaluation of the body is handed the
    /// **same** state object.
    ///
    /// ``testEachHostHandsItsBodyItsOwnScenarioState()`` proves two hosts do not
    /// share a state; that is the "not too shared" half. This is the "not too
    /// fresh" half, and without it the documented contract ("handed to every
    /// re-evaluation of the same scenario's body, never replaced between renders")
    /// would be enforced only by `ScenarioRoot.state` happening to be a `let` —
    /// a property nothing would fail if someone made it `@State` while chasing
    /// something else. An action that mutates a binding is worthless if the next
    /// body evaluation reads a different object.
    ///
    /// Re-evaluation is provoked, not waited for: `ScenarioRoot` has no mutable
    /// dependency of its own, so the scenario reads an `@Observable` counter and
    /// the test bumps it. That read happens inside `ScenarioRoot`'s body
    /// evaluation, so bumping it invalidates exactly the view whose re-evaluation
    /// is under test.
    @MainActor
    func testOneHostHandsEveryReEvaluationTheSameScenarioState() async throws {
        let witness = StateWitness()
        let trigger = RenderTrigger()
        let host = OracleHost(
            scenario: RerenderWitnessScenario(witness: witness, trigger: trigger),
            viewport: Size(width: 120, height: 60)
        )

        let firstTree = try await host.currentTree()
        XCTAssertEqual(
            try Self.attribute("generation", of: "witness", in: firstTree),
            .number(0)
        )
        let evaluationsAfterFirstRender = witness.evaluations

        trigger.generation += 1
        let secondTree = try await host.currentTree()

        XCTAssertEqual(
            try Self.attribute("generation", of: "witness", in: secondTree),
            .number(1),
            "the tree still reports generation 0, so the body was never re-evaluated and this "
                + "test cannot say anything about what a re-evaluation receives"
        )
        XCTAssertGreaterThan(
            witness.evaluations,
            evaluationsAfterFirstRender,
            "no further body evaluation happened after the invalidation"
        )
        XCTAssertEqual(
            witness.distinctInstances,
            1,
            "one host handed its body \(witness.distinctInstances) different ScenarioState "
                + "objects across \(witness.evaluations) evaluations; a Wave 3 binding "
                + "registered on the first would be orphaned by the second"
        )
    }

    /// The measurement pass that resolves `fittingSize` must not hand the real
    /// render its state, or Wave 3's bindings would be registered against an
    /// object that is about to be thrown away.
    @MainActor
    func testTheFittingSizeMeasurementPassUsesAThrowawayState() async throws {
        let witness = StateWitness()
        let host = OracleHost(scenario: WitnessScenario(witness: witness))
        _ = try await host.currentTree()

        XCTAssertEqual(
            witness.evaluations,
            2,
            "sizing by fittingSize evaluates the body once to measure and once to render"
        )
        XCTAssertEqual(
            witness.distinctInstances,
            2,
            "the measurement pass and the render pass shared a ScenarioState"
        )
    }

    // MARK: - Outside the harness

    /// A scenario is an ordinary view, so it renders with no harness at all — the
    /// `#Preview` story, and the reason ``ScenarioState`` has a public
    /// initializer.
    @MainActor
    func testAScenarioBodyRendersWithNoHarnessAtAll() {
        let view = NSHostingView(rootView: GreetingScenario().body(state: ScenarioState()))
        let fitting = view.fittingSize

        XCTAssertGreaterThan(fitting.width, 0, "the bare scenario body laid out to zero width")
        XCTAssertGreaterThan(fitting.height, 0, "the bare scenario body laid out to zero height")
    }

    // MARK: - Helpers

    private static func attribute(
        _ key: String,
        of id: String,
        in tree: SemanticNode
    ) throws -> AttributeValue {
        let node = try XCTUnwrap(tree.node(withID: id), "no node with id '\(id)' in the tree")
        return try XCTUnwrap(node.attributes[key], "node '\(id)' carries no '\(key)' attribute")
    }
}

// MARK: - Scenarios under test

private struct GreetingScenario: VerdictScenario {
    let name = "greeting-screen"

    func body(state: ScenarioState) -> some View {
        Text("Hello").verdictProbe("greeting", role: .text, text: "Hello")
    }
}

/// Reports, through the tree, which ``ScenarioState`` its body was handed.
private struct WitnessScenario: VerdictScenario {
    let name = "witness"

    let witness: StateWitness

    func body(state: ScenarioState) -> some View {
        Color.clear
            .frame(width: 40, height: 20)
            .verdictProbe(
                "witness",
                role: .container,
                attributes: ["is-first-state": .bool(witness.note(state))]
            )
    }
}

/// An invalidation handle: the scenario reads ``generation`` during its body
/// evaluation, so bumping it makes SwiftUI re-evaluate that body.
///
/// `@Observable` rather than a `@State` inside some child view, deliberately —
/// the read has to happen in the same body evaluation that calls
/// `scenario.body(state:)`, or the re-evaluation under test would be a child's
/// and not the scenario's.
@Observable
@MainActor
private final class RenderTrigger {
    var generation = 0
}

/// Reports both the state identity and the generation it was rendered at, so a
/// missing re-evaluation is distinguishable from a re-evaluation with a fresh
/// state.
private struct RerenderWitnessScenario: VerdictScenario {
    let name = "rerender-witness"

    let witness: StateWitness
    let trigger: RenderTrigger

    func body(state: ScenarioState) -> some View {
        Color.clear
            .frame(width: 40, height: 20)
            .verdictProbe(
                "witness",
                role: .container,
                attributes: [
                    "generation": .number(Double(trigger.generation)),
                    "is-first-state": .bool(witness.note(state)),
                ]
            )
    }
}

/// Records the states a scenario body was handed, and whether they were the same
/// object.
@MainActor
private final class StateWitness {
    private(set) var evaluations = 0
    private var seen: [ObjectIdentifier] = []
    private var firstSeen: ScenarioState?

    /// How many distinct `ScenarioState` objects have been handed to the body.
    var distinctInstances: Int { Set(seen).count }

    /// Record `state` and report whether it is the first one ever seen.
    func note(_ state: ScenarioState) -> Bool {
        evaluations += 1
        seen.append(ObjectIdentifier(state))
        guard let firstSeen else {
            self.firstSeen = state
            return true
        }
        return firstSeen === state
    }
}

@MainActor
private final class RegistrationLifetimeTarget {
    var count = 0
}
