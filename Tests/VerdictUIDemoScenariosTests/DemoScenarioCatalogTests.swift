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

    /// Every `*Scenario.swift` file in the target is actually in the catalog.
    ///
    /// The three counts the test below compares — `all.count`, `DemoScenarios.count`,
    /// and `expectedNames.count` — are all hand-maintained in this repo, so they
    /// agree with each other and with nothing else. A scenario file that is written,
    /// committed, and never registered is invisible to all three: measured during the
    /// Wave 1–3 audit by adding an unregistered `ProbeGapScenario.swift`, after which
    /// all 8 tests in this file still passed.
    ///
    /// That is precisely the failure this file's own doc comment warns about — "a
    /// scenario missing from the enumeration is a scenario nobody verifies again" —
    /// so it needs a check that reads the FILESYSTEM rather than another list someone
    /// has to remember to update. Same shape as `Tests/test_file_registry.py`, which
    /// takes its file list from `git ls-files` for the same reason.
    func testEveryScenarioFileOnDiskIsRegisteredInTheCatalog() throws {
        // #filePath resolves through the test file's own location, so this does not
        // depend on the working directory `swift test` happens to be run from.
        let testFile = URL(fileURLWithPath: #filePath)
        let root = testFile
            .deletingLastPathComponent()  // DemoScenariosTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // package root
        let sourceDir = root
            .appendingPathComponent("Sources")
            .appendingPathComponent("VerdictUIDemoScenarios")

        let files = try FileManager.default.contentsOfDirectory(
            at: sourceDir,
            includingPropertiesForKeys: nil
        )
        let scenarioTypes = files
            .map(\.lastPathComponent)
            .filter { $0.hasSuffix("Scenario.swift") }
            .map { $0.replacingOccurrences(of: ".swift", with: "") }
            .sorted()

        // A directory that yields nothing would make every assertion below vacuous,
        // so the scan proving it found something is itself the first assertion.
        XCTAssertFalse(
            scenarioTypes.isEmpty,
            "found no *Scenario.swift under \(sourceDir.path) — this test scanned nothing"
        )
        XCTAssertEqual(
            scenarioTypes.count,
            DemoScenarios.all.count,
            "\(scenarioTypes.count) scenario file(s) on disk but \(DemoScenarios.all.count) "
                + "in the catalog: \(scenarioTypes). A file that is never registered is "
                + "never verified by any sweep, baseline, or demo run."
        )
    }

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

        // `all` is a computed property, so every access rebuilds six entries and
        // reads six names off freshly constructed scenarios. Comparing two
        // *separately bound* evaluations is the assertion that repeating that
        // work is stable; comparing `all.map(\.name)` to itself in one
        // expression would be comparing one value to itself and could not fail.
        let first = DemoScenarios.all.map(\.name)
        let second = DemoScenarios.all.map(\.name)
        XCTAssertEqual(first, second, "two evaluations of the computed catalog disagreed")
        XCTAssertEqual(
            second,
            Self.expectedNames,
            "the second evaluation drifted from the pinned order"
        )
    }

    /// The viewport override, which nothing in Wave 2 uses and Wave 5 depends on.
    ///
    /// ``DemoScenarioEntry/makeHost(viewport:deadline:)`` defaults to the
    /// recommended viewport, and every current caller takes that default — so the
    /// override arm is unexercised code in a public API that a later wave builds
    /// its size sweeps on. Both directions are pinned: an explicit viewport is
    /// honoured, and omitting one falls back to the recommendation.
    @MainActor
    func testAnEntryHostsAtAnExplicitViewportOrFallsBackToItsRecommendation() throws {
        let entry = try XCTUnwrap(DemoScenarios.all.first)
        XCTAssertEqual(
            entry.makeHost().hostSize,
            entry.recommendedViewport,
            "the default must be the entry's own recommendation"
        )

        let override = Size(width: 321, height: 123)
        XCTAssertNotEqual(
            override,
            entry.recommendedViewport,
            "the override must differ from the recommendation or this proves nothing"
        )
        XCTAssertEqual(
            entry.makeHost(viewport: override).hostSize,
            override,
            "an explicit viewport was ignored in favour of the recommendation"
        )

        // The deadline override travels the same closure and is what makes the
        // failure path testable at all (see `DemoReportTests`).
        XCTAssertEqual(entry.makeHost(deadline: 0).deadline, 0)
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
