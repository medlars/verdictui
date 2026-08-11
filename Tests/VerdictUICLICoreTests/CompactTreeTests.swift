import Foundation
import VerdictUIDemoScenarios
import VerdictUIKernel
import VerdictUIProbe
import XCTest

@testable import VerdictUICLICore

/// The token-frugal wire format.
///
/// Two properties carry this file. The ROUND TRIP is the correctness argument —
/// a compaction that cannot be reversed is a lossy summary wearing an
/// encoding's name — and it is asserted against every real demo render rather
/// than against hand-built fixtures, because a fixture is a claim about tree
/// shapes and the catalog is a measurement of them. The SIZE BUDGET is the
/// feature: an agent pays per token, so a format that round-trips perfectly and
/// saves nothing has not done its job.
final class CompactTreeTests: XCTestCase {
    override func invokeTest() {
        autoreleasepool { super.invokeTest() }
    }

    private static var encoder: JSONEncoder { VerdictOutput.encoder(pretty: false) }

    // MARK: - Round trip

    /// Every demo scenario survives compaction byte-for-byte.
    @MainActor
    func testEveryDemoTreeSurvivesTheRoundTrip() async throws {
        for entry in DemoScenarios.all {
            let host = entry.makeHost(viewport: entry.recommendedViewport, deadline: 5)
            let original = try await host.currentTree()

            let compact = CompactTree(original)
            let restored = try XCTUnwrap(
                compact.expand(),
                "\(entry.name): a compact tree that cannot expand is a lossy summary"
            )

            XCTAssertEqual(
                restored,
                original,
                "\(entry.name) did not survive the round trip — the compact form is not an "
                    + "encoding of this tree, it is a different tree"
            )
        }
    }

    /// Structure specifically, not just equality: a format that got parents
    /// wrong but happened to reproduce a flat tree would pass an equality check
    /// on a flat fixture.
    @MainActor
    func testNestingSurvivesRatherThanFlattening() async throws {
        let entry = try XCTUnwrap(
            DemoScenarios.registry.entry(named: CleanSettingsScenario.scenarioName)
        )
        let original = try await entry.host().currentTree()

        // This scenario nests two levels deep on purpose (card-layer wraps
        // card-surface and card-pill), so a flattening bug is visible here and
        // would be invisible on any of the two-level scenarios.
        let compact = CompactTree(original)
        let restored = try XCTUnwrap(compact.expand())

        let layer = try XCTUnwrap(restored.node(withID: "card-layer"))
        XCTAssertEqual(
            Set(layer.children.map(\.id)),
            ["card-surface", "card-pill"],
            "the layering container lost its children — the parent index did not survive"
        )
        XCTAssertEqual(
            restored.children.map(\.id),
            original.children.map(\.id),
            "sibling ORDER must survive: a report listing siblings backwards is complete and "
                + "unreadable next to the source"
        )
    }

    // MARK: - The budget

    /// The plan's wire-size budget: a full demo tree ≤ 2 KB serialized.
    @MainActor
    func testEveryDemoTreeFitsTheWireBudget() async throws {
        let budget = 2_048

        for entry in DemoScenarios.all {
            let host = entry.makeHost(viewport: entry.recommendedViewport, deadline: 5)
            let tree = try await host.currentTree()

            let compactBytes = try Self.encoder.encode(CompactTree(tree)).count
            let nestedBytes = try Self.encoder.encode(tree).count

            print("WIRE \(entry.name) compact=\(compactBytes) nested=\(nestedBytes)")

            XCTAssertLessThanOrEqual(
                compactBytes,
                budget,
                "\(entry.name) serializes to \(compactBytes) B against a \(budget) B budget"
            )
            XCTAssertLessThan(
                compactBytes,
                nestedBytes,
                "\(entry.name): the compact form (\(compactBytes) B) is not smaller than plain "
                    + "nested JSON (\(nestedBytes) B), so it costs a format and buys nothing"
            )
        }
    }

    /// Interning must actually intern.
    ///
    /// The saving comes from repeated roles collapsing to one table entry, and
    /// a "compaction" that emitted a table entry per node would still round
    /// trip perfectly while saving nothing — passing every test above.
    @MainActor
    func testRepeatedRolesAreInternedRatherThanRepeated() async throws {
        let entry = try XCTUnwrap(
            DemoScenarios.registry.entry(named: CleanSettingsScenario.scenarioName)
        )
        let compact = CompactTree(try await entry.host().currentTree())

        XCTAssertGreaterThan(compact.nodeCount, 4, "this scenario should produce a real tree")
        XCTAssertLessThan(
            compact.strings.count,
            compact.nodeCount,
            "the string table (\(compact.strings.count)) is not smaller than the node count "
                + "(\(compact.nodeCount)) — nothing was actually interned"
        )
    }

    // MARK: - Truncation is never silent

    @MainActor
    func testATruncatedTreeSaysSo() async throws {
        let entry = try XCTUnwrap(
            DemoScenarios.registry.entry(named: CleanSettingsScenario.scenarioName)
        )
        let tree = try await entry.host().currentTree()

        let whole = CompactTree(tree)
        XCTAssertFalse(whole.truncated, "an untruncated tree must not claim it was truncated")

        let clipped = CompactTree(tree, maxNodes: 2)
        XCTAssertTrue(
            clipped.truncated,
            "a tree cut to 2 nodes must SAY it was cut — a truncated tree that looks complete "
                + "is a verdict about a screen nobody saw all of"
        )
        XCTAssertEqual(clipped.nodeCount, 2)
    }

    // MARK: - Malformed input

    /// `expand()` returns nil rather than crashing or inventing a tree.
    ///
    /// These arrays arrive over a socket from a client this process does not
    /// control, so they are untrusted input: a parent index pointing outside
    /// the array, or two roots, describes no tree at all.
    func testInconsistentArraysExpandToNilRatherThanACrash() {
        let cases: [(String, CompactTree)] = [
            (
                "parent index out of range",
                CompactTree(
                    ids: ["a", "b"], roleIDs: [0, 0], textIDs: [-1, -1],
                    frames: Array(repeating: 0, count: 8), parents: [-1, 99],
                    strings: ["container"], truncated: false
                )
            ),
            (
                "two roots",
                CompactTree(
                    ids: ["a", "b"], roleIDs: [0, 0], textIDs: [-1, -1],
                    frames: Array(repeating: 0, count: 8), parents: [-1, -1],
                    strings: ["container"], truncated: false
                )
            ),
            (
                "frames array too short",
                CompactTree(
                    ids: ["a"], roleIDs: [0], textIDs: [-1],
                    frames: [0, 0], parents: [-1],
                    strings: ["container"], truncated: false
                )
            ),
            (
                "role index outside the string table",
                CompactTree(
                    ids: ["a"], roleIDs: [7], textIDs: [-1],
                    frames: Array(repeating: 0, count: 4), parents: [-1],
                    strings: ["container"], truncated: false
                )
            ),
        ]

        for (label, malformed) in cases {
            XCTAssertNil(malformed.expand(), "\(label) must expand to nil")
        }

        // The control: a well-formed pair still expands, or "returns nil on
        // malformed input" is satisfied by an implementation returning nil for
        // everything.
        let valid = CompactTree(
            ids: ["root"], roleIDs: [0], textIDs: [-1],
            frames: [0, 0, 10, 10], parents: [-1],
            strings: ["container"], truncated: false
        )
        XCTAssertNotNil(valid.expand(), "a well-formed compact tree must still expand")
    }
}
