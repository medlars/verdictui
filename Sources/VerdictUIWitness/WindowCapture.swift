import ApplicationServices
import Foundation
import ImageIO
import VerdictUIKernel

/// Window-only pixel capture of a running app (CIS-009B4F22).
///
/// Two constraints are encoded here once, instead of in every caller's script:
///
/// 1. **Window-only by construction.** Capture always names ONE window id
///    (`screencapture -l`). There is no full-screen path at all, because a
///    full-screen grab on this machine can include an unrelated remote session
///    carrying patient data. A pid with no on-screen window is an error, never
///    a fallback to the screen.
/// 2. **Windows are resolved through CoreGraphics**, not System Events, which
///    intermittently reports zero windows for every process — a reading that
///    looks exactly like the app having failed to draw.
public enum WindowCapture {

    /// A window as the window server lists it. Bounds are in screen POINTS,
    /// top-left origin — the same space accessibility frames use.
    public struct WindowInfo: Equatable, Sendable, Encodable {
        public let windowID: UInt32
        public let x: Double
        public let y: Double
        public let width: Double
        public let height: Double
        public let title: String?
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case noWindow(pid: Int32)
        case windowIndexOutOfRange(index: Int, count: Int)
        case noMatchingWindow(String)
        case captureFailed(String)

        public var description: String {
            switch self {
            case .noWindow(let pid):
                "pid \(pid) has no on-screen window to capture (full-screen capture is "
                    + "never used as a fallback)"
            case .windowIndexOutOfRange(let index, let count):
                "window index \(index) is out of range — pid has \(count) on-screen window(s)"
            case .noMatchingWindow(let detail):
                "no captured window matches the accessibility window: \(detail)"
            case .captureFailed(let detail):
                "window capture failed: \(detail)"
            }
        }
    }

    /// A completed capture: the PNG on disk and its decoded pixels.
    public struct Capture: Sendable {
        public let window: WindowInfo
        public let raster: PixelRaster
        /// Pixels per point (2 on a Retina display).
        public let scale: Double
        public let path: String
    }

    /// `pid`'s ordinary (layer 0) on-screen windows, front to back.
    public static func windows(pid: pid_t) -> [WindowInfo] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        return list.compactMap { entry in
            guard (entry[kCGWindowOwnerPID as String] as? Int32) == pid,
                (entry[kCGWindowLayer as String] as? Int) == 0,
                let number = entry[kCGWindowNumber as String] as? UInt32,
                let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                let bounds = CGRect(dictionaryRepresentation: boundsDict)
            else { return nil }
            return WindowInfo(
                windowID: number, x: Double(bounds.origin.x), y: Double(bounds.origin.y),
                width: Double(bounds.width), height: Double(bounds.height),
                title: entry[kCGWindowName as String] as? String)
        }
    }

    /// The `screencapture` argv for one window. Always carries `-l <id>`:
    /// the argument that makes the capture window-only.
    static func arguments(windowID: UInt32, path: String) -> [String] {
        ["-x", "-o", "-l", String(windowID), path]
    }

    /// Capture `pid`'s `index`-th on-screen window to `url` (PNG).
    public static func capture(pid: pid_t, index: Int = 0, to url: URL) throws -> Capture {
        let all = windows(pid: pid)
        guard !all.isEmpty else { throw Failure.noWindow(pid: pid) }
        guard index >= 0, index < all.count else {
            throw Failure.windowIndexOutOfRange(index: index, count: all.count)
        }
        return try capture(window: all[index], to: url)
    }

    /// Capture exactly `window` to `url` (PNG).
    public static func capture(window: WindowInfo, to url: URL) throws -> Capture {
        try? FileManager.default.removeItem(at: url)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = arguments(windowID: window.windowID, path: url.path)
        do {
            try process.run()
        } catch {
            throw Failure.captureFailed("could not start screencapture: \(error)")
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: url.path)
        else {
            throw Failure.captureFailed(
                "screencapture exited \(process.terminationStatus) and wrote no image — "
                    + "grant Screen Recording to the process running verdictui")
        }
        let raster = try decode(url)
        return Capture(
            window: window, raster: raster,
            scale: window.width > 0 ? Double(raster.width) / window.width : 1, path: url.path)
    }

    /// Decode an image file into 8-bit RGBA.
    static func decode(_ url: URL) throws -> PixelRaster {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw Failure.captureFailed("unreadable image at \(url.path)") }
        let width = image.width
        let height = image.height
        guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw Failure.captureFailed("no sRGB colour space")
        }
        var samples = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = samples.withUnsafeMutableBytes { buffer -> Bool in
            guard
                let context = CGContext(
                    data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: sRGB,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw Failure.captureFailed("could not decode \(url.path)") }
        return try PixelRaster(width: width, height: height, samples: samples)
    }

    /// Read `surface` and annotate every node with its sampled colours.
    ///
    /// The capture is matched to the accessibility window by BOUNDS, not by
    /// list position: the two lists are ordered by different authorities, and a
    /// positional match would sample one window's pixels into another's tree —
    /// colours that are real, confident and about the wrong screen.
    public static func readTreeWithColors(
        pid: pid_t, surface: AXReader.Surface, scratch: URL
    ) throws -> SemanticNode {
        let read = try AXReader.readSurface(pid: pid, surface: surface)
        guard let frame = read.windowFrame else {
            throw Failure.noMatchingWindow("\(surface) is not a window; colours need a window")
        }
        let candidates = windows(pid: pid)
        guard
            let match = candidates.first(where: {
                abs($0.x - Double(frame.origin.x)) < 1 && abs($0.y - Double(frame.origin.y)) < 1
                    && abs($0.width - Double(frame.width)) < 1
                    && abs($0.height - Double(frame.height)) < 1
            })
        else {
            throw Failure.noMatchingWindow(
                "AX frame \(frame) against \(candidates.count) on-screen window(s)")
        }
        let shot = try capture(window: match, to: scratch)
        return ColorSampler.annotate(
            read.tree, raster: shot.raster, scale: shot.scale,
            offsetX: Double(read.anchorOrigin.x) - match.x,
            offsetY: Double(read.anchorOrigin.y) - match.y)
    }
}
