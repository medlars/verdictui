import VerdictUIDemoScenarios
import VerdictUIKernel
import VerdictUIProbe
import XCTest

/// The catalog's own contract: what ``DemoScenarios/all`` promises about the
/// scenarios it hands out, before anything is rendered.
///
/// These are the claims every later wave builds on without re-checking them. A
/// baseline is keyed by ``DemoScenarioEntry/name``, so a duplicate or empty name
/// silently merges two scenarios' history; a sweep iterates the catalog, so a
/// scenario missing from the enumeration is a scenario nobody verifies again.
/// Neither failure announces itself anywhere else.
final class DemoScenarioCatalogTests: XCTestCase {
    /// The catalog, pinned here as literals rather than derived from the code
    /// under test.
    ///
    /// Deriving the expectation from ``DemoScenarios/all`` would make the
    /// coverage test agree with whatever the catalog happened to contain,
    /// including nothing. Written out, it fails when a scenario is added
    /// without being covered here, and when one is removed — which is exactly
    /// the mutation this file has to catch.
    private static let expectedNames = [
        "demo-truncating-label",
        "demo-overlapping-badges",
        "demo-offscreen-button",
        "demo-undersized-tap-target",
        "demo-toggle-layout",
        "demo-clean-settings",
    ]

    func testTheCatalogHoldsThePinnedNumberOfScenarios() {
        XCTAssertEqual(
            DemoScenarios.all.count,
            DemoScenarios.count,
            "DemoScenarios.count is the number the executable and Task 6 budget for; it and "
                + "the enumeration have drifted apart"
        )
        XCTAssertEqual(
            DemoScenarios.count,
            Self.expectedNames.count,
            "the catalog changed size without this test's expectation changing with it"
        )
    }

    func testTheEnumerationVisitsEveryScenarioExactlyOnce() {
        var visits: [String: Int] = [:]
        for entry in DemoScenarios.all {
            visits[entry.name, default: 0] += 1
        }

        XCTAssertEqual(
            visits,
            Dictionary(uniqueKeysWithValues: Self.expectedNames.map { ($0, 1) }),
            "the enumeration did not visit each expected scenario exactly once"
        )
    }

    func testTheEnumerationOrderIsStable() {
        // Order is not decoration: the executable prints verdicts in it, and a
        // reader (and a README recording) compares runs by position.
        XCTAssertEqual(DemoScenarios.all.map(\.name), Self.expectedNames)
        XCTAssertEqual(
            DemoScenarios.all.map(\.name),
            DemoScenarios.all.map(\.name),
            "two evaluations of the computed catalog disagreed about order"
        )
    }

    func testEveryScenarioNameIsNonEmptyAndUnique() {
        let names = DemoScenarios.all.map(\.name)
        for name in names {
            XCTAssertFalse(name.isEmpty, "a scenario published an empty name")
            XCTAssertEqual(
                name,
                name.trimmingCharacters(in: .whitespacesAndNewlines),
                "'\(name)' has surrounding whitespace, which a baseline key must not carry"
            )
        }
        XCTAssertEqual(
            Set(names).count,
            names.count,
            "two scenarios share a name, so they would share a baseline: \(names)"
        )
    }

    func testEveryEntryDeclaresAViewportTheHostWillHonour() {
        for entry in DemoScenarios.all {
            let viewport = entry.recommendedViewport
            XCTAssertTrue(
                viewport.width.isFinite && viewport.height.isFinite,
                "'\(entry.name)' recommends a non-finite viewport"
            )
            XCTAssertGreaterThan(viewport.width, 0, "'\(entry.name)' recommends a zero width")
            XCTAssertGreaterThan(viewport.height, 0, "'\(entry.name)' recommends a zero height")
            // Above the cap the host silently renders at 4096 pt instead, and
            // every documented frame in that scenario would be measured against
            // a viewport nobody chose.
            XCTAssertLessThanOrEqual(
                viewport.width,
                OracleHost.sizeCap.width,
                "'\(entry.name)' recommends a width the host would clamp"
            )
            XCTAssertLessThanOrEqual(
                viewport.height,
                OracleHost.sizeCap.height,
                "'\(entry.name)' recommends a height the host would clamp"
            )
        }
    }

    func testEveryEntryDeclaresProbeIDsThatAreUniqueWithinTheScenario() {
        for entry in DemoScenarios.all {
            XCTAssertFalse(
                entry.probeIDs.isEmpty,
                "'\(entry.name)' declares no probe ids, so it asserts nothing about its own tree"
            )
            for id in entry.probeIDs {
                XCTAssertFalse(id.isEmpty, "'\(entry.name)' declares an empty probe id")
            }
            XCTAssertEqual(
                Set(entry.probeIDs).count,
                entry.probeIDs.count,
                "'\(entry.name)' declares a probe id twice: \(entry.probeIDs)"
            )
        }
    }

    func testEntryLookupFindsEveryCatalogedScenarioAndOnlyThose() {
        for name in Self.expectedNames {
            XCTAssertEqual(
                DemoScenarios.entry(named: name)?.name,
                name,
                "'\(name)' is in the catalog but cannot be looked up by name"
            )
        }
        XCTAssertNil(
            DemoScenarios.entry(named: "demo-no-such-scenario"),
            "lookup invented an entry for a name the catalog does not hold"
        )
        XCTAssertNil(DemoScenarios.entry(named: ""), "lookup matched the empty name")
    }
}
