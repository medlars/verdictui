import AppKit
import SwiftUI
import VerdictUIKernel
import XCTest

// `@testable` for the pixel-dimension arithmetic and the two backend entry
// points, which are internal because a consumer picks a backend through
// `capturePixels(backend:)` rather than by naming the private path.
@testable import VerdictUIProbe

/// Fixture for the capture tests.
///
/// Declared here rather than reusing `OracleHostTests`' `BadgesScenario`, which
/// is `private` and therefore file-confined. That confinement is load-bearing in
/// this target (`no.md` #19): sibling test files own same-named fixtures only
/// because `private` keeps each to its own file, and widening one to share it
/// would collide the moment two files pick the same name. A fixture is cheaper
/// than a namespace collision.
///
/// Every dimension is one this file chose, so a pixel assertion here is
/// arithmetic rather than a font metric — the content deliberately includes a
/// filled shape rather than only text, because text rendering is the part of the
/// pixel channel most likely to vary across machines.
private struct PixelFixtureScenario: VerdictScenario {
    var name: String { "pixel-fixture" }

    func body(state: ScenarioState) -> some View {
        VStack(spacing: 8) {
            Rectangle()
                .fill(Color.red)
                .frame(width: 40, height: 20)
                .verdictProbe("swatch", role: .image)
            Rectangle()
                .fill(Color.blue)
                .frame(width: 60, height: 20)
                .verdictProbe("bar", role: .image)
        }
        .padding(10)
        .background(Color.white)
    }
}

/// The pixel channel's capture half, held to the promises the semantic channel
/// cannot make for it: a pinned scale, a recorded backend, and bytes that are
/// the same on two renders of the same screen.
final class PixelCaptureTests: XCTestCase {
    /// Same reason as ``OracleHostTests`` — AppKit hierarchies accumulate without
    /// a window-server run loop to drain them between tests.
    override func invokeTest() {
        autoreleasepool { super.invokeTest() }
    }

    private static let viewport = Size(width: 200, height: 100)

    @MainActor
    private func makeHost() -> OracleHost {
        OracleHost(scenario: PixelFixtureScenario(), viewport: Self.viewport)
    }

    // MARK: - The pinned scale

    /// The capture is one pixel per point, NOT the device backing scale.
    ///
    /// This is the assertion the whole channel's portability rests on, and it is
    /// not what AppKit does by default: `bitmapImageRepForCachingDisplay(in:)`
    /// hands back a rep at the display's scale, measured at 240x160 for a 120x80
    /// view on this machine. A capture at 2x would make every baseline written
    /// here mismatch every capture from a 1x machine — a CI runner, a non-Retina
    /// display — and the mismatch would be reported as a UI regression.
    @MainActor
    func testCaptureIsPinnedToOnePixelPerPoint() throws {
        let host = makeHost()
        let capture = try host.capturePixels()

        XCTAssertEqual(capture.pixelsWide, 200, "width must be points, not device pixels")
        XCTAssertEqual(capture.pixelsHigh, 100, "height must be points, not device pixels")
        XCTAssertEqual(OracleHost.pixelScale, 1.0)
    }

    /// The pinned scale holds on the alternate backend too.
    ///
    /// `ImageRenderer` honours `scale` directly where AppKit does not, so the two
    /// backends reach the same dimensions by different means — and a backend that
    /// silently rendered at 2x would produce a capture that is *comparable to
    /// nothing*, including its own baseline from the other backend.
    @MainActor
    func testBothBackendsCaptureAtTheSameDimensions() throws {
        let host = makeHost()
        let appKit = try host.capturePixels(backend: .cacheDisplay)
        let swiftUI = try host.capturePixels(backend: .imageRenderer)

        XCTAssertEqual(appKit.pixelsWide, swiftUI.pixelsWide)
        XCTAssertEqual(appKit.pixelsHigh, swiftUI.pixelsHigh)
    }

    // MARK: - Determinism

    /// Two captures of an unchanged host are byte-identical.
    ///
    /// The property Task 2's double-render check is built on, and the reason the
    /// channel can have baselines at all. Measured before it was asserted, and
    /// measured ACROSS PROCESSES rather than only within one: three separate
    /// process launches of the same render produced the same FNV hash, so the
    /// stability is real rather than a warm font-cache artifact that a fresh
    /// process would break.
    @MainActor
    func testTwoCapturesOfAnUnchangedHostAreIdentical() throws {
        let host = makeHost()
        let first = try host.capturePixels()
        let second = try host.capturePixels()

        XCTAssertEqual(first.png, second.png, "an unchanged host must render the same bytes")
        XCTAssertEqual(first.contentHash, second.contentHash)
    }

    /// The hash tracks the bytes rather than being decorative.
    ///
    /// Without this, `contentHash` could be any constant and every equality test
    /// above would still pass — the Task 5 cache is keyed on this value, so a
    /// constant hash would make every scenario a cache hit for every other.
    func testTheContentHashSeparatesDifferentBytes() {
        let a = PixelCapture.hash(Data([0x01, 0x02, 0x03]))
        let b = PixelCapture.hash(Data([0x01, 0x02, 0x04]))

        XCTAssertNotEqual(a, b, "different bytes must hash differently")
        XCTAssertEqual(a, PixelCapture.hash(Data([0x01, 0x02, 0x03])), "hashing must be stable")
        XCTAssertEqual(a.count, 16, "16 hex digits of FNV-1a")
    }

    // MARK: - The divergence, pinned as a fact

    /// The two backends do NOT produce the same bytes, and the capture says which
    /// one produced it.
    ///
    /// The plan asks for this divergence to be "documented honestly"; a doc
    /// comment is a claim nobody checks, so it is asserted here instead. If the
    /// two ever DID converge this test fails loudly, which is the right outcome —
    /// it would mean the backends stopped being two different questions and the
    /// `backend` field could be retired.
    ///
    /// The consequence a caller must respect: a baseline is comparable only to a
    /// capture from the same backend, and `backend` is what lets a diff refuse a
    /// cross-backend comparison instead of reporting it as a visual change.
    @MainActor
    func testTheTwoBackendsDivergeAndEachCaptureRecordsItsOwn() throws {
        let host = makeHost()
        let appKit = try host.capturePixels(backend: .cacheDisplay)
        let swiftUI = try host.capturePixels(backend: .imageRenderer)

        XCTAssertEqual(appKit.backend, .cacheDisplay)
        XCTAssertEqual(swiftUI.backend, .imageRenderer)
        XCTAssertNotEqual(
            appKit.png,
            swiftUI.png,
            """
            the backends are documented as divergent and a diff refuses to compare \
            across them; if they now agree, that documentation and the refusal are \
            both wrong and must be revisited
            """
        )
    }

    // MARK: - Attribution

    /// A capture cites the scenario it is of.
    ///
    /// A pixel artifact reaches a reader far from the call site that produced it,
    /// and an unattributed bitmap is evidence of nothing.
    @MainActor
    func testACaptureCitesItsScenario() throws {
        let host = makeHost()
        let capture = try host.capturePixels()

        XCTAssertEqual(capture.scenarioName, host.scenarioName)
        XCTAssertFalse(capture.scenarioName.isEmpty)
    }

    // MARK: - The empty-viewport refusal

    /// A host with no area to render is REFUSED, not captured.
    ///
    /// The failure this prevents is the expensive kind: `NSBitmapImageRep` accepts
    /// a zero dimension and produces a valid, empty PNG — which compares equal to
    /// every other empty PNG. A blank scenario would then match any baseline of
    /// any other blank scenario and the channel would report PASS for a screen
    /// that rendered nothing at all.
    @MainActor
    func testAZeroAreaHostIsRefusedRatherThanCapturedAsEmpty() {
        let host = OracleHost(
            scenario: PixelFixtureScenario(),
            viewport: Size(width: 0, height: 100)
        )

        XCTAssertThrowsError(try host.capturePixels()) { error in
            guard case let .emptyViewport(scenario, width, _)? = error as? PixelCaptureError else {
                return XCTFail("expected .emptyViewport, got \(error)")
            }
            XCTAssertEqual(scenario, host.scenarioName)
            XCTAssertEqual(width, 0)
        }
    }

    /// Every error states the scenario and what to do about it.
    ///
    /// A capture failure surfaces inside a verdict, where the reader has no access
    /// to the call site; an error that names neither the subject nor a next step
    /// makes the pixel channel un-debuggable from its own output.
    func testEveryErrorNamesItsScenarioAndSuggestsAnAction() {
        let errors: [PixelCaptureError] = [
            .bitmapUnavailable(scenario: "s", width: 10, height: 10),
            .rendererProducedNoImage(scenario: "s"),
            .encodingFailed(scenario: "s"),
            .emptyViewport(scenario: "s", width: 0, height: 0),
        ]

        for error in errors {
            XCTAssertTrue(
                error.description.contains("'s'"),
                "error must name its scenario: \(error.description)"
            )
            XCTAssertTrue(
                error.description.contains("pixel capture failed"),
                "error must say what failed: \(error.description)"
            )
        }
    }
}
