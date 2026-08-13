import VerdictUIDemoScenarios
import VerdictUIKernel
import VerdictUIProbe
import XCTest

/// Wave 9's exit-gate item: the double-render determinism check is green across
/// **every** demo scenario on this machine.
///
/// This is the catalog-wide claim, and it is deliberately not a sample. A pixel
/// baseline is only writable for a scenario that renders identically twice, so a
/// scenario that quietly drifts would either be refused a baseline forever (and
/// silently lose pixel coverage) or, worse, be given one that fails at random
/// later. Checking each of the six is what turns "the demos are deterministic"
/// from an assumption into a measurement.
final class DemoScenarioDeterminismTests: XCTestCase {
    override func invokeTest() {
        autoreleasepool { super.invokeTest() }
    }

    /// Every scenario in the catalog renders identically twice.
    ///
    /// Iterates `DemoScenarios.all` rather than naming scenarios, so a scenario
    /// added later is covered without anyone remembering to extend this file —
    /// a hand-written list can only ever check the entries someone listed.
    @MainActor
    func testEveryDemoScenarioIsDeterministic() async throws {
        var checked = 0

        for entry in DemoScenarios.all {
            let result = try await DeterminismCheck.verify(scenarioName: entry.name) {
                // A FRESH host per call, which is the factory's contract:
                // reusing one would re-encode a fixed layout and report every
                // scenario as deterministic whatever it actually does.
                entry.makeHost()
            }

            guard case .deterministic = result else {
                XCTFail(
                    """
                    demo scenario '\(entry.name)' is NOT deterministic, so it \
                    cannot be given a pixel baseline: \(result)
                    """
                )
                continue
            }
            checked += 1
        }

        // The count assertion is what separates "all six passed" from "the loop
        // body never ran" — an empty catalog would otherwise satisfy every
        // assertion above by vacuity, which is the exact defect the pixel
        // channel's own vacuity guard exists for.
        XCTAssertEqual(
            checked,
            DemoScenarios.count,
            "every catalog scenario must have been checked, not merely iterated"
        )
    }
}
