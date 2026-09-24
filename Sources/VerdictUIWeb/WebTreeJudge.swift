import Foundation
import VerdictUIKernel

/// Explicit admission for a caller's observed DOM tree. This validates structure,
/// not observer identity. Native trees never select browser semantics implicitly.
public enum WebTreeJudge {
    public static let maximumBytes = 8 * 1024 * 1024
    private static func invalid(_ detail: String) -> WebBrowserError {
        .invalidWebOperation(reason: "invalid observed DOM tree: " + detail)
    }

    public static func judge(data: Data, scenario: String) throws -> Verdict {
        guard data.count <= maximumBytes else { throw invalid("byte budget exceeded") }
        // Inspect the untyped topology before recursive Codable allocation.
        let object = try JSONSerialization.jsonObject(with: data)
        var pending: [(Any, Int)] = [(object, 0)]
        var count = 0
        while let (raw, depth) = pending.popLast() {
            count += 1
            guard count <= 10_000, depth <= 100, let node = raw as? [String: Any],
                  node["children"] == nil || node["children"] is [Any] else { throw invalid("topology budget or children") }
            pending += (node["children"] as? [Any] ?? []).map { ($0, depth + 1) }
        }
        return try judge(tree: JSONDecoder().decode(SemanticNode.self, from: data), scenario: scenario)
    }

    public static func judge(tree: SemanticNode, scenario: String) throws -> Verdict {
        guard !scenario.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, scenario.utf8.count <= 4096,
              tree.frame.x == 0, tree.frame.y == 0, tree.frame.width > 0, tree.frame.height > 0 else {
            throw invalid("scenario or viewport")
        }
        var pending: [(SemanticNode, Int, SemanticNode?, Set<String>, Bool)] = [(tree, 0, nil, [], false)]
        var count = 0
        var fragments = 0
        var textBytes = 0
        var ids = Set<String>()
        while let (node, level, parent, ancestorFrames, hiddenByAnchor) = pending.popLast() {
            count += 1
            let a = node.attributes
            guard count <= 10_000, level <= 100, a.count <= 512,
                  !hiddenByAnchor || !node.isVisible else { throw invalid("node budget or hidden frame descendants") }
            let scaffold = level == 0 && node.id == "web/root" && node.role == .container
                && node.text == nil && node.isVisible && node.zIndex == nil && node.textMetrics == nil
                && Set(a.keys) == ["web.inputScrollX", "web.inputScrollY"]
                && a["web.inputScrollX"]?.numberValue != nil && a["web.inputScrollY"]?.numberValue != nil
            var hiddenAnchor = false
            var frames = ancestorFrames
            if !scaffold {
                guard let rawDepth = a["web.domDepth"]?.numberValue, let depth = Int(exactly: rawDepth),
                      (0...256).contains(depth),
                      let tag = a["web.tag"]?.stringValue, !tag.isEmpty, tag.utf8.count <= 100,
                      let frame = a["web.frame"]?.stringValue, !frame.isEmpty, frame.utf8.count <= 200 else {
                    throw invalid("missing measured DOM metadata or depth budget")
                }
                if let parentFrame = parent?.attributes["web.frame"]?.stringValue {
                    if frame == parentFrame {
                        guard let parentDepth = parent?.attributes["web.domDepth"]?.numberValue,
                              Double(depth) > parentDepth else { throw invalid("reversed DOM ancestry") }
                    } else {
                        // CDP raw DOM depths restart in each document. Only an
                        // observed frame owner with measured child bounds is a boundary.
                        guard ["iframe", "frame"].contains(parent?.attributes["web.tag"]?.stringValue ?? ""),
                              !ancestorFrames.contains(frame),
                              WebLint.rect(key: "web.documentBounds", in: a) != nil,
                              let viewport = WebLint.rect(key: "web.documentViewport", in: a),
                              !node.isVisible || (viewport.width > 0 && viewport.height > 0) else {
                            throw invalid("unmeasured document boundary")
                        }
                    }
                }
                frames.insert(frame)
                for key in ["web.interactionMeasured", "web.isClickable", "web.isFocusable", "web.hasInteractiveAncestor"] {
                    guard case .bool = a[key] else { throw invalid("interaction observation absent") }
                }
                // CDP has no LayoutObject/CSS for display:none frame owners,
                // but retains their identity for hidden child-document grafting.
                hiddenAnchor = !node.isVisible && node.role == .container && node.text == nil
                    && node.frame.width == 0 && node.frame.height == 0 && ["iframe", "frame"].contains(tag)
                    && (a["web.backendID"]?.numberValue.flatMap(Int.init(exactly:)) ?? 0) > 0
                    && ["web.position", "web.overflowX", "web.overflowY"].allSatisfy { a[$0] == nil }
                if !hiddenAnchor {
                    guard ["static", "relative", "absolute", "fixed", "sticky"].contains(a["web.position"]?.stringValue ?? ""),
                          ["visible", "hidden", "clip", "scroll", "auto"].contains(a["web.overflowX"]?.stringValue ?? ""),
                          ["visible", "hidden", "clip", "scroll", "auto"].contains(a["web.overflowY"]?.stringValue ?? "") else {
                        throw invalid("missing measured CSS metadata")
                    }
                }
            }
            for value in a.values {
                if case let .number(number) = value, !number.isFinite { throw invalid("nonfinite attribute") }
                if case let .string(string) = value { textBytes += string.utf8.count }
            }
            textBytes += node.id.utf8.count + (node.text?.utf8.count ?? 0)
            guard textBytes <= maximumBytes, node.zIndex?.isFinite != false else { throw invalid("text or layer budget") }
            if !node.id.isEmpty, !ids.insert(node.id).inserted { throw invalid("duplicate identity") }
            _ = try WebLint.checkedRect(x: node.frame.x, y: node.frame.y, width: node.frame.width, height: node.frame.height)
            let positionKeys = ["web.positioningRootDepth", "web.containingBlockDepth"]
            if positionKeys.contains(where: { a[$0] != nil }), WebPaintSemantics.positioningRange(node) == nil {
                throw invalid("positioning interval")
            }
            var rectangles = ["web.documentBounds", "web.documentViewport", "web.scrollBounds", "web.scrollViewport", "web.paintClip"]
            for prefix in ["web.inlineFragment", "web.textFragment"] {
                if let value = a[prefix + "Count"] {
                    guard let number = value.numberValue, let n = Int(exactly: number), (0...10_000).contains(n) else {
                        throw invalid("fragment count")
                    }
                    fragments += n
                    guard fragments <= 100_000 else { throw invalid("fragment budget") }
                    for index in 0..<n {
                        let key = prefix + String(index)
                        guard WebLint.rect(key: key, in: a) != nil else { throw invalid("missing measured fragment") }
                        rectangles.append(key)
                    }
                }
            }
            for key in rectangles where ["X", "Y", "Width", "Height"].contains(where: { a[key + $0] != nil }) {
                guard let rect = WebLint.rect(key: key, in: a) else { throw invalid("partial rectangle") }
                _ = try WebLint.checkedRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
            }
            pending += node.children.map { ($0, level + 1, node, frames, hiddenByAnchor || hiddenAnchor) }
        }
        return try WebLint.run(tree: tree.withAssignedStructuralPaths(), scenario: scenario, viewport: tree.frame)
    }
}
