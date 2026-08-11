// VerdictUIDemoScenarios — the deliberately bug-rich catalog.
//
// Wave 2 Task 5: the catalog itself, plus the mechanism that lets a caller walk
// it. Everything interesting in this file is about that second half — see
// `DemoScenarioEntry` for why a `[any VerdictScenario]` is not available to us.
import Foundation
import SwiftUI
import VerdictUIKernel
import VerdictUIProbe

/// One catalog member, erased to something a `for` loop can hold.
///
/// ### Why an existential does not work here
///
/// The obvious enumeration is `[any VerdictScenario]`, and it does not compile
/// against the harness: ``OracleHost/init(scenario:viewport:deadline:)`` is
/// generic over `Scenario: VerdictScenario` so the scenario's `Body` type
/// survives into the hosted view tree, and a `VerdictScenario` existential
/// cannot satisfy that constraint — the protocol has an associated type, so
/// there is no `Body` for the compiler to instantiate `NSHostingView` with. The
/// generic parameter is not incidental either; erasing it at the host boundary
/// instead (`AnyView` per scenario) would put an extra layout-transparent node
/// in every hosted tree for the sake of a loop.
///
/// ### What is erased instead
///
/// The *construction* is, not the scenario. Each entry stores a closure that
/// builds the concrete scenario and hands it to the generic initializer inside
/// its own generic context, where the type is still known. The entry itself is
/// a plain struct, so `DemoScenarios.all` is an ordinary array and Task 6, the
/// executable, and Wave 5's sweeps all iterate it the same way.
///
/// The alternatives were weighed and rejected. An `enum` with one case per
/// scenario would put a `switch` in front of every use and would have to be
/// edited in two places for each new scenario — exactly the drift a catalog
/// exists to prevent. A protocol-witness table (a `DemoScenarioProviding`
/// metatype list) reintroduces the associated type at the call site and buys
/// nothing a closure does not.
///
/// ### Nothing here is an expectation
///
/// The entry carries what a *renderer* needs: a name, the viewport the scenario
/// was designed against, and the probe ids it claims to publish. It carries no
/// expected findings, deliberately. Task 6's job is to assert that each planted
/// defect trips a named rule, and an assertion written against a rule id
/// supplied by the very module under test would pass whatever the module
/// claimed. The expected finding per scenario is documented in each scenario's
/// own doc comment, where a human — not an assertion — reads it.
public struct DemoScenarioEntry {
    /// The scenario's own ``VerdictScenario/name``, read off a constructed
    /// instance rather than restated here, so the catalog and the scenario
    /// cannot disagree about what a verdict is filed under.
    public let name: String

    /// The viewport this scenario's documented behaviour was recorded at.
    ///
    /// Not a suggestion for ``OffscreenButtonScenario``, whose planted defect is
    /// defined relative to it; a convenience for the rest.
    public let recommendedViewport: Size

    /// The probe ids this scenario claims will be in the tree, in declaration
    /// order. A claim, verified by `DemoScenarioCatalogTests` against what the
    /// render actually produces — an id that stops appearing is a scenario that
    /// silently stopped exercising something.
    public let probeIDs: [String]

    /// Builds a host for the concrete scenario. Stored as a closure because the
    /// concrete type only exists inside ``init(viewport:probeIDs:make:)``.
    private let host: @Sendable @MainActor (Size, TimeInterval) -> OracleHost

    /// - Parameters:
    ///   - viewport: value for ``recommendedViewport``.
    ///   - probeIDs: value for ``probeIDs``.
    ///   - make: builds a fresh scenario. Called once here to read the name, and
    ///     again for every host — a fresh value each time, because a host owns
    ///     the render it was constructed for and two hosts must not share one.
    init<Scenario: VerdictScenario & Sendable>(
        viewport: Size,
        probeIDs: [String],
        make: @escaping @Sendable () -> Scenario
    ) {
        self.name = make().name
        self.recommendedViewport = viewport
        self.probeIDs = probeIDs
        self.host = { viewport, deadline in
            OracleHost(scenario: make(), viewport: viewport, deadline: deadline)
        }
    }

    /// A fresh ``OracleHost`` rendering this scenario.
    ///
    /// - Parameters:
    ///   - viewport: size to render at; defaults to ``recommendedViewport``.
    ///     Overriding it is legitimate (Wave 5 sweeps sizes) but changes what
    ///     the documented findings mean.
    ///   - deadline: settle budget, forwarded to the host.
    @MainActor
    public func makeHost(
        viewport: Size? = nil,
        deadline: TimeInterval = OracleHost.defaultDeadline
    ) -> OracleHost {
        host(viewport ?? recommendedViewport, deadline)
    }
}

/// The demo catalog: every scenario Wave 2 ships, with the viewport each was
/// designed against.
///
/// Five of the six plant exactly one defect apiece, one per rule that can be
/// planted in a single static layout; the sixth
/// (``CleanSettingsScenario``) plants none and exists to catch false positives.
/// ``ToggleLayoutScenario`` is enumerated in its clean default state and is
/// Wave 3's act-and-observe fixture.
///
/// Names are stable: from Wave 5 they are baseline keys, so renaming one
/// silently orphans a baseline.
public enum DemoScenarios {
    /// Every scenario in the catalog, in a fixed order.
    ///
    /// A computed property rather than a stored `static let`: the entries hold
    /// main-actor closures and are therefore not `Sendable`, so a stored global
    /// would be a concurrency hole the compiler is right to reject. Rebuilding
    /// six structs per access costs nothing measurable — no scenario is
    /// constructed until ``DemoScenarioEntry/makeHost(viewport:deadline:)`` is
    /// called.
    public static var all: [DemoScenarioEntry] {
        [
            DemoScenarioEntry(
                viewport: TruncatingLabelScenario.recommendedViewport,
                probeIDs: ["storage-title", "storage-detail"],
                make: { TruncatingLabelScenario() }
            ),
            DemoScenarioEntry(
                viewport: OverlappingBadgesScenario.recommendedViewport,
                probeIDs: ["offers-title", "badge-row", "badge-new", "badge-sale"],
                make: { OverlappingBadgesScenario() }
            ),
            DemoScenarioEntry(
                viewport: OffscreenButtonScenario.recommendedViewport,
                probeIDs: ["filters-title", "apply-button"],
                make: { OffscreenButtonScenario() }
            ),
            DemoScenarioEntry(
                viewport: UndersizedTapTargetScenario.recommendedViewport,
                probeIDs: ["notifications-title", "dismiss-button"],
                make: { UndersizedTapTargetScenario() }
            ),
            DemoScenarioEntry(
                viewport: ToggleLayoutScenario.recommendedViewport,
                probeIDs: ["advanced-toggle", "collapsed-summary"],
                make: { ToggleLayoutScenario() }
            ),
            DemoScenarioEntry(
                viewport: CleanSettingsScenario.recommendedViewport,
                probeIDs: [
                    "settings-title",
                    "card-layer",
                    "card-surface",
                    "card-pill",
                    "button-row",
                    "cancel-button",
                    "save-button",
                ],
                make: { CleanSettingsScenario() }
            ),
        ]
    }

    /// How many scenarios the catalog holds.
    ///
    /// Pinned as a literal so adding a scenario without extending the tests
    /// fails loudly, instead of the coverage test quietly measuring whatever is
    /// there. `DemoScenarioCatalogTests` holds it to `all.count`.
    public static let count = 6

    /// The entry named `name`, or `nil`. Names are unique, which
    /// `DemoScenarioCatalogTests` enforces.
    public static func entry(named name: String) -> DemoScenarioEntry? {
        all.first { $0.name == name }
    }

    /// The catalog as a ``ScenarioRegistry``, for the surfaces that consume one.
    ///
    /// ### Why the two entry types are not merged
    ///
    /// ``DemoScenarioEntry`` and ``ScenarioEntry`` erase the same thing for
    /// different reasons and carry different payloads: the demo entry claims a
    /// `probeIDs` list that `DemoScenarioCatalogTests` verifies against the
    /// render — a catalog-specific guard against a scenario that silently
    /// stopped exercising something — while the registry entry is what a
    /// CONSUMER's `#VerdictScenario` macro generates and knows nothing about
    /// probe ids. Collapsing them would either push a demo-only assertion into
    /// the consumer surface or drop it entirely.
    ///
    /// So this rebuilds rather than casts, and the scenarios are named
    /// explicitly. That is the same cost ``ScenarioRegistry``'s own doc comment
    /// accepts for static registration, and for the same reason: a scenario
    /// missing here fails visibly at the list rather than by being absent from
    /// a CLI run nobody audits.
    public static var registry: ScenarioRegistry {
        ScenarioRegistry([
            ScenarioEntry(viewport: TruncatingLabelScenario.recommendedViewport) {
                TruncatingLabelScenario()
            },
            ScenarioEntry(viewport: OverlappingBadgesScenario.recommendedViewport) {
                OverlappingBadgesScenario()
            },
            ScenarioEntry(viewport: OffscreenButtonScenario.recommendedViewport) {
                OffscreenButtonScenario()
            },
            ScenarioEntry(viewport: UndersizedTapTargetScenario.recommendedViewport) {
                UndersizedTapTargetScenario()
            },
            ScenarioEntry(viewport: ToggleLayoutScenario.recommendedViewport) {
                ToggleLayoutScenario()
            },
            ScenarioEntry(viewport: CleanSettingsScenario.recommendedViewport) {
                CleanSettingsScenario()
            },
        ])
    }
}
