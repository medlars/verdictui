// Wave 7: the token-frugal form of an act delta.
//
// `act` is the tightest loop an agent runs — tap, look, decide, tap again — so
// the bytes it costs are paid on every iteration. That is why the plan budgets a
// typical delta at 300 B while a whole tree gets 2 KB: the tree is read once, the
// delta is read continuously.
//
// A raw `TreeDelta` does not fit. Measured on `ToggleLayoutScenario`'s toggle —
// two nodes added, one removed, one moved, which is a SMALL change — the
// synthesized JSON is **702 B**, 2.3x the budget.
//
// ### The first attempt made it BIGGER, and why
//
// The obvious design reused `CompactTree` for each added subtree. Measured: 735
// B, *larger than the raw form it replaced*. The reason is a shape mismatch that
// is invisible until you print the bytes. `CompactTree` amortizes nine array
// keys — `ids`, `roleIDs`, `textIDs`, `frames`, `parents`, `strings`,
// `structuralPaths`, `textMetrics`, `truncated` — across a whole tree, where
// they cost nothing per node. An ADDED node is typically a subtree of ONE, so
// each addition paid all nine keys plus its own `strings` table to describe a
// single node: ~280 B of envelope around ~80 B of payload, and the per-addition
// table defeated the shared one.
//
// So the added nodes are flattened into the DELTA's own parallel arrays: nine
// keys once for the whole delta rather than once per addition, one string table
// interning across additions, paths, and attribute keys together. Same three
// moves as `CompactTree`, applied at the level where the repetition actually is.
import Foundation
import VerdictUIKernel

/// A ``TreeDelta`` flattened for the wire.
///
/// ### Reading one
///
/// Paths are runs of indices into ``strings``: `["$root", "advanced-detail"]`
/// travels as two integers, and every later occurrence of `$root` costs nothing.
///
/// Added nodes live in one flat node table shared by every addition, in the same
/// parallel-array layout ``CompactTree`` uses: node `i` has id `nodeIDs[i]`,
/// role `strings[nodeRoles[i]]`, frame `nodeFrames[i*4..<i*4+4]`, and parent
/// `nodeParents[i]` — where `-1` means "this node is an addition ROOT", and
/// which addition it belongs to is given by ``added``. Nodes appear
/// depth-first, so a consumer walks the table once.
///
/// ### Why this is lossless and not a summary
///
/// ``TreeDiff/apply(_:to:)`` replays a delta onto the before-tree and reproduces
/// the after-tree exactly; that invariant is the whole reason the act loop may
/// ship a delta instead of a tree. A compaction that dropped a field would break
/// it silently — the delta would still *look* like a delta, and the tree a
/// client rebuilt from it would differ from the one the engine saw. So
/// ``expand()`` is the correctness argument, pinned by a round-trip against a
/// real act rather than a hand-built fixture.
public struct CompactDelta: Codable, Sendable, Equatable {
    /// One entry per added subtree: where it goes, and where its nodes start.
    public let added: [CompactAddition]
    /// Removed paths, each a run of ``strings`` indices.
    public let removed: [[Int]]
    /// Moved nodes.
    public let moved: [CompactMove]
    /// Attribute changes.
    public let changed: [CompactChange]

    /// Index into ``strings`` for each added node's probe id, `-1` when unprobed.
    ///
    /// Interned rather than carried literally because an added node's id also
    /// appears in its own ``CompactAddition/path`` — a node is added AT the path
    /// naming it — so storing the string twice pays for the same characters
    /// twice. Measured on the toggle: 40 B of `nodeIDs` that the string table
    /// was already carrying.
    public let nodeIDs: [Int]
    /// Index into ``strings`` for each added node's role.
    public let nodeRoles: [Int]
    /// Index into ``strings`` for each added node's text, `-1` when it has none.
    public let nodeTexts: [Int]
    /// Flattened `x, y, width, height` — four entries per added node.
    public let nodeFrames: [Double]
    /// Parent index within this table; `-1` marks an addition's root.
    public let nodeParents: [Int]
    /// Index into ``strings`` for each added node's structural path.
    ///
    /// Interned like everything else: sibling paths share long prefixes, and a
    /// path is what a finding cites when a node has no probe id — dropping it
    /// would make exactly the unprobed nodes unaddressable.
    public let nodePaths: [Int]
    /// Text metrics per added node, flattened as
    /// `intrinsicWidth, renderedLineCount, idealLineCount` — three entries per
    /// node, all `-1` where the probe reported none.
    ///
    /// Carried rather than dropped because ``TruncationRule`` reads exactly
    /// this: a delta that discards it replays into a tree on which truncation
    /// can no longer be judged, and every verdict computed from the far side
    /// would report a clean screen for a clipped label.
    ///
    /// Flattened rather than sent as objects because the three key names cost
    /// more than the values: measured on the toggle, 70 B for a single text
    /// node's metrics, of which 52 B was `intrinsicWidth`, `renderedLineCount`
    /// and `idealLineCount` spelled out. A sentinel of `-1` is unambiguous
    /// because none of the three is ever negative — a width is a length and the
    /// counts are counts.
    public let nodeMetrics: [Double]

    /// The interned string table shared by paths, roles, texts and keys.
    public let strings: [String]

    /// Where an added subtree goes, and which nodes it owns.
    public struct CompactAddition: Codable, Sendable, Equatable {
        /// Path of the added node, as ``strings`` indices.
        public let path: [Int]
        /// Child slot it occupies under its parent.
        public let index: Int
        /// Index of this subtree's root in the shared node table.
        public let node: Int

        public init(path: [Int], index: Int, node: Int) {
            self.path = path
            self.index = index
            self.node = node
        }
    }

    /// A node whose frame changed.
    public struct CompactMove: Codable, Sendable, Equatable {
        public let path: [Int]
        /// `x, y, width, height` before.
        public let from: [Double]
        /// `x, y, width, height` after.
        public let to: [Double]

        public init(path: [Int], from: [Double], to: [Double]) {
            self.path = path
            self.from = from
            self.to = to
        }
    }

    /// A node whose non-frame fields changed.
    public struct CompactChange: Codable, Sendable, Equatable {
        public let path: [Int]
        /// One entry per changed key.
        public let changes: [CompactAttributeChange]

        public init(path: [Int], changes: [CompactAttributeChange]) {
            self.path = path
            self.changes = changes
        }
    }

    /// One attribute's before/after.
    ///
    /// The KEY is interned because attribute keys repeat across nodes — a list
    /// where six rows all changed `text` spells `"text"` once. The VALUES are
    /// carried as-is: they are the payload, and interning a value that occurs
    /// once costs an index and saves nothing.
    public struct CompactAttributeChange: Codable, Sendable, Equatable {
        /// Index into ``CompactDelta/strings`` for the key.
        public let key: Int
        public let before: AttributeValue?
        public let after: AttributeValue?

        public init(key: Int, before: AttributeValue?, after: AttributeValue?) {
            self.key = key
            self.before = before
            self.after = after
        }
    }

    private enum CodingKeys: String, CodingKey {
        case added, removed, moved, changed
        case nodeIDs, nodeRoles, nodeTexts, nodeFrames, nodeParents, nodePaths, nodeMetrics
        case strings
    }

    /// Encode, omitting every empty list.
    ///
    /// ### Why this is hand-written
    ///
    /// The commonest act in a real agent loop changes nothing structurally — a
    /// tap that toggles internal state, a keystroke into a field that does not
    /// resize. Its delta is empty, and with the synthesized encoding an empty
    /// delta still spells all twelve keys and their `[]` values: measured at
    /// **170 B against a raw form of 49 B**, so the compaction made the FREQUENT
    /// case nearly four times worse while improving the rare one.
    ///
    /// A wire format that wins on big payloads and loses on small ones has
    /// optimized for the wrong distribution. Omitting empties fixes that, and it
    /// costs nothing on decode because every key already has an empty default —
    /// absent and empty mean the same thing here, which is exactly when omission
    /// is safe.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if !added.isEmpty { try container.encode(added, forKey: .added) }
        if !removed.isEmpty { try container.encode(removed, forKey: .removed) }
        if !moved.isEmpty { try container.encode(moved, forKey: .moved) }
        if !changed.isEmpty { try container.encode(changed, forKey: .changed) }
        if !nodeIDs.isEmpty { try container.encode(nodeIDs, forKey: .nodeIDs) }
        if !nodeRoles.isEmpty { try container.encode(nodeRoles, forKey: .nodeRoles) }
        if !nodeTexts.isEmpty { try container.encode(nodeTexts, forKey: .nodeTexts) }
        if !nodeFrames.isEmpty { try container.encode(nodeFrames, forKey: .nodeFrames) }
        if !nodeParents.isEmpty { try container.encode(nodeParents, forKey: .nodeParents) }
        if !nodePaths.isEmpty { try container.encode(nodePaths, forKey: .nodePaths) }
        if !nodeMetrics.isEmpty { try container.encode(nodeMetrics, forKey: .nodeMetrics) }
        if !strings.isEmpty { try container.encode(strings, forKey: .strings) }
    }

    /// Decode, treating an absent list as an empty one.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func list<T: Decodable>(_ key: CodingKeys) throws -> [T] {
            try container.decodeIfPresent([T].self, forKey: key) ?? []
        }
        self.added = try list(.added)
        self.removed = try list(.removed)
        self.moved = try list(.moved)
        self.changed = try list(.changed)
        self.nodeIDs = try list(.nodeIDs)
        self.nodeRoles = try list(.nodeRoles)
        self.nodeTexts = try list(.nodeTexts)
        self.nodeFrames = try list(.nodeFrames)
        self.nodeParents = try list(.nodeParents)
        self.nodePaths = try list(.nodePaths)
        self.nodeMetrics = try list(.nodeMetrics)
        self.strings = try list(.strings)
    }

    /// Build the arrays directly — public so a client can construct one from a
    /// decoded payload, which is what makes ``expand()``'s malformed cases
    /// writable as tests.
    public init(
        added: [CompactAddition],
        removed: [[Int]],
        moved: [CompactMove],
        changed: [CompactChange],
        nodeIDs: [Int] = [],
        nodeRoles: [Int] = [],
        nodeTexts: [Int] = [],
        nodeFrames: [Double] = [],
        nodeParents: [Int] = [],
        nodePaths: [Int] = [],
        nodeMetrics: [Double] = [],
        strings: [String]
    ) {
        self.added = added
        self.removed = removed
        self.moved = moved
        self.changed = changed
        self.nodeIDs = nodeIDs
        self.nodeRoles = nodeRoles
        self.nodeTexts = nodeTexts
        self.nodeFrames = nodeFrames
        self.nodeParents = nodeParents
        self.nodePaths = nodePaths
        self.nodeMetrics = nodeMetrics
        self.strings = strings
    }

    /// Flatten `delta`.
    public init(_ delta: TreeDelta) {
        var table: [String: Int] = [:]
        var strings: [String] = []

        func intern(_ value: String) -> Int {
            if let existing = table[value] { return existing }
            let index = strings.count
            table[value] = index
            strings.append(value)
            return index
        }
        func internPath(_ path: NodePath) -> [Int] { path.segments.map(intern) }
        func flatten(_ rect: Rect) -> [Double] { [rect.x, rect.y, rect.width, rect.height] }

        var ids: [Int] = []
        var roles: [Int] = []
        var texts: [Int] = []
        var frames: [Double] = []
        var parents: [Int] = []
        var paths: [Int] = []
        var metrics: [Double] = []

        /// Append `node` and its descendants; returns the root's table index.
        ///
        /// Recursive rather than an explicit stack — unlike ``CompactTree``,
        /// which flattens a whole screen — because an added subtree is bounded
        /// by what one act revealed, and a parent must be appended before its
        /// children for `-1` to mean "addition root".
        func append(_ node: SemanticNode, parent: Int) -> Int {
            let index = ids.count
            ids.append(node.id.isEmpty ? -1 : intern(node.id))
            roles.append(intern(node.role.identifier))
            texts.append(node.text.map(intern) ?? -1)
            frames.append(contentsOf: flatten(node.frame))
            parents.append(parent)
            paths.append(intern(node.structuralPath))
            if let measured = node.textMetrics {
                metrics.append(
                    contentsOf: [
                        measured.intrinsicWidth,
                        Double(measured.renderedLineCount),
                        Double(measured.idealLineCount),
                    ]
                )
            } else {
                metrics.append(contentsOf: [-1, -1, -1])
            }
            for child in node.children {
                _ = append(child, parent: index)
            }
            return index
        }

        self.added = delta.added.map { addition in
            CompactAddition(
                path: internPath(addition.path),
                index: addition.index,
                node: append(addition.node, parent: -1)
            )
        }
        self.removed = delta.removed.map(internPath)
        self.moved = delta.moved.map { move in
            CompactMove(
                path: internPath(move.path),
                from: flatten(move.from),
                to: flatten(move.to)
            )
        }
        self.changed = delta.changed.map { change in
            CompactChange(
                path: internPath(change.path),
                changes: change.changes.map { attribute in
                    CompactAttributeChange(
                        key: intern(attribute.key),
                        before: attribute.before,
                        after: attribute.after
                    )
                }
            )
        }

        self.nodeIDs = ids
        self.nodeRoles = roles
        self.nodeTexts = texts
        self.nodeFrames = frames
        self.nodeParents = parents
        self.nodePaths = paths
        self.nodeMetrics = metrics
        self.strings = strings
    }

    /// Rebuild the ``TreeDelta``.
    ///
    /// - Returns: the delta, or `nil` when the arrays are inconsistent — a path
    ///   index outside the string table, a node table whose columns disagree in
    ///   length, an addition pointing at a node that is not a subtree root. These
    ///   arrive over a socket from a process this one does not control, so a
    ///   malformed payload is untrusted input to be refused rather than a
    ///   hypothetical to be crashed on.
    public func expand() -> TreeDelta? {
        let count = nodeIDs.count
        guard
            nodeRoles.count == count,
            nodeTexts.count == count,
            nodeParents.count == count,
            nodePaths.count == count,
            nodeMetrics.count == count * 3,
            nodeFrames.count == count * 4
        else { return nil }

        func string(_ index: Int) -> String? {
            guard index >= 0, index < strings.count else { return nil }
            return strings[index]
        }
        func path(_ indices: [Int]) -> NodePath? {
            var segments: [String] = []
            for index in indices {
                guard let value = string(index) else { return nil }
                segments.append(value)
            }
            return NodePath(segments)
        }
        func rect(_ values: [Double]) -> Rect? {
            guard values.count == 4 else { return nil }
            return Rect(x: values[0], y: values[1], width: values[2], height: values[3])
        }

        // Children are collected first so a node can be built once its
        // descendants exist — `SemanticNode` is a value type.
        var childIndices: [[Int]] = Array(repeating: [], count: count)
        for (index, parent) in nodeParents.enumerated() where parent != -1 {
            guard parent >= 0, parent < count, parent != index else { return nil }
            childIndices[parent].append(index)
        }

        // A node reachable from two additions, or from none, means the table
        // does not describe the subtrees `added` claims — refused rather than
        // silently rebuilt into a different shape.
        var visited = Array(repeating: false, count: count)
        func build(_ index: Int) -> SemanticNode? {
            guard index >= 0, index < count, !visited[index] else { return nil }
            visited[index] = true
            guard
                let role = string(nodeRoles[index]),
                let structuralPath = string(nodePaths[index]),
                let frame = rect(Array(nodeFrames[(index * 4)..<(index * 4 + 4)]))
            else { return nil }
            let text: String?
            if nodeTexts[index] == -1 {
                text = nil
            } else {
                guard let value = string(nodeTexts[index]) else { return nil }
                text = value
            }
            let identifier: String
            if nodeIDs[index] == -1 {
                identifier = ""
            } else {
                guard let value = string(nodeIDs[index]) else { return nil }
                identifier = value
            }

            // All three sentinels or none: a half-present triple describes a
            // measurement nobody made, and guessing which half to trust is how
            // a rule ends up judging truncation against an invented width.
            let base = index * 3
            let triple = Array(nodeMetrics[base..<(base + 3)])
            let metrics: TextMetrics?
            if triple.allSatisfy({ $0 == -1 }) {
                metrics = nil
            } else {
                guard triple.allSatisfy({ $0 >= 0 }) else { return nil }
                metrics = TextMetrics(
                    intrinsicWidth: triple[0],
                    renderedLineCount: Int(triple[1]),
                    idealLineCount: Int(triple[2])
                )
            }

            var children: [SemanticNode] = []
            for child in childIndices[index] {
                guard let built = build(child) else { return nil }
                children.append(built)
            }
            return SemanticNode(
                id: identifier,
                role: Role(identifier: role),
                frame: frame,
                text: text,
                textMetrics: metrics,
                structuralPath: structuralPath,
                children: children
            )
        }

        var additions: [NodeAddition] = []
        for addition in added {
            guard
                let at = path(addition.path),
                addition.node >= 0, addition.node < count,
                nodeParents[addition.node] == -1,
                let node = build(addition.node)
            else { return nil }
            additions.append(NodeAddition(path: at, index: addition.index, node: node))
        }
        // Every node in the table must belong to exactly one addition; a stray
        // one means the payload carries nodes nothing references.
        guard visited.allSatisfy({ $0 }) else { return nil }

        var removals: [NodePath] = []
        for indices in removed {
            guard let at = path(indices) else { return nil }
            removals.append(at)
        }

        var moves: [NodeMove] = []
        for move in moved {
            guard
                let at = path(move.path),
                let from = rect(move.from),
                let to = rect(move.to)
            else { return nil }
            moves.append(NodeMove(path: at, from: from, to: to))
        }

        var changes: [NodeChange] = []
        for change in changed {
            guard let at = path(change.path) else { return nil }
            var attributes: [AttributeChange] = []
            for attribute in change.changes {
                guard let key = string(attribute.key) else { return nil }
                attributes.append(
                    AttributeChange(key: key, before: attribute.before, after: attribute.after)
                )
            }
            changes.append(NodeChange(path: at, changes: attributes))
        }

        return TreeDelta(added: additions, removed: removals, moved: moves, changed: changes)
    }
}
