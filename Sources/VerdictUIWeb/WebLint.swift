import Foundation
import VerdictUIKernel

/// Browser layout has independently scrollable documents and overflow panels.
/// Project only lint ancestry/bounds; retain the full observation for discovery,
/// input, expectations and verdict evidence. Never enlarge bounds from child
/// boxes: that would turn genuinely displaced content into its own exemption.
enum WebLint {
    static func checkedRect(x: Double, y: Double, width: Double, height: Double) throws -> Rect {
        guard x.isFinite, y.isFinite, width.isFinite, height.isFinite, width >= 0, height >= 0,
              (x + width).isFinite, (y + height).isFinite else {
            throw WebBrowserError.invalidCDPResponse(reason: "invalid web scroll geometry")
        }
        return Rect(x: x, y: y, width: width, height: height)
    }

    static func store(_ rect: Rect, key: String, in attributes: inout [String: AttributeValue]) {
        for (suffix, value) in [("X", rect.x), ("Y", rect.y), ("Width", rect.width), ("Height", rect.height)] {
            attributes[key + suffix] = .number(value)
        }
    }

    static func rect(key: String, in attributes: [String: AttributeValue]) -> Rect? {
        guard let x = attributes[key + "X"]?.numberValue, let y = attributes[key + "Y"]?.numberValue,
              let width = attributes[key + "Width"]?.numberValue, let height = attributes[key + "Height"]?.numberValue else { return nil }
        return Rect(x: x, y: y, width: width, height: height)
    }

    static func establishesFixedContainer(styles: [String]) -> Bool {
        let contain = Set(styles[12].split(separator: " ").map(String.init))
        let willChange = Set(styles[13].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        return styles[9] != "none" || styles[10] != "none" || styles[11] != "none"
            || !contain.isDisjoint(with: ["layout", "paint", "strict", "content"])
            || [33, 34, 35].contains(where: { styles.indices.contains($0) && styles[$0] != "none" })
            || !willChange.isDisjoint(with: ["transform", "filter", "perspective", "contain", "translate", "rotate", "scale"])
    }

    /// Only fully understood finite computed forms can prove an empty paint
    /// region. Unknown clip shapes remain visible and subject to ordinary lint.
    /// CSS2 clip applies only to absolutely/fixed positioned boxes. The measured
    /// site uses clip-path:inset(50%), which also applies to static boxes.
    static func emptyPaint(position: String, clip: String, clipPath: String, frame: Rect) -> Bool {
        func values(_ value: String, prefix: String) -> [String]? {
            guard value.hasPrefix(prefix), value.hasSuffix(")") else { return nil }
            return value.dropFirst(prefix.count).dropLast().split { $0 == "," || $0.isWhitespace }.map(String.init)
        }
        func pixels(_ value: String, dimension: Double, percentage: Bool) -> Double? {
            let result: Double?
            if value.hasSuffix("px") { result = Double(value.dropLast(2)) }
            else if percentage && value.hasSuffix("%") { result = Double(value.dropLast()).map { dimension * ($0 / 100) } }
            else if value == "0" { result = 0 }
            else { result = nil }
            guard let result, result.isFinite else { return nil }
            return result
        }
        if (position == "absolute" || position == "fixed"), let parts = values(clip, prefix: "rect("), parts.count == 4,
           let top = pixels(parts[0], dimension: frame.height, percentage: false),
           let right = pixels(parts[1], dimension: frame.width, percentage: false),
           let bottom = pixels(parts[2], dimension: frame.height, percentage: false),
           let left = pixels(parts[3], dimension: frame.width, percentage: false),
           right <= left || bottom <= top { return true }
        if let parts = values(clipPath, prefix: "inset("), (1...4).contains(parts.count) {
            let sides = [parts[0], parts.count > 1 ? parts[1] : parts[0], parts.count > 2 ? parts[2] : parts[0],
                         parts.count > 3 ? parts[3] : (parts.count > 1 ? parts[1] : parts[0])]
            // Percentage-only insets prove emptiness independently of transforms.
            // Pixel insets require the untransformed reference box, which a
            // DOMSnapshot bounding rectangle does not establish.
            if sides.allSatisfy({ $0.hasSuffix("%") }),
               let top = pixels(sides[0], dimension: 100, percentage: true),
               let right = pixels(sides[1], dimension: 100, percentage: true),
               let bottom = pixels(sides[2], dimension: 100, percentage: true),
               let left = pixels(sides[3], dimension: 100, percentage: true),
               (top + bottom).isFinite, (left + right).isFinite {
                return top + bottom >= 100 || left + right >= 100
            }
        }
        return false
    }

    private static func paintProjection(_ source: SemanticNode, documentClip: WebPaintSemantics.Clip? = nil,
                                        scrollClips: [WebPaintSemantics.Boundary] = [], cssClips: [WebPaintSemantics.Boundary] = [],
                                        contained: Bool = false) -> SemanticNode {
        typealias Clip = WebPaintSemantics.Clip
        typealias Boundary = WebPaintSemantics.Boundary
        var node = source
        let fixed = source.attributes["web.position"] == .string("fixed") && !contained
            && WebPaintSemantics.positioningRange(source) == nil
        let activeScroll = fixed ? [] : scrollClips.filter { !$0.escaped(by: source) }
        let activeCSS = fixed ? [] : cssClips.filter { !$0.escaped(by: source) }
        if let clip = Clip.combined(documentClip, Boundary.combined(activeScroll), Boundary.combined(activeCSS)) {
            let visible = clip.applying(to: source.frame)
            if let visible { node.frame = visible }
            else { node.isVisible = false }
            // Fragment rectangles are bounded by the original union, so this
            // finite intersection also represents an independently clipped axis.
            store(visible ?? Rect(x: 0, y: 0, width: 0, height: 0), key: "web.paintClip", in: &node.attributes)
        }
        let ownScroll = rect(key: "web.scrollViewport", in: source.attributes).map { Boundary(Clip($0), owner: source) }
        let childScroll = activeScroll + [ownScroll].compactMap { $0 }
        let clipsX = WebPaintSemantics.clips(source.attributes["web.overflowX"]?.stringValue)
        let clipsY = WebPaintSemantics.clips(source.attributes["web.overflowY"]?.stringValue)
        let ownCSS = clipsX || clipsY ? Boundary(Clip(source.frame, x: clipsX, y: clipsY), owner: source) : nil
        let childCSS = activeCSS + [ownCSS].compactMap { $0 }
        node.children = source.children.map { child in
            let changedDocument = child.attributes["web.frame"] != source.attributes["web.frame"]
                && source.attributes["web.frame"] != nil
            let ownDocument = changedDocument ? rect(key: "web.documentViewport", in: child.attributes).map { Clip($0) } : nil
            // Freeze only the iframe owner's applicable outer clips. A child
            // document's positioning metadata cannot escape those outer bounds.
            let childDocument = changedDocument ? Clip.combined(ownDocument, documentClip, Boundary.combined(childScroll), Boundary.combined(childCSS)) : documentClip
            return paintProjection(child, documentClip: childDocument, scrollClips: changedDocument ? [] : childScroll,
                cssClips: changedDocument ? [] : childCSS,
                contained: changedDocument ? false : (contained || source.attributes["web.fixedContainer"] == .bool(true)))
        }
        return node
    }

    struct OverlapBudget {
        private(set) var remaining: Int
        private(set) var consumed = 0
        var originalPairs = 0
        var fragmentEvents = 0
        var fragmentComparisons = 0

        init(limit: Int = 2_000_000) { remaining = limit }
        mutating func charge(_ amount: Int = 1) throws {
            guard amount >= 0, remaining >= amount else {
                throw WebBrowserError.invalidWebOperation(reason: "web overlap inspection exceeded its bounded work budget")
            }
            remaining -= amount; consumed += amount
        }
    }

    /// Preserve Finding equality and order without a linear scan of all earlier
    /// results for every overlap. Insertion attempts share the overlap budget.
    struct FindingAccumulator {
        private struct Key: Hashable {
            let rule: String
            let severity: String
            let nodeID: String
            let message: String
            let suggestion: String?
            init(_ finding: Finding) {
                rule = finding.rule; severity = finding.severity.rawValue
                nodeID = finding.nodeID; message = finding.message; suggestion = finding.suggestion
            }
        }
        private var seen: Set<Key>
        private(set) var values: [Finding]
        init(_ initial: [Finding] = []) {
            values = initial; seen = Set(initial.map(Key.init))
        }
        mutating func append(_ incoming: [Finding], budget: inout OverlapBudget) throws {
            for finding in incoming {
                try budget.charge()
                if seen.insert(Key(finding)).inserted { values.append(finding) }
            }
        }
    }

    /// Original DOM nodes remain the subjects. A long text is never expanded
    /// into sibling nodes, so fragments of the same text are never compared.
    /// Only distinct original-node candidates enter the bounded fragment sweep.
    static func overlapFindings(_ root: SemanticNode, context: LintContext, budget: inout OverlapBudget) throws -> [Finding] {
        func label(_ node: SemanticNode) -> String { node.id.isEmpty ? node.structuralPath : node.id }
        func boxes(_ node: SemanticNode, budget: inout OverlapBudget) throws -> [Rect] {
            let inline = node.attributes["web.inlineCandidate"] == .bool(true)
                && node.attributes["web.inlineNonHTML"] != .bool(true)
            let key = inline ? "web.inlineFragment" : "web.textFragment"
            guard inline || node.role == .text else { return [node.frame] }
            guard let count = node.attributes[key + "Count"]?.numberValue.flatMap(Int.init(exactly:)),
                  (1...100_000).contains(count) else {
                if inline { throw WebBrowserError.invalidCDPResponse(reason: "missing inline border geometry") }
                return [node.frame]
            }
            // Charge the raw measurements before decoding or clipping them.
            // A tiny visible slice must not hide repeated scans of a long text.
            try budget.charge(count)
            let measured = (0..<count).compactMap { rect(key: key + "\($0)", in: node.attributes) }
            guard measured.count == count else {
                throw WebBrowserError.invalidCDPResponse(reason: "incomplete measured overlap geometry")
            }
            if let clip = rect(key: "web.paintClip", in: node.attributes) {
                return measured.compactMap { $0.intersection(clip) }
            }
            return measured
        }
        func overlap(_ first: SemanticNode, _ second: SemanticNode, budget: inout OverlapBudget) throws -> (rect: Rect, fontPaintUnverified: Bool)? {
            try budget.charge(); budget.originalPairs += 1
            guard first.frame.intersects(second.frame) else { return nil }
            let firstBoxes = try boxes(first, budget: &budget), secondBoxes = try boxes(second, budget: &budget)
            guard !firstBoxes.isEmpty, !secondBoxes.isEmpty else { return nil }
            let rectangles = firstBoxes + secondBoxes
            // Preflight the whole event set before allocating/sorting its index
            // arrays. No truncated candidate list can turn exhaustion into PASS.
            try budget.charge(rectangles.count)
            let starts = rectangles.indices.sorted { rectangles[$0].y == rectangles[$1].y ? $0 < $1 : rectangles[$0].y < rectangles[$1].y }
            let ends = rectangles.indices.sorted { rectangles[$0].maxY == rectangles[$1].maxY ? $0 < $1 : rectangles[$0].maxY < rectangles[$1].maxY }
            var firstActive: Set<Int> = [], secondActive: Set<Int> = []
            var end = 0
            var uncertain: Rect?
            for index in starts {
                budget.fragmentEvents += 1
                let box = rectangles[index]
                while end < ends.count, rectangles[ends[end]].maxY <= box.y {
                    firstActive.remove(ends[end]); secondActive.remove(ends[end]); end += 1
                }
                let isFirst = index < firstBoxes.count
                let opposite = isFirst ? secondActive : firstActive
                var match: (Int, Rect)?
                var fontMatch: (Int, Rect)?
                for other in opposite {
                    try budget.charge(); budget.fragmentComparisons += 1
                    if let intersection = box.intersection(rectangles[other]),
                       intersection.width > SiblingOverlapRule.tolerance, intersection.height > SiblingOverlapRule.tolerance {
                        if WebPaintSemantics.fontPaintUnverified(first, second, firstBox: box, secondBox: rectangles[other]) {
                            if fontMatch.map({ other < $0.0 }) ?? true { fontMatch = (other, intersection) }
                        } else if match.map({ other < $0.0 }) ?? true {
                            match = (other, intersection)
                        }
                    }
                }
                // Keep the first stable uncertain pair, but keep scanning: a
                // later same-line collision is still a confirmed layout error.
                if let match { return (match.1, false) }
                if uncertain == nil, let fontMatch { uncertain = fontMatch.1 }

                if isFirst { firstActive.insert(index) } else { secondActive.insert(index) }
            }
            return uncertain.map { ($0, true) }
        }
        var findings: [Finding] = []
        if !context.disabledRules.contains(SiblingOverlapRule.id) {
            for parent in root.flattened() where parent.role.identifier.lowercased() != "zstack" {
                let children = parent.children.filter { $0.isVisible && !$0.frame.isEmpty && $0.zIndex == nil }
                for first in children.indices {
                    for second in children.indices where second > first {
                        if let collision = try overlap(children[first], children[second], budget: &budget),
                           let finding = WebPaintSemantics.finding(rule: SiblingOverlapRule.id, node: children[second], other: children[first], fontPaintUnverified: collision.fontPaintUnverified,
                            message: "'\(label(children[second]))' overlaps sibling '\(label(children[first]))' by \(collision.rect.width) x \(collision.rect.height) pt",
                            suggestion: "Give the siblings disjoint painted bounds or declare intentional layering.", context: context) {
                            findings.append(finding)
                        }
                    }
                }
            }
        }
        if !context.disabledRules.contains(ContentOverlapRule.id) {
            var leaves: [(node: SemanticNode, parent: String)] = []
            func collect(_ node: SemanticNode, parent: String, layered: Bool) {
                let layered = layered || node.zIndex != nil || node.role.identifier.lowercased() == "zstack"
                if node.children.isEmpty || node.role.isInteractive || node.role == .image {
                    if node.isVisible, !node.frame.isEmpty, node.role != .spacer, !layered { leaves.append((node, parent)) }
                } else {
                    for child in node.children { collect(child, parent: node.structuralPath, layered: layered) }
                }
            }
            collect(root, parent: "", layered: false)
            for first in leaves.indices {
                for second in leaves.indices where second > first {
                    // Direct siblings belong to the sibling rule. Charge their
                    // visit too so a large sibling set cannot make this scan
                    // unbounded while every candidate is rejected as related.
                    try budget.charge()
                    guard leaves[first].parent != leaves[second].parent else { continue }
                    if let collision = try overlap(leaves[first].node, leaves[second].node, budget: &budget),
                       let finding = WebPaintSemantics.finding(rule: ContentOverlapRule.id, node: leaves[second].node, other: leaves[first].node, fontPaintUnverified: collision.fontPaintUnverified,
                        message: "'\(label(leaves[second].node))' overlaps '\(label(leaves[first].node))' by \(collision.rect.width) x \(collision.rect.height) pt across different parents",
                        suggestion: "Keep content from separate branches from colliding, or declare intentional layering.", context: context) {
                        findings.append(finding)
                    }
                }
            }
        }
        return findings
    }

    /// CSS overflow:visible is allowed to paint outside its layout box (font ink
    /// often does). Only measured hidden/clip axes establish clipping here;
    /// scrolling axes and separate iframe documents retain their own scopes.
    private struct WebClippingRule: LintRule {
        static let id = ClippedContentRule.id
        static func clips(_ value: String?) -> Bool { value == "hidden" || value == "clip" }
        func evaluate(_ root: SemanticNode, context: LintContext) -> [Finding] {
            var findings: [Finding] = []
            typealias Ancestor = (node: SemanticNode, x: Bool, y: Bool)
            typealias ScrollContext = (boundary: WebPaintSemantics.Boundary, chain: [Ancestor])
            func walk(_ node: SemanticNode, ancestors: [Ancestor], frame: AttributeValue?, contained: Bool, enclosing: [ScrollContext]) {
                let ownFrame = node.attributes["web.frame"]
                let changed = ownFrame != frame
                let fixed = node.attributes["web.position"] == .string("fixed") && !contained
                    && WebPaintSemantics.positioningRange(node) == nil
                var inherited = ancestors
                var scrollContexts = changed || fixed ? [] : enclosing
                if let escaped = scrollContexts.firstIndex(where: { $0.boundary.escaped(by: node) }) {
                    // Scrolling had released ancestor axes for reachable flow.
                    // An escaping positioned subtree restores those real clips.
                    let restored = scrollContexts[escaped].chain
                    let paths = Set(restored.map { $0.node.structuralPath })
                    inherited = restored + inherited.filter { !paths.contains($0.node.structuralPath) }
                    scrollContexts = Array(scrollContexts[..<escaped])
                }
                let chain = changed || fixed ? [] : inherited.filter {
                    !WebPaintSemantics.Boundary(WebPaintSemantics.Clip($0.node.frame), owner: $0.node).escaped(by: node)
                }
                if node.isVisible, !node.frame.isEmpty, node.role != .spacer {
                    for clip in chain {
                        let ancestor = clip.node
                        let xClips = clip.x
                        let yClips = clip.y
                        let dx = xClips ? max(ancestor.frame.x - node.frame.x, node.frame.maxX - ancestor.frame.maxX) : 0
                        let dy = yClips ? max(ancestor.frame.y - node.frame.y, node.frame.maxY - ancestor.frame.maxY) : 0
                        let amount = max(dx, dy)
                        if amount > ClippedContentRule.tolerance {
                            if let finding = WebPaintSemantics.finding(rule: Self.id, node: node,
                                message: "'\((node.id.isEmpty ? node.structuralPath : node.id))' extends \(amount) pt outside the CSS clipping bounds of '\((ancestor.id.isEmpty ? ancestor.structuralPath : ancestor.id))'",
                                suggestion: "Keep the content inside the clipped axis or make that axis scrollable.", context: context) {
                                findings.append(finding)
                            }
                            break
                        }
                    }
                }
                // Judge the scroll owner against its ancestors first. Its
                // reachable content is then independent on each scrolling axis;
                // it does not paint beyond an outer card merely by being below
                // the panel's current scroll position.
                let scrolling = WebLint.rect(key: "web.scrollBounds", in: node.attributes) != nil
                let scrollX = scrolling && ["auto", "scroll"].contains(node.attributes["web.overflowX"]?.stringValue ?? "visible")
                let scrollY = scrolling && ["auto", "scroll"].contains(node.attributes["web.overflowY"]?.stringValue ?? "visible")
                if scrollX || scrollY {
                    scrollContexts.append((WebPaintSemantics.Boundary(WebPaintSemantics.Clip(node.frame), owner: node), chain))
                }
                var next = chain.map { (node: $0.node, x: $0.x && !scrollX, y: $0.y && !scrollY) }
                let clipsX = Self.clips(node.attributes["web.overflowX"]?.stringValue)
                let clipsY = Self.clips(node.attributes["web.overflowY"]?.stringValue)
                if node.isVisible && (clipsX || clipsY) { next.append((node: node, x: clipsX, y: clipsY)) }
                for child in node.children {
                    walk(child, ancestors: next, frame: ownFrame,
                         contained: (changed ? false : contained) || node.attributes["web.fixedContainer"] == .bool(true), enclosing: scrollContexts)
                }
            }
            walk(root, ancestors: [], frame: nil, contained: false, enclosing: [])
            return findings
        }
    }

    private struct Scope {
        var key: String
        var frame: String
        var bounds: Rect
        var viewport: Rect
        var fixed: Bool = false
        var roots: [SemanticNode] = []
    }

    static func run(tree: SemanticNode, scenario: String, viewport: Rect, overlapLimit: Int = 2_000_000) throws -> Verdict {
        let started = ContinuousClock.now
        // Run the non-optional no-evidence guard once on the original tree.
        let boundaryRules: [any LintRule] = [OffscreenRule()]
        var sharedRules = RuleEngine.standardRules.filter { type(of: $0).id != OffscreenRule.id && type(of: $0).id != ClippedContentRule.id
            && type(of: $0).id != SiblingOverlapRule.id && type(of: $0).id != ContentOverlapRule.id }
        sharedRules.append(WebClippingRule())
        func visibleEvidence(_ source: SemanticNode) -> SemanticNode {
            var node = source
            if node.role == .spacer { node.id = "" }
            node.children = source.children.filter(\.isVisible).map(visibleEvidence)
            return node
        }
        let evidence = RuleEngine.run(rules: [], on: visibleEvidence(tree),
                                      context: LintContext(scenario: scenario, viewport: viewport))
        let semantic = WebPaintSemantics.project(tree, context: LintContext(scenario: scenario, viewport: viewport, requiresProbedNodes: false))
        var result = RuleEngine.run(rules: sharedRules, on: semantic.tree,
            context: LintContext(scenario: scenario, viewport: viewport, requiresProbedNodes: false), includeTree: true)
        result = Verdict(scenario: scenario, findings: evidence.findings + semantic.findings + result.findings, tree: tree, timing: result.timing)
        var scopes: [Scope] = []
        var indices: [String: Int] = [:]
        func add(_ source: SemanticNode, scope: Scope, contained: Bool, enclosing: [(boundary: WebPaintSemantics.Boundary, scope: Scope)] = []) {
            let index: Int
            if let existing = indices[scope.key] { index = existing }
            else { index = scopes.count; indices[scope.key] = index; scopes.append(scope) }
            if let root = project(source, scope: scope, contained: contained, enclosing: enclosing) { scopes[index].roots.append(root) }
        }
        func project(_ source: SemanticNode, scope: Scope, contained: Bool, enclosing: [(boundary: WebPaintSemantics.Boundary, scope: Scope)]) -> SemanticNode? {
            let frame = source.attributes["web.frame"]?.stringValue ?? scope.frame
            if frame != scope.frame, let bounds = rect(key: "web.documentBounds", in: source.attributes),
               let view = rect(key: "web.documentViewport", in: source.attributes) {
                add(source, scope: Scope(key: "document/" + frame, frame: frame, bounds: bounds, viewport: view), contained: false)
                return nil
            }
            if let escaped = enclosing.firstIndex(where: { $0.boundary.escaped(by: source) }) {
                add(source, scope: enclosing[escaped].scope, contained: contained, enclosing: Array(enclosing[..<escaped]))
                return nil
            }
            let viewportFixed = WebPaintSemantics.positioningRange(source).map { $0.block == -1 } ?? !contained
            if source.attributes["web.position"] == .string("fixed"), viewportFixed, !scope.fixed {
                add(source, scope: Scope(key: "fixed/" + source.structuralPath, frame: frame,
                                         bounds: scope.viewport, viewport: scope.viewport, fixed: true), contained: false)
                return nil
            }
            var node = source
            let childContained = contained || source.attributes["web.fixedContainer"] == .bool(true)
            if let bounds = rect(key: "web.scrollBounds", in: source.attributes) {
                // The owner stays in its enclosing scope so owner/sibling
                // overlap and displacement still fail. Its scroll content uses
                // measured scrollWidth/Height, not the owner's visible window.
                let content = Scope(key: "scroll/" + source.structuralPath, frame: frame, bounds: bounds,
                                    viewport: scope.viewport, fixed: scope.fixed)
                let boundary = WebPaintSemantics.Boundary(WebPaintSemantics.Clip(source.frame), owner: source)
                for child in source.children {
                    add(child, scope: content, contained: childContained, enclosing: enclosing + [(boundary, scope)])
                }
                node.children = []
            } else {
                node.children = source.children.compactMap { project($0, scope: scope, contained: childContained, enclosing: enclosing) }
            }
            return node
        }
        for child in semantic.tree.children {
            let frame = child.attributes["web.frame"]?.stringValue ?? "main"
            let bounds = rect(key: "web.documentBounds", in: child.attributes) ?? viewport
            let view = rect(key: "web.documentViewport", in: child.attributes) ?? viewport
            add(child, scope: Scope(key: "document/" + frame, frame: frame, bounds: bounds, viewport: view), contained: false)
        }
        var accumulated = FindingAccumulator(result.findings)
        var budget = OverlapBudget(limit: overlapLimit)
        // Reachable content in another scroll scope must not appear to paint
        // over the surrounding document. Judge each scope internally, then its
        // visible paint contribution in the enclosing hierarchy. This preserves
        // fixed/flow overlap without comparing an iframe's unpainted below-fold
        // content to unrelated content outside the iframe.
        typealias Clip = WebPaintSemantics.Clip
        typealias Boundary = WebPaintSemantics.Boundary
        var overlapRoots: [(tree: SemanticNode, clips: [Boundary], contained: Bool)] = [(semantic.tree, [], false)]
        func reachable(_ node: SemanticNode, owner: Boundary) throws -> SemanticNode? {
            try budget.charge() // Bound each copied reachable-scope node before materializing it.
            guard !owner.escaped(by: node) else { return nil }
            var result = node
            result.children = try node.children.compactMap { try reachable($0, owner: owner) }
            return result
        }
        func collectOverlapRoots(_ node: SemanticNode, inheritedClips: [Boundary], contained: Bool) throws {
            try budget.charge() // Scope discovery shares the same fail-closed work budget.
            let fixed = node.attributes["web.position"] == .string("fixed") && !contained
                && WebPaintSemantics.positioningRange(node) == nil
            let clipsX = WebPaintSemantics.clips(node.attributes["web.overflowX"]?.stringValue)
            let clipsY = WebPaintSemantics.clips(node.attributes["web.overflowY"]?.stringValue)
            let ownClip = clipsX || clipsY ? Boundary(Clip(node.frame, x: clipsX, y: clipsY), owner: node) : nil
            let activeClips = fixed ? [] : inheritedClips.filter { !$0.escaped(by: node) }
            let childClips = activeClips + [ownClip].compactMap { $0 }
            let childContained = contained || node.attributes["web.fixedContainer"] == .bool(true)
            let changesDocument = node.children.contains { $0.attributes["web.frame"] != node.attributes["web.frame"] }
            let scroll = rect(key: "web.scrollBounds", in: node.attributes) != nil
            if !node.children.isEmpty, node.attributes["web.frame"] != nil, scroll || changesDocument {
                let scrollX = scroll && ["auto", "scroll"].contains(node.attributes["web.overflowX"]?.stringValue ?? "visible")
                let scrollY = scroll && ["auto", "scroll"].contains(node.attributes["web.overflowY"]?.stringValue ?? "visible")
                // Reachable content removes only scrolling axes. Escaping
                // positioned descendants belong to the enclosing paint scope.
                let retainedClips = changesDocument ? [] : childClips.map { $0.removing(x: scrollX, y: scrollY) }
                let owner = Boundary(Clip(node.frame), owner: node)
                let children = scroll ? try node.children.compactMap { try reachable($0, owner: owner) } : node.children
                overlapRoots.append((SemanticNode(id: tree.id, role: .container, frame: node.frame, children: children),
                                     retainedClips, changesDocument ? false : childContained))
            }
            for child in node.children {
                let changed = node.attributes["web.frame"] != nil && child.attributes["web.frame"] != node.attributes["web.frame"]
                try collectOverlapRoots(child, inheritedClips: changed ? [] : childClips, contained: changed ? false : childContained)
            }
        }
        try collectOverlapRoots(semantic.tree, inheritedClips: [], contained: false)
        for root in overlapRoots {
            let paint = paintProjection(root.tree, cssClips: root.clips, contained: root.contained)
            let overlaps = try overlapFindings(paint,
                context: LintContext(scenario: scenario, viewport: viewport, requiresProbedNodes: false), budget: &budget)
            try accumulated.append(overlaps, budget: &budget)
        }
        var findings = accumulated.values
        for scope in scopes {
            let projection = SemanticNode(id: tree.id, role: .container, frame: scope.bounds, children: scope.roots)
            let context = LintContext(scenario: scenario, viewport: scope.bounds, requiresProbedNodes: false)
            let report = RuleEngine.run(rules: boundaryRules, on: projection, context: context)
            findings += report.findings
        }
        // Positive out-of-flow boxes can enlarge browser scroll extents. This
        // adapter measures reachability, not author intent about that placement.
        let duration = started.duration(to: .now).components
        let elapsed = Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15
        result = Verdict(scenario: scenario, findings: findings, tree: tree, timing: .init(evaluateMs: elapsed))
        return result
    }
}
