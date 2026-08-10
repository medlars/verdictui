import SwiftUI
import VerdictUIKernel
import VerdictUIMacroSupport
import XCTest

/// The half of the macro's evidence that `assertMacroExpansion` cannot supply.
///
/// A snapshot test compares generated *text*, so a macro that emits
/// syntactically perfect source naming a method that does not exist passes it
/// and fails only in a consumer's build. Everything in this file uses the macro
/// for real: if the expansion does not compile, this target does not build, and
/// if it compiles but produces no usable tree, the assertions below fail.
///
/// This is also the file that fails when SwiftSyntax or the toolchain moves
/// under us — the wave's named top risk — because a macro that no longer
/// expands stops satisfying `View` conformance here rather than silently
/// generating nothing.
@MainActor
final class VerifiableCompilationTests: XCTestCase {
    /// Drains the autorelease pool around every test in this class.
    ///
    /// `swift test` has no window-server run loop to pump the pool between
    /// tests, so the `NSHostingView` hierarchies built below — and their
    /// CoreAnimation layers — would accumulate until the suite wedges at 0% CPU.
    /// Each test still passes in isolation, which is what makes the failure so
    /// late and so confusing; this repo has already paid for that lesson once,
    /// when a Wave 3 hang read as a framework bug.
    override func invokeTest() {
        autoreleasepool { super.invokeTest() }
    }

    /// A view whose only instrumentation is the attribute.
    @Verifiable
    struct MacroProbedRow: View {
        var body: some View {
            Text("row")
                .verdictProbe("row-label", role: .text, text: "row")
        }
    }

    /// A view carrying NO manual probe at all — the adoption claim of the whole
    /// wave: two tokens (`@Verifiable`, and later `#VerdictScenario`) buy full
    /// verification. If the walk does not run, this view's tree is a bare root
    /// with nothing under it.
    @Verifiable
    struct UnprobedRow: View {
        var body: some View {
            Text("hello")
        }
    }

    /// The same view, instrumented by hand. `verdictProbedBody` is written out
    /// as the macro would generate it — this is the differential twin.
    struct HandProbedRow: View {
        var body: some View {
            Text("row")
                .verdictProbe("row-label", role: .text, text: "row")
        }

        func verdictProbedBody(into sink: VerdictTreeSink) -> some View {
            body.verdictRoot(into: sink)
        }
    }

    func testTheGeneratedMemberExistsAndIsCallable() {
        // Reaching `verdictProbedBody` at all is the assertion: if the macro
        // expanded to nothing, this file would not compile. Calling it proves
        // the generated signature matches what a consumer is told to expect.
        let sink = VerdictTreeSink()
        _ = MacroProbedRow().verdictProbedBody(into: sink)
    }

    func testTheMacroProducesTheSameTreeAsTheHandProbedTwin() throws {
        // The plan's correctness oracle for the wave: macro tree ≡ hand tree.
        // Compared on the parts that describe STRUCTURE and IDENTITY — ids,
        // roles and text — rather than on the whole node, because frames carry
        // measured geometry that is equal here but is not the claim being made.
        let macroTree = try renderTree { sink in
            AnyView(MacroProbedRow().verdictProbedBody(into: sink))
        }
        let handTree = try renderTree { sink in
            AnyView(HandProbedRow().verdictProbedBody(into: sink))
        }

        XCTAssertEqual(
            descriptors(of: macroTree),
            descriptors(of: handTree),
            "The macro-probed tree diverged from its hand-probed twin. The macro's "
                + "whole promise is that it is a shorthand for the manual spelling."
        )
    }

    func testTheMacroTreeActuallyContainsTheProbedNode() throws {
        // Guards the trap the test above cannot see: if BOTH trees were empty,
        // they would be equal and the differential test would pass while
        // proving nothing (no.md #12 — an assertion satisfied identically by the
        // correct and the broken implementation is not a test).
        let macroTree = try renderTree { sink in
            AnyView(MacroProbedRow().verdictProbedBody(into: sink))
        }
        XCTAssertTrue(
            descriptors(of: macroTree).contains { $0.contains("row-label") },
            "The macro-probed tree has no 'row-label' node: \(descriptors(of: macroTree))"
        )
    }

    /// The shape that nearly shipped unprobed: a container carrying a modifier.
    @Verifiable
    struct ModifiedContainerRow: View {
        var body: some View {
            VStack {
                Text("alpha")
                Text("beta")
            }.padding(7)
        }
    }

    func testEveryElementInsideAModifiedContainerReachesTheTree() throws {
        // `VStack { … }.padding()` is the commonest shape in real SwiftUI, and
        // it was silently producing an EMPTY tree: the outer call is `.padding`,
        // whose callee is a member access whose base holds the closure, and the
        // walk was not recursing there. Every rule then reports PASS on a screen
        // nobody instrumented.
        //
        // Asserted at RUNTIME rather than only in a snapshot, because the
        // snapshot compares generated text and this failure is about what
        // reaches the kernel.
        let tree = try renderTree { sink in
            AnyView(ModifiedContainerRow().verdictProbedBody(into: sink))
        }
        let lines = descriptors(of: tree)
        for expected in ["alpha", "beta"] {
            XCTAssertTrue(
                lines.contains { $0.hasSuffix("|text|\(expected)") },
                "'\(expected)' never reached the tree from inside a modified container: \(lines)"
            )
        }
    }

    func testAnUnprobedElementIsProbedByTheMacroAlone() throws {
        // Wave 4 Task 2. The tree from a view carrying no manual probe must
        // still contain a node for its `Text`, with the text it renders and the
        // `.text` role — otherwise `@Verifiable` buys a root and nothing else,
        // and every rule in the kernel has nothing to evaluate.
        let tree = try renderTree { sink in
            AnyView(UnprobedRow().verdictProbedBody(into: sink))
        }
        let lines = descriptors(of: tree)
        XCTAssertTrue(
            lines.contains { $0.hasSuffix("|text|hello") },
            "No generated probe for the unprobed Text. Tree was: \(lines)"
        )
    }

    func testAGeneratedIdIsALegalProbeId() throws {
        // `verdictProbe` PRECONDITIONS on the id, so an illegal generated id
        // crashes the consumer's process instead of producing a finding. That
        // makes it the one macro defect no rule can report, which is why it is
        // asserted against the kernel's own judgement rather than against a
        // shape this test invents.
        let tree = try renderTree { sink in
            AnyView(UnprobedRow().verdictProbedBody(into: sink))
        }
        var ids: [String] = []
        func collect(_ node: SemanticNode) {
            ids.append(node.id)
            node.children.forEach(collect)
        }
        collect(tree)
        // Two node kinds are not the macro's output and must not be asserted on:
        // the root's own container, which `verdictRoot` reports with an EMPTY
        // id, and unprobed nodes, which `SemanticNode.identity` names from their
        // structural path with an `@` prefix. Filtered by what those ids LOOK
        // like rather than by position — the first version of this test dropped
        // the first node on the assumption it was always the root, and with a
        // single probe the assembler makes the PROBE the root, so it dropped the
        // only node under test and reported "cannot discriminate" while the
        // walk was working.
        let generated = ids.filter { !$0.hasPrefix("@") && !$0.isEmpty }
        XCTAssertFalse(
            generated.isEmpty,
            "No probed node at all, so this test cannot discriminate: \(ids)"
        )
        for id in generated {
            XCTAssertNil(
                ProbeRecord.idViolation(id),
                "Generated id '\(id)' is illegal: \(ProbeRecord.idViolation(id) ?? "")"
            )
        }
    }

    /// A container carrying an explicit probe, with unprobed elements inside it.
    @Verifiable
    struct HandProbedContainerRow: View {
        var body: some View {
            VStack {
                Text("inner-alpha")
                Text("inner-beta")
            }.verdictProbe("outer-container", role: .container)
        }
    }

    func testElementsNestedInsideAHandProbedContainerAreStillProbed() throws {
        // The false-green this product exists to prevent, in its most dangerous
        // form. An explicit `.verdictProbe` on an OUTER container made the walk
        // return the entire expression untouched — including everything nested
        // inside it — so a screen whose author probed the container by hand got
        // a tree with ONE node and no content.
        //
        // `vacuous-verdict` cannot catch this: that guard fires when the tree
        // carries no probed node at all, and here the container's own probe
        // makes the tree look observed. Every rule then reports PASS about
        // content nobody instrumented, and nothing anywhere reports the gap.
        // An explicit probe must suppress probing AT THAT POSITION only, never
        // recursion into children.
        let tree = try renderTree { sink in
            AnyView(HandProbedContainerRow().verdictProbedBody(into: sink))
        }
        let lines = descriptors(of: tree)
        XCTAssertTrue(
            lines.contains { $0.contains("outer-container") },
            "The hand-written container probe was lost: \(lines)"
        )
        for expected in ["inner-alpha", "inner-beta"] {
            XCTAssertTrue(
                lines.contains { $0.hasSuffix("|text|\(expected)") },
                "'\(expected)' was swallowed by the container's explicit probe: \(lines)"
            )
        }
    }

    // MARK: - Helpers

    /// Renders a view windowlessly and returns the tree it delivered.
    private func renderTree(_ build: (VerdictTreeSink) -> AnyView) throws -> SemanticNode {
        let sink = VerdictTreeSink()
        let hosting = NSHostingView(rootView: build(sink))
        hosting.frame = CGRect(x: 0, y: 0, width: 320, height: 120)
        hosting.layoutSubtreeIfNeeded()
        return try XCTUnwrap(
            sink.latestTree,
            "No tree was delivered — the root modifier never ran."
        )
    }

    /// Flattens a tree to `id|role|text` lines, sorted.
    ///
    /// Sorted because sibling order is not the property under test here and an
    /// order-sensitive comparison would make this test fail for reasons that
    /// have nothing to do with the macro.
    private func descriptors(of node: SemanticNode) -> [String] {
        var out: [String] = []
        func walk(_ current: SemanticNode) {
            out.append("\(current.id)|\(current.role)|\(current.text ?? "")")
            current.children.forEach(walk)
        }
        walk(node)
        return out.sorted()
    }
}
