// VerdictUIKernel — platform-pure. No SwiftUI/AppKit imports allowed in this target.
import Foundation

/// An opaque sRGB colour, as sampled from a captured raster.
public struct SampledColor: Hashable, Sendable, CustomStringConvertible {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// `#RRGGBB`, the spelling a designer compares against a brand palette.
    public var hex: String {
        String(format: "#%02X%02X%02X", red, green, blue)
    }

    /// The ``hex`` spelling, so a colour interpolates as `#RRGGBB`.
    public var description: String { hex }

    /// Parses `#RRGGBB` (the leading `#` is optional).
    public init?(hex: String) {
        let body = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard body.count == 6, let value = UInt32(body, radix: 16) else { return nil }
        self.init(
            red: UInt8((value >> 16) & 0xFF),
            green: UInt8((value >> 8) & 0xFF),
            blue: UInt8(value & 0xFF))
    }

    /// WCAG 2.x relative luminance.
    public var relativeLuminance: Double {
        func linear(_ channel: UInt8) -> Double {
            let c = Double(channel) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// WCAG 2.x contrast ratio, 1...21, symmetric in its arguments.
    public static func contrastRatio(_ a: SampledColor, _ b: SampledColor) -> Double {
        let (hi, lo) = (max(a.relativeLuminance, b.relativeLuminance),
                        min(a.relativeLuminance, b.relativeLuminance))
        return (hi + 0.05) / (lo + 0.05)
    }

    /// Largest per-channel difference — the same magnitude ``PixelDiff`` gates on.
    func channelDistance(to other: SampledColor) -> Int {
        max(
            abs(Int(red) - Int(other.red)),
            abs(Int(green) - Int(other.green)),
            abs(Int(blue) - Int(other.blue)))
    }
}

/// Resolves per-node colour from PIXELS, because the semantic tree carries none.
///
/// WHY FROM PIXELS (CIS-29DC2767). Neither the in-process probe nor the
/// accessibility tree exposes a resolved colour: a control drawn in the system
/// accent instead of the brand accent produces a perfect tree — right role,
/// right frame, right text. "A colour is only checkable by looking at it", so
/// this looks: it reads the region each node occupies in a window capture.
///
/// WHAT THE NUMBERS MEAN, stated plainly because a heuristic presented as a
/// measurement is the failure this project exists to prevent:
/// - `color.background` is the MODAL opaque colour in the node's region.
/// - `color.foreground` is the most frequent colour that differs from that
///   background by at least ``minimumForegroundDistance`` on some channel —
///   for a text node, the glyph colour; anti-aliased edge pixels are each rare
///   and so never win.
/// - `color.contrast` is the WCAG ratio between the two, rounded to 0.01.
///
/// A region is the node's WHOLE frame, children included, so a container's
/// sample describes everything drawn inside it. A node with no distinct second
/// colour gets a background and nothing else — never an invented foreground.
public enum ColorSampler {
    /// Attribute key for the node's modal (background) colour, `#RRGGBB`.
    public static let backgroundKey = "color.background"
    /// Attribute key for the node's distinct foreground colour, `#RRGGBB`.
    public static let foregroundKey = "color.foreground"
    /// Attribute key for the WCAG contrast ratio between the two, a number.
    public static let contrastKey = "color.contrast"

    /// A second colour must differ by this much on some channel to count as a
    /// foreground rather than as noise in the background.
    public static let minimumForegroundDistance = 40

    /// Pixels examined per node, at most. Beyond it the region is strided —
    /// deterministically, so two samples of one capture always agree.
    public static let maximumSamplesPerNode = 250_000

    /// The colours found in one region: always a background, a foreground only
    /// when a sufficiently distinct second colour exists.
    public struct Sample: Equatable, Sendable {
        public let background: SampledColor
        public let foreground: SampledColor?

        /// WCAG ratio, or `nil` when no foreground was found.
        public var contrast: Double? {
            foreground.map { SampledColor.contrastRatio($0, background) }
        }
    }

    /// Sample the pixel rectangle `[x0, x1) x [y0, y1)`, clamped to the raster.
    ///
    /// Returns `nil` when the clamped region is empty or holds no opaque pixel —
    /// a node that is offscreen in the capture has no colour, and reporting one
    /// would be a guess.
    ///
    /// `backdrop` is what a TRANSPARENT pixel would show. A window capture is
    /// opaque, so it passes `nil` and transparent pixels (rounded corners) are
    /// skipped. A windowless render has a transparent canvas, so it passes the
    /// colour the view would sit on; without one, text on a clear canvas has
    /// only its own glyph pixels and reports its ink as its background. Samples
    /// are premultiplied RGBA, as both decoders in this package produce them.
    public static func sample(
        _ raster: PixelRaster, x0: Int, y0: Int, x1: Int, y1: Int,
        backdrop: SampledColor? = nil
    ) -> Sample? {
        let left = max(0, x0)
        let top = max(0, y0)
        let right = min(raster.width, x1)
        let bottom = min(raster.height, y1)
        guard right > left, bottom > top else { return nil }

        let area = (right - left) * (bottom - top)
        let stride = max(1, Int((Double(area) / Double(maximumSamplesPerNode)).squareRoot().rounded(.up)))

        var counts: [UInt32: Int] = [:]
        var y = top
        while y < bottom {
            var x = left
            while x < right {
                let offset = raster.offset(x: x, y: y)
                let alpha = Int(raster.samples[offset + 3])
                if let backdrop {
                    // Premultiplied "over": c + (1 - a) * backdrop.
                    func over(_ channel: Int, _ back: UInt8) -> UInt32 {
                        UInt32(min(255, Int(raster.samples[offset + channel])
                            + (255 - alpha) * Int(back) / 255))
                    }
                    let key = over(0, backdrop.red) << 16 | over(1, backdrop.green) << 8
                        | over(2, backdrop.blue)
                    counts[key, default: 0] += 1
                } else if alpha >= 128 {
                    // Transparent pixels (rounded window corners, an alpha-0
                    // host) carry no colour a person can see.
                    let key =
                        UInt32(raster.samples[offset]) << 16
                        | UInt32(raster.samples[offset + 1]) << 8
                        | UInt32(raster.samples[offset + 2])
                    counts[key, default: 0] += 1
                }
                x += stride
            }
            y += stride
        }
        guard !counts.isEmpty else { return nil }

        // Ties break on the packed value so the answer never depends on
        // dictionary iteration order.
        let ranked = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        let background = color(ranked[0].key)
        let foreground = ranked.dropFirst().lazy
            .map { color($0.key) }
            .first { $0.channelDistance(to: background) >= minimumForegroundDistance }
        return Sample(background: background, foreground: foreground)
    }

    /// Annotate every node whose frame lands inside `raster`.
    ///
    /// `scale` converts points to pixels; `offsetX`/`offsetY` are the tree's
    /// root origin measured from the raster's top-left corner, in POINTS (the
    /// capture includes the titlebar, the tree's root usually does not).
    public static func annotate(
        _ node: SemanticNode, raster: PixelRaster, scale: Double,
        offsetX: Double, offsetY: Double, backdrop: SampledColor? = nil
    ) -> SemanticNode {
        var copy = node
        if !node.frame.isEmpty {
            let x0 = Int(((node.frame.x + offsetX) * scale).rounded(.down))
            let y0 = Int(((node.frame.y + offsetY) * scale).rounded(.down))
            let x1 = Int(((node.frame.x + node.frame.width + offsetX) * scale).rounded(.up))
            let y1 = Int(((node.frame.y + node.frame.height + offsetY) * scale).rounded(.up))
            if let sample = sample(raster, x0: x0, y0: y0, x1: x1, y1: y1, backdrop: backdrop) {
                copy.attributes[backgroundKey] = .string(sample.background.hex)
                if let foreground = sample.foreground, let ratio = sample.contrast {
                    copy.attributes[foregroundKey] = .string(foreground.hex)
                    copy.attributes[contrastKey] = .number((ratio * 100).rounded() / 100)
                }
            }
        }
        copy.children = node.children.map {
            annotate(
                $0, raster: raster, scale: scale, offsetX: offsetX, offsetY: offsetY,
                backdrop: backdrop)
        }
        return copy
    }

    private static func color(_ packed: UInt32) -> SampledColor {
        SampledColor(
            red: UInt8((packed >> 16) & 0xFF),
            green: UInt8((packed >> 8) & 0xFF),
            blue: UInt8(packed & 0xFF))
    }
}
