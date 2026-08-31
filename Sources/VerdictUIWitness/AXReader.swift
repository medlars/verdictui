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
        /// The window was found but its hosting group published no geometry, so
        /// there is no origin to convert coordinates against.
        ///
        /// Distinct from ``noWindow(axError:)`` because the window WAS read — a
        /// zero AXError would misreport this as success, and `.zero` as a
        /// fallback origin would leave every node in screen coordinates.
        case anchorUnreadable
        /// No element in the tree matches the requested name OR path.
        ///
        /// A press MUST distinguish this from success. A verb that reports
        /// "pressed" for a name it never matched makes "I pressed the control"
        /// and "I pressed nothing" the same answer, which leaves every caller's
        /// verdict unfalsifiable.
        case elementNotFound
        /// The element was found, but AppKit refused the press.
        ///
        /// Separate from ``elementNotFound`` because the two have opposite
        /// meanings for the caller: the name is right and the control declined,
        /// versus the name is wrong.
        case actionRefused(axError: Int32)

        public var description: String {
            switch self {
            case .notTrusted:
                "no Accessibility permission (grant it to the process running verdictui)"
            case .noWindow(let code):
                // Code 0 is `.success`: the attribute ANSWERED and its answer held
                // no window. Printing "AXError 0" for that reads as an error code
                // and sends the reader looking one up, when the fact is that the
                // call worked and the process publishes nothing window-shaped.
                code == 0
                    ? "the host publishes no accessibility-visible window — the windows "
                        + "attribute succeeded but held the application element rather "
                        + "than a window"
                    : "the host published no accessibility-visible window (AXError \(code))"
            case .hostUnavailable(let detail):
                "the witness host process is unavailable: \(detail)"
            case .anchorUnreadable:
                "the host window published no geometry for its hosting group, so node "
                    + "coordinates cannot be converted to root space"
            case .elementNotFound:
                // Says NAME OR PATH because both lookups raise this, and a
                // message naming only one sends a caller who passed the other
                // to check the wrong thing.
                "no element in the tree matches that name or path"
            case .actionRefused(let code):
                "the element was found but refused the press (AXError \(code))"
            }
        }
    }

    /// True when this process may read accessibility trees.
    ///
    /// Necessary but **not sufficient** — see ``Failure/noWindow(axError:)``.
    /// Callers must treat a failed read as authoritative over this flag.
    public static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Press the element at `path` — the identity ``readTree(pid:)`` assigns.
    ///
    /// THE ROUND TRIP: read the tree, act on what you saw. That workflow used to
    /// fail (CIS-3DDA018A) because `press(pid:named:)` searched a different
    /// vocabulary AND a different subtree from the reader — it tried Title →
    /// Description → Value from the WINDOW, while `readTree` names elements
    /// Value → Description → Title from the HOSTING CONTENT GROUP. So a name
    /// plainly visible in the output could be genuinely absent from the search,
    /// and the obvious conclusion (the press is broken) was wrong.
    ///
    /// A path is the better handle regardless: it is positional and unambiguous,
    /// where a name is a coincidence that two controls can share. This walk
    /// mirrors ``SemanticNode/withAssignedStructuralPaths(rootPath:)`` exactly —
    /// same anchor, same child order, same `role[index]` segments — because a
    /// resolver that indexes differently from the assigner is a second
    /// implementation of one rule, and the two drift silently.
    public static func press(pid: pid_t, atPath path: String) throws {
        guard isTrusted else { throw Failure.notTrusted }
        let (_, content) = try anchoredWindow(pid: pid)

        guard let target = element(at: path, from: content) else {
            throw Failure.elementNotFound
        }
        let result = AXUIElementPerformAction(target, kAXPressAction as CFString)
        guard result == .success else {
            throw Failure.actionRefused(axError: result.rawValue)
        }
    }

    /// Walk `path` from the SAME anchor and in the SAME child order the reader
    /// uses, so a path it emitted resolves here by construction.
    private static func element(at path: String, from content: AXUIElement) -> AXUIElement? {
        var segments = path.split(separator: "/").map(String.init)
        // The first segment names the root itself ("root"); anything else is not
        // a path this reader could have emitted.
        guard let root = segments.first, root == "root" else { return nil }
        segments.removeFirst()

        var current = content
        for segment in segments {
            // `role[index]` — the index is authoritative; the role is checked so
            // a path that resolves to a DIFFERENT element than it names fails
            // loudly rather than pressing the wrong control.
            guard let open = segment.lastIndex(of: "["), segment.hasSuffix("]") else { return nil }
            let roleName = String(segment[segment.startIndex..<open])
            let digits = segment[segment.index(after: open)..<segment.index(before: segment.endIndex)]
            guard let index = Int(digits) else { return nil }

            let children = (copy(current, kAXChildrenAttribute) as? [AXUIElement]) ?? []
            guard index < children.count else { return nil }
            let child = children[index]

            let childRole = role(
                axRole: string(child, kAXRoleAttribute) ?? "",
                subrole: string(child, kAXSubroleAttribute))
            guard childRole.identifier == roleName else { return nil }
            current = child
        }
        return current
    }

    /// The window and its hosting content group, resolved the way `readTree`
    /// resolves them. Extracted so the reader and the presser cannot drift onto
    /// different anchors — which is half of what CIS-3DDA018A was.
    private static func anchoredWindow(pid: pid_t) throws -> (AXUIElement, AXUIElement) {
        let window = try firstWindow(of: pid)
        return (window, hostingContent(of: window) ?? window)
    }

    /// True when an element returned in a windows list can be a window.
    ///
    /// NOT `role == kAXWindowRole`. Measured 2026-08-31: Finder's first window
    /// publishes as `AXScrollArea` (the desktop) with a real frame, so a strict
    /// equality would make real windows unreadable — which is the failure a
    /// negative control exists to catch. The only role that is never a window is
    /// the APPLICATION element itself, and a nil role has not been shown to be
    /// anything at all.
    static func isWindowElement(role: String?) -> Bool {
        guard let role else { return false }
        return role != (kAXApplicationRole as String)
    }

    /// The first genuine window of `pid`.
    ///
    /// THE ONE PLACE the windows attribute is read, because the guard below was
    /// duplicated verbatim at three call sites and a defect with N call sites
    /// cannot be closed at one of them (lesson 400).
    ///
    /// `kAXWindowsAttribute` can answer `.success` with a list whose only member
    /// is the APPLICATION element rather than a window. Taking `windows.first`
    /// on the strength of the status alone then carries that element onward, its
    /// geometry read fails — `AXPosition`, `AXSize` and `AXFrame` are all
    /// `kAXErrorAttributeUnsupported` on an application element — and the caller
    /// is told the HOSTING GROUP published no geometry. That names the wrong
    /// subject: the fact is that this process publishes no readable window, and
    /// four sessions inherited the geometry framing from that message.
    ///
    /// Reported as ``Failure/noWindow(axError:)`` deliberately, because the
    /// classification also decides RETRY: `WitnessHostProcess.waitForReady`
    /// treats `.noWindow` as "still registering" and keeps waiting, while any
    /// other failure ends the wait. A host mid-AX-registration was being
    /// abandoned on its first read.
    private static func firstWindow(of pid: pid_t) throws -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        var raw: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &raw)
        guard status == .success, let windows = raw as? [AXUIElement], let window = windows.first
        else {
            throw Failure.noWindow(axError: status.rawValue)
        }
        guard isWindowElement(role: string(window, kAXSubroleAttribute) == nil
            ? string(window, kAXRoleAttribute) : string(window, kAXRoleAttribute))
        else {
            throw Failure.noWindow(axError: status.rawValue)
        }
        return window
    }

    /// Press the first element named `name` in `pid`'s window.
    ///
    /// The ACT half of third-party observation. ``readTree(pid:)`` already
    /// observes an app VerdictUI did not write; this drives one. The daemon's
    /// `act` verb cannot: it operates on a SCENARIO, an in-process instrumented
    /// view, so it has no reach into an external application.
    ///
    /// **Why by NAME rather than by coordinate.** Measured on LaunchGate
    /// 2026-08-17: synthesised clicks at centres read off a rendered image did
    /// not change the window content at all, and System Events could not
    /// enumerate that window (`entire contents` returned empty), so coordinates
    /// were the only handle and they did not work. `AXPress` resolves the
    /// element itself and bypasses the question.
    ///
    /// **Why the name search reads several attributes.** SwiftUI leaves
    /// `AXTitle` empty and puts the label in `AXDescription`. System Events'
    /// `name`, `title`, `value` and `help` all return `missing value` for these
    /// controls — four attributes agreeing on "absent" from one blind
    /// instrument, which is one reading, not four.
    ///
    /// - Throws: ``Failure/elementNotFound`` when no element carries the name,
    ///   and ``Failure/actionRefused(axError:)`` when one does and AppKit
    ///   declines. Those are opposite facts for the caller, so they are opposite
    ///   errors — a single "press failed" would collapse them.
    public static func press(pid: pid_t, named name: String) throws {
        guard isTrusted else { throw Failure.notTrusted }

        let window = try firstWindow(of: pid)

        guard let target = firstElement(in: window, named: name) else {
            throw Failure.elementNotFound
        }
        let result = AXUIElementPerformAction(target, kAXPressAction as CFString)
        guard result == .success else {
            throw Failure.actionRefused(axError: result.rawValue)
        }
    }

    /// Depth-first search for an element whose name matches, bounded by the same
    /// node budget the tree read uses — an unbounded walk on a hostile tree is
    /// the hazard ``maximumNodes`` already exists to cap.
    private static func firstElement(
        in element: AXUIElement, named name: String, budget: inout Int
    ) -> AXUIElement? {
        guard budget > 0 else { return nil }
        budget -= 1
        if accessibleName(of: element) == name { return element }
        let kids =
            (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
        for child in kids {
            if let hit = firstElement(in: child, named: name, budget: &budget) { return hit }
        }
        return nil
    }

    private static func firstElement(in element: AXUIElement, named name: String) -> AXUIElement? {
        var budget = Self.maximumNodes
        return firstElement(in: element, named: name, budget: &budget)
    }

    /// The label a user would call this control, trying every attribute SwiftUI
    /// might populate (see ``press(pid:named:)`` for why one is not enough).
    private static func accessibleName(of element: AXUIElement) -> String {
        for key in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] as [String] {
            if let value = attribute(element, key) as? String, !value.isEmpty { return value }
        }
        return ""
    }

    private static func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var out: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, key as CFString, &out) == .success
            ? out : nil
    }

    /// Read the first window of `pid` and normalize it into a semantic tree.
    ///
    /// - Parameter pid: the windowed host process to inspect.
    /// - Returns: the normalized tree, rooted at the hosting view's content group.
    /// - Throws: ``Failure`` when the tree cannot be read.
    public static func readTree(pid: pid_t) throws -> SemanticNode {
        guard isTrusted else { throw Failure.notTrusted }

        let window = try firstWindow(of: pid)

        // Anchor on the hosting group rather than the window: the window frame
        // includes a titlebar (measured at 32 pt), so using it as the origin
        // shifts every node by that amount — a uniform offset that looks like a
        // real disagreement on every single node at once.
        let content = hostingContent(of: window) ?? window
        // NOT `?? .zero`. Falling back to the origin would leave every node in
        // SCREEN coordinates (x in the hundreds) while the probe channel reports
        // root coordinates, so the reconciler would report a frame disagreement
        // on EVERY node at once — blaming the probe channel for the witness's own
        // failure to read an origin. A witness that cannot locate its anchor has
        // not observed the window; it must say so rather than return a tree whose
        // every frame is wrong by a constant.
        guard let origin = frame(of: content)?.origin else {
            throw Failure.anchorUnreadable
        }

        var budget = Self.maximumNodes
        var root = normalize(content, origin: origin, depth: 0, budget: &budget)
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

    /// Deepest AX tree this reader will walk.
    ///
    /// A bound, not a tuning knob. An `AXUIElement` tree is a graph the platform
    /// hands us, not a structure we own: an element can reference an ancestor,
    /// and `kAXChildrenAttribute` then yields a cycle that recurses until the
    /// stack is gone. Measured 2026-08-12 — an unbounded walk **crashed the test
    /// runner with SIGSEGV**, "thread stack size exceeded due to excessive
    /// recursion", inside `AXUIElementCopyAttributeValue`. It read as a flaky
    /// runner rather than a defect, because the process died AFTER printing its
    /// per-test results, so `--filter` runs reported the suite green.
    ///
    /// 64 is far past any real view hierarchy (the measured demo window is 3
    /// deep) and far short of the ~500 frames the stack allows.
    static let maximumDepth = 64

    /// Largest number of elements a single read will normalize.
    ///
    /// A depth bound alone does NOT bound the work, and the difference is not
    /// academic. `maximumDepth` stops infinite recursion (`no.md` #44) but says
    /// nothing about BREADTH: a tree 64 deep with even modest branching has more
    /// nodes than can be walked, and every node costs roughly five CROSS-PROCESS
    /// accessibility calls, so the cost is IPC-bound rather than CPU-bound and no
    /// amount of waiting finishes it.
    ///
    /// Measured 2026-08-12: reading Finder's live tree with a depth bound and no
    /// node budget did not terminate in 60 s and was SIGKILLed at the default
    /// runner limit. The demo scenarios never exposed this because a harness-built
    /// window is a handful of nodes — which is precisely why the Wave 8 gate asks
    /// for a third-party app: a reader is only proven on trees it did not design
    /// for.
    ///
    /// 4096 is ~100x the largest window measured here and still bounded work.
    /// Hitting it truncates VISIBLY (the node that hit the budget keeps its own
    /// entry and loses its children), so the reconciler reports missing children
    /// as visibility gaps rather than agreeing about nothing.
    static let maximumNodes = 4096

    /// Recursively convert an AX element into a ``SemanticNode``.
    ///
    /// `origin` is the hosting group's screen origin; subtracting it converts
    /// AX's screen coordinates into the SwiftUI root coordinates the probe
    /// channel reports. Both are y-down, so no axis flip is involved — the
    /// conversion needs no display metrics and survives a monitor change.
    ///
    /// `depth` bounds the walk at ``maximumDepth``; see that property for why an
    /// unbounded one is not merely slow but fatal.
    static func normalize(
        _ element: AXUIElement,
        origin: CGPoint,
        depth: Int,
        budget: inout Int
    ) -> SemanticNode {
        budget -= 1
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

        // Stop descending at the bound rather than truncating silently: the node
        // itself is still reported, so a tree that hits the limit is visibly
        // shallow rather than absent, and the reconciler reports the missing
        // children as visibility gaps instead of agreeing about nothing.
        // Two independent bounds, because they stop two different runaways.
        // Depth stops a CYCLE (an element referencing an ancestor); the node
        // budget stops sheer BREADTH, which a depth bound cannot see and which
        // is what actually hangs a read of a real application's tree.
        var children: [SemanticNode] = []
        if depth < Self.maximumDepth, budget > 0 {
            for child in copy(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
                guard budget > 0 else { break }
                children.append(
                    normalize(child, origin: origin, depth: depth + 1, budget: &budget))
            }
        }

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
        let position = positionValue as! AXValue  // audit-allow: checked by CFGetTypeID above
        // swift-format-ignore: NeverForceUnwrap
        let extent = sizeValue as! AXValue  // audit-allow: checked by CFGetTypeID above
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
