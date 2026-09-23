import VerdictUIKernel

/// DOMSnapshot geometry is document-relative; CDP input coordinates are relative
/// to the root page viewport. Preserve frame identity while moving child boxes
/// through the iframe's border and scale into their enclosing coordinate space.
enum WebFrameGeometry {
    static func markInputCoordinates(_ source: SemanticNode) -> SemanticNode {
        var node = source
        node.attributes["web.inputX"] = .number(node.frame.x)
        node.attributes["web.inputY"] = .number(node.frame.y)
        node.attributes["web.inputWidth"] = .number(node.frame.width)
        node.attributes["web.inputHeight"] = .number(node.frame.height)
        node.children = source.children.map(markInputCoordinates)
        return node
    }

    static func embedding(_ source: SemanticNode, in owner: SemanticNode) -> SemanticNode {
        transform(source,
                  x: owner.attributes["web.contentX"]?.numberValue ?? owner.frame.x,
                  y: owner.attributes["web.contentY"]?.numberValue ?? owner.frame.y,
                  scaleX: owner.attributes["web.scaleX"]?.numberValue ?? 1,
                  scaleY: owner.attributes["web.scaleY"]?.numberValue ?? 1,
                  visible: owner.isVisible, clip: owner.frame)
    }

    private static func transform(_ source: SemanticNode, x: Double, y: Double,
                                  scaleX: Double, scaleY: Double, visible: Bool, clip: Rect) -> SemanticNode {
        var node = source
        node.frame = Rect(x: x + source.frame.x * scaleX, y: y + source.frame.y * scaleY,
                          width: source.frame.width * scaleX, height: source.frame.height * scaleY)
        node.isVisible = visible && source.isVisible && (node.frame.isEmpty || node.frame.intersects(clip))
        if let contentX = node.attributes["web.contentX"]?.numberValue { node.attributes["web.contentX"] = .number(x + contentX * scaleX) }
        if let contentY = node.attributes["web.contentY"]?.numberValue { node.attributes["web.contentY"] = .number(y + contentY * scaleY) }
        if let sx = node.attributes["web.scaleX"]?.numberValue { node.attributes["web.scaleX"] = .number(sx * scaleX) }
        if let sy = node.attributes["web.scaleY"]?.numberValue { node.attributes["web.scaleY"] = .number(sy * scaleY) }
        if var metrics = node.textMetrics { metrics.intrinsicWidth *= scaleX; node.textMetrics = metrics }
        node.children = source.children.map { transform($0, x: x, y: y, scaleX: scaleX, scaleY: scaleY,
                                                       visible: visible, clip: clip) }
        return node
    }

    static func graft(_ children: [SemanticNode], ownerBackend: Double, ownerFrame: String,
                      into source: SemanticNode) -> (SemanticNode, Bool) {
        var node = source
        if node.attributes["web.backendID"]?.numberValue == ownerBackend && node.attributes["web.frame"]?.stringValue == ownerFrame {
            node.children += children.map { embedding($0, in: node) }
            return (node, true)
        }
        var found = false
        node.children = source.children.map {
            let (child, didFind) = graft(children, ownerBackend: ownerBackend, ownerFrame: ownerFrame, into: $0)
            found = found || didFind
            return child
        }
        return (node, found)
    }
}
