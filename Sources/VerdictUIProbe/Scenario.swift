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
    // Cells let a returned factory binding outlive this state without retaining it.
    private final class Cell<Value> {
        var value: Value
        init(_ value: Value) { self.value = value }
    }

    fileprivate enum ActionRecord {
        case bool(get: () -> Bool, set: (Bool) -> Void)
        case text(get: () -> String, set: (String) -> Void)
        case slider(get: () -> Double, set: (Double) -> Void)
        case tap(() -> Void)

        init(_ action: ProbeSiteAction) {
            switch action {
            case .bool(let binding):
                self = .bool(get: { binding.wrappedValue }, set: { binding.wrappedValue = $0 })
            case .text(let binding):
                self = .text(get: { binding.wrappedValue }, set: { binding.wrappedValue = $0 })
            case .slider(let binding):
                self = .slider(get: { binding.wrappedValue }, set: { binding.wrappedValue = $0 })
            case .tap(let handler): self = .tap(handler)
            }
        }

        var verbs: [String] {
            switch self {
            case .bool: ["tap", "toggle"]
            case .text: ["setText"]
            case .slider: ["setSlider"]
            case .tap: ["tap"]
            }
        }
    }

    /// A modifier owns this lease. Retirement travels with the lease itself,
    /// so rejecting a late delivery needs no append-only identity tombstones.
    @MainActor
    final class SiteToken: Hashable {
        fileprivate weak var owner: ScenarioState?
        fileprivate var id: String?
        fileprivate var action: ActionRecord?
        fileprivate var isRetired = false

        nonisolated static func == (lhs: SiteToken, rhs: SiteToken) -> Bool { lhs === rhs }
        nonisolated func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }

        fileprivate func retire() {
            isRetired = true
            action = nil
        }
    }

    private struct SiteSlot {
        var admitted: SiteToken?
        weak var pending: SiteToken?
    }

    private var bools: [String: Cell<Bool>] = [:]
    private var strings: [String: Cell<String>] = [:]
    private var doubles: [String: Cell<Double>] = [:]
    private var manual: [String: ActionRecord] = [:]
    private var sites: [String: SiteSlot] = [:]
    private var sitesRetired = false
    private var performingAction = false

    public init() {}

    // MARK: - Durable binding factories

    /// The first call seeds the cell; later calls preserve its value. The binding
    /// owns its scalar cell, and only weakly references this state's publisher.
    public func boolBinding(_ id: String, default defaultValue: Bool = false) -> Binding<Bool> {
        if bools[id] == nil { bools[id] = Cell(defaultValue) }
        let cell = bools[id]!
        return Binding(get: { cell.value }, set: { [weak self] value in
            self?.publishBindingWrite()
            cell.value = value
        })
    }

    public func stringBinding(_ id: String, default defaultValue: String = "") -> Binding<String> {
        if strings[id] == nil { strings[id] = Cell(defaultValue) }
        let cell = strings[id]!
        return Binding(get: { cell.value }, set: { [weak self] value in
            self?.publishBindingWrite()
            cell.value = value
        })
    }

    public func doubleBinding(_ id: String, default defaultValue: Double = 0) -> Binding<Double> {
        if doubles[id] == nil { doubles[id] = Cell(defaultValue) }
        let cell = doubles[id]!
        return Binding(get: { cell.value }, set: { [weak self] value in
            self?.publishBindingWrite()
            cell.value = value
        })
    }

    private func publishBindingWrite() {
        if !performingAction { objectWillChange.send() }
    }

    /// A durable manual registration. The newest manual action replaces its
    /// predecessor and takes precedence over a same-ID factory binding.
    public func registerTap(_ id: String, _ handler: @escaping () -> Void) {
        register(probeID: id, action: .tap(handler))
    }

    /// Register operations on the supplied current target, without writing or
    /// publishing during registration. Unlike the old snapshot implementation,
    /// typed actions invoke this binding's setter; constants remain unchanged.
    /// These closures retain the binding for the registration's lifetime.
    public func register(probeID id: String, action: ProbeSiteAction) {
        manual[id] = ActionRecord(action)
    }

    // MARK: - Rendered site ownership (private to the probe module)

    func registerSite(probeID id: String, token: SiteToken, action: ProbeSiteAction) {
        guard !sitesRetired, !token.isRetired else { return }
        guard token.owner == nil || token.owner === self else { return }
        guard token.id == nil || token.id == id else { return }
        token.owner = self
        token.id = id
        token.action = ActionRecord(action)
        var slot = sites[id] ?? SiteSlot()
        if token !== slot.admitted && token !== slot.pending {
            slot.pending?.retire()
            slot.pending = token
        }
        sites[id] = slot
    }

    /// Preference delivery, independent of semantic tree equality, admits the
    /// currently rendered token. A superseded token can never regain ownership.
    func admitSites(_ tokens: [String: Set<SiteToken>]) {
        guard !sitesRetired else { return }
        for (id, var slot) in sites {
            let proposed = tokens[id] ?? []
            if !proposed.isEmpty && proposed.allSatisfy({ $0.isRetired }) {
                continue // A late old-token delivery cannot revoke a newer owner.
            }
            let next = proposed.count == 1 ? proposed.first : nil
            let valid = next.flatMap { token in
                token.owner === self && token.id == id && !token.isRetired
                    && (token === slot.admitted || token === slot.pending) ? token : nil
            }
            if let previous = slot.admitted, previous !== valid {
                previous.retire()
            }
            slot.admitted = valid
            if valid != nil && valid === slot.pending { slot.pending = nil }
            // An older delivery cannot retire a replacement whose preference
            // has not arrived. The modifier owns that weak pending lease.
            sites[id] = slot
        }
    }

    func retireSites() {
        sitesRetired = true
        for slot in sites.values {
            slot.admitted?.retire()
            slot.pending?.retire()
        }
        sites.removeAll()
    }

    // Site ownership permanently fences an ID for this state: missing/stale
    // admission never falls back to a manual record, a factory or an old site.
    private func record(for id: String) -> ActionRecord? {
        guard !sitesRetired else { return nil }
        if let slot = sites[id] {
            return slot.admitted?.action
        }
        if let action = manual[id] { return action }
        if bools[id] != nil {
            return ActionRecord(.bool(boolBinding(id)))
        }
        if strings[id] != nil {
            return ActionRecord(.text(stringBinding(id)))
        }
        if doubles[id] != nil {
            return ActionRecord(.slider(doubleBinding(id)))
        }
        return nil
    }

    /// Verbs are derived from the same current records consulted by dispatch.
    public var actionableProbes: [String: [String]] {
        let ids = Set(bools.keys).union(strings.keys).union(doubles.keys)
            .union(manual.keys).union(sites.keys)
        let result = Dictionary(uniqueKeysWithValues: ids.compactMap { id in
            record(for: id).map { (id, $0.verbs) }
        })
        return result
    }

    private func requiredRecord(_ id: String) throws -> ActionRecord {
        guard let action = record(for: id) else { throw ProbeActionError.unknownProbe(id) }
        return action
    }

    private func performWrite(_ body: () -> Void) {
        let previous = performingAction
        performingAction = true
        defer { performingAction = previous }
        if !previous { objectWillChange.send() }
        body()
    }

    // MARK: - ProbeAction performance

    func performTap(_ id: String) throws {
        switch try requiredRecord(id) {
        case .tap(let handler): performWrite(handler)
        case .bool(let get, let set): performWrite { set(!get()) }
        default: throw ProbeActionError.unknownProbe(id)
        }
    }

    func performToggle(_ id: String) throws {
        guard case .bool(let get, let set) = try requiredRecord(id) else {
            throw ProbeActionError.typeMismatch(id: id, expected: "bool")
        }
        performWrite { set(!get()) }
    }

    func performSetText(_ id: String, _ value: String) throws {
        guard case .text(_, let set) = try requiredRecord(id) else {
            throw ProbeActionError.typeMismatch(id: id, expected: "string")
        }
        performWrite { set(value) }
    }

    func performSetSlider(_ id: String, _ value: Double) throws {
        guard case .slider(_, let set) = try requiredRecord(id) else {
            throw ProbeActionError.typeMismatch(id: id, expected: "double")
        }
        performWrite { set(value) }
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
