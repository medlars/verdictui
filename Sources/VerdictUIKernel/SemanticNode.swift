// VerdictUIKernel — platform-pure. No SwiftUI/AppKit imports allowed in this target.
import Foundation

/// Semantic role of a probed element.
///
/// The case list mirrors SwiftUI's accessibility role vocabulary so the Wave 8
/// cross-validation channel can map an in-process role onto the `AXUIElement`
/// role of the same element 1:1. Anything the probe cannot classify becomes
/// ``Role/custom(_:)`` rather than a silent `container`, so unclassified
/// elements stay visible in the tree instead of disappearing into a default.
public enum Role: Hashable, Sendable {
    /// Layout container (`VStack`, `HStack`, `ZStack`, `Group`, …).
    case container
    /// Static text (`Text`, `Label` title).
    case text
    /// Push button (`Button`, `Link`).
    case button
    /// Binary control (`Toggle`).
    case toggle
    /// Continuous control (`Slider`, `Stepper`).
    case slider
    /// Editable text input (`TextField`, `SecureField`, `TextEditor`).
    case textField
    /// Image content (`Image`, `AsyncImage`).
    case image
    /// Collection container (`List`, `Table`, `ForEach` host).
    case list
    /// One row inside a ``Role/list``.
    case listRow
    /// Navigation chrome (`NavigationStack` bar, toolbar).
    case navigation
    /// Tab chrome (`TabView` bar).
    case tabBar
    /// Menu surface (`Menu`, context menu, `Picker` popup).
    case menu
    /// Layout `Spacer` — occupies space, renders nothing.
    case spacer
    /// Anything the probe could not classify; carries the raw role string.
    case custom(String)

    /// Wire identifier for this role — the string that crosses the JSON boundary.
    public var identifier: String {
        switch self {
        case .container: "container"
        case .text: "text"
        case .button: "button"
        case .toggle: "toggle"
        case .slider: "slider"
        case .textField: "textField"
        case .image: "image"
        case .list: "list"
        case .listRow: "listRow"
        case .navigation: "navigation"
        case .tabBar: "tabBar"
        case .menu: "menu"
        case .spacer: "spacer"
        case .custom(let name): name
        }
    }

    /// Reconstruct a role from its wire identifier; unknown strings become
    /// ``Role/custom(_:)`` so a newer probe never fails to decode on an older kernel.
    ///
    /// Round-trip caveat: `Role.custom("button")` decodes back as `Role.button`.
    /// Probes must not mint custom roles that collide with the known vocabulary.
    public init(identifier: String) {
        switch identifier {
        case "container": self = .container
        case "text": self = .text
        case "button": self = .button
        case "toggle": self = .toggle
        case "slider": self = .slider
        case "textField": self = .textField
        case "image": self = .image
        case "list": self = .list
        case "listRow": self = .listRow
        case "navigation": self = .navigation
        case "tabBar": self = .tabBar
        case "menu": self = .menu
        case "spacer": self = .spacer
        default: self = .custom(identifier)
        }
    }

    /// True for roles a user can hit with a pointer or finger — the set
    /// ``TapTargetRule`` polices. `listRow` is excluded on purpose: rows are
    /// row-height-sized by the platform, so measuring them against a tap
    /// minimum produces noise, not defects.
    public var isInteractive: Bool {
        switch self {
        case .button, .toggle, .slider, .textField, .menu: true
        case .container, .text, .image, .list, .listRow, .navigation, .tabBar, .spacer, .custom:
            false
        }
    }

    /// True for roles that render glyphs, i.e. roles ``TruncationRule`` inspects.
    public var isTextBearing: Bool {
        switch self {
        case .text, .button, .textField: true
        case .container, .toggle, .slider, .image, .list, .listRow, .navigation, .tabBar, .menu,
            .spacer, .custom:
            false
        }
    }
}

extension Role: Codable {
    public init(from decoder: any Decoder) throws {
        let identifier = try decoder.singleValueContainer().decode(String.self)
        self.init(identifier: identifier)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(identifier)
    }
}

/// A role-specific attribute value: exactly three primitive cases, encoded as a
/// bare JSON scalar.
///
/// Deliberately not recursive (no arrays, no nested objects) — see the Wave 1
/// over-modeling risk in `docs/implementation-plan.md`. A rule that needs
/// structure flattens it into dotted keys (`"text.alignment"`) instead.
public enum AttributeValue: Hashable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)

    /// The wrapped string, or `nil` if this value is a number or bool.
    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    /// The wrapped number, or `nil` if this value is a string or bool.
    public var numberValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    /// The wrapped bool, or `nil` if this value is a string or number.
    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }
}

extension AttributeValue: CustomStringConvertible {
    /// Human-readable rendering used inside finding messages.
    public var description: String {
        switch self {
        case .string(let value): value
        case .number(let value): Self.format(value)
        case .bool(let value): value ? "true" : "false"
        }
    }

    /// Trim the trailing `.0` from whole numbers so messages read `44` not `44.0`.
    static func format(_ value: Double) -> String {
        value == value.rounded() && value.magnitude < 1e15
            ? String(Int64(value))
            : String(format: "%g", value)
    }
}

extension AttributeValue: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        // Bool first: JSON `true` also satisfies some numeric decoders.
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        }
    }
}

/// Text-layout measurements the probe collects during the layout pass.
///
/// The kernel defines the contract now; Wave 2's `ProbeLayout` supplies the
/// numbers by measuring the same text under an unconstrained proposal
/// (`intrinsicWidth`, `idealLineCount`) and under the real proposal
/// (`renderedLineCount`).
public struct TextMetrics: Equatable, Codable, Sendable {
    /// Width the text needs when proposed unlimited space, in points.
    public var intrinsicWidth: Double
    /// Line count actually rendered inside the resolved frame.
    public var renderedLineCount: Int
    /// Line count the text wants when not line-limited.
    public var idealLineCount: Int

    public init(intrinsicWidth: Double, renderedLineCount: Int, idealLineCount: Int) {
        self.intrinsicWidth = intrinsicWidth
        self.renderedLineCount = renderedLineCount
        self.idealLineCount = idealLineCount
    }

    /// True when fewer lines rendered than the text wanted — vertical truncation.
    public var isLineTruncated: Bool { renderedLineCount < idealLineCount }
}

/// One node in the semantic tree that probed views emit during the layout pass.
///
/// This is the ground-truth record VerdictUI verifies against — produced by the
/// layout engine itself (Layout-protocol probe / preference-key stream), never
/// reconstructed from accessibility scraping or pixels.
public struct SemanticNode: Equatable, Sendable {
    /// Stable identifier supplied by the probe (`.verdictProbe("save-button")`).
    /// Empty for unprobed nodes, which fall back to ``structuralPath`` for identity.
    public var id: String
    /// Semantic role, used for role-aware linting and AX reconciliation.
    public var role: Role
    /// Resolved frame in root coordinates, as placed by the layout pass.
    public var frame: Rect
    /// Visible text content, if any (drives truncation lint).
    public var text: String?
    /// Role-specific data: toggle state, slider value, suppression directives.
    /// Reserved keys use the `verdict.` prefix (see ``LintContext/suppressionKey``).
    public var attributes: [String: AttributeValue]
    /// Whether the element actually renders: opacity > 0 and not clipped away.
    /// Rules skip invisible nodes so hidden scaffolding never produces findings.
    public var isVisible: Bool
    /// Explicit `zIndex`, when the view declared one. A non-`nil` value marks
    /// deliberate layering, which ``SiblingOverlapRule`` treats as intent.
    public var zIndex: Double?
    /// Text-layout measurements, when this node renders text.
    public var textMetrics: TextMetrics?
    /// Parent-chain path used as identity for unprobed nodes,
    /// e.g. `root/container[0]/text[2]`. See ``withAssignedStructuralPaths(rootPath:)``.
    public var structuralPath: String
    /// Child nodes in layout order.
    public var children: [SemanticNode]

    public init(
        id: String,
        role: Role,
        frame: Rect,
        text: String? = nil,
        attributes: [String: AttributeValue] = [:],
        isVisible: Bool = true,
        zIndex: Double? = nil,
        textMetrics: TextMetrics? = nil,
        structuralPath: String = "",
        children: [SemanticNode] = []
    ) {
        self.id = id
        self.role = role
        self.frame = frame
        self.text = text
        self.attributes = attributes
        self.isVisible = isVisible
        self.zIndex = zIndex
        self.textMetrics = textMetrics
        self.structuralPath = structuralPath
        self.children = children
    }

    /// Identity used for diff matching: the probe `id` when present, the
    /// ``structuralPath`` otherwise (prefixed so the two namespaces cannot collide).
    /// Empty for a node with neither, which callers resolve positionally.
    public var identity: String {
        if !id.isEmpty { return id }
        if !structuralPath.isEmpty { return "@" + structuralPath }
        return ""
    }

    /// Every node in the subtree, self first, children in layout order (preorder).
    public func flattened() -> [SemanticNode] {
        var result: [SemanticNode] = []
        appendFlattened(into: &result)
        return result
    }

    private func appendFlattened(into result: inout [SemanticNode]) {
        result.append(self)
        for child in children {
            child.appendFlattened(into: &result)
        }
    }

    /// First node in the subtree whose ``id`` matches, in preorder.
    /// Returns `nil` for an empty query so a missing probe id never matches
    /// the unprobed nodes that share the empty id.
    public func node(withID id: String) -> SemanticNode? {
        guard !id.isEmpty else { return nil }
        if self.id == id { return self }
        for child in children {
            if let match = child.node(withID: id) { return match }
        }
        return nil
    }

    /// Copy of this subtree with ``structuralPath`` filled in for every node:
    /// `rootPath` for self and `<parent>/<role>[<index>]` for each descendant.
    ///
    /// Wave 2's probe assigns paths while building the tree; this exists so the
    /// kernel can canonicalize a hand-built or partially probed tree before diffing.
    public func withAssignedStructuralPaths(rootPath: String = "root") -> SemanticNode {
        var copy = self
        copy.structuralPath = rootPath
        copy.children = children.enumerated().map { index, child in
            child.withAssignedStructuralPaths(rootPath: "\(rootPath)/\(child.role.identifier)[\(index)]")
        }
        return copy
    }
}

extension SemanticNode: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, role, frame, text, attributes, isVisible, zIndex, textMetrics, structuralPath,
            children
    }

    /// Decodes leniently: only `id`, `role`, and `frame` are required, so a
    /// hand-written or older fixture still loads with documented defaults
    /// (`isVisible` true, no attributes, no children, empty structural path).
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        role = try container.decode(Role.self, forKey: .role)
        frame = try container.decode(Rect.self, forKey: .frame)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        attributes =
            try container.decodeIfPresent([String: AttributeValue].self, forKey: .attributes) ?? [:]
        isVisible = try container.decodeIfPresent(Bool.self, forKey: .isVisible) ?? true
        zIndex = try container.decodeIfPresent(Double.self, forKey: .zIndex)
        textMetrics = try container.decodeIfPresent(TextMetrics.self, forKey: .textMetrics)
        structuralPath = try container.decodeIfPresent(String.self, forKey: .structuralPath) ?? ""
        children = try container.decodeIfPresent([SemanticNode].self, forKey: .children) ?? []
    }

    /// Omits empty collections, `nil` values, and an empty structural path so the
    /// wire format stays token-frugal for the Wave 7 MCP surface.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(role, forKey: .role)
        try container.encode(frame, forKey: .frame)
        try container.encodeIfPresent(text, forKey: .text)
        if !attributes.isEmpty {
            try container.encode(attributes, forKey: .attributes)
        }
        try container.encode(isVisible, forKey: .isVisible)
        try container.encodeIfPresent(zIndex, forKey: .zIndex)
        try container.encodeIfPresent(textMetrics, forKey: .textMetrics)
        if !structuralPath.isEmpty {
            try container.encode(structuralPath, forKey: .structuralPath)
        }
        if !children.isEmpty {
            try container.encode(children, forKey: .children)
        }
    }
}

/// Platform-pure size (CoreGraphics-free, see `no.md` #5).
public struct Size: Equatable, Codable, Sendable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
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

    /// True when the rectangle encloses no area, i.e. nothing can render in it.
    public var isEmpty: Bool { width <= 0 || height <= 0 }

    /// Right edge (`x + width`).
    public var maxX: Double { x + width }

    /// Bottom edge (`y + height`) — VerdictUI uses SwiftUI's y-down convention.
    public var maxY: Double { y + height }

    /// Width and height as a ``Size``.
    public var size: Size { Size(width: width, height: height) }

    /// True when the two rectangles share any area. Empty rectangles never intersect.
    public func intersects(_ other: Rect) -> Bool {
        !(other.x >= maxX || other.maxX <= x || other.y >= maxY || other.maxY <= y)
    }

    /// The shared area, or `nil` when the rectangles do not intersect.
    /// Used to quantify overlap in finding messages.
    public func intersection(_ other: Rect) -> Rect? {
        guard intersects(other) else { return nil }
        let originX = max(x, other.x)
        let originY = max(y, other.y)
        return Rect(
            x: originX,
            y: originY,
            width: min(maxX, other.maxX) - originX,
            height: min(maxY, other.maxY) - originY
        )
    }

    /// True when `other` lies entirely inside this rectangle (edges inclusive).
    public func contains(_ other: Rect) -> Bool {
        other.x >= x && other.y >= y && other.maxX <= maxX && other.maxY <= maxY
    }
}
