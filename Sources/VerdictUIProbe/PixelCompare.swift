// VerdictUIProbe — Wave 9 Task 3: the platform half of the pixel comparison.
//
// `PixelDiff` (kernel) compares two planes of RGBA bytes and knows nothing about
// image formats. This file supplies those planes and writes the artifacts, which
// is the part that genuinely needs AppKit. The split is why the comparison rules
// — the thresholds, the region arithmetic, the refusals — are testable on a
// machine with no display, and it is the seam the plan means by "kernel-adjacent".
//
// Everything here either decodes, writes a file, or converts an already-computed
// result into a `Finding`. No comparison logic lives on this side of the line.
import AppKit
import Foundation
import VerdictUIKernel

// MARK: - Decoding

extension PixelRaster {
    /// Decode a ``PixelCapture``'s PNG bytes into comparable RGBA samples.
    ///
    /// Draws through an explicitly-constructed sRGB context rather than reading
    /// the bitmap's own buffer. That is deliberate: an `NSBitmapImageRep` read
    /// back from a PNG can arrive in any colour space, with any alpha layout and
    /// any row padding, and comparing two rasters that were normalised
    /// differently would report the *normalisation* as a visual change. Drawing
    /// both through the same fixed context is what makes "same picture" mean the
    /// same thing on both sides of the comparison.
    ///
    /// - Throws: ``PixelCompareError/decodeFailed(scenario:)`` when the bytes are
    ///   not a readable image, and whatever ``PixelRaster/init(width:height:samples:)``
    ///   throws for a buffer that does not match its dimensions.
    public init(decoding capture: PixelCapture) throws {
        guard
            let rep = NSBitmapImageRep(data: capture.png),
            let cgImage = rep.cgImage,
            let space = CGColorSpace(name: CGColorSpace.sRGB)
        else {
            throw PixelCompareError.decodeFailed(scenario: capture.scenarioName)
        }

        let width = capture.pixelsWide
        let height = capture.pixelsHigh
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let drew = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard
                let context = CGContext(
                    data: raw.baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width * 4,
                    space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )
            else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drew else {
            throw PixelCompareError.decodeFailed(scenario: capture.scenarioName)
        }
        try self.init(width: width, height: height, samples: buffer)
    }

    /// PNG-encode this raster, for writing a heat map to disk.
    ///
    /// - Throws: ``PixelCompareError/encodeFailed`` when the samples cannot be
    ///   represented as PNG.
    func pngData() throws -> Data {
        guard
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: width,
                pixelsHigh: height,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: width * 4,
                bitsPerPixel: 32
            ),
            let destination = rep.bitmapData
        else {
            throw PixelCompareError.encodeFailed
        }
        samples.withUnsafeBytes { source in
            guard let base = source.baseAddress else { return }
            destination.update(from: base.assumingMemoryBound(to: UInt8.self), count: samples.count)
        }
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw PixelCompareError.encodeFailed
        }
        return png
    }
}

// MARK: - Errors

/// Why a pixel comparison could not be carried out on this side of the line.
///
/// Kernel-side refusals (dimension mismatch, backend mismatch, a malformed
/// buffer) are `PixelDiffError`. These are the platform ones.
public enum PixelCompareError: Error, CustomStringConvertible, Equatable {
    /// A capture's bytes could not be read back as an image.
    case decodeFailed(scenario: String)

    /// A raster could not be encoded as PNG for an artifact.
    case encodeFailed

    /// The artifact directory could not be created or written.
    case artifactWriteFailed(path: String, reason: String)

    public var description: String {
        switch self {
        case let .decodeFailed(scenario):
            return """
                pixel comparison failed for '\(scenario)': the capture's bytes could not be \
                decoded as an image. The capture is corrupt; re-record it.
                """
        case .encodeFailed:
            return "pixel comparison failed: the diff heat map could not be encoded as PNG."
        case let .artifactWriteFailed(path, reason):
            return """
                pixel comparison produced a result but could not write its artifacts to \
                '\(path)': \(reason). The comparison itself is unaffected; the finding will \
                cite no artifact paths.
                """
        }
    }
}

// MARK: - Artifacts

/// Where a comparison's before/after/heat images were written.
///
/// Paths rather than image payloads, on purpose: the MCP surface is token-metered
/// and a base64 PNG in a finding would cost more than the entire rest of a
/// verdict. A path is something an agent can open when it decides it needs to.
public struct PixelDiffArtifacts: Equatable, Sendable {
    /// The recorded baseline image.
    public let baselinePath: String

    /// The capture that was compared against it.
    public let candidatePath: String

    /// Red-over-transparent heat map of the pixels that exceeded tolerance.
    public let heatPath: String
}

// MARK: - Comparing two captures

/// The pixel channel's compare-and-report entry point.
public enum PixelCompare {
    /// Default directory for diff artifacts, relative to a project root.
    public static let artifactDirectory = "logs/pixel-diffs"

    /// Compare a candidate capture against a baseline and report a finding when
    /// they differ.
    ///
    /// - Throws: ``PixelDiffError/backendMismatch(baseline:candidate:)`` when the
    ///   two captures came from different backends — the one refusal that must
    ///   happen before any bytes are read, because the two backends produce
    ///   different output for the same view (measured, Wave 9 Task 1) and the
    ///   difference would be reported as a UI regression on every run.
    ///
    /// - Returns: the comparison result and a finding, or `nil` for the finding
    ///   when the frames match within tolerance. A PASS produces no finding at
    ///   all rather than an `severity: .warning` "no change detected" — a verdict
    ///   whose findings list grows on success is one nobody reads.
    public static func compare(
        baseline: PixelCapture,
        candidate: PixelCapture,
        nodeID: String? = nil,
        tolerance: PixelTolerance = .standard,
        artifactRoot: URL? = nil
    ) throws -> (result: PixelDiffResult, finding: Finding?) {
        guard baseline.backend == candidate.backend else {
            throw PixelDiffError.backendMismatch(
                baseline: baseline.backend.rawValue,
                candidate: candidate.backend.rawValue
            )
        }

        let baseRaster = try PixelRaster(decoding: baseline)
        let candidateRaster = try PixelRaster(decoding: candidate)
        let result = try PixelDiff.compare(
            baseline: baseRaster,
            candidate: candidateRaster,
            tolerance: tolerance
        )

        guard !result.matches else { return (result, nil) }

        // Artifacts are written only on a FAILING comparison. Writing them on
        // every run would fill the directory with images of screens that did not
        // change, and the one image a reader wants would be indistinguishable
        // from thousands that carry no information.
        let artifacts = try artifactRoot.map { root in
            try writeArtifacts(
                baseline: baseline,
                candidate: candidate,
                heat: try PixelDiff.heatMap(
                    baseline: baseRaster,
                    candidate: candidateRaster,
                    tolerance: tolerance
                ),
                root: root
            )
        }

        return (
            result,
            finding(
                for: result,
                scenario: candidate.scenarioName,
                nodeID: nodeID,
                tolerance: tolerance,
                artifacts: artifacts
            )
        )
    }

    /// Turn a failing comparison into a `Finding` that cites its evidence.
    ///
    /// The message leads with the channel delta rather than the pixel count,
    /// because the count is the number that cannot tell a real regression from
    /// an invisible one: a border going red and a border shifting one shade
    /// touch exactly the same 196 pixels (measured), and only the delta
    /// separates them.
    static func finding(
        for result: PixelDiffResult,
        scenario: String,
        nodeID: String?,
        tolerance: PixelTolerance,
        artifacts: PixelDiffArtifacts?
    ) -> Finding {
        let percent = String(format: "%.2f", result.differingFraction * 100)
        var message = """
            pixels changed in '\(scenario)': max channel delta \(result.maxChannelDelta) \
            (tolerance \(tolerance.perChannel)) across \(result.differingPixels) of \
            \(result.totalPixels) pixels (\(percent)%)
            """
        if let region = result.changedRegion {
            message += """
                , bounded by (\(Int(region.x)), \(Int(region.y))) \
                \(Int(region.width))x\(Int(region.height))
                """
        }
        if let artifacts {
            message += """
                . Artifacts: baseline \(artifacts.baselinePath), candidate \
                \(artifacts.candidatePath), heat map \(artifacts.heatPath)
                """
        }

        return Finding(
            rule: "pixel-diff",
            severity: .error,
            // The node when the comparison was region-scoped, the scenario
            // otherwise. A finding must always cite something a reader can
            // locate (CLAUDE.md rule 4), and a whole-frame diff has no narrower
            // subject than the frame.
            nodeID: nodeID ?? scenario,
            message: message,
            suggestion: """
                Open the heat map to see which region changed. If the change is \
                intended, re-record the baseline; if it is not, the semantic \
                channel will not catch it — pixels are the only evidence for \
                colour, gradient, shadow and glyph rendering.
                """
        )
    }

    /// Write before/after/heat PNGs under `root`, returning their paths.
    static func writeArtifacts(
        baseline: PixelCapture,
        candidate: PixelCapture,
        heat: PixelRaster,
        root: URL
    ) throws -> PixelDiffArtifacts {
        // Scenario names reach here from author-supplied strings and become path
        // components, so anything that could escape the directory is replaced
        // rather than trusted.
        let safeName = candidate.scenarioName.map { character in
            character.isLetter || character.isNumber || character == "-" || character == "_"
                ? character : "-"
        }
        let slug = String(safeName)
        let directory = root.appendingPathComponent(slug, isDirectory: true)

        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
        } catch {
            throw PixelCompareError.artifactWriteFailed(
                path: directory.path, reason: error.localizedDescription)
        }

        let baselineURL = directory.appendingPathComponent("baseline.png")
        let candidateURL = directory.appendingPathComponent("candidate.png")
        let heatURL = directory.appendingPathComponent("heat.png")

        do {
            try baseline.png.write(to: baselineURL)
            try candidate.png.write(to: candidateURL)
            try heat.pngData().write(to: heatURL)
        } catch let error as PixelCompareError {
            throw error
        } catch {
            throw PixelCompareError.artifactWriteFailed(
                path: directory.path, reason: error.localizedDescription)
        }

        return PixelDiffArtifacts(
            baselinePath: baselineURL.path,
            candidatePath: candidateURL.path,
            heatPath: heatURL.path
        )
    }
}
