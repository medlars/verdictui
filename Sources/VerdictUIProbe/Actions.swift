// VerdictUIProbe — SwiftUI instrumentation runtime.
//
// Wave 3 Task 3: in-process action injection. Actions mutate ``ScenarioState``
// bindings registered at probe sites — no CGEvent synthesis, no Accessibility
// permission. Wave 8's middle loop is the real-event channel; see docs/kernel.md
// "Trust levels" for the difference.
import SwiftUI

/// An in-process act against a probed control, keyed by probe id.
///
/// Each case names the probe it targets. ``custom`` exists for scenario-specific
/// mutations that do not fit the typed cases; its first associated value is still
/// a probe id (for evidence), and the closure receives the harness-owned
/// ``ScenarioState``.
public enum ProbeAction {
    /// Activate a control: fires a registered tap handler, or toggles a bool
    /// binding when the probe is a toggle without a separate tap handler.
    case tap(String)
    /// Replace the string binding registered for the probe.
    case setText(String, String)
    /// Flip the bool binding registered for the probe.
    case toggle(String)
    /// Replace the double binding registered for the probe.
    case setSlider(String, Double)
    /// Run an arbitrary mutation against the scenario state.
    case custom(String, @MainActor (ScenarioState) -> Void)

    /// Probe id every case carries — the evidence key for unknown-target failures.
    public var probeID: String {
        switch self {
        case .tap(let id), .toggle(let id), .setSlider(let id, _), .custom(let id, _):
            return id
        case .setText(let id, _):
            return id
        }
    }

    /// Stable, readable form used in step evidence and as a transition's
    /// identity within a ``ScenarioStateMachine``.
    ///
    /// Spelled by hand rather than derived from the enum: an interpolated case
    /// is a compiler detail that may change between toolchains, and a walk
    /// report keyed on it would not survive a Swift upgrade — the same reason
    /// ``Variant/describe(_:)-(DynamicTypeSize)`` spells its vocabulary out.
    ///
    /// The VALUE is part of the description for `setText`/`setSlider` because
    /// two transitions that differ only in what they type are two different
    /// moves; omitting it would make them collide as one ambiguous edge.
    /// ``custom`` cannot describe its closure, so it is identified by probe id
    /// alone — two custom transitions leaving one state with the same id are
    /// genuinely indistinguishable here, and the machine reports that as an
    /// ambiguity rather than picking one by declaration order.
    public var description: String {
        switch self {
        case .tap(let id): "tap(\(id))"
        case .setText(let id, let value): "setText(\(id), \"\(value)\")"
        case .toggle(let id): "toggle(\(id))"
        case .setSlider(let id, let value): "setSlider(\(id), \(value))"
        case .custom(let id, _): "custom(\(id))"
        }
    }

    /// Apply this action to `state`. Throws ``ProbeActionError`` when the probe
    /// has no compatible binding registered.
    @MainActor
    public func apply(to state: ScenarioState) throws {
        switch self {
        case .tap(let id):
            try state.performTap(id)
        case .setText(let id, let value):
            try state.performSetText(id, value)
        case .toggle(let id):
            try state.performToggle(id)
        case .setSlider(let id, let value):
            try state.performSetSlider(id, value)
        case .custom(_, let body):
            body(state)
        }
    }
}

/// Why an action could not be applied. Always names the probe id.
public enum ProbeActionError: Error, Equatable, CustomStringConvertible {
    /// No binding (or tap handler) was registered for this probe id.
    case unknownProbe(String)
    /// A binding exists but is the wrong type for this ``ProbeAction`` case.
    case typeMismatch(id: String, expected: String)

    public var description: String {
        switch self {
        case .unknownProbe(let id):
            return "no action binding registered for probe id '\(id)'"
        case .typeMismatch(let id, let expected):
            return "probe id '\(id)' has no \(expected) binding"
        }
    }

    /// Probe id cited in a finding or test failure.
    public var probeID: String {
        switch self {
        case .unknownProbe(let id), .typeMismatch(let id, _): id
        }
    }
}

/// What a `.verdictProbe(..., action:)` site registers onto ``ScenarioState``.
///
/// Distinct from ``ProbeAction`` (which is the *request* to mutate) — this is the
/// *capability* the scenario installs at a probe.
public enum ProbeSiteAction {
    case bool(Binding<Bool>)
    case text(Binding<String>)
    case slider(Binding<Double>)
    case tap(() -> Void)
}
