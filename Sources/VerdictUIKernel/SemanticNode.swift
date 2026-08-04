// VerdictUIKernel — platform-pure. No SwiftUI/AppKit imports allowed in this target.
import Foundation

/// One node in the semantic tree that probed views emit during the layout pass.
/// This is the ground-truth record VerdictUI verifies against — produced by the
/// layout engine itself (Layout-protocol probe / preference-key stream), never
/// reconstructed from accessibility scraping or pixels.
public struct SemanticNode: Equatable, Codable, Sendable {
    /// Stable identifier supplied by the probe (`.verdictProbe("save-button")`).
    public var id: String
    /// Semantic role (button, text, list, container, …). Free-form at Wave 1;
    /// constrained to a role enum in Wave 2 when the probe vocabulary lands.
    public var role: String
    /// Resolved frame in root coordinates, as placed by the layout pass.
    public var frame: Rect
    /// Visible text content, if any (drives truncation lint).
    public var text: String?
    /// Child nodes in layout order.
    public var children: [SemanticNode]

    public init(
        id: String,
        role: String,
        frame: Rect,
        text: String? = nil,
        children: [SemanticNode] = []
    ) {
        self.id = id
        self.role = role
        self.frame = frame
        self.text = text
        self.children = children
    }
}

/// Platform-pure rectangle (CoreGraphics-free so the kernel runs anywhere,
/// including Linux CI for the pure-logic test suite).
public struct Rect: Equatable, Codable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var isEmpty: Bool { width <= 0 || height <= 0 }

    public func intersects(_ other: Rect) -> Bool {
        !(other.x >= x + width || other.x + other.width <= x
            || other.y >= y + height || other.y + other.height <= y)
    }
}
