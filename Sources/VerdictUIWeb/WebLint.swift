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
            || !willChange.isDisjoint(with: ["transform", "filter", "perspective", "contain"])
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

    private static func paintProjection(_ source: SemanticNode, documentClip: Rect? = nil,
                                        scrollClip: Rect? = nil, contained: Bool = false) -> SemanticNode {
        var node = source
        let fixed = source.attributes["web.position"] == .string("fixed") && !contained
        let activeScroll = fixed ? nil : scrollClip
        for clip in [documentClip, activeScroll].compactMap({ $0 }) {
            if let visible = node.frame.intersection(clip) { node.frame = visible }
            else { node.isVisible = false }
        }
        let ownScroll = rect(key: "web.scrollViewport", in: source.attributes)
        let childScroll = ownScroll.flatMap { own in activeScroll.map { own.intersection($0) ?? Rect(x: 0, y: 0, width: 0, height: 0) } ?? own } ?? activeScroll
        node.children = source.children.map { child in
            let changedDocument = child.attributes["web.frame"] != source.attributes["web.frame"]
                && source.attributes["web.frame"] != nil
            let ownDocument = changedDocument ? rect(key: "web.documentViewport", in: child.attributes) : nil
            var childDocument = ownDocument ?? documentClip
            if changedDocument {
                // A fixed element can escape its own document's scroll panels,
                // never the outer document's clip around the iframe itself.
                for outer in [documentClip, childScroll].compactMap({ $0 }) {
                    childDocument = childDocument.map { $0.intersection(outer) ?? Rect(x: 0, y: 0, width: 0, height: 0) } ?? outer
                }
            }
            return paintProjection(child, documentClip: childDocument, scrollClip: changedDocument ? nil : childScroll,
                contained: changedDocument ? false : (contained || source.attributes["web.fixedContainer"] == .bool(true)))
        }
        return node
    }

    private static func fragmentProjection(_ source: SemanticNode, originals: inout [String: String]) -> SemanticNode {
        var node = source
        node.children = source.children.flatMap { child -> [SemanticNode] in
            let nested = fragmentProjection(child, originals: &originals)
            guard nested.children.isEmpty, nested.role == .text,
                  let count = nested.attributes["web.textFragmentCount"]?.numberValue.flatMap(Int.init(exactly:)),
                  (1...100_000).contains(count) else { return [nested] }
            let boxes = (0..<count).compactMap { rect(key: "web.textFragment\($0)", in: nested.attributes) }
            guard boxes.count == count else { return [nested] }
            return boxes.enumerated().map { index, box in
                var fragment = nested
                fragment.id = nested.id + "/paint-fragment/\(index)"
                fragment.structuralPath = nested.structuralPath + "/paint-fragment/\(index)"
                fragment.frame = box
                originals[fragment.id] = (nested.id.isEmpty ? nested.structuralPath : nested.id)
                return fragment
            }
        }
        return node
    }

    /// CSS overflow:visible is allowed to paint outside its layout box (font ink
    /// often does). Only measured hidden/clip axes establish clipping here;
    /// scrolling axes and separate iframe documents retain their own scopes.
    private struct WebClippingRule: LintRule {
        static let id = ClippedContentRule.id
        static func clips(_ value: String?) -> Bool { value == "hidden" || value == "clip" }
        func evaluate(_ root: SemanticNode, context: LintContext) -> [Finding] {
            var findings: [Finding] = []
            func walk(_ node: SemanticNode, ancestors: [(node: SemanticNode, x: Bool, y: Bool)], frame: AttributeValue?, contained: Bool) {
                let ownFrame = node.attributes["web.frame"]
                let changed = ownFrame != frame
                let fixed = node.attributes["web.position"] == .string("fixed") && !contained
                let chain = changed || fixed ? [] : ancestors
                if node.isVisible, !node.frame.isEmpty, node.role != .spacer {
                    for clip in chain {
                        let ancestor = clip.node
                        let xClips = clip.x
                        let yClips = clip.y
                        let dx = xClips ? max(ancestor.frame.x - node.frame.x, node.frame.maxX - ancestor.frame.maxX) : 0
                        let dy = yClips ? max(ancestor.frame.y - node.frame.y, node.frame.maxY - ancestor.frame.maxY) : 0
                        let amount = max(dx, dy)
                        if amount > ClippedContentRule.tolerance {
                            if let finding = context.makeFinding(rule: Self.id, node: node,
                                message: "'\((node.id.isEmpty ? node.structuralPath : node.id))' extends \(amount) pt outside the CSS clipping bounds of '\((ancestor.id.isEmpty ? ancestor.structuralPath : ancestor.id))'",
                                suggestion: "Keep the content inside the clipped axis or make that axis scrollable.", defaultSeverity: .error) {
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
                var next = chain.map { (node: $0.node, x: $0.x && !scrollX, y: $0.y && !scrollY) }
                let clipsX = Self.clips(node.attributes["web.overflowX"]?.stringValue)
                let clipsY = Self.clips(node.attributes["web.overflowY"]?.stringValue)
                if node.isVisible && (clipsX || clipsY) { next.append((node: node, x: clipsX, y: clipsY)) }
                for child in node.children {
                    walk(child, ancestors: next, frame: ownFrame,
                         contained: (changed ? false : contained) || node.attributes["web.fixedContainer"] == .bool(true))
                }
            }
            walk(root, ancestors: [], frame: nil, contained: false)
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

    static func run(tree: SemanticNode, scenario: String, viewport: Rect) -> Verdict {
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
        var result = RuleEngine.run(rules: sharedRules, on: tree,
            context: LintContext(scenario: scenario, viewport: viewport, requiresProbedNodes: false), includeTree: true)
        result = Verdict(scenario: scenario, findings: evidence.findings + result.findings, tree: tree, timing: result.timing)
        var scopes: [Scope] = []
        var indices: [String: Int] = [:]
        func add(_ source: SemanticNode, scope: Scope, contained: Bool) {
            let index: Int
            if let existing = indices[scope.key] { index = existing }
            else { index = scopes.count; indices[scope.key] = index; scopes.append(scope) }
            if let root = project(source, scope: scope, contained: contained) { scopes[index].roots.append(root) }
        }
        func project(_ source: SemanticNode, scope: Scope, contained: Bool) -> SemanticNode? {
            let frame = source.attributes["web.frame"]?.stringValue ?? scope.frame
            if frame != scope.frame, let bounds = rect(key: "web.documentBounds", in: source.attributes),
               let view = rect(key: "web.documentViewport", in: source.attributes) {
                add(source, scope: Scope(key: "document/" + frame, frame: frame, bounds: bounds, viewport: view), contained: false)
                return nil
            }
            if source.attributes["web.position"] == .string("fixed"), !contained, !scope.fixed {
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
                for child in source.children { add(child, scope: content, contained: childContained) }
                node.children = []
            } else {
                node.children = source.children.compactMap { project($0, scope: scope, contained: childContained) }
            }
            return node
        }
        for child in tree.children {
            let frame = child.attributes["web.frame"]?.stringValue ?? "main"
            let bounds = rect(key: "web.documentBounds", in: child.attributes) ?? viewport
            let view = rect(key: "web.documentViewport", in: child.attributes) ?? viewport
            add(child, scope: Scope(key: "document/" + frame, frame: frame, bounds: bounds, viewport: view), contained: false)
        }
        var findings = result.findings
        var elapsed = (evidence.timing.evaluateMs ?? 0) + (result.timing.evaluateMs ?? 0)
        // Reachable content in another scroll scope must not appear to paint
        // over the surrounding document. Judge each scope internally, then its
        // visible paint contribution in the enclosing hierarchy. This preserves
        // fixed/flow overlap without comparing an iframe's unpainted below-fold
        // content to unrelated content outside the iframe.
        var overlapRoots = [tree]
        for node in tree.flattened() where !node.children.isEmpty && node.attributes["web.frame"] != nil {
            if rect(key: "web.scrollBounds", in: node.attributes) != nil || node.children.contains(where: {
                $0.attributes["web.frame"] != node.attributes["web.frame"]
            }) {
                overlapRoots.append(SemanticNode(id: tree.id, role: .container, frame: node.frame, children: node.children))
            }
        }
        for root in overlapRoots {
            var originals: [String: String] = [:]
            let fragmented = fragmentProjection(root, originals: &originals)
            let paint = paintProjection(fragmented)
            let report = RuleEngine.run(rules: [SiblingOverlapRule(), ContentOverlapRule()], on: paint,
                context: LintContext(scenario: scenario, viewport: viewport, requiresProbedNodes: false))
            for source in report.findings {
                var finding = source
                if let original = originals[finding.nodeID] { finding.nodeID = original }
                func remap(_ message: String) -> String {
                    message.split(separator: "'", omittingEmptySubsequences: false).enumerated().map { index, part in
                        index.isMultiple(of: 2) ? String(part) : (originals[String(part)] ?? String(part))
                    }.joined(separator: "'")
                }
                finding.message = remap(finding.message)
                finding.suggestion = finding.suggestion.map(remap)
                if !findings.contains(finding) { findings.append(finding) }
            }
            elapsed += report.timing.evaluateMs ?? 0
        }
        for scope in scopes {
            let projection = SemanticNode(id: tree.id, role: .container, frame: scope.bounds, children: scope.roots)
            let context = LintContext(scenario: scenario, viewport: scope.bounds, requiresProbedNodes: false)
            let report = RuleEngine.run(rules: boundaryRules, on: projection, context: context)
            findings += report.findings; elapsed += report.timing.evaluateMs ?? 0
        }
        // Positive out-of-flow boxes can enlarge browser scroll extents. This
        // adapter measures reachability, not author intent about that placement.
        result = Verdict(scenario: scenario, findings: findings, tree: tree, timing: .init(evaluateMs: elapsed))
        return result
    }
}
