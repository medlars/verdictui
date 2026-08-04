import VerdictUIDemoScenarios
import VerdictUIKernel
import VerdictUIProbe
import XCTest

/// Every scenario in the catalog reaches a settled tree, and that tree contains
/// exactly the probes the catalog claims for it.
///
/// Which rule each planted defect trips is Task 6's assertion, not this file's.
/// What has to be true first is that the scenario renders at all and that its
/// probe ids are the ones the catalog advertises — otherwise a Task 6 failure
/// would be ambiguous between "the rule stopped firing" and "the node it fires
/// on stopped existing", and those have very different fixes.
final class DemoScenarioRenderingTests: XCTestCase {
    /// Every test here builds an AppKit view hierarchy, and `swift test` has no
    /// window-server run loop to drain the autorelease pool between tests.
    /// Without this the hosted hierarchies accumulate until the suite wedges at
    /// 0% CPU, each test still passing in isolation.
    override func invokeTest() { autoreleasepool { super.invokeTest() } }

    @MainActor
    func testEveryScenarioSettlesAtItsRecommendedViewport() async throws {
        for entry in DemoScenarios.all {
            let host = entry.makeHost()
            let tree = try await host.currentTree()

            XCTAssertEqual(
                host.scenarioName,
                entry.name,
                "the host filed '\(entry.name)' under a different name"
            )
            XCTAssertEqual(
                tree.frame,
                Rect(
                    x: 0,
                    y: 0,
                    width: entry.recommendedViewport.width,
                    height: entry.recommendedViewport.height
                ),
                "'\(entry.name)' rendered into a viewport other than the one it recommends"
            )
            // A clamped host lays content out under a constraint the scenario
            // did not choose, which would make every documented frame in this
            // catalog a description of something else.
            XCTAssertFalse(host.wasClamped, "'\(entry.name)' was clamped by the host")
        }
    }

    @MainActor
    func testEveryScenarioPublishesTheProbeIDsItDeclares() async throws {
        for entry in DemoScenarios.all {
            let tree = try await entry.makeHost().currentTree()
            for id in entry.probeIDs {
                let node = tree.node(withID: id)
                XCTAssertNotNil(
                    node,
                    "'\(entry.name)' declares probe '\(id)' but no such node reached the tree"
                )
                // A probe that reached the tree with an empty frame is a probe
                // Task 6 cannot make an assertion about; `zero-size` would fire
                // instead of the rule the scenario was written for.
                if let node {
                    XCTAssertFalse(
                        node.frame.isEmpty,
                        "'\(entry.name)' probe '\(id)' resolved to an empty frame"
                    )
                }
            }
        }
    }

    /// The reverse direction, and the one that catches drift: a probe added to a
    /// scenario without being declared is a probe no test knows to look for, and
    /// it can change the assembled tree's shape — a new node can become the
    /// parent of an existing one — under assertions that never mention it.
    @MainActor
    func testNoScenarioPublishesAProbeItDidNotDeclare() async throws {
        for entry in DemoScenarios.all {
            let tree = try await entry.makeHost().currentTree()
            let rendered = tree.flattened().map(\.id).filter { !$0.isEmpty }

            XCTAssertEqual(
                Set(rendered),
                Set(entry.probeIDs),
                "'\(entry.name)' rendered probes \(rendered.sorted()) but declares "
                    + "\(entry.probeIDs.sorted())"
            )
            XCTAssertEqual(
                Set(rendered).count,
                rendered.count,
                "'\(entry.name)' rendered a probe id twice: \(rendered)"
            )
        }
    }

}
