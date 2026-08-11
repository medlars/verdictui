// Wave 6: the serializable form of a sweep report.
//
// `SweepReport` is not `Codable` and is not made so. `Variant` holds SwiftUI's
// `ColorScheme`, `DynamicTypeSize` and `LayoutDirection` — framework enums with
// no raw values and no `Codable` conformance — and retrofitting them would put
// this package's spelling of "dark" on types Apple owns, where a future SDK
// could add a case and change what our JSON means without a commit here saying
// so.
//
// So the wire form is declared HERE, once, and names its own spellings. The
// same shape serves Wave 7's MCP surface.
import Foundation
import VerdictUIKernel
import VerdictUIProbe

/// One sweep cell, as it appears on the wire.
public struct SweepCellWire: Codable, Sendable, Equatable {
    /// The variant's stable display name, e.g. `de_DE/dark/AX3`.
    public let variant: String
    /// PASS, FAIL, or absent when the cell could not be rendered.
    public let status: String?
    /// Findings this cell produced.
    public let findings: [Finding]
    /// Why the cell could not be rendered, when it could not.
    public let error: String?

    /// Whether this cell was measured at all.
    ///
    /// Three states survive onto the wire — passed, failed, unmeasured —
    /// because collapsing the third into either of the others is the exact
    /// false-green the engine refuses everywhere else.
    public var wasMeasured: Bool { status != nil }
}

/// A sweep report, as it appears on the wire.
public struct SweepReportWire: Codable, Sendable, Equatable {
    public let scenario: String
    public let cells: [SweepCellWire]
    /// Markdown rule × variant grid — the table the plan calls for, rendered
    /// once here so every surface prints the same one.
    public let grid: String

    /// True only when every cell rendered AND every rendered cell passed.
    public var isClean: Bool {
        cells.allSatisfy { $0.wasMeasured && $0.status == Verdict.Status.pass.rawValue }
    }

    /// Convert an engine-side report to its wire form.
    public init(_ report: SweepReport) {
        self.scenario = report.scenario
        self.grid = report.markdownGrid()
        self.cells = report.cells.map { cell in
            SweepCellWire(
                variant: cell.variant.name,
                status: cell.verdict?.status.rawValue,
                findings: cell.verdict?.findings ?? [],
                error: cell.error
            )
        }
    }
}
