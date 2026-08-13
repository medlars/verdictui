import XCTest

@testable import VerdictUIKernel

/// The pixel comparison's arithmetic, tested without a render server.
///
/// Every raster here is built by hand, which is the point of the kernel/probe
/// split: these assertions are about the comparison RULES — what counts as a
/// difference, what is refused, where the changed region is — and they hold on a
/// machine with no display. The probe-side tests cover the other half, where
/// real captures come from real rendering.
final class PixelDiffTests: XCTestCase {
    // MARK: - Fixtures

    /// A solid-colour raster, so a planted change is arithmetic rather than a
    /// font metric.
    private func solid(
        _ width: Int, _ height: Int, r: UInt8, g: UInt8, b: UInt8, a: UInt8 = 255
    ) throws -> PixelRaster {
        var samples: [UInt8] = []
        samples.reserveCapacity(width * height * 4)
        for _ in 0..<(width * height) { samples.append(contentsOf: [r, g, b, a]) }
        return try PixelRaster(width: width, height: height, samples: samples)
    }

    /// `base` with one pixel replaced.
    private func mutating(
        _ base: PixelRaster, x: Int, y: Int, to colour: (UInt8, UInt8, UInt8, UInt8)
    ) throws -> PixelRaster {
        var samples = base.samples
        let i = base.offset(x: x, y: y)
        samples[i] = colour.0
        samples[i + 1] = colour.1
        samples[i + 2] = colour.2
        samples[i + 3] = colour.3
        return try PixelRaster(width: base.width, height: base.height, samples: samples)
    }

    // MARK: - Identity

    func testTwoIdenticalRastersMatchWithNoChangedRegion() throws {
        let raster = try solid(8, 6, r: 10, g: 20, b: 30)
        let result = try PixelDiff.compare(baseline: raster, candidate: raster)

        XCTAssertTrue(result.matches)
        XCTAssertEqual(result.differingPixels, 0)
        XCTAssertEqual(result.maxChannelDelta, 0)
        XCTAssertNil(result.changedRegion)
        XCTAssertEqual(result.totalPixels, 48)
    }

    // MARK: - The measured discriminator

    /// The finding that shaped this file: pixel COUNT cannot separate a visible
    /// regression from an invisible one, and channel MAGNITUDE can.
    ///
    /// Measured on the real capture path 2026-08-13: a border going red and a
    /// border shifting by 2% of one channel both touch exactly 196 of 8000
    /// pixels. A threshold on the count fires identically on both; only the
    /// delta separates them. This test pins that property directly, because it
    /// is the reason `PixelTolerance.maxDifferingFraction` defaults to 0 while
    /// several general-purpose image-diff tools default it to ~5%.
    func testTheChannelDeltaSeparatesChangesThatThePixelCountCannot() throws {
        let baseline = try solid(10, 10, r: 0, g: 0, b: 0)
        // Same pixel, two very different changes.
        let invisible = try mutating(baseline, x: 3, y: 4, to: (0, 0, 5, 255))
        let obvious = try mutating(baseline, x: 3, y: 4, to: (255, 56, 60, 255))

        let faint = try PixelDiff.compare(baseline: baseline, candidate: invisible)
        let loud = try PixelDiff.compare(baseline: baseline, candidate: obvious)

        // Identical on the count — which is precisely why the count cannot be
        // the discriminator.
        XCTAssertEqual(faint.differingPixels, loud.differingPixels)
        // And separated on the delta.
        XCTAssertEqual(faint.maxChannelDelta, 5)
        XCTAssertEqual(loud.maxChannelDelta, 255)
    }

    /// A 1-px regression must FAIL, not be swallowed by an area allowance.
    ///
    /// The negative control is the second half: with the ~5% allowance a
    /// general-purpose diff tool ships as its default, the very change this
    /// channel exists to catch reports as a match.
    func testASinglePixelChangeFailsUnderTheDefaultToleranceButPassesUnderAnAreaAllowance() throws {
        let baseline = try solid(10, 10, r: 255, g: 255, b: 255)
        let candidate = try mutating(baseline, x: 0, y: 0, to: (255, 0, 0, 255))

        let strict = try PixelDiff.compare(baseline: baseline, candidate: candidate)
        XCTAssertFalse(strict.matches, "a 1-px regression is exactly what this channel is for")
        XCTAssertEqual(strict.differingPixels, 1)

        let lenient = try PixelDiff.compare(
            baseline: baseline,
            candidate: candidate,
            tolerance: PixelTolerance(perChannel: 2, maxDifferingFraction: 0.05)
        )
        XCTAssertTrue(lenient.matches, "1 of 100 px is under a 5% allowance — the swallow case")
    }

    // MARK: - PixelDiffResult

    /// `PixelDiffResult.differingFraction` is what `matches` is decided on, so
    /// an off-by-one in it silently moves every area-allowance verdict.
    func testTheDifferingFractionIsTheShareOfTheFrameThatChanged() throws {
        let baseline = try solid(10, 10, r: 0, g: 0, b: 0)
        var candidate = try mutating(baseline, x: 0, y: 0, to: (255, 0, 0, 255))
        candidate = try mutating(candidate, x: 1, y: 0, to: (255, 0, 0, 255))

        let result = try PixelDiff.compare(baseline: baseline, candidate: candidate)

        XCTAssertEqual(result.differingPixels, 2)
        XCTAssertEqual(result.totalPixels, 100)
        XCTAssertEqual(result.differingFraction, 0.02, accuracy: 1e-9)
    }

    /// A result over an empty frame must report 0, not divide by zero. Reachable
    /// only by constructing the result directly — `PixelRaster` refuses a
    /// zero dimension — but the guard is what keeps that refusal the ONLY way in.
    func testTheDifferingFractionOfAnEmptyFrameIsZeroRatherThanNotANumber() {
        let empty = PixelDiffResult(
            differingPixels: 0,
            totalPixels: 0,
            maxChannelDelta: 0,
            changedRegion: nil,
            toleratedFraction: 0
        )

        XCTAssertEqual(empty.differingFraction, 0)
        XCTAssertFalse(empty.differingFraction.isNaN, "0/0 must not leak NaN into a verdict")
        XCTAssertTrue(empty.matches)
    }

    /// `matches` reads the allowance the result was JUDGED against, not one
    /// supplied afterwards — so a result cannot be re-interpreted more leniently
    /// than the comparison that produced it.
    func testAResultCarriesTheAreaAllowanceItWasJudgedAgainst() throws {
        let baseline = try solid(10, 10, r: 255, g: 255, b: 255)
        let candidate = try mutating(baseline, x: 5, y: 5, to: (0, 0, 0, 255))

        let strict = try PixelDiff.compare(baseline: baseline, candidate: candidate)
        let lenient = try PixelDiff.compare(
            baseline: baseline,
            candidate: candidate,
            tolerance: PixelTolerance(perChannel: 2, maxDifferingFraction: 0.5)
        )

        // Same pixels, same delta — only the allowance differs, and only the
        // verdict follows it.
        XCTAssertEqual(strict.differingPixels, lenient.differingPixels)
        XCTAssertEqual(strict.maxChannelDelta, lenient.maxChannelDelta)
        XCTAssertFalse(strict.matches)
        XCTAssertTrue(lenient.matches)
    }

    /// An out-of-range area allowance is clamped rather than trusted: a negative
    /// value would make `matches` unreachable and a value above 1 would make it
    /// unconditional, and both are silent.
    func testAnOutOfRangeAreaAllowanceIsClamped() {
        XCTAssertEqual(PixelTolerance(maxDifferingFraction: -3).maxDifferingFraction, 0)
        XCTAssertEqual(PixelTolerance(maxDifferingFraction: 7).maxDifferingFraction, 1)
    }

    // MARK: - Tolerance

    func testAChannelDeltaWithinToleranceIsNotADifference() throws {
        let baseline = try solid(4, 4, r: 100, g: 100, b: 100)
        let candidate = try mutating(baseline, x: 1, y: 1, to: (102, 100, 100, 255))

        let standard = try PixelDiff.compare(baseline: baseline, candidate: candidate)
        XCTAssertTrue(standard.matches, "delta 2 is the documented rounding allowance")
        XCTAssertEqual(standard.differingPixels, 0)
        // Reported even though tolerated — the number that says how close a pass was.
        XCTAssertEqual(standard.maxChannelDelta, 2)

        let exact = try PixelDiff.compare(
            baseline: baseline, candidate: candidate, tolerance: .exact)
        XCTAssertFalse(exact.matches, "exact tolerance must see what standard forgives")
        XCTAssertEqual(exact.differingPixels, 1)
    }

    func testAlphaOnlyChangesAreDetected() throws {
        // Alpha is a channel like any other: a control that faded out is a
        // visual change even when its RGB is untouched.
        let baseline = try solid(4, 4, r: 10, g: 20, b: 30, a: 255)
        let candidate = try mutating(baseline, x: 2, y: 2, to: (10, 20, 30, 0))

        let result = try PixelDiff.compare(baseline: baseline, candidate: candidate)
        XCTAssertFalse(result.matches)
        XCTAssertEqual(result.maxChannelDelta, 255)
    }

    // MARK: - Changed region

    func testTheChangedRegionBoundsEveryDifferingPixel() throws {
        let baseline = try solid(20, 20, r: 0, g: 0, b: 0)
        var candidate = try mutating(baseline, x: 4, y: 6, to: (255, 255, 255, 255))
        candidate = try mutating(candidate, x: 9, y: 11, to: (255, 255, 255, 255))

        let region = try XCTUnwrap(
            try PixelDiff.compare(baseline: baseline, candidate: candidate).changedRegion)

        XCTAssertEqual(region.x, 4)
        XCTAssertEqual(region.y, 6)
        // Inclusive of both endpoints: 4...9 is six columns, 6...11 is six rows.
        XCTAssertEqual(region.width, 6)
        XCTAssertEqual(region.height, 6)
    }

    func testASingleChangedPixelBoundsToAOneByOneRegion() throws {
        let baseline = try solid(5, 5, r: 0, g: 0, b: 0)
        let candidate = try mutating(baseline, x: 2, y: 3, to: (255, 0, 0, 255))

        let region = try XCTUnwrap(
            try PixelDiff.compare(baseline: baseline, candidate: candidate).changedRegion)
        XCTAssertEqual(region.width, 1)
        XCTAssertEqual(region.height, 1)
        XCTAssertEqual(region.x, 2)
        XCTAssertEqual(region.y, 3)
    }

    // MARK: - Refusals

    func testADimensionMismatchIsRefusedRatherThanReportedAsAMaximalDifference() throws {
        let baseline = try solid(4, 4, r: 0, g: 0, b: 0)
        let candidate = try solid(4, 5, r: 0, g: 0, b: 0)

        XCTAssertThrowsError(try PixelDiff.compare(baseline: baseline, candidate: candidate)) {
            guard case let PixelDiffError.dimensionMismatch(bw, bh, cw, ch) = $0 else {
                return XCTFail("expected a dimension mismatch, got \($0)")
            }
            XCTAssertEqual([bw, bh, cw, ch], [4, 4, 4, 5])
            // The message must send the reader at the semantic channel, which
            // can name the node that resized — pixels cannot.
            XCTAssertTrue(
                "\($0)".contains("semantic channel"),
                "a size change needs the channel that can attribute it: \($0)")
        }
    }

    func testARasterWhoseBufferDoesNotMatchItsDimensionsIsRefusedAtConstruction() throws {
        // Caught here rather than at compare time: a short buffer would read
        // past its own rows and report the garbage as a visual difference — a
        // wrong answer indistinguishable from a real finding.
        XCTAssertThrowsError(try PixelRaster(width: 4, height: 4, samples: [0, 0, 0, 255])) {
            guard case let PixelDiffError.malformedRaster(_, _, expected, actual) = $0 else {
                return XCTFail("expected a malformed raster, got \($0)")
            }
            XCTAssertEqual(expected, 64)
            XCTAssertEqual(actual, 4)
        }
    }

    func testAZeroDimensionRasterIsRefused() throws {
        // A zero-area raster encodes and compares equal to every other zero-area
        // raster, so admitting one would make a blank frame match any baseline.
        XCTAssertThrowsError(try PixelRaster(width: 0, height: 4, samples: []))
    }

    // MARK: - Region cropping (Task 4)

    func testCroppingReturnsExactlyTheRequestedRectangle() throws {
        let base = try solid(10, 10, r: 0, g: 0, b: 0)
        let marked = try mutating(base, x: 4, y: 5, to: (255, 0, 0, 255))

        let crop = try marked.cropped(to: Rect(x: 4, y: 5, width: 2, height: 3))

        XCTAssertEqual(crop.width, 2)
        XCTAssertEqual(crop.height, 3)
        // The marked pixel is the crop's origin, which proves the rows were read
        // from the right offset rather than merely being the right size.
        XCTAssertEqual(crop.samples[crop.offset(x: 0, y: 0)], 255)
        XCTAssertEqual(crop.samples[crop.offset(x: 1, y: 0)], 0)
    }

    /// A region diff must be blind to changes OUTSIDE its region — that is the
    /// whole point of scoping, and a crop that silently returned the full frame
    /// would pass every other test in this file.
    func testAChangeOutsideTheRegionIsInvisibleToARegionDiff() throws {
        let base = try solid(10, 10, r: 0, g: 0, b: 0)
        let changedElsewhere = try mutating(base, x: 9, y: 9, to: (255, 0, 0, 255))

        let region = Rect(x: 0, y: 0, width: 3, height: 3)
        let result = try PixelDiff.compare(
            baseline: try base.cropped(to: region),
            candidate: try changedElsewhere.cropped(to: region)
        )
        XCTAssertTrue(result.matches, "the change is outside the region")
        XCTAssertEqual(result.totalPixels, 9, "and the region really is 3x3, not the frame")

        // Control: the same change IS visible to a whole-frame diff, so the
        // fixture is genuinely different and this is scoping rather than a
        // comparison that cannot fail.
        let whole = try PixelDiff.compare(baseline: base, candidate: changedElsewhere)
        XCTAssertFalse(whole.matches)
    }

    /// Frames land on fractional points, and rounding INWARD would drop the edge
    /// — which is exactly where a border, a shadow or a focus ring lives.
    func testAFractionalFrameRoundsOutwardSoTheEdgeIsNeverClipped() throws {
        let base = try solid(10, 10, r: 0, g: 0, b: 0)

        let crop = try base.cropped(to: Rect(x: 2.4, y: 3.6, width: 3.2, height: 2.1))

        // x: 2.4 -> 2, (2.4+3.2)=5.6 -> 6, so 4 columns. Rounding inward would
        // give 3 and lose a column of the element's own border.
        XCTAssertEqual(crop.width, 4)
        // y: 3.6 -> 3, (3.6+2.1)=5.7 -> 6, so 3 rows.
        XCTAssertEqual(crop.height, 3)
    }

    func testARegionOutsideTheCaptureIsRefusedRatherThanClamped() throws {
        let base = try solid(10, 10, r: 0, g: 0, b: 0)

        // Clamping would compare a different area than the caller asked for and
        // report the answer as if it were the requested one.
        for offending in [
            Rect(x: 8, y: 0, width: 5, height: 2),  // runs off the right edge
            Rect(x: -1, y: 0, width: 3, height: 2),  // starts before the origin
            Rect(x: 0, y: 9, width: 2, height: 4),  // runs off the bottom
        ] {
            XCTAssertThrowsError(try base.cropped(to: offending)) {
                guard case PixelDiffError.regionOutOfBounds = $0 else {
                    return XCTFail("expected regionOutOfBounds for \(offending), got \($0)")
                }
            }
        }
    }

    func testANonFiniteOrEmptyFrameIsRefused() throws {
        let base = try solid(10, 10, r: 0, g: 0, b: 0)

        // Every comparison against NaN is false, so without the explicit guard a
        // NaN frame would pass the bounds checks and crop to garbage.
        XCTAssertThrowsError(
            try base.cropped(to: Rect(x: .nan, y: 0, width: 2, height: 2)))
        XCTAssertThrowsError(
            try base.cropped(to: Rect(x: 0, y: 0, width: .infinity, height: 2)))
        XCTAssertThrowsError(
            try base.cropped(to: Rect(x: 0, y: 0, width: 0, height: 2)))
    }

    func testCroppingHonoursTheScale() throws {
        let base = try solid(20, 20, r: 0, g: 0, b: 0)

        // The same 5x5-point frame is 10x10 pixels at 2x. Getting this wrong
        // would crop a quarter of the intended element and still return a
        // perfectly valid raster.
        let atOne = try base.cropped(to: Rect(x: 0, y: 0, width: 5, height: 5), scale: 1)
        let atTwo = try base.cropped(to: Rect(x: 0, y: 0, width: 5, height: 5), scale: 2)

        XCTAssertEqual(atOne.width, 5)
        XCTAssertEqual(atTwo.width, 10)
    }

    // MARK: - Heat map

    func testTheHeatMapMarksOnlyThePixelsThatExceededTolerance() throws {
        let baseline = try solid(4, 4, r: 0, g: 0, b: 0)
        let candidate = try mutating(baseline, x: 1, y: 2, to: (255, 0, 0, 255))

        let heat = try PixelDiff.heatMap(baseline: baseline, candidate: candidate)

        XCTAssertEqual(heat.width, 4)
        XCTAssertEqual(heat.height, 4)
        let marked = heat.offset(x: 1, y: 2)
        XCTAssertEqual(heat.samples[marked], 255, "the changed pixel is painted red")
        XCTAssertGreaterThan(heat.samples[marked + 3], 0, "and is opaque enough to see")

        // Every other pixel is fully transparent, so the map cannot read as a
        // whole-frame change.
        for y in 0..<4 {
            for x in 0..<4 where !(x == 1 && y == 2) {
                XCTAssertEqual(
                    heat.samples[heat.offset(x: x, y: y) + 3], 0,
                    "(\(x),\(y)) did not change and must not be painted")
            }
        }
    }

    /// A flat mask would draw a one-shade shift and an outright colour change
    /// identically — which is the same blindness the pixel COUNT has. The heat
    /// map's alpha carries severity so the image says which one happened.
    func testTheHeatMapIntensityScalesWithTheChannelDelta() throws {
        let baseline = try solid(4, 4, r: 0, g: 0, b: 0)
        let faint = try mutating(baseline, x: 0, y: 0, to: (0, 0, 10, 255))
        let loud = try mutating(baseline, x: 0, y: 0, to: (255, 0, 0, 255))

        let faintHeat = try PixelDiff.heatMap(baseline: baseline, candidate: faint)
        let loudHeat = try PixelDiff.heatMap(baseline: baseline, candidate: loud)

        let i = faintHeat.offset(x: 0, y: 0)
        XCTAssertGreaterThan(
            loudHeat.samples[i + 3], faintHeat.samples[i + 3],
            "a bigger delta must draw more strongly, or the map cannot tell them apart")
    }

    func testTheHeatMapRefusesMismatchedDimensions() throws {
        let baseline = try solid(4, 4, r: 0, g: 0, b: 0)
        let candidate = try solid(5, 4, r: 0, g: 0, b: 0)
        XCTAssertThrowsError(try PixelDiff.heatMap(baseline: baseline, candidate: candidate))
    }
}
