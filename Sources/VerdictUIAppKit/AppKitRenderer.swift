// VerdictUIAppKit — the AppKit producer.
//
// Wave 11. Everything before this file could only judge SwiftUI: `verdictProbe`
// is `extension View`, and the accessibility witness needs an `AXGroup` anchor
// that only a SwiftUI hosting view publishes — so an AppKit product had no path
// at all, measured against PanoMac and Notes (both exit 2 from `inspect`).
//
// The kernel never had that limit. It imports only Foundation, `Rect` is
// hand-rolled (`no.md` #5), and every rule judges geometry and text metrics —
// all of which an `NSView` carries natively. The missing piece was a PRODUCER,
// and that is all this file is: a view-hierarchy walk that emits the same wire
// shape `TreeAssembly` emits, so `judge` cannot tell the two producers apart.
//
// What it deliberately is NOT: a screenshot, an accessibility scrape, or an
// Automator script. No window is ordered on screen, no app need be running, and
// no permission is required. The layout pass happens off-screen in the calling
// process.
import AppKit
import VerdictUIKernel

/// Turns a live `NSView` hierarchy into the semantic tree `VerdictUIKernel`
/// judges — off-screen, with no window, no screenshot, and no permissions.
///
/// ```swift
/// let controller = StartupManagerViewController()
/// let tree = AppKitRenderer.tree(for: controller, viewport: CGSize(width: 720, height: 480))
/// let verdict = RuleEngine.run(
///     rules: RuleEngine.standardRules,
///     on: tree,
///     context: .macOS(viewport: tree.frame, scenario: "startup-manager")
/// )
/// ```
///
/// ### `@MainActor` is a requirement, not a preference
///
/// AppKit layout (`layoutSubtreeIfNeeded`, `frame`, `intrinsicContentSize`)
/// is main-thread-only, and forcing a layout pass is the entire point of this
/// type. Isolating to the main actor is how that is expressed to the compiler
/// rather than left to a comment nobody reads.
///
/// ### Identity: `NSUserInterfaceItemIdentifier`, not a new API
///
/// The SwiftUI path asks the developer to add `.verdictProbe("save-button")`.
/// The AppKit path asks for nothing: it reads `view.identifier`, which AppKit
/// developers already set (Interface Builder writes it; so does anyone doing
/// UI testing). A view with no identifier still gets an id — a synthesized one
/// derived from its structural position — because `RuleEngine` refuses a tree
/// with no probed node as *vacuous*, and an AppKit codebase sets `identifier`
/// on approximately none of its views. See ``synthesizedID(for:path:)``.
@MainActor
public enum AppKitRenderer {

    /// Structural path assigned to the root node. Matches
    /// `TreeAssembly.rootPath` and the kernel's `TreeDiff.rootSegment` so trees
    /// from the two producers are diffable against each other.
    public static let rootPath = "root"

    /// Prefix on every synthesized id, so a caller can always tell an id the
    /// developer chose from one this renderer invented.
    ///
    /// A finding citing `ak:root/button[1]` says "you did not name this, so I
    /// named it by where it sits"; a finding citing `save-button` says the
    /// developer named it. Conflating the two would make a finding's node id
    /// look stable when it is actually positional and moves with any reorder.
    public static let synthesizedIDPrefix = "ak:"

    // MARK: - Entry points

    /// The semantic tree for `controller`'s view.
    ///
    /// Touches `controller.view`, which LOADS the view if it has not been loaded
    /// — that is the intent: a controller nobody has shown still has a layout,
    /// and the whole promise here is judging it without showing it.
    ///
    /// - Parameters:
    ///   - controller: the controller whose view is walked.
    ///   - viewport: size to lay out at, in points. `nil` keeps the view's own
    ///     frame, which is what a controller loaded from a nib already carries.
    public static func tree(for controller: NSViewController, viewport: CGSize? = nil)
        -> SemanticNode
    {
        tree(for: controller.view, viewport: viewport)
    }

    /// The semantic tree for `view`, after forcing a real layout pass.
    ///
    /// - Parameters:
    ///   - view: root of the hierarchy to walk. Frames in the result are in
    ///     THIS view's coordinate space, converted with `convert(_:to:)`.
    ///   - viewport: size to lay out at, in points. When supplied, the root's
    ///     frame is set to it before layout, so a caller can ask "how does this
    ///     look at 320 pt wide" without mutating anything permanently — the
    ///     frame is restored before returning.
    public static func tree(for view: NSView, viewport: CGSize? = nil) -> SemanticNode {
        let originalFrame = view.frame
        defer { view.frame = originalFrame }

        if let viewport {
            view.frame = NSRect(origin: originalFrame.origin, size: viewport)
        }
        // The layout pass. No window, no screenshot: `layoutSubtreeIfNeeded`
        // resolves auto-layout constraints and calls `layout()` down the whole
        // subtree, which is everything the geometry rules need. A view built
        // with springs-and-struts rather than constraints already has its
        // frames and this is a no-op for it.
        view.layoutSubtreeIfNeeded()

        let node = walk(view, root: view, path: rootPath)
        // Assigned by the KERNEL's own helper rather than by the walk, so the
        // SwiftUI and AppKit producers cannot drift on what a structural path
        // looks like — the identity that findings, diffs and baselines key on.
        return node.withAssignedStructuralPaths(rootPath: rootPath)
    }

    // MARK: - The walk

    /// One node plus its whole subtree.
    ///
    /// `path` is threaded through only to synthesize ids for unidentified views;
    /// the authoritative `structuralPath` is assigned in one pass at the end by
    /// the kernel helper. Two sources for the same string would be two places to
    /// get it wrong.
    private static func walk(_ view: NSView, root: NSView, path: String) -> SemanticNode {
        let role = role(of: view)
        let children = childrenToWalk(of: view).enumerated().map { index, subview in
            walk(
                subview,
                root: root,
                path: "\(path)/\(AppKitRenderer.role(of: subview).identifier)[\(index)]"
            )
        }
        let text = text(of: view)

        return SemanticNode(
            id: identity(of: view, path: path),
            role: role,
            frame: frame(of: view, in: root),
            text: text,
            attributes: attributes(of: view),
            isVisible: isVisible(view),
            textMetrics: textMetrics(of: view, role: role, text: text),
            children: children
        )
    }

    // MARK: - Scope

    /// The subviews worth walking into.
    ///
    /// ### Why a boundary is necessary, with the measurement that forced it
    ///
    /// AppKit assembles a control from PRIVATE subviews the developer never
    /// wrote and cannot change. `NSScrollView` alone contributes
    /// `_NSScrollViewContentBackgroundView`, `NSScrollPocket`, `PocketMask`,
    /// `PocketBlur`, `NSHardPocketView`, `BackdropView`, `NSBannerView`,
    /// `_NSBannerDecorationView` and several dimming layers — all deliberately
    /// stacked on top of each other, because that is how a scroll view is drawn.
    ///
    /// Measured against PanoMac's real `StartupManagerViewController` layout
    /// with no boundary: 36 nodes, 19 of them AppKit internals, and a verdict of
    /// **30 findings** — every one a sibling-overlap or content-overlap between
    /// two private decoration layers. None was actionable, and a genuine defect
    /// would have been invisible inside the list. A producer that emits noise at
    /// that ratio is worse than one that emits nothing, because the noise looks
    /// like work.
    ///
    /// ### The rule
    ///
    /// A platform control is a **leaf**: its own frame, text and role are
    /// reported, its innards are not. That is the same argument
    /// `docs/adoption.md` makes for tier 2b — a view you cannot edit is probed
    /// from the OUTSIDE, and the verdict is a claim about the box rather than
    /// its contents.
    ///
    /// `NSScrollView` is the one exception, and a deliberate one: its
    /// `documentView` is the developer's OWN content, is editable, and is
    /// exactly what they want judged. So the scroll view's decoration is
    /// skipped and its document is walked.
    static func childrenToWalk(of view: NSView) -> [NSView] {
        if let scrollView = view as? NSScrollView {
            // The document, not the clip view: `NSClipView` is scaffolding, and
            // reporting it adds a node the developer did not write between two
            // they did.
            return scrollView.documentView.map { [$0] } ?? []
        }
        guard !isOpaquePlatformControl(view) else { return [] }
        return view.subviews
    }

    /// True for a control whose subviews belong to AppKit rather than to the
    /// developer.
    ///
    /// Listed by CLASS rather than by a name heuristic. A rule like "skip
    /// anything starting with `_`" would be shorter and wrong in both
    /// directions: it lets `NSScrollPocket` and `BackdropView` through, and it
    /// would swallow a developer's own `_InternalRow`. The list names what
    /// AppKit actually assembles from privates; anything not on it is walked,
    /// so an unknown class is reported rather than silently dropped.
    static func isOpaquePlatformControl(_ view: NSView) -> Bool {
        view is NSTableView || view is NSOutlineView || view is NSCollectionView
            || view is NSButton || view is NSTextField || view is NSSlider || view is NSStepper
            || view is NSSwitch || view is NSProgressIndicator || view is NSSegmentedControl
            || view is NSComboBox || view is NSDatePicker || view is NSColorWell
            || view is NSPathControl || view is NSTokenField || view is NSSearchField
            || view is NSScroller || view is NSTableHeaderView || view is NSVisualEffectView
    }

    // MARK: - Identity

    /// The id this node is cited by: the developer's own
    /// `NSUserInterfaceItemIdentifier` when set, otherwise a synthesized one.
    static func identity(of view: NSView, path: String) -> String {
        if let identifier = view.identifier?.rawValue, !identifier.isEmpty {
            return identifier
        }
        return synthesizedID(for: view, path: path)
    }

    /// A positional id for a view the developer never named.
    ///
    /// Positional ids are WEAKER than chosen ones — they move when siblings are
    /// reordered — which is why they carry ``synthesizedIDPrefix``: a reader can
    /// see at a glance that this identity is derived rather than declared, and a
    /// developer who wants a stable one sets `view.identifier`.
    static func synthesizedID(for view: NSView, path: String) -> String {
        synthesizedIDPrefix + path
    }

    // MARK: - Role mapping

    /// Map an AppKit class onto the kernel's role vocabulary.
    ///
    /// Ordered most-specific-first because AppKit's hierarchy is deep and
    /// `is` matches superclasses: `NSButton` is checked before `NSControl`,
    /// `NSTableView` before `NSView`. An unrecognized class becomes
    /// ``Role/custom(_:)`` carrying its type name, never a silent `.container`
    /// — an unclassified node that reads as a container gets judged by
    /// `EmptyContainerRule`, which would state more than the tree supports
    /// (`docs/tree-contract.md` says exactly this about `custom`).
    static func role(of view: NSView) -> Role {
        switch view {
        case is NSPopUpButton:
            // BEFORE `NSButton`, which it subclasses: a pop-up presents a menu,
            // and a `case` order that put the superclass first would swallow it
            // silently — the switch would compile and simply never reach here.
            return .menu
        case is NSButton:
            // `NSSwitch` is not an `NSButton`, so ordering does not matter here;
            // a checkbox-style `NSButton` is still a button, which is what the
            // tap-target rule wants to measure.
            return .button
        case is NSSwitch:
            return .toggle
        case is NSSlider, is NSStepper:
            return .slider
        case let field as NSTextField:
            // The one role that depends on STATE rather than class: the same
            // class is a label when not editable and an input when it is, and
            // `Role.isInteractive` (which drives TapTargetRule) must not police
            // a static label as though it were a control.
            return field.isEditable ? .textField : .text
        case is NSTextView:
            return .textField
        case is NSImageView:
            return .image
        case is NSTableView, is NSOutlineView, is NSCollectionView:
            // `custom`, NOT `.list`, and the reason is the same one
            // `EmptyContainerRule` gives for excluding `custom` in the first
            // place: an unclassified node reported as an empty container
            // "states more than the tree supports".
            //
            // These controls are OPAQUE LEAVES here — their row views are
            // AppKit's, so `childrenToWalk(of:)` never descends into them and
            // they can never have children. Calling them `.list` therefore told
            // the rule "this node's job is holding content" while the walk
            // guaranteed it would hold none, and the rule correctly reported
            // every table screen as blank. Measured against a table with three
            // SEEDED rows: "reserves 720 x 480 pt but renders nothing".
            //
            // Declining to look inside and finding nothing inside are different
            // claims. `custom` is the honest one, and it is exactly the tier-2b
            // move `docs/adoption.md` prescribes for a view you cannot edit.
            return .custom(String(describing: type(of: view)))
        case is NSTableRowView:
            return .listRow
        case is NSTabView:
            return .tabBar
        case is NSScrollView, is NSStackView, is NSClipView, is NSBox, is NSSplitView,
            is NSVisualEffectView:
            return .container
        case is NSProgressIndicator:
            return .custom("progressIndicator")
        default:
            // A plain `NSView` really is a container; anything else is something
            // this mapping has not learned, and says so by name.
            return type(of: view) == NSView.self
                ? .container : .custom(String(describing: type(of: view)))
        }
    }

    // MARK: - Geometry

    /// `view`'s frame in `root`'s coordinate space, converted to the kernel's
    /// **y-down** convention.
    ///
    /// Two conversions, and the second is the one that is easy to miss. AppKit's
    /// default coordinate system has y increasing UPWARD from the bottom-left;
    /// the kernel — and every tree the SwiftUI producer emits — uses y-DOWN from
    /// the top-left, which is what `OffscreenRule` and `MisalignmentRule` assume.
    /// Emitting the raw AppKit y would put the top of the screen at the bottom
    /// and quietly invert every vertical judgement.
    ///
    /// A root that is itself flipped (`isFlipped == true`, common for custom
    /// document views) is already y-down, so no flip is applied.
    static func frame(of view: NSView, in root: NSView) -> Rect {
        // `bounds` converted from the view itself, not `frame` converted from the
        // superview: `frame` is expressed in the SUPERVIEW's space and is also
        // the WRONG rectangle for a view with a non-identity bounds transform
        // (a scaled or scrolled clip view), where `frame` and the drawn content
        // diverge.
        let converted = view.convert(view.bounds, to: root)
        let rootHeight = root.bounds.height
        let y = root.isFlipped ? converted.origin.y : rootHeight - converted.maxY
        return Rect(
            x: Double(converted.origin.x),
            y: Double(y),
            width: Double(converted.width),
            height: Double(converted.height)
        )
    }

    /// Whether this node actually renders.
    ///
    /// Three independent ways an AppKit view is invisible: explicitly hidden,
    /// fully transparent, or occupying no area. A view hidden by an ANCESTOR is
    /// handled by the walk carrying that down — see ``isVisible(_:)``'s ancestor
    /// check — because a subview of a hidden view is invisible no matter what
    /// its own flags say, and rules skip invisible nodes.
    static func isVisible(_ view: NSView) -> Bool {
        guard !view.isHidden, view.alphaValue > 0 else { return false }
        guard view.bounds.width > 0, view.bounds.height > 0 else { return false }
        // Walk up: `isHiddenOrHasHiddenAncestor` exists but also reports true for
        // a view not yet in a window, which is EVERY view here by construction —
        // using it would mark the whole tree invisible and silence every rule.
        var ancestor = view.superview
        while let current = ancestor {
            if current.isHidden || current.alphaValue <= 0 { return false }
            ancestor = current.superview
        }
        return true
    }

    // MARK: - Text

    /// The string this view renders, or `nil` when it renders none.
    ///
    /// `stringValue` before `title`, because an `NSButton`'s `stringValue` is
    /// its title while an `NSTextField`'s `title` is empty — asking in the other
    /// order gets a button right and a text field wrong.
    static func text(of view: NSView) -> String? {
        let raw: String?
        switch view {
        case let field as NSTextField:
            raw = field.stringValue
        case let button as NSButton:
            raw = button.title
        case let textView as NSTextView:
            raw = textView.string
        case let control as NSControl:
            raw = control.stringValue
        default:
            raw = nil
        }
        guard let raw, !raw.isEmpty else { return nil }
        return raw
    }

    /// Text-layout measurements, or `nil` when this node cannot honestly supply
    /// them.
    ///
    /// The honesty boundary is the same one `TreeAssembly.textMetrics` draws,
    /// and for the same reason: `TruncationRule` skips nodes without metrics on
    /// purpose, so what a producer DECLINES to fill in matters as much as what
    /// it fills. `nil` is returned when:
    ///
    /// - the role does not render text, so there are no lines to count;
    /// - there is no text, or it is empty;
    /// - the text contains a hard line break, which makes the single-line
    ///   denominator unknown — the same gap `TreeAssembly` documents;
    /// - the view cannot be measured (no font, or a zero-height measurement),
    ///   which would make every derived count a division by zero.
    ///
    /// ### What is measured and what is derived
    ///
    /// | Field | Provenance |
    /// |---|---|
    /// | `intrinsicWidth` | **measured** — the width the attributed string occupies with no width constraint. |
    /// | `renderedLineCount` | **derived** — the height the string occupies at the FRAME's width, divided by one line's height. |
    /// | `idealLineCount` | **derived** — the lines the string wants, honouring an explicit `maximumNumberOfLines` cap of 1 only insofar as it does not lie about what the text needs. |
    ///
    /// Both counts share one denominator — the height of the same string with no
    /// width constraint, which for text with no hard break is exactly one line —
    /// so only the division and the rounding are ours.
    static func textMetrics(of view: NSView, role: Role, text: String?) -> TextMetrics? {
        guard role.isTextBearing else { return nil }
        guard let text, !text.isEmpty, !text.contains(where: \.isNewline) else { return nil }
        guard let attributed = attributedString(for: view, text: text) else { return nil }

        let unconstrained = attributed.boundingRect(
            with: NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let lineHeight = unconstrained.height
        guard lineHeight > 0, unconstrained.width > 0 else { return nil }

        let width = view.bounds.width
        guard width > 0 else { return nil }

        // What the text WANTS at this width, ignoring any line cap: that is the
        // ideal. Capping it by `maximumNumberOfLines` here would make ideal and
        // rendered agree by construction and the truncation rule could never
        // fire — the producer would be reporting the constraint back as though
        // it were the content's need.
        let idealHeight = attributed.boundingRect(
            with: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).height
        let idealLines = lineCount(of: idealHeight, unit: lineHeight)

        // What actually renders: the frame's height in lines, capped by an
        // explicit `maximumNumberOfLines` when the developer set one. This is
        // the number the rule compares against ideal, so it must reflect the
        // CONSTRAINT rather than the desire.
        var renderedLines = lineCount(of: Double(view.bounds.height), unit: lineHeight)
        if let field = view as? NSTextField, field.maximumNumberOfLines > 0 {
            renderedLines = min(renderedLines, field.maximumNumberOfLines)
        }
        renderedLines = min(renderedLines, idealLines)

        return TextMetrics(
            intrinsicWidth: Double(unconstrained.width),
            renderedLineCount: renderedLines,
            idealLineCount: idealLines
        )
    }

    /// The attributed string to measure, carrying the view's real font.
    ///
    /// Measuring with the wrong font produces a plausible, wrong
    /// `intrinsicWidth`, and a wrong intrinsic width is exactly the number the
    /// truncation rule decides on — so a default-font fallback would be a
    /// silent measurement error rather than a missing one.
    private static func attributedString(for view: NSView, text: String) -> NSAttributedString? {
        if let field = view as? NSTextField {
            // The field's own attributed value when it has one — it carries the
            // real font, kerning and paragraph style. `stringValue`-derived text
            // with the field's font is the fallback for a plain label.
            let attributed = field.attributedStringValue
            if attributed.length > 0 { return attributed }
            guard let font = field.font else { return nil }
            return NSAttributedString(string: text, attributes: [.font: font])
        }
        if let textView = view as? NSTextView, let font = textView.font {
            return NSAttributedString(string: text, attributes: [.font: font])
        }
        if let button = view as? NSButton {
            let attributed = button.attributedTitle
            if attributed.length > 0 { return attributed }
            guard let font = button.font else { return nil }
            return NSAttributedString(string: text, attributes: [.font: font])
        }
        guard let font = (view as? NSControl)?.font else { return nil }
        return NSAttributedString(string: text, attributes: [.font: font])
    }

    /// `height` expressed in whole lines of `unit`, never less than one:
    /// content that was measured at all occupies at least one line. Matches
    /// `TreeAssembly`'s rounding exactly.
    private static func lineCount(of height: Double, unit: Double) -> Int {
        max(1, Int((height / unit).rounded()))
    }

    // MARK: - Attributes

    /// Role-specific state a rule or a reader can use.
    ///
    /// Deliberately sparse. Every key added here is a key some rule may key off
    /// later, and a producer that dumps every AppKit property would bury the
    /// three that matter in a hundred that do not.
    static func attributes(of view: NSView) -> [String: AttributeValue] {
        var attributes: [String: AttributeValue] = [:]
        switch view {
        case let toggle as NSSwitch:
            attributes["isOn"] = .bool(toggle.state == .on)
        case let slider as NSSlider:
            attributes["sliderValue"] = .number(slider.doubleValue)
        case let button as NSButton where button.allowsMixedState || button.state != .off:
            attributes["state"] = .number(Double(button.state.rawValue))
        case let field as NSTextField where field.isEditable:
            attributes["isEditable"] = .bool(true)
        default:
            break
        }
        if !view.isEnabledForVerdict {
            attributes["isEnabled"] = .bool(false)
        }
        return attributes
    }
}

extension NSView {
    /// Whether this view is enabled, for views that have the concept.
    ///
    /// A plain `NSView` has no enabled state and reports `true`: absence of the
    /// concept is not the same as being disabled, and reporting `false` for
    /// every container would put a misleading attribute on most of the tree.
    fileprivate var isEnabledForVerdict: Bool {
        (self as? NSControl)?.isEnabled ?? true
    }
}
