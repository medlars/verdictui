import SwiftUI
import VerdictUIKernel

/// One cell of a variant matrix: the environment a scenario is rendered under.
///
/// The `OracleHost` pins locale, colour scheme, dynamic type and layout
/// direction so a machine's own settings cannot change a verdict. A sweep needs
/// the opposite — to vary exactly those axes deliberately — so a `Variant`
/// re-applies its values AFTER the pin, which is the only order that works:
/// applied before, the pin would overwrite them and every cell would render
/// identically while reporting different names. That failure is silent, which is
/// why ``SweepTests`` asserts cells actually differ rather than merely running.
/// `Equatable` rather than `Hashable`: ``Size`` is `Equatable` only, and the
/// report keys cells by ``name`` — a string — so nothing here needs hashing.
/// Conforming would mean hand-writing `hash(into:)` for a capability no caller
/// uses.
public struct Variant: Equatable, Sendable {
    /// Locale identifier, e.g. `de_DE`. German is the standard stress case:
    /// its compounds are the longest common-language strings a layout meets.
    public var localeIdentifier: String
    /// Colour scheme for this cell.
    public var colorScheme: ColorScheme
    /// Accessibility text size for this cell.
    ///
    /// **Inert on macOS, and deliberately kept anyway.** Measured 2026-08-11:
    /// the environment value is delivered — a reader inside the host prints
    /// `accessibility5` — but `Text` renders byte-identically at `.medium` and
    /// `.accessibility5` (13x18 pt at `.body`, 116x16 pt unstyled). macOS sizes
    /// text from `NSFont` and the Accessibility "larger text" setting, not from
    /// SwiftUI Dynamic Type, so this axis moves nothing on this platform today.
    ///
    /// It stays in the vocabulary because the axis is real on iOS, which the
    /// platform-pure kernel is meant to reach, and because REMOVING it would
    /// silently drop the "German string truncates at AX3" case the plan names.
    /// But a sweep that varies ONLY this axis on macOS produces cells that
    /// cannot disagree — a table of identical answers reading as a clean result.
    /// ``SweepTests`` pins the inertness rather than asserting a scaling that
    /// does not happen, so the day it starts working the test fails and says so.
    public var dynamicTypeSize: DynamicTypeSize
    /// Reading direction — `rightToLeft` mirrors the whole layout, which catches
    /// hardcoded leading/trailing padding that no other axis can.
    public var layoutDirection: LayoutDirection
    /// Host size for this cell, or `nil` to use the scenario's own recommendation.
    public var viewport: Size?

    public init(
        localeIdentifier: String = "en_US",
        colorScheme: ColorScheme = .light,
        dynamicTypeSize: DynamicTypeSize = .medium,
        layoutDirection: LayoutDirection = .leftToRight,
        viewport: Size? = nil
    ) {
        self.localeIdentifier = localeIdentifier
        self.colorScheme = colorScheme
        self.dynamicTypeSize = dynamicTypeSize
        self.layoutDirection = layoutDirection
        self.viewport = viewport
    }

    /// The cell the `OracleHost` renders by default — the pinned baseline every
    /// other variant is a deviation from.
    public static let baseline = Variant()

    /// Stable, readable cell name used in reports and as a dictionary key.
    ///
    /// Deliberately built from every axis rather than only the ones that differ
    /// from ``baseline``: a name that omits its defaults changes meaning when a
    /// default changes, and a sweep report is read months after it was produced.
    public var name: String {
        "\(localeIdentifier)/\(colorScheme == .dark ? "dark" : "light")"
            + "/\(Self.describe(dynamicTypeSize))"
            + "/\(layoutDirection == .rightToLeft ? "rtl" : "ltr")"
            + (viewport.map { "/\(Self.describe($0.width))x\(Self.describe($0.height))" } ?? "")
    }

    /// A dimension for a cell name. `Double.pointsDescription` is kernel-internal,
    /// and widening it to public for a filename would export a formatting detail
    /// as API.
    static func describe(_ value: Double) -> String {
        value == value.rounded() && value.magnitude < 1e15
            ? String(Int64(value))
            : String(format: "%g", value)
    }

    /// `DynamicTypeSize` has no stable string form, so the vocabulary is spelled
    /// here — an interpolated enum description is a compiler detail that may
    /// change between toolchains, and a sweep report keyed on it would not
    /// survive a Swift upgrade.
    static func describe(_ size: DynamicTypeSize) -> String {
        switch size {
        case .xSmall: "xs"
        case .small: "s"
        case .medium: "m"
        case .large: "l"
        case .xLarge: "xl"
        case .xxLarge: "xxl"
        case .xxxLarge: "xxxl"
        case .accessibility1: "ax1"
        case .accessibility2: "ax2"
        case .accessibility3: "ax3"
        case .accessibility4: "ax4"
        case .accessibility5: "ax5"
        @unknown default: "unknown"
        }
    }
}

extension View {
    /// Re-apply a variant's environment on top of the host's pins.
    ///
    /// Must be applied AFTER `verdictPinnedEnvironment()` in the modifier chain.
    /// SwiftUI resolves the environment outside-in, so the OUTERMOST writer of a
    /// key wins — a variant applied by a scenario's own body sits inside the
    /// host's pin and is silently overwritten. Measured before this was fixed:
    /// two cells at `.medium` and `.accessibility5` both rendered a label
    /// 116.0 pt wide, a sweep that ran and reported while measuring one thing
    /// twice. `OracleHost` therefore takes the variant and applies it here.
    public func verdictVariant(_ variant: Variant) -> some View {
        environment(\.locale, Locale(identifier: variant.localeIdentifier))
            .environment(\.colorScheme, variant.colorScheme)
            .environment(\.dynamicTypeSize, variant.dynamicTypeSize)
            .environment(\.layoutDirection, variant.layoutDirection)
    }

}

/// One cell's result.
public struct SweepCell: Sendable {
    /// The variant this cell rendered under.
    public let variant: Variant
    /// The verdict, or `nil` when the cell could not be rendered at all.
    public let verdict: Verdict?
    /// Why the cell failed to render, when `verdict` is `nil`.
    ///
    /// A cell that could not render is NOT a passing cell and not a failing one
    /// — it is an unmeasured cell, and collapsing it into either would make a
    /// broken variant indistinguishable from a clean or a defective one.
    public let error: String?

    /// True when this cell produced a verdict with no error-severity findings.
    public var passed: Bool { verdict?.status == .pass }
}

/// The result of rendering one scenario across a variant matrix.
public struct SweepReport: Sendable {
    /// Scenario swept.
    public let scenario: String
    /// One cell per variant, in matrix order.
    public let cells: [SweepCell]

    /// Cells that produced a verdict with error findings.
    public var failingCells: [SweepCell] { cells.filter { $0.verdict != nil && !$0.passed } }

    /// Cells that could not be rendered at all — neither pass nor fail.
    public var unmeasuredCells: [SweepCell] { cells.filter { $0.verdict == nil } }

    /// True only when every cell RENDERED and every rendered cell passed.
    ///
    /// An unmeasured cell makes the sweep not-clean rather than silently clean:
    /// "we could not look" must never read as "we looked and it was fine".
    public var isClean: Bool { failingCells.isEmpty && unmeasuredCells.isEmpty }

    /// Rule × variant grid, as markdown — the "German string truncates at AX3"
    /// table the plan calls for.
    public func markdownGrid() -> String {
        let rules = Set(cells.flatMap { $0.verdict?.findings.map(\.rule) ?? [] }).sorted()
        guard !rules.isEmpty else {
            return "All \(cells.count) variant(s) of `\(scenario)` are clean."
        }

        var lines = ["| rule | " + cells.map(\.variant.name).joined(separator: " | ") + " |"]
        lines.append("|---" + String(repeating: "|---", count: cells.count) + "|")
        for rule in rules {
            let marks = cells.map { cell -> String in
                guard let verdict = cell.verdict else { return "?" }
                let count = verdict.findings.filter { $0.rule == rule }.count
                return count == 0 ? "·" : String(count)
            }
            lines.append("| `\(rule)` | " + marks.joined(separator: " | ") + " |")
        }
        return lines.joined(separator: "\n")
    }
}

/// Renders one scenario across a cartesian variant matrix.
public struct Sweep<Scenario: VerdictScenario>: Sendable where Scenario: Sendable {
    /// Scenario under test.
    public let scenario: Scenario
    /// Variants to render, in order.
    public let variants: [Variant]

    public init(scenario: Scenario, variants: [Variant]) {
        self.scenario = scenario
        self.variants = variants
    }

    /// Build the cartesian product of the supplied axes.
    ///
    /// Any axis left empty contributes its baseline value rather than
    /// annihilating the product — an empty array meaning "no cells at all" would
    /// turn a caller who varied only locales into a sweep that renders nothing
    /// and reports clean.
    public static func matrix(
        locales: [String] = [],
        colorSchemes: [ColorScheme] = [],
        dynamicTypeSizes: [DynamicTypeSize] = [],
        layoutDirections: [LayoutDirection] = [],
        viewports: [Size?] = []
    ) -> [Variant] {
        let locales = locales.isEmpty ? [Variant.baseline.localeIdentifier] : locales
        let schemes = colorSchemes.isEmpty ? [Variant.baseline.colorScheme] : colorSchemes
        let sizes =
            dynamicTypeSizes.isEmpty ? [Variant.baseline.dynamicTypeSize] : dynamicTypeSizes
        let directions =
            layoutDirections.isEmpty ? [Variant.baseline.layoutDirection] : layoutDirections
        let sizesOrNil: [Size?] = viewports.isEmpty ? [nil] : viewports

        var result: [Variant] = []
        for locale in locales {
            for scheme in schemes {
                for size in sizes {
                    for direction in directions {
                        for viewport in sizesOrNil {
                            result.append(
                                Variant(
                                    localeIdentifier: locale,
                                    colorScheme: scheme,
                                    dynamicTypeSize: size,
                                    layoutDirection: direction,
                                    viewport: viewport
                                )
                            )
                        }
                    }
                }
            }
        }
        return result
    }

    /// Render every cell and collect its verdict.
    ///
    /// Cells are rendered SEQUENTIALLY on the main actor. `OracleHost` hosts an
    /// `NSHostingView`, which is main-actor state, so parallel cells would
    /// interleave layout passes on one run loop — the determinism Wave 2 spent a
    /// spike establishing is worth more than the wall-clock a concurrent sweep
    /// would buy.
    /// - Parameter includeTrees: embed each cell's tree in its verdict. Off by
    ///   default because a matrix multiplies tree size by its cell count and the
    ///   MCP surface pays per token; on when a caller needs to compare cells'
    ///   geometry rather than only their findings.
    @MainActor
    public func run(
        rules: [any LintRule] = RuleEngine.standardRules,
        deadline: TimeInterval = OracleHost.defaultDeadline,
        includeTrees: Bool = false
    ) async -> SweepReport {
        var cells: [SweepCell] = []
        for variant in variants {
            do {
                let host = OracleHost(
                    scenario: scenario,
                    viewport: variant.viewport,
                    deadline: deadline,
                    variant: variant
                )
                let tree = try await host.currentTree()
                let verdict = RuleEngine.run(
                    rules: rules,
                    on: tree,
                    context: LintContext.macOS(
                        viewport: tree.frame,
                        scenario: "\(scenario.name) [\(variant.name)]"
                    ),
                    includeTree: includeTrees
                )
                cells.append(SweepCell(variant: variant, verdict: verdict, error: nil))
            } catch {
                // Recorded as unmeasured, never as a pass. A cell whose host
                // could not settle says nothing about the UI, and reporting it
                // as clean is the false-green this product exists to prevent.
                cells.append(
                    SweepCell(variant: variant, verdict: nil, error: String(describing: error))
                )
            }
        }
        return SweepReport(scenario: scenario.name, cells: cells)
    }
}
