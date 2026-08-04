// VerdictUIKernel — platform-pure. No SwiftUI/AppKit imports allowed in this target.
import Foundation

/// Location of a node inside a semantic tree, as the chain of sibling-local
/// identities from the root.
///
/// Segments come from ``SemanticNode/identity`` (probe `id` first, structural-path
/// component second, positional index as last resort — see
/// ``TreeDiff/childSegments(of:)``), which is what makes a path stable across a
/// mutation instead of shifting whenever a sibling is inserted.
public struct NodePath: Hashable, Sendable, CustomStringConvertible {
    /// Identity segments, root first, this node last.
    public var segments: [String]

    public init(_ segments: [String]) {
        self.segments = segments
    }

    /// The path of the tree root — every path starts here.
    public static let root = NodePath([TreeDiff.rootSegment])

    /// This path extended by one child segment.
    public func appending(_ segment: String) -> NodePath {
        NodePath(segments + [segment])
    }

    /// The enclosing path, or `nil` for the root.
    public var parent: NodePath? {
        segments.count > 1 ? NodePath(Array(segments.dropLast())) : nil
    }

    /// The final segment — this node's own identity.
    public var leaf: String { segments.last ?? "" }

    /// Slash-joined rendering for finding messages and agent output.
    public var description: String { segments.joined(separator: "/") }
}

extension NodePath: Codable {
    /// Encoded as a JSON array of segments, not a joined string: a
    /// structural-path segment may itself contain `/`.
    public init(from decoder: any Decoder) throws {
        segments = try decoder.singleValueContainer().decode([String].self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(segments)
    }
}

/// One field-level change on a matched node.
///
/// `key` names the field using a flat, dotted vocabulary (see the static
/// constants and ``attributeKey(_:)``). `nil` on `before` or `after` means the
/// field was absent on that side — a `text` that appeared, a `zIndex` that was
/// dropped. Frame changes are reported as ``NodeMove`` instead, never here.
public struct AttributeChange: Equatable, Codable, Sendable {
    /// Change key for ``SemanticNode/id`` — only ever emitted for the root,
    /// since elsewhere an id change makes the node a different node.
    public static let idKey = "id"
    /// Change key for ``SemanticNode/role``.
    public static let roleKey = "role"
    /// Change key for ``SemanticNode/text``.
    public static let textKey = "text"
    /// Change key for ``SemanticNode/isVisible``.
    public static let isVisibleKey = "isVisible"
    /// Change key for ``SemanticNode/zIndex``.
    public static let zIndexKey = "zIndex"
    /// Change key for ``SemanticNode/structuralPath``.
    public static let structuralPathKey = "structuralPath"
    /// Change key for ``TextMetrics/intrinsicWidth``.
    public static let intrinsicWidthKey = "textMetrics.intrinsicWidth"
    /// Change key for ``TextMetrics/renderedLineCount``.
    public static let renderedLineCountKey = "textMetrics.renderedLineCount"
    /// Change key for ``TextMetrics/idealLineCount``.
    public static let idealLineCountKey = "textMetrics.idealLineCount"
    /// Change key for a node's index among its siblings. Emitted only when the
    /// surviving siblings' relative order actually changed — an insertion that
    /// merely shifts later siblings is not a reorder.
    public static let childIndexKey = "childIndex"
    /// Prefix for entries in ``SemanticNode/attributes``.
    public static let attributePrefix = "attributes."

    /// Change key for the named entry in ``SemanticNode/attributes``.
    public static func attributeKey(_ name: String) -> String { attributePrefix + name }

    public var key: String
    public var before: AttributeValue?
    public var after: AttributeValue?

    public init(key: String, before: AttributeValue?, after: AttributeValue?) {
        self.key = key
        self.before = before
        self.after = after
    }
}

/// A node that exists in the after-tree but not the before-tree.
///
/// Carries the whole added subtree, not just its location: an agent reading a
/// delta-only response (Wave 7) has to see what appeared, and ``TreeDiff/apply(_:to:)``
/// cannot reconstruct the after-tree from a bare path. Recorded in `no.md` #6.
public struct NodeAddition: Equatable, Codable, Sendable {
    /// Full path of the added node in the after-tree.
    public var path: NodePath
    /// Insertion index among the parent's children in the after-tree.
    public var index: Int
    /// The added subtree, verbatim.
    public var node: SemanticNode

    public init(path: NodePath, index: Int, node: SemanticNode) {
        self.path = path
        self.index = index
        self.node = node
    }
}

/// A matched node whose resolved frame changed.
public struct NodeMove: Equatable, Codable, Sendable {
    public var path: NodePath
    public var from: Rect
    public var to: Rect

    public init(path: NodePath, from: Rect, to: Rect) {
        self.path = path
        self.from = from
        self.to = to
    }
}

/// A matched node whose non-geometric fields changed.
public struct NodeChange: Equatable, Codable, Sendable {
    public var path: NodePath
    public var changes: [AttributeChange]

    public init(path: NodePath, changes: [AttributeChange]) {
        self.path = path
        self.changes = changes
    }
}

/// The complete difference between two semantic trees.
///
/// Completeness is the point: ``TreeDiff/apply(_:to:)`` replays a delta onto the
/// before-tree and reproduces the after-tree exactly. That invariant is what lets
/// the act→observe loop ship a delta instead of a full tree.
public struct TreeDelta: Equatable, Codable, Sendable {
    /// Nodes present only in the after-tree, with their subtrees.
    public var added: [NodeAddition]
    /// Paths present only in the before-tree; the whole subtree is gone.
    public var removed: [NodePath]
    /// Matched nodes whose frame changed.
    public var moved: [NodeMove]
    /// Matched nodes whose other fields changed.
    public var changed: [NodeChange]

    public init(
        added: [NodeAddition] = [],
        removed: [NodePath] = [],
        moved: [NodeMove] = [],
        changed: [NodeChange] = []
    ) {
        self.added = added
        self.removed = removed
        self.moved = moved
        self.changed = changed
    }

    /// True when the two trees were identical.
    public var isEmpty: Bool {
        added.isEmpty && removed.isEmpty && moved.isEmpty && changed.isEmpty
    }

    /// One-line census for finding messages and settle timeouts.
    public var summary: String {
        "added \(added.count), removed \(removed.count), moved \(moved.count), "
            + "changed \(changed.count)"
    }
}

/// Why a delta could not be replayed onto a tree.
public enum TreeDiffError: Error, Equatable, CustomStringConvertible {
    /// A removal, move, or change named a path that does not exist in the tree.
    case pathNotFound(NodePath)
    /// An addition or reorder named an index outside its parent's child range.
    case indexOutOfRange(NodePath, Int)
    /// Two instructions claimed the same child slot.
    case conflictingIndex(NodePath, Int)
    /// A change carried a value of the wrong shape for its key, or an unknown key.
    case malformedChange(String)
    /// The delta removed the root, which has no valid representation.
    case rootRemoved

    public var description: String {
        switch self {
        case .pathNotFound(let path): "no node at path '\(path)'"
        case .indexOutOfRange(let path, let index): "index \(index) out of range under '\(path)'"
        case .conflictingIndex(let path, let index): "index \(index) claimed twice under '\(path)'"
        case .malformedChange(let key): "change key '\(key)' is unknown or carried a wrong value"
        case .rootRemoved: "delta removed the tree root"
        }
    }
}

/// Structural diff between two semantic trees, and its inverse.
///
/// Matching is id-first: a node is identified by its probe `id`, falling back to
/// its ``SemanticNode/structuralPath`` and then to its sibling index. Matching is
/// O(n) — one dictionary of segments per parent, no tree-edit-distance search.
///
/// Deliberate scope limits (documented in `docs/kernel.md`):
/// - A node whose parent changed is reported as a removal plus an addition, not a
///   relocation. Structure therefore always replays exactly; an explicit
///   `relocated` case can arrive later without breaking the wire format.
/// - Duplicate identities among siblings (which ``DuplicateProbeIDRule`` reports as
///   an error) make that parent's children match positionally instead.
public enum TreeDiff {
    /// Path segment of the tree root. Fixed rather than identity-derived so that
    /// giving the root a probe id does not re-key every path in the tree.
    public static let rootSegment = "$root"

    // MARK: - Compute

    /// The complete difference from `before` to `after`.
    public static func compute(before: SemanticNode, after: SemanticNode) -> TreeDelta {
        var delta = TreeDelta()
        diff(before: before, after: after, at: .root, extraChanges: [], into: &delta)
        return delta
    }

    private static func diff(
        before: SemanticNode,
        after: SemanticNode,
        at path: NodePath,
        extraChanges: [AttributeChange],
        into delta: inout TreeDelta
    ) {
        if before.frame != after.frame {
            delta.moved.append(NodeMove(path: path, from: before.frame, to: after.frame))
        }

        var changes = extraChanges + fieldChanges(before: before, after: after)
        changes.sort { $0.key < $1.key }
        if !changes.isEmpty {
            delta.changed.append(NodeChange(path: path, changes: changes))
        }

        diffChildren(before: before, after: after, at: path, into: &delta)
    }

    private static func fieldChanges(before: SemanticNode, after: SemanticNode)
        -> [AttributeChange]
    {
        var changes: [AttributeChange] = []
        if before.id != after.id {
            changes.append(
                AttributeChange(
                    key: AttributeChange.idKey,
                    before: .string(before.id),
                    after: .string(after.id)
                )
            )
        }
        if before.role != after.role {
            changes.append(
                AttributeChange(
                    key: AttributeChange.roleKey,
                    before: .string(before.role.identifier),
                    after: .string(after.role.identifier)
                )
            )
        }
        if before.text != after.text {
            changes.append(
                AttributeChange(
                    key: AttributeChange.textKey,
                    before: before.text.map(AttributeValue.string),
                    after: after.text.map(AttributeValue.string)
                )
            )
        }
        if before.isVisible != after.isVisible {
            changes.append(
                AttributeChange(
                    key: AttributeChange.isVisibleKey,
                    before: .bool(before.isVisible),
                    after: .bool(after.isVisible)
                )
            )
        }
        if before.zIndex != after.zIndex {
            changes.append(
                AttributeChange(
                    key: AttributeChange.zIndexKey,
                    before: before.zIndex.map(AttributeValue.number),
                    after: after.zIndex.map(AttributeValue.number)
                )
            )
        }
        if before.structuralPath != after.structuralPath {
            changes.append(
                AttributeChange(
                    key: AttributeChange.structuralPathKey,
                    before: .string(before.structuralPath),
                    after: .string(after.structuralPath)
                )
            )
        }
        changes.append(
            contentsOf: textMetricChanges(before: before.textMetrics, after: after.textMetrics)
        )
        changes.append(contentsOf: attributeChanges(before: before, after: after))
        return changes
    }

    /// Emits one entry per differing component. A `nil` → non-`nil` transition
    /// differs on all three, so ``apply(_:to:)`` can always rebuild the value.
    private static func textMetricChanges(before: TextMetrics?, after: TextMetrics?)
        -> [AttributeChange]
    {
        guard before != after else { return [] }
        let components: [(String, (TextMetrics) -> Double)] = [
            (AttributeChange.intrinsicWidthKey, \.intrinsicWidth),
            (AttributeChange.renderedLineCountKey, { Double($0.renderedLineCount) }),
            (AttributeChange.idealLineCountKey, { Double($0.idealLineCount) }),
        ]
        return components.compactMap { key, extract in
            let beforeValue = before.map(extract)
            let afterValue = after.map(extract)
            guard beforeValue != afterValue else { return nil }
            return AttributeChange(
                key: key,
                before: beforeValue.map(AttributeValue.number),
                after: afterValue.map(AttributeValue.number)
            )
        }
    }

    private static func attributeChanges(before: SemanticNode, after: SemanticNode)
        -> [AttributeChange]
    {
        let names = Set(before.attributes.keys).union(after.attributes.keys).sorted()
        return names.compactMap { name in
            let beforeValue = before.attributes[name]
            let afterValue = after.attributes[name]
            guard beforeValue != afterValue else { return nil }
            return AttributeChange(
                key: AttributeChange.attributeKey(name),
                before: beforeValue,
                after: afterValue
            )
        }
    }

    private static func diffChildren(
        before: SemanticNode,
        after: SemanticNode,
        at path: NodePath,
        into delta: inout TreeDelta
    ) {
        let beforeSegments = childSegments(of: before)
        let afterSegments = childSegments(of: after)
        let afterIndexBySegment = Dictionary(
            uniqueKeysWithValues: afterSegments.enumerated().map { ($1, $0) }
        )
        let beforeIndexBySegment = Dictionary(
            uniqueKeysWithValues: beforeSegments.enumerated().map { ($1, $0) }
        )

        for segment in beforeSegments where afterIndexBySegment[segment] == nil {
            delta.removed.append(path.appending(segment))
        }

        for (index, segment) in afterSegments.enumerated()
        where beforeIndexBySegment[segment] == nil {
            delta.added.append(
                NodeAddition(
                    path: path.appending(segment),
                    index: index,
                    node: after.children[index]
                )
            )
        }

        let survivingBefore = beforeSegments.filter { afterIndexBySegment[$0] != nil }
        let survivingAfter = afterSegments.filter { beforeIndexBySegment[$0] != nil }
        let reordered = survivingBefore != survivingAfter

        for segment in survivingBefore {
            guard
                let beforeIndex = beforeIndexBySegment[segment],
                let afterIndex = afterIndexBySegment[segment]
            else { continue }
            var extraChanges: [AttributeChange] = []
            if reordered {
                extraChanges.append(
                    AttributeChange(
                        key: AttributeChange.childIndexKey,
                        before: .number(Double(beforeIndex)),
                        after: .number(Double(afterIndex))
                    )
                )
            }
            diff(
                before: before.children[beforeIndex],
                after: after.children[afterIndex],
                at: path.appending(segment),
                extraChanges: extraChanges,
                into: &delta
            )
        }
    }

    /// Sibling-local identity for each child of `node`, in layout order.
    ///
    /// Probe `id` wins, then the last component of ``SemanticNode/structuralPath``
    /// (unique among siblings by construction), then the sibling index. If the
    /// result is not unique — duplicate probe ids, which ``DuplicateProbeIDRule``
    /// reports — the whole sibling group falls back to positional segments so a
    /// path can never be ambiguous.
    public static func childSegments(of node: SemanticNode) -> [String] {
        let segments = node.children.enumerated().map { index, child -> String in
            let identity = child.identity
            return identity.isEmpty ? "#\(index)" : identity
        }
        guard Set(segments).count == segments.count else {
            return node.children.indices.map { "#\($0)" }
        }
        return segments
    }

    // MARK: - Apply

    /// Replay `delta` onto `before` and return the reconstructed after-tree.
    ///
    /// Round-trip invariant, enforced by the property suite:
    /// `apply(compute(before:after:), to: before) == after`.
    ///
    /// - Throws: ``TreeDiffError`` when the delta does not fit the tree — an
    ///   unknown path, a colliding index, a malformed change. Never silently
    ///   produces a wrong tree.
    public static func apply(_ delta: TreeDelta, to before: SemanticNode) throws -> SemanticNode {
        let removals = Set(delta.removed)
        var additionsByParent: [NodePath: [NodeAddition]] = [:]
        for addition in delta.added {
            guard let parent = addition.path.parent else {
                throw TreeDiffError.pathNotFound(addition.path)
            }
            additionsByParent[parent, default: []].append(addition)
        }
        var movesByPath: [NodePath: Rect] = [:]
        for move in delta.moved { movesByPath[move.path] = move.to }
        var changesByPath: [NodePath: [AttributeChange]] = [:]
        for change in delta.changed {
            changesByPath[change.path, default: []].append(contentsOf: change.changes)
        }

        guard !removals.contains(.root) else { throw TreeDiffError.rootRemoved }

        var context = ApplyContext(
            removals: removals,
            additionsByParent: additionsByParent,
            moves: movesByPath,
            changes: changesByPath
        )
        guard let rebuilt = try rebuild(before, at: .root, context: &context) else {
            throw TreeDiffError.rootRemoved
        }

        // Every instruction must have found its node; an orphan means the delta
        // describes a different tree and the result would be silently wrong.
        if let orphan = context.removals.first { throw TreeDiffError.pathNotFound(orphan) }
        if let orphan = context.moves.keys.first { throw TreeDiffError.pathNotFound(orphan) }
        if let orphan = context.changes.keys.first { throw TreeDiffError.pathNotFound(orphan) }
        if let orphan = context.additionsByParent.keys.first {
            throw TreeDiffError.pathNotFound(orphan)
        }
        return rebuilt
    }

    /// Mutable bookkeeping for a single ``apply(_:to:)`` run: instructions are
    /// consumed as they are matched so leftovers can be reported.
    private struct ApplyContext {
        var removals: Set<NodePath>
        var additionsByParent: [NodePath: [NodeAddition]]
        var moves: [NodePath: Rect]
        var changes: [NodePath: [AttributeChange]]
    }

    private static func rebuild(
        _ node: SemanticNode,
        at path: NodePath,
        context: inout ApplyContext
    ) throws -> SemanticNode? {
        if context.removals.remove(path) != nil { return nil }

        var result = node
        if let frame = context.moves.removeValue(forKey: path) {
            result.frame = frame
        }

        var childIndexTargets: [String: Int] = [:]
        let ownChanges = context.changes.removeValue(forKey: path) ?? []
        try applyFieldChanges(ownChanges, to: &result)

        let segments = childSegments(of: node)
        for segment in segments {
            let childPath = path.appending(segment)
            if let target = try takeChildIndexTarget(at: childPath, context: &context) {
                childIndexTargets[segment] = target
            }
        }

        var survivors: [(segment: String, node: SemanticNode)] = []
        for (index, segment) in segments.enumerated() {
            let childPath = path.appending(segment)
            if let rebuilt = try rebuild(node.children[index], at: childPath, context: &context) {
                survivors.append((segment, rebuilt))
            } else {
                childIndexTargets.removeValue(forKey: segment)
            }
        }

        let additions = context.additionsByParent.removeValue(forKey: path) ?? []
        result.children = try assembleChildren(
            survivors: survivors,
            targets: childIndexTargets,
            additions: additions,
            at: path
        )
        return result
    }

    /// Pulls a `childIndex` instruction out of a child's change list ahead of the
    /// recursion, because reordering is the parent's job, not the child's.
    private static func takeChildIndexTarget(at childPath: NodePath, context: inout ApplyContext)
        throws -> Int?
    {
        guard var changes = context.changes[childPath] else { return nil }
        guard let position = changes.firstIndex(where: { $0.key == AttributeChange.childIndexKey })
        else { return nil }
        let entry = changes.remove(at: position)
        if changes.isEmpty {
            context.changes.removeValue(forKey: childPath)
        } else {
            context.changes[childPath] = changes
        }
        guard let target = entry.after?.numberValue else {
            throw TreeDiffError.malformedChange(AttributeChange.childIndexKey)
        }
        return Int(target)
    }

    /// Places additions at their after-tree indices, explicitly reordered
    /// survivors at theirs, then fills the remaining slots with the remaining
    /// survivors in before-order.
    private static func assembleChildren(
        survivors: [(segment: String, node: SemanticNode)],
        targets: [String: Int],
        additions: [NodeAddition],
        at path: NodePath
    ) throws -> [SemanticNode] {
        let total = survivors.count + additions.count
        var slots = [SemanticNode?](repeating: nil, count: total)

        func place(_ node: SemanticNode, at index: Int) throws {
            guard index >= 0, index < total else {
                throw TreeDiffError.indexOutOfRange(path, index)
            }
            guard slots[index] == nil else {
                throw TreeDiffError.conflictingIndex(path, index)
            }
            slots[index] = node
        }

        for addition in additions.sorted(by: { $0.index < $1.index }) {
            try place(addition.node, at: addition.index)
        }
        var unplaced: [SemanticNode] = []
        for survivor in survivors {
            if let target = targets[survivor.segment] {
                try place(survivor.node, at: target)
            } else {
                unplaced.append(survivor.node)
            }
        }
        var cursor = unplaced.makeIterator()
        for index in slots.indices where slots[index] == nil {
            guard let next = cursor.next() else { throw TreeDiffError.indexOutOfRange(path, index) }
            slots[index] = next
        }
        return slots.compactMap { $0 }
    }

    private static func applyFieldChanges(
        _ changes: [AttributeChange],
        to node: inout SemanticNode
    ) throws {
        var metricComponents: [String: Double?] = [:]
        for change in changes {
            switch change.key {
            case AttributeChange.childIndexKey:
                throw TreeDiffError.malformedChange(change.key)
            case AttributeChange.idKey:
                node.id = try requireString(change)
            case AttributeChange.roleKey:
                node.role = Role(identifier: try requireString(change))
            case AttributeChange.textKey:
                node.text = try optionalString(change)
            case AttributeChange.isVisibleKey:
                guard let value = change.after?.boolValue else {
                    throw TreeDiffError.malformedChange(change.key)
                }
                node.isVisible = value
            case AttributeChange.zIndexKey:
                node.zIndex = try optionalNumber(change)
            case AttributeChange.structuralPathKey:
                node.structuralPath = try requireString(change)
            case AttributeChange.intrinsicWidthKey,
                AttributeChange.renderedLineCountKey,
                AttributeChange.idealLineCountKey:
                metricComponents[change.key] = try optionalNumber(change)
            default:
                guard change.key.hasPrefix(AttributeChange.attributePrefix) else {
                    throw TreeDiffError.malformedChange(change.key)
                }
                let name = String(change.key.dropFirst(AttributeChange.attributePrefix.count))
                guard !name.isEmpty else { throw TreeDiffError.malformedChange(change.key) }
                node.attributes[name] = change.after
            }
        }
        if !metricComponents.isEmpty {
            node.textMetrics = rebuiltMetrics(base: node.textMetrics, components: metricComponents)
        }
    }

    private static func rebuiltMetrics(base: TextMetrics?, components: [String: Double?])
        -> TextMetrics?
    {
        func value(_ key: String, _ fallback: Double?) -> Double? {
            components.keys.contains(key) ? components[key] ?? nil : fallback
        }
        let intrinsic = value(AttributeChange.intrinsicWidthKey, base?.intrinsicWidth)
        let rendered = value(
            AttributeChange.renderedLineCountKey,
            base.map { Double($0.renderedLineCount) }
        )
        let ideal = value(AttributeChange.idealLineCountKey, base.map { Double($0.idealLineCount) })
        if intrinsic == nil, rendered == nil, ideal == nil { return nil }
        return TextMetrics(
            intrinsicWidth: intrinsic ?? 0,
            renderedLineCount: Int(rendered ?? 0),
            idealLineCount: Int(ideal ?? 0)
        )
    }

    private static func requireString(_ change: AttributeChange) throws -> String {
        guard let value = change.after?.stringValue else {
            throw TreeDiffError.malformedChange(change.key)
        }
        return value
    }

    private static func optionalString(_ change: AttributeChange) throws -> String? {
        guard let after = change.after else { return nil }
        guard let value = after.stringValue else {
            throw TreeDiffError.malformedChange(change.key)
        }
        return value
    }

    private static func optionalNumber(_ change: AttributeChange) throws -> Double? {
        guard let after = change.after else { return nil }
        guard let value = after.numberValue else {
            throw TreeDiffError.malformedChange(change.key)
        }
        return value
    }
}
