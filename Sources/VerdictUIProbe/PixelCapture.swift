// VerdictUIProbe — Wave 9 Task 1: the pixel channel's capture half.
//
// Pixels are the exception path, never the default. Every question geometry can
// answer is answered by the semantic tree, which is cheap, structural, and cites
// node ids. This file exists for the residue — a gradient, a shadow, an image's
// content, a font's rendering — where the only honest evidence is the rendered
// bitmap.
//
// Two backends, and they do NOT agree. The divergence is measured rather than
// assumed, and is documented on ``PixelBackend`` because a caller that believes
// the two are interchangeable will diff a baseline captured by one against a
// capture from the other and read the mismatch as a UI regression.
import AppKit
import SwiftUI
import VerdictUIKernel

// MARK: - Backend

/// Which rendering path produces a ``PixelCapture``.
///
/// ### The divergence, measured
///
/// The two backends do not produce the same bytes for the same view, and the
/// difference starts at the scale. Measured 2026-08-12 on a 120x80 view of the
/// same content:
///
/// | Backend | Pixels | PNG bytes |
/// | --- | --- | --- |
/// | ``cacheDisplay`` (via `bitmapImageRepForCachingDisplay`) | 240x160 | 2463 |
/// | ``imageRenderer`` at `scale = 1` | 120x80 | 1228 |
///
/// `bitmapImageRepForCachingDisplay(in:)` hands back a rep at the *device*
/// backing scale — 2x on any Retina display — so the plan's "scale pinned 1.0"
/// is not something that backend does on its own. ``cacheDisplay`` therefore
/// builds its own `NSBitmapImageRep` at exactly one pixel per point instead of
/// asking the view for one; that is what makes a capture reproducible on a
/// machine with a different display attached.
///
/// Even at matched dimensions the bytes still differ, because the two take
/// different paths through the render server. Neither is "wrong"; they answer
/// slightly different questions, and a baseline is only ever comparable to a
/// capture from the same backend. ``PixelCapture/backend`` records which one
/// produced it so a diff can refuse a cross-backend comparison rather than
/// report it as a visual change.
public enum PixelBackend: String, Sendable, Codable, CaseIterable {
    /// AppKit's `NSView.cacheDisplay(in:to:)` against the live hosting view.
    ///
    /// The default, because it renders the same view instance the semantic tree
    /// was assembled from — so the pixels and the tree describe one layout pass,
    /// not two independent ones that might have settled differently.
    case cacheDisplay

    /// SwiftUI's `ImageRenderer`, rendering the scenario's view value afresh.
    ///
    /// An alternate backend, offered because it honours `scale` directly and is
    /// the path SwiftUI itself documents. It re-evaluates the view rather than
    /// reading the hosted one, so a scenario whose body depends on state the
    /// host has since mutated will render its *initial* appearance here.
    case imageRenderer
}

// MARK: - Capture

/// One rendered bitmap of a scenario, with everything needed to decide whether a
/// later capture is comparable to it.
public struct PixelCapture: Sendable, Equatable {
    /// PNG-encoded bytes of the render.
    public let png: Data

    /// Width in pixels. At the pinned 1.0 scale this equals the host's width in
    /// points; it is stored rather than derived so a capture read back from disk
    /// can be checked against the host that is about to be compared to it.
    public let pixelsWide: Int

    /// Height in pixels.
    public let pixelsHigh: Int

    /// Which backend produced these bytes. See ``PixelBackend`` — a baseline is
    /// comparable only to a capture from the same backend.
    public let backend: PixelBackend

    /// Content hash of ``png``, for cheap equality and for the Task 5 cache key.
    public let contentHash: String

    /// Scenario this capture is of, so a finding and an artifact path can cite
    /// the same string the author chose.
    public let scenarioName: String

    init(png: Data, pixelsWide: Int, pixelsHigh: Int, backend: PixelBackend, scenarioName: String) {
        self.png = png
        self.pixelsWide = pixelsWide
        self.pixelsHigh = pixelsHigh
        self.backend = backend
        self.scenarioName = scenarioName
        contentHash = Self.hash(png)
    }

    /// FNV-1a over the PNG bytes, rendered as 16 lowercase hex digits.
    ///
    /// Not a cryptographic hash and not required to be one: nothing here defends
    /// against an adversary choosing colliding bitmaps, it only needs to separate
    /// two renders of the same screen cheaply enough to run on every capture.
    static func hash(_ data: Data) -> String {
        var value: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data {
            value = (value ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
        }
        return String(format: "%016lx", value)
    }
}

// MARK: - Errors

/// Why a pixel capture could not be produced.
///
/// Every case names the scenario, because a capture failure surfaces in a
/// verdict far from the call site that caused it.
public enum PixelCaptureError: Error, CustomStringConvertible, Equatable {
    /// The bitmap backing store could not be allocated at the requested size.
    case bitmapUnavailable(scenario: String, width: Int, height: Int)

    /// `ImageRenderer` returned no image for the scenario's view.
    case rendererProducedNoImage(scenario: String)

    /// The rendered bitmap could not be encoded as PNG.
    case encodingFailed(scenario: String)

    /// The host has no area to render — a zero or negative dimension.
    case emptyViewport(scenario: String, width: Double, height: Double)

    public var description: String {
        switch self {
        case let .bitmapUnavailable(scenario, width, height):
            return """
                pixel capture failed for '\(scenario)': could not allocate a \
                \(width)x\(height) bitmap. The viewport is likely larger than \
                available memory allows; render a smaller region.
                """
        case let .rendererProducedNoImage(scenario):
            return """
                pixel capture failed for '\(scenario)': ImageRenderer produced no \
                image. Try the .cacheDisplay backend, which renders the hosted \
                view rather than re-evaluating the scenario body.
                """
        case let .encodingFailed(scenario):
            return "pixel capture failed for '\(scenario)': the bitmap could not be encoded as PNG."
        case let .emptyViewport(scenario, width, height):
            return """
                pixel capture failed for '\(scenario)': viewport is \(width)x\(height), \
                which has no area to render. Give the scenario an explicit viewport.
                """
        }
    }
}

// MARK: - Capturing from a host

extension OracleHost {
    /// Scale every capture is pinned to, in pixels per point.
    ///
    /// 1.0 so a baseline captured on a Retina machine is byte-comparable to one
    /// captured on a non-Retina machine, or on a CI runner with no display at
    /// all. See ``PixelBackend`` for why this needs enforcing rather than
    /// assuming — the AppKit path defaults to the device scale.
    public nonisolated static let pixelScale: CGFloat = 1.0

    /// Render the currently-hosted layout to a bitmap.
    ///
    /// Does not settle first. A caller wanting pixels of a *settled* layout calls
    /// ``currentTree()`` (or ``settle(timeout:)``) before this, so the two
    /// channels describe the same pass; capturing an unsettled host is a real
    /// use (Task 2's double-render check does it deliberately) and this method
    /// does not decide for the caller.
    public func capturePixels(
        backend: PixelBackend = .cacheDisplay
    ) throws -> PixelCapture {
        let pixels = try pixelDimensions()
        switch backend {
        case .cacheDisplay:
            return try captureViaCacheDisplay(pixels: pixels)
        case .imageRenderer:
            return try captureViaImageRenderer(pixels: pixels)
        }
    }

    /// Host size in whole pixels at ``pixelScale``, or a thrown error when the
    /// host has no area to render.
    ///
    /// A zero-area host is rejected rather than captured: `NSBitmapImageRep`
    /// accepts a zero dimension and hands back an empty image, which encodes to
    /// a valid PNG and compares equal to every other empty PNG — so a scenario
    /// that renders nothing would match any baseline of any other scenario that
    /// renders nothing, and the channel would report PASS for a blank screen.
    private func pixelDimensions() throws -> (wide: Int, high: Int) {
        let wide = Int((hostSize.width * Self.pixelScale).rounded())
        let high = Int((hostSize.height * Self.pixelScale).rounded())
        guard wide > 0, high > 0 else {
            throw PixelCaptureError.emptyViewport(
                scenario: scenarioName,
                width: hostSize.width,
                height: hostSize.height
            )
        }
        return (wide, high)
    }

    /// AppKit path: render the live hosting view into an explicitly-1x bitmap.
    ///
    /// The rep is constructed here rather than obtained from
    /// `bitmapImageRepForCachingDisplay(in:)`, which returns a rep at the device
    /// backing scale — 2x on a Retina display. Measured: the AppKit convenience
    /// gives 240x160 for a 120x80 view, so a baseline captured on this machine
    /// would mismatch every capture from a 1x one. See ``PixelBackend``.
    private func captureViaCacheDisplay(
        pixels: (wide: Int, high: Int)
    ) throws -> PixelCapture {
        guard
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: pixels.wide,
                pixelsHigh: pixels.high,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
        else {
            throw PixelCaptureError.bitmapUnavailable(
                scenario: scenarioName,
                width: pixels.wide,
                height: pixels.high
            )
        }
        // Points, not pixels: with a 1x rep the two are equal, and stating the
        // size in the view's own units is what keeps that true if the scale is
        // ever changed deliberately.
        rep.size = NSSize(width: hostSize.width, height: hostSize.height)
        renderHostedView(into: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw PixelCaptureError.encodingFailed(scenario: scenarioName)
        }
        return PixelCapture(
            png: png,
            pixelsWide: rep.pixelsWide,
            pixelsHigh: rep.pixelsHigh,
            backend: .cacheDisplay,
            scenarioName: scenarioName
        )
    }

    /// SwiftUI path: re-render the scenario's view value through `ImageRenderer`.
    ///
    /// Renders the view AFRESH rather than reading the hosted instance, so a
    /// host whose state has been mutated since construction renders its initial
    /// appearance here. That asymmetry is the reason ``PixelBackend/cacheDisplay``
    /// is the default.
    private func captureViaImageRenderer(
        pixels: (wide: Int, high: Int)
    ) throws -> PixelCapture {
        let renderer = makeImageRenderer()
        renderer.scale = Self.pixelScale
        guard let cgImage = renderer.cgImage else {
            throw PixelCaptureError.rendererProducedNoImage(scenario: scenarioName)
        }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw PixelCaptureError.encodingFailed(scenario: scenarioName)
        }
        return PixelCapture(
            png: png,
            pixelsWide: rep.pixelsWide,
            pixelsHigh: rep.pixelsHigh,
            backend: .imageRenderer,
            scenarioName: scenarioName
        )
    }
}
