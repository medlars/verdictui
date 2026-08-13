// VerdictUIKernel — platform-pure. No SwiftUI/AppKit imports allowed in this target.
//
// Wave 9 Task 3: the pixel channel's comparison half.
//
// This file is the *kernel-adjacent* piece the plan asks for, and the seam it
// sits on is deliberate. Comparing two rasters is arithmetic over bytes: it
// needs no image format, no colour management and no render server, so it
// belongs with the verdict engine rather than with the SwiftUI runtime. Turning
// PNG bytes into a plane of RGBA samples is the opposite — pure platform work —
// and lives in `VerdictUIProbe` as a thin adapter. Splitting there is what lets
// the comparison rules be tested on any machine, including one with no display.
//
// ### What the thresholds are, and how they were chosen
//
// Measured 2026-08-13 on this capture path (windowless host, 1x pinned), not
// inherited from a general-purpose image-diff tool:
//
// | Change | Differing px (of 8000) | Max channel delta |
// | --- | --- | --- |
// | Two renders of one screen | 0 | 0 |
// | Border colour black -> red | 196 (2.45%) | 255 |
// | Border colour black -> near-black | 196 (2.45%) | 5 |
// | Text moved by a whole point | 649 | 216 |
//
// Two things follow, and both run against the obvious design.
//
// **The pixel COUNT does not separate a real regression from an invisible
// one.** A border going red and a border shifting by 2% of one channel touch
// exactly the same 196 pixels. Any rule of the form "fail when more than N% of
// pixels differ" fires identically on both, so it cannot be the primary
// discriminator. Channel MAGNITUDE is what separates them, and it is therefore
// what ``PixelTolerance/perChannel`` gates on.
//
// **Sub-pixel anti-aliasing jitter does not occur here.** Offsets of 0.37 pt
// and 0.5 pt both produced byte-identical output; only a full 1 pt move changed
// anything, and when it did the change was large (649 px, 497 of them saturated)
// rather than a faint halo. This capture path snaps layout to the pixel grid, so
// the classic "every glyph edge shimmers" motivation for AA tolerance is absent.
// ``PixelTolerance/perChannel`` still defaults to a small non-zero value, but
// for an honest and much narrower reason: to absorb rounding in colour
// conversion, not to paper over a moved element. Its default is documented as
// what it is — a rounding allowance — rather than as anti-aliasing insurance the
// measurements do not support.
import Foundation

// MARK: - Raster

/// A decoded image: 8-bit RGBA samples in row-major order, four bytes per pixel.
///
/// Deliberately not an image *format*. Nothing here knows about PNG, colour
/// profiles or compression — those are the adapter's problem, and keeping them
/// out is what lets this type and everything that consumes it stay in the
/// platform-pure kernel.
public struct PixelRaster: Equatable, Sendable {
    /// Width in pixels.
    public let width: Int

    /// Height in pixels.
    public let height: Int

    /// `width * height * 4` bytes, row-major, RGBA.
    public let samples: [UInt8]

    /// - Throws: ``PixelDiffError/malformedRaster(width:height:expectedBytes:actualBytes:)``
    ///   when the sample count does not match the stated dimensions. Checked at
    ///   construction rather than at compare time: a raster whose buffer is
    ///   short would otherwise read past its own rows and report the resulting
    ///   garbage as a visual difference, which is a wrong answer that looks
    ///   exactly like a real finding.
    public init(width: Int, height: Int, samples: [UInt8]) throws {
        let expected = width * height * 4
        guard width > 0, height > 0, samples.count == expected else {
            throw PixelDiffError.malformedRaster(
                width: width,
                height: height,
                expectedBytes: expected,
                actualBytes: samples.count
            )
        }
        self.width = width
        self.height = height
        self.samples = samples
    }

    /// Byte offset of the pixel at (`x`, `y`).
    func offset(x: Int, y: Int) -> Int { (y * width + x) * 4 }

    /// The sub-rectangle of this raster covered by `rect`, as its own raster.
    ///
    /// Wave 9 Task 4's primitive: a baseline scoped to one probe's frame is
    /// smaller to store, cheaper to compare, and — the reason that matters —
    /// attributable, because a finding can name the node instead of the screen.
    /// A whole-frame diff says "something changed"; a region diff says which
    /// element changed.
    ///
    /// `rect` arrives in POINTS from a ``SemanticNode``'s frame and is converted
    /// at `scale`. Coordinates are rounded outward — origin down, extent up — so
    /// a frame landing between pixel boundaries yields a region that fully
    /// CONTAINS the element rather than one that clips its edge. Clipping would
    /// be the worse error by far: the edge is exactly where a border, a shadow
    /// or a focus ring lives, which is the content this channel exists to judge.
    ///
    /// - Throws: ``PixelDiffError/regionOutOfBounds(region:width:height:)`` when
    ///   the rectangle is not wholly inside the raster. A region that hangs off
    ///   the edge is NOT silently clamped: a clamped crop compares a different
    ///   area than the caller asked for and reports the result as if it were the
    ///   requested one, so a node that moved partly offscreen would be diffed
    ///   against the wrong pixels and could report a match.
    public func cropped(to rect: Rect, scale: Double = 1.0) throws -> PixelRaster {
        // `isEmpty` already treats a NaN or infinite component as empty, which
        // is the check that matters here: a NaN frame passes every `<`/`>`
        // comparison below (every comparison against NaN is false), so without
        // it a broken layout would crop to garbage rather than be refused.
        guard !rect.isEmpty, scale > 0, scale.isFinite else {
            throw PixelDiffError.regionOutOfBounds(
                region: rect, width: width, height: height)
        }

        let minX = Int((rect.x * scale).rounded(.down))
        let minY = Int((rect.y * scale).rounded(.down))
        let maxX = Int(((rect.x + rect.width) * scale).rounded(.up))
        let maxY = Int(((rect.y + rect.height) * scale).rounded(.up))
        let cropWidth = maxX - minX
        let cropHeight = maxY - minY

        guard
            minX >= 0, minY >= 0, cropWidth > 0, cropHeight > 0,
            maxX <= width, maxY <= height
        else {
            throw PixelDiffError.regionOutOfBounds(
                region: rect, width: width, height: height)
        }

        var out = [UInt8]()
        out.reserveCapacity(cropWidth * cropHeight * 4)
        for y in minY..<maxY {
            let rowStart = offset(x: minX, y: y)
            out.append(contentsOf: samples[rowStart..<(rowStart + cropWidth * 4)])
        }
        return try PixelRaster(width: cropWidth, height: cropHeight, samples: out)
    }
}

// MARK: - Tolerance

/// How much difference is not a difference.
public struct PixelTolerance: Equatable, Sendable {
    /// Largest per-channel absolute delta still treated as identical, 0–255.
    ///
    /// Default 2, and that number is a **rounding allowance**, not an
    /// anti-aliasing one. Measured on this capture path, two renders of one
    /// screen differ by exactly zero and a sub-pixel offset does not change a
    /// single byte — so there is no AA shimmer for a tolerance to absorb. What
    /// there can be is ±1 from an 8-bit colour conversion, and 2 covers that
    /// with a margin while staying far below the delta of any change a human
    /// could see (the smallest deliberate regression measured here was 5).
    ///
    /// Set to 0 for an exact-bytes comparison.
    public let perChannel: UInt8

    /// Fraction of the frame (0–1) allowed to differ *beyond* ``perChannel``
    /// before the comparison reports a change.
    ///
    /// Default 0: any pixel that clears the channel tolerance counts. This is
    /// the deliberate opposite of the usual image-diff default, and the
    /// measurement is why — a 1-px border regression, the exact case this
    /// channel exists to catch, moves only 2.45% of the frame. A "fewer than 5%
    /// of pixels changed" allowance, which several general-purpose diff tools
    /// ship as their default, would swallow it whole and report PASS.
    ///
    /// Raise it only for a scenario with a known-noisy region, and say so at the
    /// call site.
    public let maxDifferingFraction: Double

    /// The default: 2 per channel, no area allowance. See each property.
    public static let standard = PixelTolerance(perChannel: 2, maxDifferingFraction: 0)

    /// Byte-for-byte identity.
    public static let exact = PixelTolerance(perChannel: 0, maxDifferingFraction: 0)

    public init(perChannel: UInt8 = 2, maxDifferingFraction: Double = 0) {
        self.perChannel = perChannel
        self.maxDifferingFraction = max(0, min(1, maxDifferingFraction))
    }
}

// MARK: - Result

/// What comparing two rasters found.
public struct PixelDiffResult: Equatable, Sendable {
    /// Pixels whose worst channel delta exceeded ``PixelTolerance/perChannel``.
    public let differingPixels: Int

    /// Total pixels compared, so a reader can judge the count without knowing
    /// the viewport.
    public let totalPixels: Int

    /// Largest per-channel delta seen anywhere, tolerated or not.
    ///
    /// Reported even when the comparison passes, because it is the number that
    /// says *how close* a pass was — a run at delta 2 against a tolerance of 2
    /// is one rounding change away from failing and is worth seeing.
    public let maxChannelDelta: Int

    /// Bounding box of the differing pixels, or `nil` when there are none.
    ///
    /// A box rather than a list: the list is the heat artifact's job, and a
    /// finding that carried thousands of coordinates would be unreadable and
    /// expensive on the token-metered MCP surface. The box is what lets a reader
    /// say "the change is in the top-left corner" without opening an image.
    public let changedRegion: Rect?

    /// Fraction of the frame that differed, 0–1.
    public var differingFraction: Double {
        totalPixels == 0 ? 0 : Double(differingPixels) / Double(totalPixels)
    }

    /// True when the two rasters are the same picture within tolerance.
    public var matches: Bool {
        differingPixels == 0 || differingFraction <= toleratedFraction
    }

    /// The area allowance this result was judged against, carried so ``matches``
    /// does not need the tolerance passed back in.
    let toleratedFraction: Double
}

// MARK: - Errors

/// Why two captures could not be compared.
///
/// Every case is a refusal to answer rather than a wrong answer. A comparison
/// that cannot be made honestly must not degrade into a difference report: the
/// reader would act on it as a UI regression, which is the most expensive shape
/// a verification tool has.
public enum PixelDiffError: Error, CustomStringConvertible, Equatable {
    /// The two rasters are different sizes.
    case dimensionMismatch(
        baselineWidth: Int, baselineHeight: Int, candidateWidth: Int, candidateHeight: Int)

    /// A raster's buffer does not match its stated dimensions.
    case malformedRaster(width: Int, height: Int, expectedBytes: Int, actualBytes: Int)

    /// The two captures came from different rendering backends.
    ///
    /// Measured in Wave 9 Task 1 and recorded on `PixelBackend`: the two
    /// backends produce different bytes for the same view even at matched
    /// dimensions, because they take different paths through the render server.
    /// Comparing across them would report that difference as a visual change on
    /// every single run.
    case backendMismatch(baseline: String, candidate: String)

    /// A region-scoped crop asked for pixels outside the captured frame.
    ///
    /// Refused rather than clamped: a clamped crop compares a different area
    /// than the caller requested while reporting the result as the requested
    /// one, so a node that moved partly offscreen would be diffed against the
    /// wrong pixels — and could report a match.
    case regionOutOfBounds(region: Rect, width: Int, height: Int)

    /// A region-scoped comparison named a probe id the tree does not contain.
    case unknownRegionNode(nodeID: String, scenario: String)

    /// Human-readable refusal naming what could not be compared and what to do.
    ///
    /// Each message ends in an instruction rather than a diagnosis, because a
    /// refusal reaches its reader inside a verdict, far from the call site that
    /// caused it — "cannot compare" alone leaves them to rediscover why.
    public var description: String {
        switch self {
        case let .dimensionMismatch(bw, bh, cw, ch):
            return """
                cannot compare pixels: baseline is \(bw)x\(bh) but candidate is \(cw)x\(ch). \
                A size change is a layout change — verify it with the semantic channel, \
                which can name the node that resized, then re-record the baseline.
                """
        case let .malformedRaster(width, height, expected, actual):
            return """
                cannot compare pixels: a \(width)x\(height) raster needs \(expected) bytes \
                but carries \(actual). The decode step produced a buffer that does not \
                match its own dimensions.
                """
        case let .backendMismatch(baseline, candidate):
            return """
                cannot compare pixels: baseline was captured with the '\(baseline)' backend \
                and the candidate with '\(candidate)'. The two do not produce identical bytes \
                for the same view, so the difference would be the backend rather than the UI. \
                Re-capture the candidate with '\(baseline)', or re-record the baseline.
                """
        case let .regionOutOfBounds(region, width, height):
            return """
                cannot compare pixels: the requested region (\(Int(region.x)), \(Int(region.y))) \
                \(Int(region.width))x\(Int(region.height)) is not wholly inside the \
                \(width)x\(height) capture. The node has moved or resized past the viewport — \
                the semantic channel can name what moved, and `offscreen` or `clipped-content` \
                will already be reporting it.
                """
        case let .unknownRegionNode(nodeID, scenario):
            return """
                cannot compare pixels: '\(scenario)' has no probed node '\(nodeID)' to scope the \
                comparison to. Check the id against `.verdictProbe(_:)`, or compare the whole \
                frame instead of a region.
                """
        }
    }
}

// MARK: - The comparison

/// Structural comparison of two rendered frames.
public enum PixelDiff {
    /// Compare `candidate` against `baseline`.
    ///
    /// - Throws: ``PixelDiffError/dimensionMismatch`` when the two differ in
    ///   size. Not reported as a maximal difference: "the layout resized" and
    ///   "the colours changed" are different findings with different fixes, and
    ///   the semantic channel answers the first one far better than pixels can.
    public static func compare(
        baseline: PixelRaster,
        candidate: PixelRaster,
        tolerance: PixelTolerance = .standard
    ) throws -> PixelDiffResult {
        guard baseline.width == candidate.width, baseline.height == candidate.height else {
            throw PixelDiffError.dimensionMismatch(
                baselineWidth: baseline.width,
                baselineHeight: baseline.height,
                candidateWidth: candidate.width,
                candidateHeight: candidate.height
            )
        }

        var differing = 0
        var maxDelta = 0
        var minX = Int.max
        var minY = Int.max
        var maxX = Int.min
        var maxY = Int.min

        let allowance = Int(tolerance.perChannel)
        for y in 0..<baseline.height {
            for x in 0..<baseline.width {
                let i = baseline.offset(x: x, y: y)
                var worst = 0
                for channel in 0..<4 {
                    let delta = abs(Int(baseline.samples[i + channel]) - Int(candidate.samples[i + channel]))
                    if delta > worst { worst = delta }
                }
                if worst > maxDelta { maxDelta = worst }
                guard worst > allowance else { continue }
                differing += 1
                if x < minX { minX = x }
                if y < minY { minY = y }
                if x > maxX { maxX = x }
                if y > maxY { maxY = y }
            }
        }

        let region: Rect? =
            differing == 0
            ? nil
            : Rect(
                x: Double(minX),
                y: Double(minY),
                width: Double(maxX - minX + 1),
                height: Double(maxY - minY + 1)
            )

        return PixelDiffResult(
            differingPixels: differing,
            totalPixels: baseline.width * baseline.height,
            maxChannelDelta: maxDelta,
            changedRegion: region,
            toleratedFraction: tolerance.maxDifferingFraction
        )
    }

    /// Per-pixel heat map of the comparison: opaque red where a pixel exceeded
    /// tolerance, transparent where it did not.
    ///
    /// Intensity scales with the channel delta so a reader can see *how* wrong a
    /// region is, not merely that it is wrong — a border that shifted one shade
    /// and a border that changed colour outright cover the same pixels (measured:
    /// both 196), and a flat mask would draw them identically.
    ///
    /// - Throws: the same dimension and shape errors as ``compare(baseline:candidate:tolerance:)``.
    public static func heatMap(
        baseline: PixelRaster,
        candidate: PixelRaster,
        tolerance: PixelTolerance = .standard
    ) throws -> PixelRaster {
        guard baseline.width == candidate.width, baseline.height == candidate.height else {
            throw PixelDiffError.dimensionMismatch(
                baselineWidth: baseline.width,
                baselineHeight: baseline.height,
                candidateWidth: candidate.width,
                candidateHeight: candidate.height
            )
        }

        let allowance = Int(tolerance.perChannel)
        var out = [UInt8](repeating: 0, count: baseline.samples.count)
        for i in stride(from: 0, to: baseline.samples.count, by: 4) {
            var worst = 0
            for channel in 0..<4 {
                let delta = abs(Int(baseline.samples[i + channel]) - Int(candidate.samples[i + channel]))
                if delta > worst { worst = delta }
            }
            guard worst > allowance else { continue }
            // Red channel full, alpha scaled by severity with a visible floor —
            // a 1-unit-over-tolerance pixel must still be findable by eye, so
            // the scale starts at 64 rather than at 0.
            out[i] = 255
            out[i + 3] = UInt8(min(255, 64 + worst))
        }
        return try PixelRaster(width: baseline.width, height: baseline.height, samples: out)
    }
}
