import VerdictUIKernel

/// DOMSnapshot geometry is document-relative; CDP input coordinates are relative
/// to the root page viewport. Preserve frame identity while moving child boxes
/// through the iframe's border and scale into their enclosing coordinate space.
enum WebFrameGeometry {
    static func markInputCoordinates(_ source: SemanticNode, scrollX: Double, scrollY: Double) -> SemanticNode {
        var node = source
        node.attributes["web.inputScrollX"] = .number(scrollX)
        node.attributes["web.inputScrollY"] = .number(scrollY)
        node.attributes["web.inputX"] = .number(node.frame.x)
        node.attributes["web.inputY"] = .number(node.frame.y)
        node.attributes["web.inputWidth"] = .number(node.frame.width)
        node.attributes["web.inputHeight"] = .number(node.frame.height)
        node.children = source.children.map { markInputCoordinates($0, scrollX: scrollX, scrollY: scrollY) }
        return node
    }

    /// Chromium's getNodeForLocation consumes document coordinates; input and
    /// getContentQuads consume viewport coordinates. Preserve each renderer's
    /// root scroll offset even when its same-process child frames are embedded.
    static func hitPoint(x: Double, y: Double, attributes: [String: AttributeValue]) throws -> [String: CDPValue] {
        guard let sx = attributes["web.inputScrollX"]?.numberValue, let sy = attributes["web.inputScrollY"]?.numberValue,
              let px = Int64(exactly: (x + sx).rounded(.towardZero)),
              let py = Int64(exactly: (y + sy).rounded(.towardZero)) else {
            throw WebBrowserError.invalidCDPResponse(reason: "invalid document hit-test coordinates")
        }
        return ["x": .integer(px), "y": .integer(py)]
    }

    static func embedding(_ source: SemanticNode, in owner: SemanticNode) throws -> SemanticNode {
        var child = source
        if WebLint.rect(key: "web.documentViewport", in: child.attributes) != nil {
            // HTML.clientHeight can be the full document height in quirks mode.
            // The frame owner's measured client box is the child viewport.
            let viewport = try WebLint.checkedRect(x: 0, y: 0,
                width: owner.attributes["web.contentWidth"]?.numberValue ?? owner.frame.width,
                height: owner.attributes["web.contentHeight"]?.numberValue ?? owner.frame.height)
            WebLint.store(viewport, key: "web.documentViewport", in: &child.attributes)
        }
        return try transform(child,
                  x: owner.attributes["web.contentX"]?.numberValue ?? owner.frame.x,
                  y: owner.attributes["web.contentY"]?.numberValue ?? owner.frame.y,
                  scaleX: owner.attributes["web.scaleX"]?.numberValue ?? 1,
                  scaleY: owner.attributes["web.scaleY"]?.numberValue ?? 1,
                  visible: owner.isVisible)
    }

    private static func transform(_ source: SemanticNode, x: Double, y: Double,
                                  scaleX: Double, scaleY: Double, visible: Bool) throws -> SemanticNode {
        var node = source
        node.frame = try WebLint.checkedRect(x: x + source.frame.x * scaleX, y: y + source.frame.y * scaleY,
                          width: source.frame.width * scaleX, height: source.frame.height * scaleY)
        // CSS visibility is independent of current scroll position. CDP scrolls
        // a reachable target before input; clipping here made that impossible.
        node.isVisible = visible && source.isVisible
        for key in ["web.documentBounds", "web.documentViewport", "web.scrollBounds", "web.scrollViewport"] {
            if let rect = WebLint.rect(key: key, in: node.attributes) {
                let shifted = try WebLint.checkedRect(x: x + rect.x * scaleX, y: y + rect.y * scaleY,
                                                      width: rect.width * scaleX, height: rect.height * scaleY)
                WebLint.store(shifted, key: key, in: &node.attributes)
            }
        }
        if let contentX = node.attributes["web.contentX"]?.numberValue { node.attributes["web.contentX"] = .number(x + contentX * scaleX) }
        if let contentY = node.attributes["web.contentY"]?.numberValue { node.attributes["web.contentY"] = .number(y + contentY * scaleY) }
        if let sx = node.attributes["web.scaleX"]?.numberValue { node.attributes["web.scaleX"] = .number(sx * scaleX) }
        if let sy = node.attributes["web.scaleY"]?.numberValue { node.attributes["web.scaleY"] = .number(sy * scaleY) }
        if var metrics = node.textMetrics { metrics.intrinsicWidth *= scaleX; node.textMetrics = metrics }
        node.children = try source.children.map { try transform($0, x: x, y: y, scaleX: scaleX, scaleY: scaleY,
                                                       visible: visible) }
        return node
    }

    static func graft(_ children: [SemanticNode], ownerBackend: Double, ownerFrame: String,
                      into source: SemanticNode) throws -> (SemanticNode, Bool) {
        var node = source
        if node.attributes["web.backendID"]?.numberValue == ownerBackend && node.attributes["web.frame"]?.stringValue == ownerFrame {
            node.children += try children.map { try embedding($0, in: node) }
            return (node, true)
        }
        var found = false
        node.children = try source.children.map {
            let (child, didFind) = try graft(children, ownerBackend: ownerBackend, ownerFrame: ownerFrame, into: $0)
            found = found || didFind
            return child
        }
        return (node, found)
    }
}
