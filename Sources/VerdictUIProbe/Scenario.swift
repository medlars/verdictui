// VerdictUIProbe — SwiftUI instrumentation runtime.
//
// Wave 2 Task 4: what a caller hands the harness. A scenario is a name plus a
// view — nothing more — because everything else the harness needs (the sink, the
// coordinate space, the pinned environment, the host size) is the harness's job
// to supply. A scenario author who has to remember to apply `.verdictRoot(into:)`
// is an author who will forget, and the failure mode of forgetting is an empty
// tree that looks like a passing verdict.
import SwiftUI

/// The state handed to a scenario body on every evaluation.
///
/// ### What it is in Wave 2
///
/// An empty, harness-owned box with a stable identity. That is deliberately all
/// it is: the type exists now so the `body(state:)` signature does not have to
/// change later, and so that the *lifetime* guarantee later waves depend on can
/// be established and tested now — one `ScenarioState` per ``OracleHost``,
/// handed to every re-evaluation of the same scenario's body, never replaced
/// between renders.
///
/// A reference type for exactly that reason. A struct would be copied into each
/// body evaluation, so nothing a later wave stores here could survive a
/// re-render, and the guarantee would be untestable — there would be no identity
/// to compare. `@MainActor` because SwiftUI evaluates bodies on the main actor
/// and Wave 3 will mutate this from action injection, so isolating it to the
/// actor that already owns it makes "no locks, no races" a compiler-checked claim
/// rather than a comment.
///
/// ### What lands here later
///
/// - **Wave 3 (settle engine + action injection)**: bindings registered at probe
///   sites, so `ProbeAction.tap("save")` mutates the scenario's own state
///   in-process instead of synthesizing an event.
/// - **Wave 5 (variant sweeps)**: named states and transitions, so
///   `Sweep.walk(paths:)` can drive a scenario through a state machine and take a
///   verdict per step.
///
/// Neither is modelled here. A speculative `actions` dictionary or a `variant`
/// field would be API that nothing reads, tested by nothing, and shaped by a
/// guess about a wave that has not been designed yet — and it would have to be
/// changed anyway once Wave 3 discovers what a binding registration actually
/// needs to carry.
@MainActor
public final class ScenarioState {
    /// Creates a state box.
    ///
    /// Public because a caller rendering a scenario body outside the harness — in
    /// a `#Preview`, or in a unit test that only wants the view — needs one, and
    /// making it internal would mean a scenario body could only ever be evaluated
    /// by VerdictUI. There is nothing to configure and nothing to get wrong.
    public init() {}
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
