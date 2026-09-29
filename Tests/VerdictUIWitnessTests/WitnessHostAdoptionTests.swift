import XCTest

@testable import VerdictUIWitness

/// A launch must adopt only the host IT started.
///
/// Every witness host shares one bundle identifier, and the reader finds its host
/// by that identifier because LaunchServices detaches the process. Taking the
/// newest match adopted whatever was already running — a previous scenario's
/// still-terminating host, an MCP render host, a peer session's — and then read
/// a window serving a different scenario under this scenario's name
/// (CTS-7685E2ED).
final class WitnessHostAdoptionTests: XCTestCase {
    func testAHostRunningBeforeTheLaunchIsNeverAdopted() {
        XCTAssertNil(
            WitnessHostProcess.launchedHostPID(running: [101, 202], excluding: [101, 202]),
            "only pre-existing hosts are running, so this launch's host has not appeared yet")
    }

    func testTheNewestHostThatThisLaunchStartedIsAdopted() {
        XCTAssertEqual(
            WitnessHostProcess.launchedHostPID(running: [101, 303, 202], excluding: [101, 202]),
            303,
            "the pre-existing host 202 is newest in launch order but must not win")
        XCTAssertEqual(
            WitnessHostProcess.launchedHostPID(running: [303, 404], excluding: []), 404)
    }

    func testNoRunningHostYieldsNothing() {
        XCTAssertNil(WitnessHostProcess.launchedHostPID(running: [], excluding: [101]))
    }
}
