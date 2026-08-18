// VerdictUIProbe — SwiftUI instrumentation runtime.
//
// Wave 2 Task 4 + Wave 3 Task 3: a scenario is a name plus a view; the harness
// owns the sink, coordinate space, pinned environment, and host size. Wave 3
// stores action bindings on ``ScenarioState`` so `ProbeAction` can mutate the
// same state the body reads.
import Combine
import SwiftUI

/// The state handed to a scenario body on every evaluation.
///
/// One instance per ``OracleHost``, handed to every re-evaluation of the same
/// scenario's body, never replaced between renders. A reference type so action
/// injection can mutate bindings that survive re-render. `ObservableObject` so
/// those mutations invalidate ``ScenarioRoot`` and SwiftUI rebuilds the tree.
///
/// ### Action bindings
///
/// Call ``boolBinding(_:default:)``, ``stringBinding(_:default:)``,
/// ``doubleBinding(_:default:)``, or ``registerTap(_:_:)`` from `body(state:)`
/// (typically with the same id as `.verdictProbe`), or pass a
/// ``ProbeSiteAction`` to `.verdictProbe(_:role:text:attributes:action:)`.
/// ``ProbeAction`` then mutates those registrations in-process.
@MainActor
public final class ScenarioState: ObservableObject {
    private var bools: [String: Bool] = [:]
    private var strings: [String: String] = [:]
    private var doubles: [String: Double] = [:]
    private var taps: [String: () -> Void] = [:]

    public init() {}

    // MARK: - Binding factories

    /// A bool binding keyed by probe id. The first call seeds `default`; later
    /// calls reuse the stored value so a re-render does not reset user/actions.
    public func boolBinding(
        _ id: String,
        default defaultValue: Bool = false
    ) -> Binding<Bool> {
        if bools[id] == nil {
            objectWillChange.send()
            bools[id] = defaultValue
        }
        return Binding(
            get: { self.bools[id] ?? defaultValue },
            set: {
                self.objectWillChange.send()
                self.bools[id] = $0
            }
        )
    }

    /// A string binding keyed by probe id.
    public func stringBinding(
        _ id: String,
        default defaultValue: String = ""
    ) -> Binding<String> {
        if strings[id] == nil {
            objectWillChange.send()
            strings[id] = defaultValue
        }
        return Binding(
            get: { self.strings[id] ?? defaultValue },
            set: {
                self.objectWillChange.send()
                self.strings[id] = $0
            }
        )
    }

    /// A double binding keyed by probe id (sliders).
    public func doubleBinding(
        _ id: String,
        default defaultValue: Double = 0
    ) -> Binding<Double> {
        if doubles[id] == nil {
            objectWillChange.send()
            doubles[id] = defaultValue
        }
        return Binding(
            get: { self.doubles[id] ?? defaultValue },
            set: {
                self.objectWillChange.send()
                self.doubles[id] = $0
            }
        )
    }

    /// Register a tap handler for a button-like probe.
    public func registerTap(_ id: String, _ handler: @escaping () -> Void) {
        taps[id] = handler
    }

    /// Install a ``ProbeSiteAction`` under `id` (used by `.verdictProbe(..., action:)`).
    ///
    /// For bool/text/slider, copies the current wrapped value into owned storage
    /// so later ``ProbeAction`` mutations do not need to retain the `Binding`
    /// (storing `Binding` values on the state object crashed headless hosts).
    public func register(probeID id: String, action: ProbeSiteAction) {
        switch action {
        case .bool(let binding):
            if bools[id] == nil {
                objectWillChange.send()
                bools[id] = binding.wrappedValue
            }
        case .text(let binding):
            if strings[id] == nil {
                objectWillChange.send()
                strings[id] = binding.wrappedValue
            }
        case .slider(let binding):
            if doubles[id] == nil {
                objectWillChange.send()
                doubles[id] = binding.wrappedValue
            }
        case .tap(let handler):
            taps[id] = handler
        }
    }

    // MARK: - Discovery

    /// Every probe that has a binding registered, mapped to the ``ProbeAction``
    /// verbs it accepts.
    ///
    /// This exists because `role` cannot answer the question. A role is a claim
    /// about what a node IS; actionability is a claim about what the harness can
    /// DRIVE, and a probe may carry `.toggle` with no binding behind it. Without
    /// this, a caller discovers actionability only by acting and being refused —
    /// which is discovery by failure, and on the shipped catalog it fails far
    /// more often than it succeeds.
    ///
    /// Derived from the same dictionaries ``performTap(_:)`` and its siblings
    /// consult, so the answer cannot drift from the behaviour: a second registry
    /// listing "what is actionable" would be a claim about the first one, and
    /// the two would disagree the moment either changed.
    ///
    /// A bool reports both `tap` and `toggle` because ``performTap(_:)`` falls
    /// through to a toggle when no separate handler is registered — the verbs
    /// listed are the ones that will actually be ACCEPTED, not the ones the
    /// storage is named after.
    ///
    /// Verbs are spelled out rather than derived from `ProbeAction` case names:
    /// an interpolated case is a compiler detail that may change between
    /// toolchains, the same reason ``ProbeAction/description`` spells its own.
    public var actionableProbes: [String: [String]] {
        var result: [String: [String]] = [:]
        for id in taps.keys { result[id, default: []].append("tap") }
        for id in bools.keys {
            // `tap` first: that is the order performTap tries them in.
            var verbs = result[id] ?? []
            if !verbs.contains("tap") { verbs.append("tap") }
            verbs.append("toggle")
            result[id] = verbs
        }
        for id in strings.keys { result[id, default: []].append("setText") }
        for id in doubles.keys { result[id, default: []].append("setSlider") }
        return result
    }

    // MARK: - ProbeAction performance

    func performTap(_ id: String) throws {
        if let handler = taps[id] {
            objectWillChange.send()
            handler()
            return
        }
        if bools[id] != nil {
            try performToggle(id)
            return
        }
        throw ProbeActionError.unknownProbe(id)
    }

    func performToggle(_ id: String) throws {
        guard let current = bools[id] else {
            if strings[id] != nil || doubles[id] != nil || taps[id] != nil {
                throw ProbeActionError.typeMismatch(id: id, expected: "bool")
            }
            throw ProbeActionError.unknownProbe(id)
        }
        objectWillChange.send()
        bools[id] = !current
    }

    func performSetText(_ id: String, _ value: String) throws {
        guard strings[id] != nil else {
            if bools[id] != nil || doubles[id] != nil || taps[id] != nil {
                throw ProbeActionError.typeMismatch(id: id, expected: "string")
            }
            throw ProbeActionError.unknownProbe(id)
        }
        objectWillChange.send()
        strings[id] = value
    }

    func performSetSlider(_ id: String, _ value: Double) throws {
        guard doubles[id] != nil else {
            if bools[id] != nil || strings[id] != nil || taps[id] != nil {
                throw ProbeActionError.typeMismatch(id: id, expected: "double")
            }
            throw ProbeActionError.unknownProbe(id)
        }
        objectWillChange.send()
        doubles[id] = value
    }
}

/// Installs the harness-owned ``ScenarioState`` so `.verdictProbe(..., action:)`
/// can register bindings without threading `state` through every modifier.
private struct VerdictScenarioStateKey: EnvironmentKey {
    static let defaultValue: ScenarioState? = nil
}

extension EnvironmentValues {
    /// The ``OracleHost``-owned scenario state, or `nil` outside a host.
    public var verdictScenarioState: ScenarioState? {
        get { self[VerdictScenarioStateKey.self] }
        set { self[VerdictScenarioStateKey.self] = newValue }
    }
}

/// One named, renderable subject for VerdictUI to verify.
///
/// ```swift
/// struct CheckoutScreen: VerdictScenario {
///     let name = "checkout"
///
///     func body(state: ScenarioState) -> some View {
///         VStack {
///             Text("Total: $42.00").verdictProbe("total", role: .text, text: "Total: $42.00")
///             Button("Pay") {}.verdictProbe("pay", role: .button, text: "Pay")
///         }
///     }
/// }
/// ```
///
/// ### What a conformance is responsible for, and what it is not
///
/// It supplies a ``name`` and a view. It does **not** apply
/// ``SwiftUI/View/verdictRoot(into:)``, install a `VerdictTreeSink`, pin the
/// environment, or choose a viewport: ``OracleHost`` does all four, so a scenario
/// cannot half-wire the pipeline and cannot be rendered with a different
/// environment than the one a verdict was recorded under.
///
/// ### Why `body` takes the state rather than reading it from the environment
///
/// An explicit parameter makes the injection point visible in the signature, so
/// Wave 3's action bindings and Wave 5's variant sweeps arrive as a change to
/// ``ScenarioState`` and to nothing else — no new modifier for authors to apply,
/// no environment key they can forget. It also keeps the state reachable in
/// `body`'s own scope, where a `Binding` must be constructed from.
///
/// `@ViewBuilder` so a body can be written as a bare list of views and use `if`
/// and `switch` like any other SwiftUI body. `@MainActor` because building a view
/// touches main-actor state; ``name`` is deliberately left unisolated so a
/// scenario can be constructed and listed (Wave 6's `verdictui list`) without
/// hopping to the main actor.
public protocol VerdictScenario {
    /// The view this scenario renders.
    associatedtype Body: View

    /// Stable, human-readable identity — the name a verdict is filed under, the
    /// name `verdictui verify <scenario>` takes, and the name a baseline is keyed
    /// by. Unique within a suite of scenarios; VerdictUI does not mangle it.
    var name: String { get }

    /// The view to verify, built with the harness-owned `state`.
    ///
    /// Called on every SwiftUI evaluation of the hosted root, not once per host,
    /// so it must be a function of its inputs: a body that captures the result of
    /// its own first evaluation (a lazily-created identifier, a random value)
    /// makes the resulting tree depend on how many times SwiftUI chose to
    /// re-evaluate it, which is the one thing a verification engine cannot have.
    @MainActor @ViewBuilder func body(state: ScenarioState) -> Body
}
