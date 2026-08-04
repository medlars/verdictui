import XCTest

@testable import VerdictUIKernel

/// Property-style verification of the diff round-trip: for randomly generated
/// trees and randomly generated mutations,
/// `apply(compute(before:after:), to: before) == after`.
///
/// The generator is a seeded SplitMix64, so a failure reproduces exactly — the
/// project treats nondeterministic test output as P0 debt.
final class TreeDiffPropertyTests: XCTestCase {

    /// Deterministic `RandomNumberGenerator` (SplitMix64). Reproducibility is the
    /// entire point: a shrinking-free property test is only useful if the failing
    /// case comes back on the next run.
    private struct SeededGenerator: RandomNumberGenerator {
        private var state: UInt64

        init(seed: UInt64) { state = seed }

        mutating func next() -> UInt64 {
            state = state &+ 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    private enum Mutation: CaseIterable {
        case insert, delete, moveFrame, mutateFields, reparent, reorder
    }

    private struct Census {
        var added = 0
        var removed = 0
        var moved = 0
        var changed = 0
    }

    private static let roles: [Role] = [
        .container, .text, .button, .toggle, .image, .list, .listRow, .custom("badge"),
    ]

    // MARK: - The properties

    func testDeltaRoundTripsOnProbedTrees() throws {
        try runProperty(seed: 0x0001_1E1D_1C7A_0001, probed: true)
    }

    /// Unprobed nodes are matched by structural path, which shifts when a sibling
    /// is inserted (the probe recomputes paths every layout pass). The round-trip
    /// must still be exact — the delta simply carries more removals and additions.
    func testDeltaRoundTripsOnUnprobedStructuralTrees() throws {
        try runProperty(seed: 0x0002_57B0_C7A1_0002, probed: false)
    }

    private func runProperty(seed: UInt64, probed: Bool, iterations: Int = 200) throws {
        var rng = SeededGenerator(seed: seed)
        var census = Census()

        for iteration in 0..<iterations {
            var counter = 0
            let before = canonicalized(
                makeTree(depth: 3, counter: &counter, using: &rng, probed: probed),
                probed: probed
            )
            var after = before
            for _ in 0..<Int.random(in: 1...4, using: &rng) {
                after = mutate(after, counter: &counter, using: &rng, probed: probed)
            }
            after = canonicalized(after, probed: probed)

            let delta = TreeDiff.compute(before: before, after: after)
            let context = "seed \(seed) iteration \(iteration)"

            XCTAssertEqual(
                delta.isEmpty,
                before == after,
                "delta emptiness must track tree equality — \(context)"
            )
            XCTAssertEqual(
                TreeDiff.compute(before: before, after: after),
                delta,
                "compute must be deterministic — \(context)"
            )

            let rebuilt = try TreeDiff.apply(delta, to: before)
            XCTAssertEqual(rebuilt, after, "apply(compute()) must reproduce the tree — \(context)")

            census.added += delta.added.count
            census.removed += delta.removed.count
            census.moved += delta.moved.count
            census.changed += delta.changed.count
        }

        // Guard against a generator that silently stops producing interesting
        // trees: a round-trip test over only-empty deltas proves nothing.
        XCTAssertGreaterThan(census.added, 0, "no additions exercised")
        XCTAssertGreaterThan(census.removed, 0, "no removals exercised")
        XCTAssertGreaterThan(census.moved, 0, "no moves exercised")
        XCTAssertGreaterThan(census.changed, 0, "no field changes exercised")
    }

    // MARK: - Generation

    private func canonicalized(_ tree: SemanticNode, probed: Bool) -> SemanticNode {
        probed ? tree : tree.withAssignedStructuralPaths()
    }

    private func makeTree(
        depth: Int,
        counter: inout Int,
        using rng: inout SeededGenerator,
        probed: Bool
    ) -> SemanticNode {
        counter += 1
        let serial = counter
        let childCount = depth <= 0 ? 0 : Int.random(in: 0...3, using: &rng)
        let children = (0..<childCount).map { _ in
            makeTree(depth: depth - 1, counter: &counter, using: &rng, probed: probed)
        }
        return SemanticNode(
            id: probed ? "n\(serial)" : "",
            role: Self.roles.randomElement(using: &rng) ?? .container,
            frame: randomRect(using: &rng),
            text: Bool.random(using: &rng) ? "t\(serial)" : nil,
            attributes: Bool.random(using: &rng)
                ? ["badgeCount": .number(Double(serial % 5))] : [:],
            isVisible: Bool.random(using: &rng),
            zIndex: Bool.random(using: &rng) ? Double(serial % 3) : nil,
            textMetrics: Bool.random(using: &rng)
                ? TextMetrics(
                    intrinsicWidth: Double(Int.random(in: 10...300, using: &rng)),
                    renderedLineCount: Int.random(in: 0...3, using: &rng),
                    idealLineCount: Int.random(in: 0...3, using: &rng)
                )
                : nil,
            children: children
        )
    }

    private func randomRect(using rng: inout SeededGenerator) -> Rect {
        Rect(
            x: Double(Int.random(in: 0...200, using: &rng)),
            y: Double(Int.random(in: 0...200, using: &rng)),
            width: Double(Int.random(in: 0...80, using: &rng)),
            height: Double(Int.random(in: 0...80, using: &rng))
        )
    }

    // MARK: - Mutation

    private func mutate(
        _ tree: SemanticNode,
        counter: inout Int,
        using rng: inout SeededGenerator,
        probed: Bool
    ) -> SemanticNode {
        switch Mutation.allCases.randomElement(using: &rng) ?? .mutateFields {
        case .insert:
            let parent = indexPaths(of: tree).randomElement(using: &rng) ?? []
            let parentNode = node(tree, at: parent)
            let index = Int.random(in: 0...parentNode.children.count, using: &rng)
            let fresh = makeTree(depth: 1, counter: &counter, using: &rng, probed: probed)
            return inserting(fresh, into: tree, atParent: parent, index: index)
        case .delete:
            guard let victim = nonRootIndexPaths(of: tree).randomElement(using: &rng) else {
                return tree
            }
            return removing(tree, at: victim)
        case .moveFrame:
            let path = indexPaths(of: tree).randomElement(using: &rng) ?? []
            var target = node(tree, at: path)
            target.frame = randomRect(using: &rng)
            return replacing(tree, at: path, with: target)
        case .mutateFields:
            let path = indexPaths(of: tree).randomElement(using: &rng) ?? []
            var target = node(tree, at: path)
            mutateFields(of: &target, counter: &counter, using: &rng)
            return replacing(tree, at: path, with: target)
        case .reparent:
            return reparenting(tree, using: &rng)
        case .reorder:
            let candidates = indexPaths(of: tree).filter { node(tree, at: $0).children.count > 1 }
            guard let path = candidates.randomElement(using: &rng) else { return tree }
            var target = node(tree, at: path)
            target.children = target.children.shuffled(using: &rng)
            return replacing(tree, at: path, with: target)
        }
    }

    private func mutateFields(
        of target: inout SemanticNode,
        counter: inout Int,
        using rng: inout SeededGenerator
    ) {
        counter += 1
        switch Int.random(in: 0...5, using: &rng) {
        case 0:
            target.text = Bool.random(using: &rng) ? "m\(counter)" : nil
        case 1:
            target.isVisible.toggle()
        case 2:
            target.zIndex = Bool.random(using: &rng) ? Double(counter % 4) : nil
        case 3:
            target.attributes["badgeCount"] =
                Bool.random(using: &rng) ? .number(Double(counter % 7)) : nil
        case 4:
            target.role = Self.roles.randomElement(using: &rng) ?? .container
        default:
            target.textMetrics =
                Bool.random(using: &rng)
                ? TextMetrics(
                    intrinsicWidth: Double(counter % 300),
                    renderedLineCount: counter % 4,
                    idealLineCount: (counter + 1) % 4
                )
                : nil
        }
    }

    private func reparenting(_ tree: SemanticNode, using rng: inout SeededGenerator) -> SemanticNode {
        guard let source = nonRootIndexPaths(of: tree).randomElement(using: &rng) else { return tree }
        let subtree = node(tree, at: source)
        let pruned = removing(tree, at: source)
        // Destinations are recomputed on the pruned tree so no path can point
        // inside the subtree that just moved.
        guard let destination = indexPaths(of: pruned).randomElement(using: &rng) else { return tree }
        let index = Int.random(in: 0...node(pruned, at: destination).children.count, using: &rng)
        return inserting(subtree, into: pruned, atParent: destination, index: index)
    }

    // MARK: - Index-path plumbing

    private func indexPaths(of node: SemanticNode, prefix: [Int] = []) -> [[Int]] {
        var result = [prefix]
        for (index, child) in node.children.enumerated() {
            result.append(contentsOf: indexPaths(of: child, prefix: prefix + [index]))
        }
        return result
    }

    private func nonRootIndexPaths(of node: SemanticNode) -> [[Int]] {
        indexPaths(of: node).filter { !$0.isEmpty }
    }

    private func node(_ root: SemanticNode, at path: [Int]) -> SemanticNode {
        path.reduce(root) { current, index in current.children[index] }
    }

    private func replacing(_ root: SemanticNode, at path: [Int], with node: SemanticNode)
        -> SemanticNode
    {
        guard let index = path.first else { return node }
        var copy = root
        copy.children[index] = replacing(root.children[index], at: Array(path.dropFirst()), with: node)
        return copy
    }

    private func removing(_ root: SemanticNode, at path: [Int]) -> SemanticNode {
        guard let index = path.first else { return root }
        var copy = root
        if path.count == 1 {
            copy.children.remove(at: index)
        } else {
            copy.children[index] = removing(root.children[index], at: Array(path.dropFirst()))
        }
        return copy
    }

    private func inserting(
        _ child: SemanticNode,
        into root: SemanticNode,
        atParent path: [Int],
        index: Int
    ) -> SemanticNode {
        var copy = root
        if let first = path.first {
            copy.children[first] = inserting(
                child,
                into: root.children[first],
                atParent: Array(path.dropFirst()),
                index: index
            )
        } else {
            copy.children.insert(child, at: index)
        }
        return copy
    }
}
