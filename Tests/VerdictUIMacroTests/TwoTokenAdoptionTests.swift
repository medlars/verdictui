import SwiftUI
import VerdictUIKernel
import VerdictUIMacroSupport
import XCTest

/// A view written the way an app author writes one: no VerdictUI anywhere in it
/// except the attribute on line one.
///
/// Nothing here is arranged to be verifiable — no `.verdictProbe`, no
/// `.verdictRoot`, no ids chosen for a test. That is the point: this is the
/// BEFORE state of the wave's adoption claim, and the only thing separating it
/// from a fully verified view is the two tokens the exit gate names.
@Verifiable
struct UnadornedSettingsRow: View {
    let title: String

    var body: some View {
        VStack {
            Text("Notifications")
            Button("Enable") {}
        }
    }
}

/// A custom view that is NOT `@Verifiable` — the passthrough case.
///
/// Deliberately plain: a consumer's tree is mostly views like this, and the walk
/// wraps every one of them in `verdictProbing(_:)`.
///
/// File scope, not nested in the test case, and that is REQUIRED rather than
/// stylistic: a `#VerdictScenario` body referencing `TwoTokenAdoptionTests.X`
/// rendered an EMPTY tree — measured, both views missing, not just the plain
/// one. The macro lifts the closure into a generated struct at enum scope, so a
/// name qualified by the enclosing XCTestCase does not resolve the way it reads.
struct PlainCustomRow: View {
    var body: some View {
        Text("plain-content")
    }
}

/// A `@Verifiable` sibling, so one scenario exercises BOTH overloads.
@Verifiable
struct VerifiableCustomRow: View {
    var body: some View {
        Text("verifiable-content")
    }
}

/// The same view, reached through the OTHER token.
///
/// Declared at type scope because a `declaration` macro may not introduce
/// arbitrary names at global scope (see `VerdictScenarioCompilationTests` for
/// the compiler's exact objection).
enum AdoptionScenarios {
    #VerdictScenario("two-token-adoption") {
        UnadornedSettingsRow(title: "ignored")
    }

    /// Both `verdictProbing(_:)` overloads in one render — a `@Verifiable` view
    /// beside a plain one. See `testANonVerifiableViewStillRendersThroughTheProbingOverload`.
    #VerdictScenario("mixed-overload") {
        VStack {
            VerifiableCustomRow()
            PlainCustomRow()
        }
    }
}

/// The Wave 4 exit-gate claim, asserted rather than described.
///
/// > A previously unprobed demo view gains full verification by adding exactly
/// > two tokens (`@Verifiable`, `#VerdictScenario`).
///
/// Every other test in this target checks a PIECE of that — an expansion is
/// well-formed, a probe reaches the tree, a scenario hosts. None of them state
/// the claim itself, and a claim that only appears in prose is not enforced by
/// anything (lesson 215: a sentence describing intent reads exactly like a
/// control and is not one). This file is the control.
@MainActor
final class TwoTokenAdoptionTests: XCTestCase {
    /// Drains the autorelease pool around every test in this class.
    ///
    /// `swift test` has no window-server run loop to pump it between tests, so
    /// `NSHostingView` hierarchies and their CoreAnimation layers accumulate
    /// until the suite wedges at 0% CPU — and each test still passes in
    /// isolation, which is what makes that failure so late and so confusing.
    override func invokeTest() {
        autoreleasepool { super.invokeTest() }
    }

    func testTheTwoTokensBuyAVerdictThatCanSeeTheContent() async throws {
        // The whole adoption claim in one path: host the macro-declared
        // scenario, run the real rule engine over what comes back, and require
        // a verdict that OBSERVED the view.
        //
        // `vacuous-verdict` is the assertion that matters. It fires when a tree
        // carries no probed node, so a PASS from a view the two tokens failed to
        // instrument would be caught here rather than read as success — which is
        // exactly the false green this product exists to prevent, and exactly
        // what the LaunchGate trial found before that guard existed.
        let host = OracleHost(scenario: AdoptionScenarios.TwoTokenAdoptionScenario())
        let tree = try await host.currentTree()
        let verdict = RuleEngine.run(
            rules: RuleEngine.standardRules,
            on: tree,
            context: .macOS(viewport: tree.frame, scenario: "two-token-adoption")
        )

        XCTAssertFalse(
            verdict.findings.contains { $0.rule == "vacuous-verdict" },
            """
            The two tokens produced a tree the engine could not observe. That is \
            the adoption claim failing in its worst form: a PASS about content \
            nobody instrumented. Findings: \(verdict.findings.map { $0.rule })
            """
        )
    }

    func testBothElementsOfTheUnadornedViewReachTheTree() async throws {
        // The positive half. `vacuous-verdict` staying silent proves SOMETHING
        // was probed; it does not prove the view's actual content was, and a
        // walk that probed only the outer container would satisfy the test above
        // while leaving both elements invisible (no.md #23 — a container's own
        // probe makes a tree look observed).
        //
        // So this names the content, and names it by the strings the author
        // wrote rather than by generated ids: an id is the macro's own output
        // and asserting on it would let the macro define its own correctness,
        // while the labels come from the view.
        let host = OracleHost(scenario: AdoptionScenarios.TwoTokenAdoptionScenario())
        let tree = try await host.currentTree()
        let texts = Self.allText(in: tree)

        for expected in ["Notifications", "Enable"] {
            XCTAssertTrue(
                texts.contains(expected),
                "'\(expected)' never reached the tree from an unadorned view: \(texts)"
            )
        }
    }

    func testTheViewCarriesNoVerdictUISpellingOtherThanTheTwoTokens() throws {
        // "Exactly two tokens" is a claim about the SOURCE, and the two tests
        // above cannot see it: they would pass just as well if the view were
        // covered in hand-written probes. Without this, the gate's word
        // "exactly" is unenforced and the fixture could drift into being
        // instrumented by hand while the suite stayed green.
        //
        // Read from the file on disk rather than from a string constant, because
        // a constant is a copy of the fixture and copies drift.
        let source = try String(contentsOf: Self.thisFile, encoding: .utf8)
        let viewSource = try XCTUnwrap(
            source.range(of: "struct UnadornedSettingsRow: View {").map { range in
                String(source[range.lowerBound...].prefix(while: { $0 != "}" }))
            },
            "The fixture view was renamed; this guard can no longer find it."
        )

        for forbidden in ["verdictProbe", "verdictRoot", "VerdictTreeSink"] {
            XCTAssertFalse(
                viewSource.contains(forbidden),
                """
                The fixture view spells '\(forbidden)'. It must stay unadorned — \
                the exit-gate claim is that TWO tokens suffice, and a view carrying \
                manual instrumentation cannot demonstrate that.
                """
            )
        }
    }

    func testANonVerifiableViewStillRendersThroughTheProbingOverload() async throws {
        // The passthrough overload of `verdictProbing(_:)`, at runtime.
        //
        // Until this test, `verdictProbing` appeared ONLY inside expansion
        // snapshots — generated TEXT, which cannot show that the resolved
        // overload renders anything. That leaves the branch a consumer hits most
        // often completely unexercised: most views in a real app are not
        // `@Verifiable`, and the walk wraps every one of them.
        //
        // Two failure modes it closes, both silent. If the passthrough dropped
        // its view, a plain subview would vanish from the render with no finding
        // — the tree would simply be missing content nobody declared. And if the
        // CONSTRAINED overload wrongly captured non-conforming types, this would
        // fail to compile rather than mis-render, which is the good direction.
        //
        // Asserted on the two views TOGETHER, in one scenario, because that is
        // what pins the DISCRIMINATION: a run where both render proves the
        // overloads resolve differently and correctly, where either alone is
        // satisfied by an implementation that treats every view the same way.
        let host = OracleHost(scenario: AdoptionScenarios.MixedOverloadScenario())
        let tree = try await host.currentTree()
        let texts = Self.allText(in: tree)

        // The @Verifiable sibling MUST reach the tree. It is the positive half:
        // it proves the render happened at all and that the constrained overload
        // resolved, so a total failure cannot masquerade as the expected
        // absence asserted below.
        XCTAssertTrue(
            texts.contains("verifiable-content"),
            """
            The @Verifiable sibling did not reach the tree, so the render or the \
            constrained overload is broken and this test cannot discriminate \
            anything. Tree text: \(texts)
            """
        )

        // The plain view must NOT contribute a node, and this expectation was
        // MEASURED after a first draft asserted the opposite and failed.
        //
        // The first version demanded "plain-content" in the tree, conflating two
        // different things: the passthrough overload RENDERS the view (it
        // returns it unchanged), but an unprobed view has nothing to report, so
        // it contributes no NODE. Rendering and being measured are separate
        // facts, and only the second one shows up here.
        //
        // Asserting the absence is what makes this a real discriminator. If the
        // CONSTRAINED overload ever captured non-conforming types — the failure
        // mode that would silently change what every scenario measures —
        // "plain-content" would appear and this fails.
        XCTAssertFalse(
            texts.contains("plain-content"),
            """
            A non-@Verifiable view contributed a node to the tree. It has no \
            probes, so it has nothing to report — its content appearing means \
            the constrained overload captured a type it must not. Tree text: \(texts)
            """
        )
    }

    // MARK: - Helpers

    private static let thisFile = URL(fileURLWithPath: #filePath)

    /// Every non-nil `text` in the tree.
    private static func allText(in node: SemanticNode) -> [String] {
        var out: [String] = []
        func walk(_ current: SemanticNode) {
            if let text = current.text { out.append(text) }
            current.children.forEach(walk)
        }
        walk(node)
        return out
    }
}
