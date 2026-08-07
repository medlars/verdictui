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
