import AppKit
import SwiftUI
import VerdictUIKernel
import XCTest

@testable import VerdictUIProbe

/// A card whose 1-px border colour is the only thing that varies.
///
/// Every dimension and colour is chosen here, so a difference between two
/// instances is attributable to the border and nothing else. The geometry is
/// deliberately IDENTICAL across instances — that is what makes this the
/// channel's existence proof: the semantic tree sees the same frames, the same
/// roles and the same text in both, so no geometric rule can distinguish them.
private struct BorderedCardScenario: VerdictScenario {
    let borderColor: Color

    var name: String { "bordered-card" }

    func body(state: ScenarioState) -> some View {
        Rectangle()
            .fill(Color.white)
            .frame(width: 60, height: 40)
            .border(borderColor, width: 1)
            .verdictProbe("card", role: .image)
            .padding(10)
            .background(Color.white)
    }
}

/// The pixel channel's comparison half, driven through real captures.
///
/// The kernel tests cover the comparison RULES on hand-built rasters. These
/// cover the half that needs a render server: that a real capture decodes into
/// something comparable, that the channel catches what the semantic rules
/// cannot, and that it refuses the comparisons it must not make.
final class PixelCompareTests: XCTestCase {
    /// AppKit hierarchies accumulate without a window-server run loop to drain
    /// them between tests — same reason as `OracleHostTests`.
    override func invokeTest() {
        autoreleasepool { super.invokeTest() }
    }

    private static let viewport = Size(width: 100, height: 80)

    @MainActor
    private func capture(border: Color) async throws -> PixelCapture {
        let host = OracleHost(
            scenario: BorderedCardScenario(borderColor: border), viewport: Self.viewport)
        _ = try await host.currentTree()
        return try host.capturePixels()
    }

    // MARK: - Decoding

    @MainActor
    func testARealCaptureDecodesToARasterOfItsOwnDimensions() async throws {
        let capture = try await capture(border: .black)
        let raster = try PixelRaster(decoding: capture)

        XCTAssertEqual(raster.width, capture.pixelsWide)
        XCTAssertEqual(raster.height, capture.pixelsHigh)
        XCTAssertEqual(raster.samples.count, capture.pixelsWide * capture.pixelsHigh * 4)
    }

    @MainActor
    func testTwoCapturesOfOneScreenCompareAsIdentical() async throws {
        let first = try await capture(border: .black)
        let second = try await capture(border: .black)

        let (result, finding) = try PixelCompare.compare(baseline: first, candidate: second)

        XCTAssertTrue(result.matches)
        XCTAssertEqual(result.differingPixels, 0)
        XCTAssertNil(finding, "a passing comparison must not add a finding nobody reads")
    }

    // MARK: - The existence proof (Wave 9 exit gate)

    /// The pixel channel catches a 1-px border-colour regression that every
    /// semantic rule misses.
    ///
    /// This is the wave's existence proof, and it is only worth anything with
    /// both halves asserted. The semantic half is the control: if the geometry
    /// DID change, a geometric rule might have caught it and the pixel channel
    /// would not be proving it earns its cost. So the trees are compared first
    /// and required to be identical — same nodes, same frames — and only then is
    /// the pixel difference asserted.
    @MainActor
    func testThePixelChannelCatchesABorderColourChangeEverySemanticRuleMisses() async throws {
        let blackHost = OracleHost(
            scenario: BorderedCardScenario(borderColor: .black), viewport: Self.viewport)
        let blackTree = try await blackHost.currentTree()
        let blackPixels = try blackHost.capturePixels()

        let redHost = OracleHost(
            scenario: BorderedCardScenario(borderColor: .red), viewport: Self.viewport)
        let redTree = try await redHost.currentTree()
        let redPixels = try redHost.capturePixels()

        // Control: the semantic channel cannot see this at all. Identical trees
        // means every geometric rule evaluates identical input and therefore
        // returns an identical verdict — the pixel channel is the only witness.
        XCTAssertEqual(
            blackTree, redTree,
            "the fixture must differ ONLY in colour; a geometry change would make this "
                + "prove nothing about the pixel channel")

        let verdictBefore = RuleEngine.run(
            rules: RuleEngine.standardRules,
            on: blackTree,
            context: .macOS(viewport: blackTree.frame, scenario: "bordered-card"))
        let verdictAfter = RuleEngine.run(
            rules: RuleEngine.standardRules,
            on: redTree,
            context: .macOS(viewport: redTree.frame, scenario: "bordered-card"))
        XCTAssertEqual(
            verdictBefore.findings, verdictAfter.findings,
            "the semantic rules must be blind to this, or it is not the existence proof")

        // And the pixel channel is not blind to it.
        let (result, finding) = try PixelCompare.compare(
            baseline: blackPixels, candidate: redPixels)

        XCTAssertFalse(result.matches, "the border colour changed and the pixels must say so")
        let reported = try XCTUnwrap(finding)
        XCTAssertEqual(reported.rule, "pixel-diff")
        XCTAssertEqual(reported.severity, .error)
        // The delta is the discriminator (see PixelDiffTests) and must be in the
        // message, not merely computed.
        XCTAssertTrue(
            reported.message.contains("max channel delta"),
            "the finding must lead with the delta: \(reported.message)")
        XCTAssertGreaterThan(result.maxChannelDelta, 100)
    }

    // MARK: - Refusals

    @MainActor
    func testACrossBackendComparisonIsRefusedBeforeAnyBytesAreRead() async throws {
        let host = OracleHost(
            scenario: BorderedCardScenario(borderColor: .black), viewport: Self.viewport)
        _ = try await host.currentTree()
        let viaCacheDisplay = try host.capturePixels(backend: .cacheDisplay)
        let viaRenderer = try host.capturePixels(backend: .imageRenderer)

        // Measured in Wave 9 Task 1: the two backends do not agree even at
        // matched dimensions, so comparing across them reports the backend as a
        // UI change on every run.
        XCTAssertThrowsError(
            try PixelCompare.compare(baseline: viaCacheDisplay, candidate: viaRenderer)
        ) {
            guard case let PixelDiffError.backendMismatch(baseline, candidate) = $0 else {
                return XCTFail("expected a backend mismatch, got \($0)")
            }
            XCTAssertEqual(baseline, "cacheDisplay")
            XCTAssertEqual(candidate, "imageRenderer")
        }
    }

    @MainActor
    func testAViewportChangeIsRefusedAsADimensionMismatchRatherThanDiffed() async throws {
        let small = OracleHost(
            scenario: BorderedCardScenario(borderColor: .black),
            viewport: Size(width: 100, height: 80))
        _ = try await small.currentTree()
        let large = OracleHost(
            scenario: BorderedCardScenario(borderColor: .black),
            viewport: Size(width: 120, height: 80))
        _ = try await large.currentTree()

        XCTAssertThrowsError(
            try PixelCompare.compare(
                baseline: try small.capturePixels(), candidate: try large.capturePixels())
        ) {
            guard case PixelDiffError.dimensionMismatch = $0 else {
                return XCTFail("expected a dimension mismatch, got \($0)")
            }
        }
    }

    // MARK: - Artifacts

    @MainActor
    func testAFailingComparisonWritesBeforeAfterAndHeatArtifactsAndCitesThemByPath() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("verdictui-pixeldiff-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let baseline = try await capture(border: .black)
        let candidate = try await capture(border: .red)

        let (_, finding) = try PixelCompare.compare(
            baseline: baseline, candidate: candidate, artifactRoot: root)
        let reported = try XCTUnwrap(finding)

        let directory = root.appendingPathComponent("bordered-card")
        for name in ["baseline.png", "candidate.png", "heat.png"] {
            let path = directory.appendingPathComponent(name).path
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: path), "\(name) was not written")
            // Referenced BY PATH in the finding — the MCP surface is token-metered
            // and an embedded image would cost more than the rest of the verdict.
            XCTAssertTrue(
                reported.message.contains(path), "the finding must cite \(name) by path")
        }

        // The heat artifact must be a readable image, not merely a file that exists.
        let heat = try Data(
            contentsOf: directory.appendingPathComponent("heat.png"))
        let rep = try XCTUnwrap(NSBitmapImageRep(data: heat))
        XCTAssertEqual(rep.pixelsWide, baseline.pixelsWide)
        XCTAssertEqual(rep.pixelsHigh, baseline.pixelsHigh)
    }

    @MainActor
    func testAPassingComparisonWritesNoArtifacts() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("verdictui-pixeldiff-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let baseline = try await capture(border: .black)
        let candidate = try await capture(border: .black)

        let (result, finding) = try PixelCompare.compare(
            baseline: baseline, candidate: candidate, artifactRoot: root)

        XCTAssertTrue(result.matches)
        XCTAssertNil(finding)
        // Writing an image of every screen that did NOT change would bury the
        // one image a reader wants among thousands that carry no information.
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: root.path),
            "artifacts are evidence for a failure, not a log of every run")
    }

    @MainActor
    func testAScenarioNameCannotEscapeTheArtifactDirectory() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("verdictui-pixeldiff-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let baseline = try await capture(border: .black)
        let candidate = try await capture(border: .red)
        // Scenario names are author-supplied strings that become path components.
        let hostile = PixelCapture(
            png: candidate.png,
            pixelsWide: candidate.pixelsWide,
            pixelsHigh: candidate.pixelsHigh,
            backend: candidate.backend,
            scenarioName: "../../escaped"
        )

        let artifacts = try PixelCompare.writeArtifacts(
            baseline: baseline,
            candidate: hostile,
            heat: try PixelDiff.heatMap(
                baseline: try PixelRaster(decoding: baseline),
                candidate: try PixelRaster(decoding: candidate)),
            root: root
        )

        XCTAssertTrue(
            artifacts.heatPath.hasPrefix(root.path),
            "artifacts must stay under the root: \(artifacts.heatPath)")
        XCTAssertFalse(artifacts.heatPath.contains(".."))
    }
}
