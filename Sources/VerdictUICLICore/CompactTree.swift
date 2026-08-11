// Wave 7: the token-frugal wire format.
//
// An agent pays per token, so the shape a tree arrives in is a PRODUCT feature
// rather than a serialization detail. Nested JSON spends most of its bytes on
// repeated keys and structural punctuation: every node in a 40-node tree
// carries its own `"role":`, `"frame":`, `"x":`, `"width":` — the same nine
// strings, forty times.
//
// This encodes a tree as parallel arrays plus a parent-index list, with every
// repeated string interned. The structure survives exactly (the parent index IS
// the tree) and the byte count drops by the repetition.
import Foundation
import VerdictUIKernel

/// A semantic tree flattened into parallel arrays.
///
/// ### Reading one
///
/// Node `i` has id `ids[i]`, role `strings[roleIDs[i]]`, and frame
/// `frames[i*4..<i*4+4]` as `x, y, width, height`. Its parent is node
/// `parents[i]`, or `-1` for the root. Nodes appear in depth-first order, so a
/// consumer that wants the tree back walks the array once.
///
/// ### Why a string table
///
/// Roles repeat heavily — a real screen is mostly `text` and `container` — and
/// so do texts in list-shaped UI. Interning turns each repeat into one small
/// integer. Ids are NOT interned: they are unique by construction (that is what
/// makes them ids), so a table would add an index per node and save nothing.
public struct CompactTree: Codable, Sendable, Equatable {
    /// Probe id per node, `""` for an unprobed node.
    public let ids: [String]
    /// Index into ``strings`` for each node's role.
    public let roleIDs: [Int]
    /// Index into ``strings`` for each node's text, or `-1` when it has none.
    public let textIDs: [Int]
    /// Flattened `x, y, width, height` — four entries per node.
    public let frames: [Double]
    /// Parent index per node; `-1` marks the root.
    public let parents: [Int]
    /// The interned string table.
    public let strings: [String]
    /// Text metrics per node, `nil` where the probe reported none.
    ///
    /// Carried rather than dropped because ``TruncationRule`` reads exactly
    /// this: a wire format that discards it round-trips into a tree on which
    /// truncation can no longer be judged, and every verdict computed from the
    /// far side would report a clean screen for a clipped label. Sparse by
    /// nature — most nodes are not text — so the cost is one `null` per
    /// non-text node.
    public let textMetrics: [TextMetrics?]
    /// Structural path per node.
    ///
    /// The path is what a finding cites when a node has no probe id, so
    /// dropping it makes exactly the unprobed nodes unaddressable — the ones a
    /// reader most needs located.
    public let structuralPaths: [String]
    /// True when the tree was truncated to fit a byte budget.
    ///
    /// Named on the wire rather than inferred: a consumer must be able to tell
    /// "this is the whole screen" from "this is as much of it as fit", and a
    /// truncated tree that looks complete is a verdict about a screen nobody
    /// saw all of.
    public let truncated: Bool

    /// Build the arrays directly.
    ///
    /// Public so a client can construct one from a decoded payload, and so the
    /// malformed cases ``expand()`` must survive can be written down: those
    /// arrays arrive over a socket from a process this one does not control, so
    /// "a parent index pointing outside the array" is untrusted input rather
    /// than a hypothetical.
    public init(
        ids: [String],
        roleIDs: [Int],
        textIDs: [Int],
        frames: [Double],
        parents: [Int],
        strings: [String],
        textMetrics: [TextMetrics?]? = nil,
        structuralPaths: [String]? = nil,
        truncated: Bool
    ) {
        self.ids = ids
        self.roleIDs = roleIDs
        self.textIDs = textIDs
        self.frames = frames
        self.parents = parents
        self.strings = strings
        self.textMetrics = textMetrics ?? Array(repeating: nil, count: ids.count)
        self.structuralPaths = structuralPaths ?? Array(repeating: "", count: ids.count)
        self.truncated = truncated
    }

    /// Flatten `tree`.
    ///
    /// - Parameter maxNodes: stop after this many nodes, setting ``truncated``.
    ///   `nil` encodes the whole tree.
    public init(_ tree: SemanticNode, maxNodes: Int? = nil) {
        var ids: [String] = []
        var roleIDs: [Int] = []
        var textIDs: [Int] = []
        var frames: [Double] = []
        var parents: [Int] = []
        var metrics: [TextMetrics?] = []
        var paths: [String] = []
        var table: [String: Int] = [:]
        var strings: [String] = []
        var didTruncate = false

        func intern(_ value: String) -> Int {
            if let existing = table[value] { return existing }
            let index = strings.count
            table[value] = index
            strings.append(value)
            return index
        }

        // Depth-first with an explicit stack rather than recursion: a deeply
        // nested SwiftUI hierarchy is ordinary, and a stack overflow inside a
        // serializer would surface as a crash in the daemon rather than as a
        // finding.
        var stack: [(node: SemanticNode, parent: Int)] = [(tree, -1)]
        while let (node, parent) = stack.popLast() {
            if let maxNodes, ids.count >= maxNodes {
                didTruncate = true
                break
            }
            let index = ids.count
            ids.append(node.id)
            roleIDs.append(intern(node.role.identifier))
            textIDs.append(node.text.map(intern) ?? -1)
            frames.append(contentsOf: [
                node.frame.x, node.frame.y, node.frame.width, node.frame.height,
            ])
            parents.append(parent)
            metrics.append(node.textMetrics)
            paths.append(node.structuralPath)

            // Reversed so children are popped in declaration order — a report
            // that lists siblings backwards is technically complete and
            // unreadable next to the source.
            for child in node.children.reversed() {
                stack.append((child, index))
            }
        }

        self.ids = ids
        self.roleIDs = roleIDs
        self.textIDs = textIDs
        self.frames = frames
        self.parents = parents
        self.strings = strings
        self.textMetrics = metrics
        self.structuralPaths = paths
        self.truncated = didTruncate
    }

    /// How many nodes this encodes.
    public var nodeCount: Int { ids.count }

    /// Rebuild the nested tree.
    ///
    /// The round trip is the correctness argument for the whole format: a
    /// compaction that cannot be reversed is a lossy summary wearing an
    /// encoding's name, and `CompactTreeTests` pins it against the demo
    /// catalog rather than against hand-built fixtures.
    ///
    /// - Returns: the root, or `nil` when the arrays are empty or inconsistent.
    public func expand() -> SemanticNode? {
        guard !ids.isEmpty else { return nil }
        guard
            roleIDs.count == ids.count,
            textIDs.count == ids.count,
            parents.count == ids.count,
            textMetrics.count == ids.count,
            structuralPaths.count == ids.count,
            frames.count == ids.count * 4
        else { return nil }

        // Children are collected first, then nodes are built from the leaves
        // up, because `SemanticNode` is a value type: a parent must know its
        // children before it can be constructed.
        var childIndices: [[Int]] = Array(repeating: [], count: ids.count)
        var rootIndex: Int?
        for (index, parent) in parents.enumerated() {
            if parent == -1 {
                // A second root means the arrays do not describe one tree.
                if rootIndex != nil { return nil }
                rootIndex = index
                continue
            }
            guard parent >= 0, parent < ids.count, parent != index else { return nil }
            childIndices[parent].append(index)
        }
        guard let root = rootIndex else { return nil }

        func build(_ index: Int) -> SemanticNode? {
            guard
                roleIDs[index] >= 0, roleIDs[index] < strings.count,
                textIDs[index] < strings.count
            else { return nil }

            var children: [SemanticNode] = []
            for child in childIndices[index] {
                guard let built = build(child) else { return nil }
                children.append(built)
            }
            let base = index * 4
            return SemanticNode(
                id: ids[index],
                role: Role(identifier: strings[roleIDs[index]]),
                frame: Rect(
                    x: frames[base],
                    y: frames[base + 1],
                    width: frames[base + 2],
                    height: frames[base + 3]
                ),
                text: textIDs[index] >= 0 ? strings[textIDs[index]] : nil,
                textMetrics: textMetrics[index],
                structuralPath: structuralPaths[index],
                children: children
            )
        }
        return build(root)
    }
}
