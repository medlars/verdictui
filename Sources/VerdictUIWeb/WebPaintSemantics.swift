import Foundation
import VerdictUIKernel

/// The semantic layout subject is not necessarily every object that paints.
/// These classifications never change the returned observation or prove that
/// a presentation layer is harmless; ambiguous paint remains a cited warning.
enum WebPaintSemantics {
    static let unverifiedRule = "web-paint-unverified"
    static let presentationKey = "web.presentationOnly"
    private static let presentationTags: Set<String> = ["div", "span", "::before", "::after"]
    private static let graphicTags: Set<String> = [
        "path", "rect", "circle", "ellipse", "line", "polyline", "polygon", "g",
    ]

    struct Projection {
        var tree: SemanticNode
        var findings: [Finding]
    }

    static func project(_ source: SemanticNode, context: LintContext) -> Projection {
        var findings: [Finding] = []
        func nonempty(_ value: String?) -> Bool {
            value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
        func walk(_ source: SemanticNode, interactiveAncestor: Bool) -> (SemanticNode, Bool, Bool) {
            let attributes = source.attributes
            let interactive = source.role.isInteractive || attributes["web.isClickable"] == .bool(true)
                || attributes["web.isFocusable"] == .bool(true)
            let inert = attributes["web.interactionMeasured"] == .bool(true)
                && attributes["web.isClickable"] == .bool(false) && attributes["web.isFocusable"] == .bool(false)
            let unnamed = !nonempty(source.text) && !nonempty(attributes["accessibilityLabel"]?.stringValue)
            let inheritedInteraction = interactiveAncestor || attributes["web.hasInteractiveAncestor"] == .bool(true)
            let children = source.children.map { walk($0, interactiveAncestor: inheritedInteraction || interactive) }
            let tag = attributes["web.tag"]?.stringValue ?? ""
            let passiveGraphic = inert && unnamed && source.role == .container && graphicTags.contains(tag)
                && children.allSatisfy { $0.1 }
            let presentation = inert && unnamed && source.role == .container && presentationTags.contains(tag)
                && !inheritedInteraction && children.allSatisfy { $0.2 }
            var node = source
            node.attributes.removeValue(forKey: presentationKey)
            if presentation { node.attributes[presentationKey] = .bool(true) }
            node.children = children.map { $0.0 }
            // SVG text, links, foreignObject, labelled graphics, focus targets
            // event listeners and use references each keep the composition non-atomic.
            if tag == "svg", children.allSatisfy({ $0.1 }) {
                let clipX = clips(attributes["web.overflowX"]?.stringValue)
                let clipY = clips(attributes["web.overflowY"]?.stringValue)
                if clipX || clipY {
                    for child in source.children.flatMap({ $0.flattened() }) where child.isVisible && !child.frame.isEmpty {
                        let dx = clipX ? max(source.frame.x - child.frame.x, child.frame.maxX - source.frame.maxX) : 0
                        let dy = clipY ? max(source.frame.y - child.frame.y, child.frame.maxY - source.frame.maxY) : 0
                        if max(dx, dy) > ClippedContentRule.tolerance,
                           !context.isSuppressed(rule: ClippedContentRule.id, on: child),
                           let finding = context.makeFinding(rule: unverifiedRule, node: child,
                            message: "SVG component '\(label(child))' extends beyond '\(label(source))'. Internal vector paint clipping is unverified; this is not an independent UI layout defect.",
                            suggestion: "Inspect the rendered SVG if internal stroke or fill clipping matters.", defaultSeverity: .warning) {
                            findings.append(finding)
                        }
                    }
                }
                node.children = []
            }
            return (node, passiveGraphic, presentation)
        }
        let tree = walk(source, interactiveAncestor: false).0
        return Projection(tree: tree, findings: findings)
    }

    static func label(_ node: SemanticNode) -> String { node.id.isEmpty ? node.structuralPath : node.id }
    static func clips(_ value: String?) -> Bool { value == "hidden" || value == "clip" }
    static func isPresentation(_ node: SemanticNode) -> Bool { node.attributes[presentationKey] == .bool(true) }

    static func finding(rule: String, node: SemanticNode, other: SemanticNode? = nil,
                        message: String, suggestion: String, context: LintContext) -> Finding? {
        guard !context.isSuppressed(rule: rule, on: node) else { return nil }
        if isPresentation(node) || other.map(isPresentation) == true {
            return context.makeFinding(rule: unverifiedRule, node: node,
                message: message + ". Presentation-layer paint is unverified; geometry alone establishes neither a functional defect nor harmlessness.",
                suggestion: "Inspect the composed paint and confirm that meaningful content remains visible and usable.", defaultSeverity: .warning)
        }
        return context.makeFinding(rule: rule, node: node, message: message,
                                   suggestion: suggestion, defaultSeverity: .error)
    }

    /// Optional axes avoid invented huge rectangles when only one axis clips.
    struct Clip {
        var minX: Double?
        var maxX: Double?
        var minY: Double?
        var maxY: Double?

        init(_ rect: Rect, x: Bool = true, y: Bool = true) {
            minX = x ? rect.x : nil; maxX = x ? rect.maxX : nil
            minY = y ? rect.y : nil; maxY = y ? rect.maxY : nil
        }

        func intersecting(_ other: Clip) -> Clip {
            var result = self
            for key in [\Clip.minX, \Clip.minY] {
                if let value = other[keyPath: key] { result[keyPath: key] = result[keyPath: key].map { max($0, value) } ?? value }
            }
            for key in [\Clip.maxX, \Clip.maxY] {
                if let value = other[keyPath: key] { result[keyPath: key] = result[keyPath: key].map { min($0, value) } ?? value }
            }
            return result
        }

        func applying(to rect: Rect) -> Rect? {
            let x = minX.map { max($0, rect.x) } ?? rect.x
            let y = minY.map { max($0, rect.y) } ?? rect.y
            let right = maxX.map { min($0, rect.maxX) } ?? rect.maxX
            let bottom = maxY.map { min($0, rect.maxY) } ?? rect.maxY
            guard right > x, bottom > y else { return nil }
            return Rect(x: x, y: y, width: right - x, height: bottom - y)
        }

        static func combined(_ clips: Clip?...) -> Clip? {
            clips.compactMap { $0 }.reduce(nil as Clip?) { result, clip in result.map { $0.intersecting(clip) } ?? clip }
        }
    }
}
