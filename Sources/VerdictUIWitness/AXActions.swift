import ApplicationServices
import Foundation

/// Acting on a running app beyond a press (CIS-07CB1181).
///
/// `inspect` could press and nothing else, so a surface reachable only by
/// typing, scrolling, focusing, stepping or opening a menu could not be driven.
/// Every verb here resolves its target through the SAME structural-path walk
/// and the SAME anchor the reader uses (``AXReader/anchor(pid:surface:)``), so a
/// path read from the tree is the path acted on.
///
/// Drag and hover are deliberately absent. Both need synthesized pointer
/// events, which move the owner's real cursor across their screen — the
/// distraction Wave 11 exists to remove. They are tracked rather than faked.
extension AXReader {

    /// One action on one element.
    public enum Action: Equatable, Sendable, CustomStringConvertible {
        /// Any accessibility action by its raw name, e.g. `AXIncrement`.
        case perform(String)
        /// Write the element's `AXValue` — the reliable way to "type" into a
        /// text field, because it needs neither focus nor a key window.
        case setValue(String)
        /// Make the element the app's focused element.
        case focus
        /// Scroll a scroll area (or its vertical scroll bar) to a fraction in 0...1.
        case scrollTo(Double)
        /// Post keystrokes to the process, after focusing the element.
        case type(String)

        /// The CLI vocabulary. Returns `nil` for an unknown verb, a missing
        /// value, or a scroll fraction outside 0...1 — refused rather than
        /// clamped, because a clamped scroll reads as having done what was asked.
        public init?(verb: String, value: String?) {
            let aliases: [String: String] = [
                "press": kAXPressAction, "increment": kAXIncrementAction,
                "decrement": kAXDecrementAction, "show-menu": kAXShowMenuAction,
                "confirm": kAXConfirmAction, "cancel": kAXCancelAction,
                "raise": kAXRaiseAction, "pick": kAXPickAction,
                "scroll-to-visible": "AXScrollToVisible",
            ]
            switch verb {
            case let name where aliases[name] != nil:
                self = .perform(aliases[name] ?? name)
            case let raw where raw.hasPrefix("ax:") && raw.count > 3:
                self = .perform(String(raw.dropFirst(3)))
            case "set-value":
                guard let value else { return nil }
                self = .setValue(value)
            case "focus":
                self = .focus
            case "scroll-to":
                guard let value, let fraction = Double(value), (0...1).contains(fraction)
                else { return nil }
                self = .scrollTo(fraction)
            case "type":
                guard let value, !value.isEmpty else { return nil }
                self = .type(value)
            default:
                return nil
            }
        }

        /// Every verb the CLI accepts, for help text and error messages.
        public static let verbs = [
            "press", "increment", "decrement", "show-menu", "confirm", "cancel", "raise",
            "pick", "scroll-to-visible", "focus", "set-value", "scroll-to", "type", "ax:<AXName>",
        ]

        public var description: String {
            switch self {
            case .perform(let name): name
            case .setValue: "set-value"
            case .focus: "focus"
            case .scrollTo(let fraction): "scroll-to \(fraction)"
            case .type: "type"
            }
        }
    }

    /// Perform `action` on the element at `path` in `surface`.
    ///
    /// - Throws: ``Failure/elementNotFound`` for a path that does not resolve,
    ///   ``Failure/actionUnsupported(action:available:)`` when the element does
    ///   not advertise the action (naming what it does advertise),
    ///   ``Failure/attributeNotSettable(_:)`` for a refused write, and
    ///   ``Failure/actionRefused(axError:)`` when AppKit declines.
    public static func act(
        pid: pid_t, atPath path: String, surface: Surface = .window(0), action: Action
    ) throws {
        guard isTrusted else { throw Failure.notTrusted }
        let content = try anchor(pid: pid, surface: surface).element
        guard let target = element(at: path, from: content) else {
            throw Failure.elementNotFound
        }
        switch action {
        case .perform(let name):
            let available = actionNames(of: target)
            guard available.contains(name) else {
                throw Failure.actionUnsupported(action: name, available: available)
            }
            try check(AXUIElementPerformAction(target, name as CFString))
        case .setValue(let text):
            try write(target, kAXValueAttribute, text as CFString)
        case .focus:
            try write(target, kAXFocusedAttribute, kCFBooleanTrue)
        case .scrollTo(let fraction):
            let bar =
                string(target, kAXRoleAttribute) == (kAXScrollBarRole as String)
                ? target : element(copy(target, kAXVerticalScrollBarAttribute))
            guard let bar else {
                throw Failure.actionUnsupported(
                    action: "scroll-to", available: actionNames(of: target))
            }
            try write(bar, kAXValueAttribute, NSNumber(value: fraction))
        case .type(let text):
            // Focus first when the element allows it; a field that refuses
            // focus may still be the first responder already.
            try? write(target, kAXFocusedAttribute, kCFBooleanTrue)
            try postKeystrokes(text, to: pid)
        }
    }

    static func actionNames(of element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success,
            let list = names as? [String]
        else { return [] }
        return list
    }

    private static func write(_ element: AXUIElement, _ attribute: String, _ value: CFTypeRef)
        throws
    {
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success,
            settable.boolValue
        else { throw Failure.attributeNotSettable(attribute) }
        try check(AXUIElementSetAttributeValue(element, attribute as CFString, value))
    }

    private static func check(_ result: AXError) throws {
        guard result == .success else { throw Failure.actionRefused(axError: result.rawValue) }
    }

    /// Unicode keystrokes posted to ONE process — never to the session, so no
    /// other app (and no terminal the owner is typing in) receives them.
    private static func postKeystrokes(_ text: String, to pid: pid_t) throws {
        for scalar in text.utf16 {
            var unit = scalar
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)
                else { throw Failure.actionRefused(axError: AXError.failure.rawValue) }
                event.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unit)
                event.postToPid(pid)
            }
        }
    }
}
