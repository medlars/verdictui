import XCTest

@testable import VerdictUIKernel
@testable import VerdictUIWitness

/// End-to-end tests that spawn the REAL witness host binary and read its
/// accessibility tree.
///
/// These exist because a library test cannot see an artifact that refuses to
/// work (`no.md` #32, #34, #37). Every layer below this one — the role table,
/// the coordinate arithmetic, the reconciler — is a pure function over values
/// someone chose. Only running the binary asks whether the window server
/// actually publishes what the reader expects.
///
/// They are skipped rather than failed where the environment cannot host a
/// window (a headless CI runner, an untrusted process), because a red that
/// means "this machine has no window server" teaches its reader to discount the
/// suite. The skip is LOUD: it names which precondition was unmet.
final class WitnessIntegrationTests: XCTestCase {

    /// The built host binary, alongside the test bundle.
    private var hostExecutable: URL? {
        let bundle = Bundle(for: type(of: self)).bundleURL.deletingLastPathComponent()
        let candidate = bundle.appendingPathComponent("verdictui-witness-host")
        return FileManager.default.isExecutableFile(atPath: candidate.path) ? candidate : nil
    }

    /// True where a window server is unavailable — the same shape as
    /// `ConstrainedTimingEnvironment`, and for the same reason: a check that
    /// cannot observe its subject must skip, never pass and never fail.
    private var isHeadless: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["CI"] != nil || environment["CODEX_CI"] != nil
            || environment["VERDICTUI_SKIP_WITNESS"] != nil
    }

    func testTheHostPublishesATreeThroughTheAccessibilityServer() throws {
        try XCTSkipIf(isHeadless, "no window server on this host")
        let executable = try XCTUnwrap(
            hostExecutable, "verdictui-witness-host was not built alongside the tests")
        try XCTSkipUnless(
            AXReader.isTrusted,
            "this process lacks Accessibility permission; grant it to the terminal running tests")

        let host = WitnessHostProcess(executable: executable, lifetime: 20)
        let tree = try host.readTree(scenario: "demo-clean-settings")

        // The tree must be POPULATED. An empty tree is what a witness reports
        // when it read the wrong process, anchored on the wrong element, or
        // raced the window — and every one of those is indistinguishable from a
        // scenario that renders nothing unless something asserts otherwise.
        let nodes = tree.flattened()
        XCTAssertGreaterThan(
            nodes.count, 1,
            "the witness read a tree with \(nodes.count) node(s); a real window publishes more")

        // Something text-bearing must have survived normalization. If text
        // extraction regressed to reading one attribute, the tree still has the
        // right SHAPE and loses every label — a populated-looking tree that says
        // nothing, which is the failure this asserts against.
        XCTAssertTrue(
            nodes.contains { $0.text?.isEmpty == false },
            "no node carried text; AXValue/AXDescription extraction is not working")

        // Frames must be root-relative, not screen-relative. A screen-anchored
        // tree has origins in the hundreds and would disagree with the probe
        // channel on every node at once.
        let origins = nodes.compactMap { $0.frame.x }
        XCTAssertLessThan(
            origins.min() ?? .greatestFiniteMagnitude, 100,
            "frames look screen-relative; the hosting-group origin was not subtracted")
    }

    func testAReadAgainstADeadProcessFailsRatherThanReturningAnEmptyTree() throws {
        try XCTSkipUnless(AXReader.isTrusted, "this process lacks Accessibility permission")

        // pid 1 (launchd) exists but publishes no accessibility window. The
        // read must FAIL: returning an empty tree here would let a broken
        // witness report "no disagreements" forever, which is a PASS produced by
        // reading nothing at all.
        XCTAssertThrowsError(try AXReader.readTree(pid: 1)) { error in
            guard case AXReader.Failure.noWindow = error else {
                return XCTFail("expected .noWindow, got \(error)")
            }
        }
    }

    func testAMissingHostBinaryIsReportedAsHostUnavailable() {
        let host = WitnessHostProcess(
            executable: URL(fileURLWithPath: "/nonexistent/verdictui-witness-host"),
            lifetime: 2
        )
        XCTAssertThrowsError(try host.readTree(scenario: "demo-clean-settings")) { error in
            guard case AXReader.Failure.hostUnavailable = error else {
                return XCTFail("expected .hostUnavailable, got \(error)")
            }
        }
    }
}
