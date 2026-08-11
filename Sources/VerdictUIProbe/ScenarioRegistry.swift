// VerdictUIProbe — SwiftUI instrumentation runtime.
//
// Wave 4 Task 3: the registry `#VerdictScenario` registers into, and the type
// Wave 6's `verdictui list` enumerates. Registration is STATIC — a declared
// list, never a runtime scan — for the reason spelled out on `ScenarioRegistry`.
import Foundation
import SwiftUI
import VerdictUIKernel

/// One registered scenario, erased to something a `for` loop can hold.
///
/// ### Why an existential does not work here
///
/// The obvious spelling is `[any VerdictScenario]`, and it does not compile
/// against the harness: ``OracleHost/init(scenario:viewport:deadline:settlePolicy:clock:)``
/// is generic over `Scenario: VerdictScenario` so the scenario's `Body` type
/// survives into the hosted view tree, and a `VerdictScenario` existential
/// cannot satisfy that constraint — the protocol has an associated type, so
/// there is no `Body` for the compiler to instantiate `NSHostingView` with.
///
/// What is erased is the *construction*, not the scenario: each entry stores a
/// closure that builds the concrete scenario and hands it to the generic
/// initializer inside its own generic context, where the type is still known.
/// ``VerdictUIDemoScenarios/DemoScenarioEntry`` reached the same shape
/// independently in Wave 2; this is that pattern generalised for consumers.
public struct ScenarioEntry: Sendable {
    /// The scenario's own ``VerdictScenario/name``, read off a constructed
    /// instance rather than restated, so an entry and its scenario cannot
    /// disagree about what a verdict is filed under.
    public let name: String

    /// The viewport this scenario asks to be rendered at, or `nil` to let
    /// ``OracleHost`` measure one.
    public let viewport: Size?

    /// Builds a host for the concrete scenario. A closure because the concrete
    /// type exists only inside ``init(viewport:make:)``.
    private let makeHost: @Sendable @MainActor (Size?, TimeInterval, Variant?) -> OracleHost

    /// - Parameters:
    ///   - viewport: value for ``viewport``.
    ///   - make: builds a fresh scenario. Called once here to read the name, and
    ///     again for every host — a fresh value each time, because a host owns
    ///     the render it was constructed for and two hosts must not share one.
    public init<Scenario: VerdictScenario & Sendable>(
        viewport: Size? = nil,
        make: @escaping @Sendable () -> Scenario
    ) {
        self.name = make().name
        self.viewport = viewport
        self.makeHost = { viewport, deadline, variant in
            OracleHost(
                scenario: make(),
                viewport: viewport,
                deadline: deadline,
                variant: variant
            )
        }
    }

    /// A fresh ``OracleHost`` rendering this scenario.
    ///
    /// - Parameters:
    ///   - viewport: size to render at; defaults to this entry's ``viewport``.
    ///   - deadline: settle budget, forwarded to the host.
    ///   - variant: environment overrides for a sweep cell, forwarded to the
    ///     host. Registry entries could not carry one until Wave 6: the stored
    ///     closure dropped the parameter, so `verdictui sweep` over a REGISTERED
    ///     scenario would have rendered the baseline environment for every cell
    ///     while reporting each cell's variant name — the silent failure
    ///     ``SweepTests/testVariantsActuallyChangeTheRenderedTree`` exists to
    ///     catch, arriving through a surface that test does not cover.
    @MainActor
    public func host(
        viewport override: Size? = nil,
        deadline: TimeInterval = OracleHost.defaultDeadline,
        variant: Variant? = nil
    ) -> OracleHost {
        makeHost(override ?? viewport, deadline, variant)
    }
}

/// A named collection of scenarios, built from a static list.
///
/// ### Why registration is static and not a runtime scan
///
/// The tempting design is a global mutable registry that each scenario adds
/// itself to from a type-level initializer. Swift has no such hook — there is no
/// portable "run this at load" for a struct — and the ways to fake one are all
/// worse than an explicit list: an `+load`-style ObjC hook does not exist for
/// Swift value types, and a runtime scan of loaded types is exactly the
/// reflection this design rules out (it is slow, it breaks under dead-code
/// stripping, and it makes "which scenarios exist" depend on link order rather
/// than on anything readable).
///
/// So the macro generates the ENTRY and the author names it in one list. The
/// cost is one line per scenario; what it buys is that the set of scenarios is
/// a value you can read, diff, and test — and a scenario that was never listed
/// fails visibly at the list rather than by being silently absent from a run.
///
/// ```swift
/// #VerdictScenario("checkout") {
///     Text("Total: $42.00")
/// }
///
/// let registry = ScenarioRegistry([CheckoutScenario.verdictEntry])
/// ```
public struct ScenarioRegistry: Sendable {
    /// Every registered entry, in the order given.
    public let entries: [ScenarioEntry]

    /// - Parameter entries: the scenarios this registry holds. Duplicate names
    ///   are preserved rather than rejected here — ``duplicateNames`` reports
    ///   them, so a caller can decide whether a duplicate is a build error or a
    ///   warning, and a registry can still be constructed for inspection when
    ///   one exists. Silently dropping a duplicate would make a scenario vanish
    ///   from a run with nothing anywhere saying so.
    public init(_ entries: [ScenarioEntry]) {
        self.entries = entries
    }

    /// Every scenario name, in registration order.
    public var names: [String] { entries.map(\.name) }

    /// The entry registered under `name`, or `nil`.
    ///
    /// Returns the FIRST match when names collide; ``duplicateNames`` is how a
    /// caller learns that happened, because a lookup that silently prefers one
    /// of two identically-named scenarios cannot report which it chose.
    public func entry(named name: String) -> ScenarioEntry? {
        entries.first { $0.name == name }
    }

    /// Names registered more than once, sorted.
    ///
    /// A name is a verdict's filing key and, from Wave 5, a baseline key — so a
    /// collision silently files two scenarios' results under one identity. This
    /// is reported rather than prevented at `init` so the registry is
    /// constructible for inspection: a tool that cannot build the registry
    /// cannot tell the author which names collided.
    public var duplicateNames: [String] {
        var seen: Set<String> = []
        var duplicates: Set<String> = []
        for name in names {
            if seen.contains(name) {
                duplicates.insert(name)
            }
            seen.insert(name)
        }
        return duplicates.sorted()
    }
}
