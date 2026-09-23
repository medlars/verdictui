import Foundation

/// Names are labels, never form values. Keeping this separate from geometry
/// lets hidden label references name a visible control without exposing input.
enum DOMAccessibleNames {
    static func resolve(tags: [String], types: [Int], values: [String],
                        attributes: [[String: String]], parents: [Int]) -> [String?] {
        func normalized(_ text: String?) -> String? {
            guard let text else { return nil }
            let result = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return result.isEmpty ? nil : result
        }
        var contents = [String](repeating: "", count: tags.count)
        var identifiers: [String: Int] = [:]
        for index in tags.indices {
            if let id = attributes[index]["id"], identifiers[id] == nil { identifiers[id] = index }
        }
        for index in tags.indices.reversed() {
            if types[index] == 3 { contents[index] = values[index] }
            // Browser shadow trees, textarea defaults, and editable regions can
            // carry values as text nodes. Those are not accessible names.
            if ["input", "textarea", "script", "style"].contains(tags[index])
                || DOMSnapshotAssembly.role(tag: tags[index], attributes: attributes[index]) == .textField {
                contents[index] = ""
            }
            if parents[index] >= 0 { contents[parents[index]] = contents[index] + " " + contents[parents[index]] }
        }
        var labels: [String: [String]] = [:]
        for index in tags.indices where tags[index] == "label" {
            if let target = attributes[index]["for"], let text = normalized(contents[index]) {
                labels[target, default: []].append(text)
            }
        }
        return tags.indices.map { index in
            let attrs = attributes[index]
            if let references = attrs["aria-labelledby"] {
                let text = references.split(whereSeparator: \.isWhitespace).compactMap { reference in
                    identifiers[String(reference)].flatMap { normalized(contents[$0]) }
                }.joined(separator: " ")
                if let name = normalized(text) { return name }
            }
            if let name = normalized(attrs["aria-label"]) { return name }
            let role = DOMSnapshotAssembly.role(tag: tags[index], attributes: attrs)
            if role.isInteractive || tags[index] == "select" {
                if let id = attrs["id"], let text = labels[id], let name = normalized(text.joined(separator: " ")) { return name }
                var ancestor = parents[index]
                while ancestor >= 0 {
                    if tags[ancestor] == "label", let name = normalized(contents[ancestor]) { return name }
                    ancestor = parents[ancestor]
                }
            }
            if role == .image || (tags[index] == "input" && attrs["type"] == "image"),
                let name = normalized(attrs["alt"]) { return name }
            if role == .button {
                if let name = normalized(contents[index]) { return name }
                if tags[index] == "input", let name = normalized(attrs["value"]) { return name }
            }
            return normalized(attrs["title"]) ?? normalized(attrs["placeholder"])
        }
    }
}
