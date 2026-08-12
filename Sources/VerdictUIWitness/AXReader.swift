import ApplicationServices
import Foundation
import VerdictUIKernel

/// Reads an `AXUIElement` tree from a windowed host process and normalizes it
/// into the kernel's ``SemanticNode`` vocabulary.
///
/// ### Why this reads ANOTHER process
///
/// A process cannot read its own accessibility tree. Measured 2026-08-12:
/// `AXUIElementCopyAttributeValue(kAXWindowsAttribute)` against the caller's own
/// pid returns **-25208 (`kAXErrorAttributeUnsupported`)** at the same instant
/// `NSApp.windows` reports one visible window. The accessibility server mediates
/// between processes; a self-query is not a supported path, and no permission
/// grant changes it. So the witness renders its scenario in a **separate
/// windowed host process** and reads that — see ``WitnessHostProcess``.
///
/// This is also why `OracleHost` is not reused: it is windowless on purpose (the
/// CI story — it runs under a sandbox that denies every `com.apple.windowserver*`
/// mach-lookup), and AX needs the opposite. Two hosts, two constraints.
public enum AXReader {

    /// Why a cross-validation read could not be performed.
    public enum Failure: Error, Equatable, CustomStringConvertible {
        /// The calling process is not trusted for Accessibility.
        case notTrusted
        /// The host process published no accessibility-visible window.
        ///
        /// Distinguished from ``notTrusted`` because the two have different
        /// fixes and, critically, because `AXIsProcessTrusted()` returns `true`
        /// in this case: a witness gating only on the trust flag proceeds and
        /// reads an empty tree, which at the point of use is indistinguishable
        /// from a scenario that genuinely renders nothing.
        case noWindow(axError: Int32)
        /// The host process exited or never started.
        case hostUnavailable(String)

        public var description: String {
            switch self {
            case .notTrusted:
                "no Accessibility permission (grant it to the process running verdictui)"
            case .noWindow(let code):
                "the host published no accessibility-visible window (AXError \(code))"
            case .hostUnavailable(let detail):
                "the witness host process is unavailable: \(detail)"
            }
        }
    }

    /// True when this process may read accessibility trees.
    ///
    /// Necessary but **not sufficient** — see ``Failure/noWindow(axError:)``.
    /// Callers must treat a failed read as authoritative over this flag.
    public static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Read the first window of `pid` and normalize it into a semantic tree.
    ///
    /// - Parameter pid: the windowed host process to inspect.
    /// - Returns: the normalized tree, rooted at the hosting view's content group.
    /// - Throws: ``Failure`` when the tree cannot be read.
    public static func readTree(pid: pid_t) throws -> SemanticNode {
        guard isTrusted else { throw Failure.notTrusted }

        let app = AXUIElementCreateApplication(pid)
        var raw: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &raw)
        guard status == .success, let windows = raw as? [AXUIElement], let window = windows.first
        else {
            throw Failure.noWindow(axError: status.rawValue)
        }

        // Anchor on the hosting group rather than the window: the window frame
        // includes a titlebar (measured at 32 pt), so using it as the origin
        // shifts every node by that amount — a uniform offset that looks like a
        // real disagreement on every single node at once.
        let content = hostingContent(of: window) ?? window
        let origin = frame(of: content)?.origin ?? .zero

        var root = normalize(content, origin: origin)
        // Structural paths are the key the reconciler matches on, and the
        // external channel has no probe ids to fall back to, so assigning them
        // is not optional here.
        root = root.withAssignedStructuralPaths()
        return root
    }

    // MARK: - Normalization

    /// The `NSHostingView`'s group, i.e. the element whose bounds are the
    /// SwiftUI root's bounds.
    static func hostingContent(of window: AXUIElement) -> AXUIElement? {
        guard let children = copy(window, kAXChildrenAttribute) as? [AXUIElement] else {
            return nil
        }
        // The hosting view publishes as AXGroup with subrole AXHostingView.
        // Fall back to the largest group so a future AppKit change degrades to a
        // plausible anchor rather than to the window (whose titlebar offset
        // would corrupt every frame).
        for child in children
        where string(child, kAXSubroleAttribute) == "AXHostingView" {
            return child
        }
        return children.first { string($0, kAXRoleAttribute) == kAXGroupRole as String }
    }

    /// Recursively convert an AX element into a ``SemanticNode``.
    ///
    /// `origin` is the hosting group's screen origin; subtracting it converts
    /// AX's screen coordinates into the SwiftUI root coordinates the probe
    /// channel reports. Both are y-down, so no axis flip is involved — the
    /// conversion needs no display metrics and survives a monitor change.
    static func normalize(_ element: AXUIElement, origin: CGPoint) -> SemanticNode {
        let axRole = string(element, kAXRoleAttribute) ?? ""
        let subrole = string(element, kAXSubroleAttribute)
        let box = frame(of: element)

        let rect =
            box.map {
                Rect(
                    x: Double($0.origin.x - origin.x),
                    y: Double($0.origin.y - origin.y),
                    width: Double($0.size.width),
                    height: Double($0.size.height)
                )
            } ?? Rect(x: 0, y: 0, width: 0, height: 0)

        let role = role(axRole: axRole, subrole: subrole)
        var attributes: [String: AttributeValue] = [:]
        // A checkbox's AXValue is its 0/1 state, not its label — keep it as
        // state so a toggle comparison has something to compare.
        if role == .toggle, let number = copy(element, kAXValueAttribute) as? NSNumber {
            attributes["toggleOn"] = .bool(number.intValue != 0)
        }

        let children =
            (copy(element, kAXChildrenAttribute) as? [AXUIElement] ?? [])
            .map { normalize($0, origin: origin) }

        return SemanticNode(
            id: "",  // AX carries no probe ids; identity is the structural path.
            role: role,
            frame: rect,
            text: text(of: element, role: role),
            attributes: attributes,
            isVisible: true,
            children: children
        )
    }

    /// Map an AX role onto the kernel's shared vocabulary.
    ///
    /// The mapping was measured against a live window rather than taken from
    /// documentation; the correspondence is 1:1 because ``Role`` was authored in
    /// Wave 1 to mirror this vocabulary. An unmapped role becomes
    /// ``Role/custom(_:)`` carrying the raw AX string, so an element VerdictUI
    /// has no opinion about stays visible in the tree instead of defaulting to
    /// `container` and silently claiming to be a layout box.
    static func role(axRole: String, subrole: String?) -> Role {
        switch axRole {
        case kAXStaticTextRole: return .text
        case kAXButtonRole: return .button
        case kAXCheckBoxRole: return .toggle
        case kAXRadioButtonRole: return .toggle
        case kAXSliderRole: return .slider
        case kAXTextFieldRole: return .textField
        case kAXTextAreaRole: return .textField
        case kAXImageRole: return .image
        case kAXTableRole, kAXOutlineRole, kAXListRole: return .list
        case kAXRowRole: return .listRow
        case kAXToolbarRole: return .navigation
        case kAXTabGroupRole: return .tabBar
        case kAXMenuRole, kAXMenuButtonRole, kAXPopUpButtonRole:
            return .menu
        case kAXGroupRole, kAXScrollAreaRole, kAXSplitGroupRole:
            return .container
        default:
            return .custom(axRole.isEmpty ? "unknown" : axRole)
        }
    }

    /// The element's visible text.
    ///
    /// Reads **both** `AXValue` and `AXDescription`, because the platform puts
    /// text in different attributes depending on role — measured: `AXStaticText`
    /// and `AXTextField` carry it in `AXValue`, while `AXButton`, `AXCheckBox`
    /// and `AXImage` carry it in `AXDescription`. A reader that consults one
    /// attribute loses half the vocabulary and still returns a populated-looking
    /// tree, so the loss is invisible at the point of use.
    static func text(of element: AXUIElement, role: Role) -> String? {
        // A toggle's AXValue is its state; its label is the description.
        if role != .toggle, let value = copy(element, kAXValueAttribute) as? String,
            !value.isEmpty
        {
            return value
        }
        for attribute in [kAXDescriptionAttribute, kAXTitleAttribute] {
            if let text = string(element, attribute), !text.isEmpty { return text }
        }
        return nil
    }

    // MARK: - AX primitives

    static func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return value
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        copy(element, attribute) as? String
    }

    /// Screen frame of an element, or `nil` when it publishes no geometry.
    static func frame(of element: AXUIElement) -> CGRect? {
        guard let positionValue = copy(element, kAXPositionAttribute),
            let sizeValue = copy(element, kAXSizeAttribute)
        else { return nil }
        // `as? AXValue` is rejected as always-true: AXValue is a CF type that
        // bridges as AnyObject, so the compiler cannot express the check that
        // way. CFGetTypeID is the real discriminator, and it must be consulted
        // BEFORE the cast — an element publishing a non-AXValue here would
        // otherwise be forced into one.
        guard CFGetTypeID(positionValue) == AXValueGetTypeID(),
            CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { return nil }
        // swift-format-ignore: NeverForceUnwrap
        let position = positionValue as! AXValue  // checked by CFGetTypeID above
        // swift-format-ignore: NeverForceUnwrap
        let extent = sizeValue as! AXValue  // checked by CFGetTypeID above
        var point = CGPoint.zero
        var size = CGSize.zero
        // A getter that fails leaves the out-params untouched, so a false here
        // must return nil rather than report a (0,0) frame — an element at the
        // origin is a plausible-looking lie.
        guard AXValueGetValue(position, .cgPoint, &point),
            AXValueGetValue(extent, .cgSize, &size)
        else { return nil }
        return CGRect(origin: point, size: size)
    }
}
