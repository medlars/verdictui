import Foundation
import VerdictUIKernel

/// The fields consumed from CDP's columnar DOMSnapshot format. Unknown browser
/// fields are ignored; malformed columns fail closed instead of yielding PASS.
public enum DOMSnapshotAssembly {
    public static let computedStyles = ["display", "visibility", "opacity", "z-index"]

    public static func assemble(
        _ payload: [String: CDPValue], viewport: Rect, redacting secrets: [String] = []
    ) throws -> SemanticNode {
        guard case let .array(rawStrings) = payload["strings"],
            case let .array(documents) = payload["documents"], !documents.isEmpty
        else { throw malformed("missing strings or documents") }
        let strings = try rawStrings.map { value -> String in
            guard case let .string(text) = value else { throw malformed("non-string string table") }
            return text
        }
        var children: [SemanticNode] = []
        for document in documents {
            guard case let .object(fields) = document else { throw malformed("invalid document") }
            children += try buildDocument(fields, strings: strings, secrets: secrets)
        }
        return SemanticNode(id: "web/root", role: .container, frame: viewport, children: children)
            .withAssignedStructuralPaths()
    }

    private static func buildDocument(
        _ document: [String: CDPValue], strings: [String], secrets: [String]
    ) throws -> [SemanticNode] {
        guard case let .object(nodes) = document["nodes"],
            case let .object(layout) = document["layout"] else { throw malformed("missing node/layout tables") }
        let parents = try integers(nodes["parentIndex"])
        let types = try integers(nodes["nodeType"])
        let names = try integers(nodes["nodeName"])
        let values = try integers(nodes["nodeValue"])
        let backend = try integers(nodes["backendNodeId"])
        guard parents.count <= 100_000, types.count == parents.count,
            names.count == parents.count, values.count == parents.count, backend.count == parents.count,
            case let .array(attributes) = nodes["attributes"], attributes.count == parents.count
        else { throw malformed("mismatched or oversized node columns") }
        let layoutNodes = try integers(layout["nodeIndex"])
        guard case let .array(bounds) = layout["bounds"], case let .array(styles) = layout["styles"],
            bounds.count == layoutNodes.count, styles.count == layoutNodes.count
        else { throw malformed("mismatched layout columns") }
        let scrollX = document["scrollOffsetX"]?.doubleValue ?? 0
        let scrollY = document["scrollOffsetY"]?.doubleValue ?? 0
        var geometry: [Int: (Rect, [String])] = [:]
        for (offset, index) in layoutNodes.enumerated() {
            guard parents.indices.contains(index), geometry[index] == nil else {
                throw malformed("invalid or duplicate layout index")
            }
            let frame = try rectangle(bounds[offset])
            var style = try integers(styles[offset]).map { try string($0, in: strings) }
            if style.isEmpty && types[index] == 9 { style = ["block", "visible", "1", "auto"] }
            guard style.count == computedStyles.count else { throw malformed("missing computed styles") }
            geometry[index] = (Rect(x: frame.x - scrollX, y: frame.y - scrollY,
                                   width: frame.width, height: frame.height), style)
        }
        var textBoxes: [Int: [Rect]] = [:]
        if case let .object(boxes) = document["textBoxes"] {
            let indices = try integers(boxes["layoutIndex"])
            guard case let .array(boxBounds) = boxes["bounds"], indices.count == boxBounds.count else {
                throw malformed("mismatched text boxes")
            }
            for (offset, index) in indices.enumerated() {
                guard layoutNodes.indices.contains(index) else { throw malformed("invalid text box index") }
                textBoxes[layoutNodes[index], default: []].append(try rectangle(boxBounds[offset]))
            }
        }
        var assembled: [Int: [SemanticNode]] = [:]
        var seenIDs: Set<Int> = []
        for index in parents.indices.reversed() {
            let parent = parents[index]
            guard parent == -1 || (parent >= 0 && parent < index), backend[index] > 0,
                seenIDs.insert(backend[index]).inserted else {
                throw malformed("invalid parent topology or backend identity")
            }
            let tag = try string(names[index], in: strings).lowercased()
            var descendants = assembled[index] ?? []
            if let (frame, style) = geometry[index], types[index] == 1 || types[index] == 3 {
                let rawAttrs = try integers(attributes[index])
                guard rawAttrs.count.isMultiple(of: 2) else { throw malformed("odd attribute column") }
                var attrs: [String: String] = [:]
                for pair in stride(from: 0, to: rawAttrs.count, by: 2) {
                    attrs[try string(rawAttrs[pair], in: strings)] = try string(rawAttrs[pair + 1], in: strings)
                }
                let rawText = types[index] == 3 ? try string(values[index], in: strings) : nil
                let role = role(tag: tag, attributes: attrs)
                let visible = style[0] != "none" && style[1] != "hidden" && style[1] != "collapse"
                    && (Double(style[2]) ?? 1) > 0 && attrs["aria-hidden"] != "true"
                // Document/body boxes are browser scaffolding, not evidence. An
                // empty page must retain the kernel's vacuous-verdict failure.
                if tag != "html" && tag != "body" && !(types[index] == 3 && rawText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false) {
                    var metadata: [String: AttributeValue] = ["web.tag": .string(tag)]
                    if let domID = attrs["id"] { metadata["web.id"] = .string(WebRedaction.clean(domID, secrets: secrets)) }
                    if let label = attrs["aria-label"] ?? attrs["alt"] ?? attrs["placeholder"] {
                        metadata["accessibilityLabel"] = .string(WebRedaction.clean(label, secrets: secrets))
                    }
                    metadata["web.enabled"] = .bool(attrs["disabled"] == nil && attrs["aria-disabled"] != "true")
                    metadata["web.password"] = .bool(attrs["type"]?.lowercased() == "password")
                    if role == .textField { metadata["web.value"] = .string("[REDACTED]") }
                    if role == .toggle { metadata["isOn"] = .bool(attrs["checked"] != nil || attrs["aria-checked"] == "true") }
                    let boxes = textBoxes[index] ?? []
                    let lineCount = Set(boxes.map { Int(($0.y * 2).rounded()) }).count
                    let metrics = boxes.isEmpty ? nil : TextMetrics(
                        intrinsicWidth: boxes.reduce(0) { $0 + $1.width },
                        renderedLineCount: lineCount, idealLineCount: lineCount)
                    let node = SemanticNode(
                        id: "web/\(backend[index])", role: role, frame: frame,
                        text: rawText.map { WebRedaction.clean($0, secrets: secrets) },
                        attributes: metadata, isVisible: visible,
                        zIndex: Double(style[3]), textMetrics: metrics, children: descendants)
                    descendants = [node]
                }
            }
            if parent >= 0 { assembled[parent, default: []].insert(contentsOf: descendants, at: 0) }
            else { assembled[-1, default: []].insert(contentsOf: descendants, at: 0) }
        }
        return assembled[-1] ?? []
    }

    static func role(tag: String, attributes: [String: String]) -> Role {
        if let aria = attributes["role"]?.split(separator: " ").first.map(String.init) {
            switch aria {
            case "button", "link", "tab": return .button
            case "checkbox", "radio", "switch": return .toggle
            case "slider", "spinbutton": return .slider
            case "textbox", "searchbox", "combobox": return .textField
            case "img": return .image
            case "list", "table", "grid": return .list
            case "listitem", "row": return .listRow
            case "navigation": return .navigation
            case "tablist": return .tabBar
            case "menu", "menubar": return .menu
            case "heading", "paragraph", "status", "alert": return .text
            case "none", "presentation", "group", "region", "main", "form": return .container
            default: return .custom("web.\(aria)")
            }
        }
        switch tag {
        case "#text": return .text
        case "button", "a", "summary": return .button
        case "textarea", "select": return .textField
        case "input":
            switch attributes["type"]?.lowercased() ?? "text" {
            case "checkbox", "radio": return .toggle
            case "range", "number": return .slider
            case "submit", "button", "reset", "image": return .button
            default: return .textField
            }
        case "img", "svg": return .image
        case "ul", "ol", "table": return .list
        case "li", "tr": return .listRow
        case "nav": return .navigation
        default: return .container
        }
    }

    private static func integers(_ value: CDPValue?) throws -> [Int] {
        guard case let .array(values) = value else { throw malformed("missing integer column") }
        return try values.map {
            guard case let .integer(number) = $0, let exact = Int(exactly: number) else {
                throw malformed("invalid integer index")
            }
            return exact
        }
    }

    private static func string(_ index: Int, in strings: [String]) throws -> String {
        guard strings.indices.contains(index) else { throw malformed("string index out of range") }
        return strings[index]
    }

    private static func rectangle(_ value: CDPValue) throws -> Rect {
        guard case let .array(values) = value, values.count == 4 else { throw malformed("invalid rectangle") }
        let coordinates = try values.map { element -> Double in
            guard let value = element.doubleValue, value.isFinite else { throw malformed("non-finite rectangle") }
            return value
        }
        guard coordinates[2] >= 0, coordinates[3] >= 0 else { throw malformed("negative rectangle extent") }
        return Rect(x: coordinates[0], y: coordinates[1], width: coordinates[2], height: coordinates[3])
    }

    private static func malformed(_ reason: String) -> WebBrowserError {
        .invalidCDPResponse(reason: "DOM snapshot: \(reason)")
    }
}

extension CDPValue {
    var doubleValue: Double? {
        switch self { case let .number(n): n; case let .integer(n): Double(n); default: nil }
    }
    var stringValue: String? { if case let .string(s) = self { s } else { nil } }
}
