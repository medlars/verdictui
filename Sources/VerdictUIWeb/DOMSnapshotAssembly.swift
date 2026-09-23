import Foundation
import VerdictUIKernel

/// The fields consumed from CDP's columnar DOMSnapshot format. Unknown browser
/// fields are ignored; malformed columns fail closed instead of yielding PASS.
public enum DOMSnapshotAssembly {
    public static let computedStyles = ["display", "visibility", "opacity", "z-index", "position", "clip", "clip-path",
                                        "overflow-x", "overflow-y", "transform", "filter", "perspective", "contain", "will-change"]

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
        guard documents.count <= 256 else { throw malformed("too many documents") }
        let trees = try documents.map { document -> [SemanticNode] in
            guard case let .object(fields) = document else { throw malformed("invalid document") }
            return try buildDocument(fields, strings: strings, secrets: secrets, viewport: viewport)
        }
        var visited: Set<Int> = [0]
        func embed(_ source: SemanticNode, chain: Set<Int>) throws -> SemanticNode {
            var node = source
            node.children = try node.children.map { try embed($0, chain: chain) }
            if let raw = node.attributes["web.documentIndex"]?.numberValue, let index = Int(exactly: raw) {
                guard trees.indices.contains(index), !chain.contains(index), visited.insert(index).inserted else {
                    throw malformed("invalid embedded document graph")
                }
                let descendants = try trees[index].map { try embed($0, chain: chain.union([index])) }
                node.children += try descendants.map { try WebFrameGeometry.embedding($0, in: node) }
            }
            return node
        }
        let children = try trees[0].map { try embed($0, chain: [0]) }
        guard visited.count == trees.count else { throw malformed("orphaned embedded document") }
        guard case let .object(main) = documents[0], let scrollX = main["scrollOffsetX"]?.doubleValue,
              let scrollY = main["scrollOffsetY"]?.doubleValue else { throw malformed("missing root scroll coordinates") }
        let input: [String: AttributeValue] = ["web.inputScrollX": .number(scrollX), "web.inputScrollY": .number(scrollY)]
        return SemanticNode(id: "web/root", role: .container, frame: viewport, attributes: input,
                            children: children.map { WebFrameGeometry.markInputCoordinates($0, scrollX: scrollX, scrollY: scrollY) })
            .withAssignedStructuralPaths()
    }

    private static func buildDocument(
        _ document: [String: CDPValue], strings: [String], secrets: [String], viewport: Rect
    ) throws -> [SemanticNode] {
        guard case let .object(nodes) = document["nodes"],
            case let .object(layout) = document["layout"] else { throw malformed("missing node/layout tables") }
        let frameID: String
        if case let .integer(index) = document["frameId"], let exact = Int(exactly: index) {
            frameID = try string(exact, in: strings)
        } else { frameID = "main" }
        let embedded = try rareIntegers(nodes["contentDocumentIndex"])
        let parents = try integers(nodes["parentIndex"])
        let types = try integers(nodes["nodeType"])
        let names = try integers(nodes["nodeName"])
        let values = try integers(nodes["nodeValue"])
        let backend = try integers(nodes["backendNodeId"])
        guard parents.count <= 100_000, types.count == parents.count,
            names.count == parents.count, values.count == parents.count, backend.count == parents.count,
            case let .array(attributes) = nodes["attributes"], attributes.count == parents.count
        else { throw malformed("mismatched or oversized node columns") }
        let clickable = try clickableIndices(nodes["isClickable"], count: parents.count)
        var depths: [Int] = []
        for (index, parent) in parents.enumerated() {
            guard parent == -1 || (parent >= 0 && parent < index) else { throw malformed("invalid parent topology") }
            let depth = parent == -1 ? 0 : depths[parent] + 1
            guard depth <= 256 else { throw malformed("node hierarchy exceeds depth limit") }
            depths.append(depth)
        }
        let tags = try names.map { try string($0, in: strings).lowercased() }
        // CDP uses -1 for an absent or empty string value.
        let nodeValues = try values.enumerated().map { types[$0.offset] == 3 && $0.element != -1 ? try string($0.element, in: strings) : "" }
        let nodeAttributes = try attributes.map { value -> [String: String] in
            let rawAttrs = try integers(value)
            guard rawAttrs.count.isMultiple(of: 2) else { throw malformed("odd attribute column") }
            var attrs: [String: String] = [:]
            for pair in stride(from: 0, to: rawAttrs.count, by: 2) {
                let valueIndex = rawAttrs[pair + 1]
                attrs[try string(rawAttrs[pair], in: strings)] = valueIndex == -1 ? "" : try string(valueIndex, in: strings)
            }
            return attrs
        }
        let focusableNodes = parents.indices.map { types[$0] == 1 && focusable(tag: tags[$0], attributes: nodeAttributes[$0]) }
        // html/body and display:contents can be omitted from the semantic tree.
        // Preserve their interaction evidence before that omission, in O(nodes).
        var interactiveAncestors: [Bool] = []
        for parent in parents {
            interactiveAncestors.append(parent >= 0 && (interactiveAncestors[parent] || clickable.contains(parent) || focusableNodes[parent]))
        }
        let accessibleNames = DOMAccessibleNames.resolve(tags: tags, types: types, values: nodeValues,
                                                         attributes: nodeAttributes, parents: parents)
        // Repeated DOM indices are valid, so bound rows independently of the
        // 100,000-node budget that previously bounded unique layout indices.
        guard case let .array(rawLayoutNodes) = layout["nodeIndex"], rawLayoutNodes.count <= 100_000 else {
            throw malformed("missing or oversized layout index column")
        }
        let layoutNodes = try integers(.array(rawLayoutNodes))
        guard case let .array(bounds) = layout["bounds"], case let .array(styles) = layout["styles"],
            bounds.count == layoutNodes.count, styles.count == layoutNodes.count
        else { throw malformed("mismatched layout columns") }
        guard let scrollX = document["scrollOffsetX"]?.doubleValue,
            let scrollY = document["scrollOffsetY"]?.doubleValue,
            let contentWidth = document["contentWidth"]?.doubleValue,
            let contentHeight = document["contentHeight"]?.doubleValue else {
            throw malformed("missing document scroll extent")
        }
        let documentBounds = try WebLint.checkedRect(x: -scrollX, y: -scrollY, width: contentWidth, height: contentHeight)
        let documentViewport = viewport
        var geometry: [Int: (Rect, [String])] = [:]
        var clientRects: [Int: Rect] = [:]
        var offsetRects: [Int: Rect] = [:]
        var scrollRects: [Int: Rect] = [:]
        for (offset, index) in layoutNodes.enumerated() {
            guard parents.indices.contains(index) else {
                throw malformed("invalid layout index")
            }
            let frame = try rectangle(bounds[offset])
            if case let .array(rects) = layout["clientRects"], rects.indices.contains(offset), case let .array(values) = rects[offset], !values.isEmpty {
                clientRects[index] = try rectangle(rects[offset])
            }
            if case let .array(rects) = layout["offsetRects"], rects.indices.contains(offset), case let .array(values) = rects[offset], !values.isEmpty {
                offsetRects[index] = try rectangle(rects[offset])
            }
            if case let .array(rects) = layout["scrollRects"], rects.indices.contains(offset), case let .array(values) = rects[offset], !values.isEmpty {
                scrollRects[index] = try rectangle(rects[offset])
            }
            var style = try integers(styles[offset]).map { try string($0, in: strings) }
            if style.isEmpty && types[index] == 9 { style = ["block", "visible", "1", "auto", "static", "auto", "none", "visible", "visible", "none", "none", "none", "none", "auto"] }
            guard style.count == computedStyles.count else { throw malformed("missing computed styles") }
            let shifted = Rect(x: frame.x - scrollX, y: frame.y - scrollY,
                               width: frame.width, height: frame.height)
            guard shifted.x.isFinite, shifted.y.isFinite, shifted.maxX.isFinite, shifted.maxY.isFinite else {
                throw malformed("layout coordinate overflow")
            }
            if let (previous, previousStyle) = geometry[index] {
                // Chromium BuildLayoutTreeNode recursively emits anonymous
                // pseudo-element children with the same DOM index. Every row
                // uses BuildStylesForNode(node), while its bounds may differ.
                // https://github.com/chromium/chromium/blob/main/third_party/blink/renderer/core/inspector/inspector_dom_snapshot_agent.cc
                guard previousStyle == style else { throw malformed("conflicting layout styles for DOM node") }
                geometry[index] = (try union(previous, shifted), style)
            } else {
                geometry[index] = (shifted, style)
            }
        }
        var textBoxes: [Int: [Rect]] = [:]
        if case let .object(boxes) = document["textBoxes"] {
            guard case let .array(rawIndices) = boxes["layoutIndex"], rawIndices.count <= 100_000 else {
                throw malformed("missing or oversized text box index column")
            }
            let indices = try integers(.array(rawIndices))
            guard case let .array(boxBounds) = boxes["bounds"], indices.count == boxBounds.count else {
                throw malformed("mismatched text boxes")
            }
            for (offset, index) in indices.enumerated() {
                guard layoutNodes.indices.contains(index) else { throw malformed("invalid text box index") }
                textBoxes[layoutNodes[index], default: []].append(try rectangle(boxBounds[offset]))
            }
        }
        let inlineGeometry: [String: CDPValue]?
        if let supplied = document["verdictInlineFragments"] {
            guard case let .object(records) = supplied, records.count <= 4096 else {
                throw malformed("invalid inline fragment table")
            }
            inlineGeometry = records
        } else { inlineGeometry = nil }
        var consumedInline: Set<String> = []
        var inlineFragmentCount = 0
        var assembled: [Int: [SemanticNode]] = [:]
        var seenIDs: Set<Int> = []
        for index in parents.indices.reversed() {
            let parent = parents[index]
            guard parent == -1 || (parent >= 0 && parent < index), backend[index] > 0,
                seenIDs.insert(backend[index]).inserted else {
                throw malformed("invalid parent topology or backend identity")
            }
            let tag = tags[index]
            var descendants = assembled[index] ?? []
            if geometry[index] == nil && types[index] == 1 && (tag == "iframe" || tag == "frame") {
                // CDP retains frame-owner DOM identity when display:none removes
                // its LayoutObject. Keep an invisible anchor for document/session
                // grafting; generic display:contents nodes may have visible children.
                var metadata: [String: AttributeValue] = [
                    "web.tag": .string(tag), "web.backendID": .number(Double(backend[index])),
                    "web.frame": .string(frameID),
                    "web.isClickable": .bool(clickable.contains(index)),
                    "web.isFocusable": .bool(focusableNodes[index]),
                    "web.hasInteractiveAncestor": .bool(interactiveAncestors[index]),
                    "web.interactionMeasured": .bool(nodes["isClickable"] != nil),
                ]
                if let embedded = embedded[index] { metadata["web.documentIndex"] = .number(Double(embedded)) }
                if let domID = nodeAttributes[index]["id"] { metadata["web.id"] = .string(WebRedaction.clean(domID, secrets: secrets)) }
                descendants = [SemanticNode(id: "", role: .container, frame: Rect(x: 0, y: 0, width: 0, height: 0),
                                            attributes: metadata, isVisible: false, children: descendants.map(hidden))]
            } else if let (frame, style) = geometry[index], types[index] == 1 || types[index] == 3 {
                let attrs = nodeAttributes[index]
                let rawText = types[index] == 3 ? nodeValues[index] : nil
                let mappedRole = role(tag: tag, attributes: attrs)
                let role: Role
                if case let .custom(raw) = mappedRole { role = .custom(WebRedaction.clean(raw, secrets: secrets)) }
                else { role = mappedRole }
                if role == .textField || tag == "input" || tag == "textarea" { descendants = [] }
                let accessibleName = accessibleNames[index].map { WebRedaction.clean($0, secrets: secrets) }
                let visible = style[0] != "none" && style[1] != "hidden" && style[1] != "collapse"
                    && (Double(style[2]) ?? 1) > 0 && !WebLint.emptyPaint(position: style[4], clip: style[5], clipPath: style[6], frame: frame)
                if !visible { descendants = descendants.map(hidden) }
                // Document/body boxes are browser scaffolding, not evidence. An
                // empty page must retain the kernel's vacuous-verdict failure.
                if tag != "html" && tag != "body" && !(types[index] == 3 && rawText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false) {
                    var metadata: [String: AttributeValue] = ["web.tag": .string(WebRedaction.clean(tag, secrets: secrets)), "web.backendID": .number(Double(backend[index]))]
                    metadata["web.frame"] = .string(frameID)
                    metadata["web.position"] = .string(style[4])
                    metadata["web.isClickable"] = .bool(clickable.contains(index))
                    metadata["web.isFocusable"] = .bool(focusableNodes[index])
                    metadata["web.hasInteractiveAncestor"] = .bool(interactiveAncestors[index])
                    metadata["web.interactionMeasured"] = .bool(nodes["isClickable"] != nil)
                    if types[index] == 1 && style[0] == "inline" && !tag.hasPrefix("::") {
                        metadata["web.inlineCandidate"] = .bool(true)
                        if let inlineGeometry {
                            let key = String(backend[index])
                            guard let measured = inlineGeometry[key] else { throw malformed("missing inline border fragments") }
                            consumedInline.insert(key)
                            if measured == .null {
                                metadata["web.inlineNonHTML"] = .bool(true)
                            } else {
                                guard case let .array(raw) = measured, !raw.isEmpty,
                                      raw.count <= 100_000 - inlineFragmentCount else {
                                    throw malformed("invalid or oversized inline border fragments")
                                }
                                inlineFragmentCount += raw.count
                                let fragments = try raw.map(rectangle)
                                let measuredUnion = try fragments.dropFirst().reduce(fragments[0], union)
                                // Layout snapshot bounds are quantized to 1/64 CSS px;
                                // client rects retain fractional transformed coordinates.
                                guard abs(measuredUnion.x - frame.x) <= 0.1,
                                      abs(measuredUnion.y - frame.y) <= 0.1,
                                      abs(measuredUnion.width - frame.width) <= 0.1,
                                      abs(measuredUnion.height - frame.height) <= 0.1 else {
                                    throw malformed("inline geometry changed during capture")
                                }
                                metadata["web.inlineFragmentCount"] = .number(Double(fragments.count))
                                for (part, fragment) in fragments.enumerated() {
                                    WebLint.store(fragment, key: "web.inlineFragment\(part)", in: &metadata)
                                }
                            }
                        }
                    }
                    metadata["web.overflowX"] = .string(style[7])
                    metadata["web.overflowY"] = .string(style[8])
                    metadata["web.scrollX"] = .number(scrollX)
                    metadata["web.scrollY"] = .number(scrollY)
                    // Only measured containing-block properties qualify; a fixed
                    // descendant of these ancestors scrolls with that ancestor.
                    metadata["web.fixedContainer"] = .bool(WebLint.establishesFixedContainer(styles: style))
                    if (style[7] == "auto" || style[7] == "scroll" || style[8] == "auto" || style[8] == "scroll"),
                       let client = clientRects[index], let scroll = scrollRects[index] {
                        let offset = offsetRects[index] ?? frame
                        let sx = offset.width > 0 ? frame.width / offset.width : 1
                        let sy = offset.height > 0 ? frame.height / offset.height : 1
                        let extent = try WebLint.checkedRect(x: frame.x + (client.x - scroll.x) * sx,
                            y: frame.y + (client.y - scroll.y) * sy, width: scroll.width * sx, height: scroll.height * sy)
                        WebLint.store(extent, key: "web.scrollBounds", in: &metadata)
                        let window = try WebLint.checkedRect(x: frame.x + client.x * sx, y: frame.y + client.y * sy,
                                                            width: client.width * sx, height: client.height * sy)
                        WebLint.store(window, key: "web.scrollViewport", in: &metadata)
                    }
                    if let embedded = embedded[index] { metadata["web.documentIndex"] = .number(Double(embedded)) }
                    if tag == "iframe" || tag == "frame" {
                        let client = clientRects[index] ?? Rect(x: 0, y: 0, width: frame.width, height: frame.height)
                        let offset = offsetRects[index] ?? frame
                        let scaleX = offset.width > 0 ? frame.width / offset.width : 1
                        let scaleY = offset.height > 0 ? frame.height / offset.height : 1
                        metadata["web.contentWidth"] = .number(client.width)
                        metadata["web.contentHeight"] = .number(client.height)
                        metadata["web.contentX"] = .number(frame.x + client.x * scaleX)
                        metadata["web.contentY"] = .number(frame.y + client.y * scaleY)
                        metadata["web.scaleX"] = .number(scaleX)
                        metadata["web.scaleY"] = .number(scaleY)
                    }
                    if let domID = attrs["id"] { metadata["web.id"] = .string(WebRedaction.clean(domID, secrets: secrets)) }
                    if let label = accessibleName {
                        metadata["accessibilityLabel"] = .string(label)
                    }
                    metadata["web.enabled"] = .bool(attrs["disabled"] == nil && attrs["aria-disabled"] != "true")
                    metadata["web.password"] = .bool(attrs["type"]?.lowercased() == "password")
                    if role == .textField { metadata["web.value"] = .string("[REDACTED]") }
                    if role == .toggle { metadata["isOn"] = .bool(attrs["checked"] != nil || attrs["aria-checked"] == "true") }
                    let boxes = textBoxes[index] ?? []
                    if !boxes.isEmpty {
                        metadata["web.textFragmentCount"] = .number(Double(boxes.count))
                        for (part, box) in boxes.enumerated() {
                            let shifted = try WebLint.checkedRect(x: box.x - scrollX, y: box.y - scrollY,
                                                                 width: box.width, height: box.height)
                            WebLint.store(shifted, key: "web.textFragment\(part)", in: &metadata)
                        }
                    }
                    let lines = try boxes.map { box -> Int in
                        guard let line = Int(exactly: (box.y * 2).rounded()) else {
                            throw malformed("text box line coordinate out of range")
                        }
                        return line
                    }
                    let lineCount = Set(lines).count
                    let metrics = boxes.isEmpty ? nil : TextMetrics(
                        intrinsicWidth: boxes.reduce(0) { $0 + $1.width },
                        renderedLineCount: lineCount, idealLineCount: lineCount)
                    let node = SemanticNode(
                        id: role == .container ? "" : (frameID == "main" ? "web/\(backend[index])" : "web/\(frameID)/\(backend[index])"), role: role, frame: frame,
                        text: rawText.map { WebRedaction.clean($0, secrets: secrets) } ?? accessibleName,
                        attributes: metadata, isVisible: visible,
                        zIndex: Double(style[3]), textMetrics: metrics, children: descendants)
                    descendants = [node]
                }
            }
            if parent >= 0 { assembled[parent, default: []].insert(contentsOf: descendants, at: 0) }
            else { assembled[-1, default: []].insert(contentsOf: descendants, at: 0) }
        }
        if let inlineGeometry, consumedInline.count != inlineGeometry.count {
            throw malformed("unexpected inline border fragment identity")
        }
        return (assembled[-1] ?? []).map { source in
            var node = source
            WebLint.store(documentBounds, key: "web.documentBounds", in: &node.attributes)
            WebLint.store(documentViewport, key: "web.documentViewport", in: &node.attributes)
            return node
        }
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
        if let editable = attributes["contenteditable"], editable != "false" { return .textField }
        switch tag {
        case "#text": return .text
        case "br", "wbr": return .spacer
        case "button", "summary": return .button
        case "a": return attributes["href"] == nil ? .container : .button
        case "textarea": return .textField
        case "select": return .menu
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

    // Chromium emits an empty sparse index list for measured non-clickability.
    // An absent optional column stays unmeasured in the semantic metadata.
    // https://github.com/chromium/chromium/blob/main/third_party/blink/renderer/core/inspector/inspector_dom_snapshot_agent.cc
    private static func clickableIndices(_ value: CDPValue?, count: Int) throws -> Set<Int> {
        guard let value else { return [] }
        guard case let .object(column) = value else { throw malformed("invalid clickable column") }
        let indices = try integers(column["index"])
        guard indices.count <= count, Set(indices).count == indices.count,
              indices.allSatisfy({ (0..<count).contains($0) }) else { throw malformed("invalid clickable index") }
        return Set(indices)
    }

    private static func focusable(tag: String, attributes: [String: String]) -> Bool {
        if attributes["tabindex"] != nil { return true }
        if let editable = attributes["contenteditable"], editable.lowercased() != "false" { return true }
        if ["button", "input", "select", "textarea", "summary"].contains(tag) { return true }
        if ["a", "area"].contains(tag), attributes["href"] != nil { return true }
        if ["audio", "video"].contains(tag), attributes["controls"] != nil { return true }
        let roles: Set<String> = ["button", "link", "checkbox", "radio", "switch", "slider", "spinbutton",
                                  "textbox", "combobox", "listbox", "option", "menuitem", "menuitemcheckbox",
                                  "menuitemradio", "tab", "treeitem", "searchbox"]
        return attributes["role"]?.split(separator: " ").contains { roles.contains(String($0).lowercased()) } == true
    }

    private static func rareIntegers(_ value: CDPValue?) throws -> [Int: Int] {
        guard let value else { return [:] }
        guard case let .object(fields) = value else { throw malformed("invalid sparse column") }
        let indices = try integers(fields["index"])
        let values = try integers(fields["value"])
        guard indices.count == values.count, Set(indices).count == indices.count else { throw malformed("invalid sparse column lengths") }
        return Dictionary(uniqueKeysWithValues: zip(indices, values))
    }

    private static func hidden(_ node: SemanticNode) -> SemanticNode {
        var node = node
        node.isVisible = false
        node.children = node.children.map(hidden)
        return node
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
        guard (coordinates[0] + coordinates[2]).isFinite, (coordinates[1] + coordinates[3]).isFinite else {
            throw malformed("rectangle coordinate overflow")
        }
        return Rect(x: coordinates[0], y: coordinates[1], width: coordinates[2], height: coordinates[3])
    }

    private static func union(_ first: Rect, _ second: Rect) throws -> Rect {
        // Empty anonymous fragments often sit at (0,0); they must not pull a
        // displaced visible box toward the document origin, in either order.
        if second.isEmpty { return first }
        if first.isEmpty { return second }
        let x = min(first.x, second.x), y = min(first.y, second.y)
        let width = max(first.maxX, second.maxX) - x
        let height = max(first.maxY, second.maxY) - y
        guard width.isFinite, height.isFinite else { throw malformed("layout fragment union overflow") }
        return Rect(x: x, y: y, width: width, height: height)
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
