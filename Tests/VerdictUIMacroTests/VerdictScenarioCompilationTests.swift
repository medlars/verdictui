import SwiftUI
import VerdictUIKernel
import VerdictUIMacroSupport
import XCTest

// The scenarios under test, declared inside an enum rather than at file scope.
//
// That nesting is REQUIRED, not stylistic: the compiler rejects the file-scope
// spelling outright with "'declaration' macros are not allowed to introduce
// arbitrary names at global scope". A freestanding declaration macro whose
// `names:` is `arbitrary` — which this one must be, since the generated type
// name is derived from a string the author writes and is therefore unknowable
// to the declaration — may only expand where the compiler can bound the names
// it introduces, and type scope is such a place. The typealiases below keep the
// call sites in this file short; a consumer writes `MacroScenarios.Checkout…`
// or adds their own alias.
//
// These three declarations are themselves an assertion: if the macro fails to
// expand, or expands to source that does not compile, this file does not build
// and the whole target fails. That is the half `assertMacroExpansion` cannot
// supply — a snapshot compares text and cannot tell that generated source names
// a protocol requirement it does not satisfy.
enum MacroScenarios {
    #VerdictScenario("macro-checkout") {
        Text("Total: $42.00")
        Button("Pay") {}
    }

    #VerdictScenario("macro-single") {
        Text("only")
    }

    // Exercises the name → type-name transform on a name that is not already an
    // identifier: spaces and hyphens are word boundaries, so this is
    // `MacroTwoWordsScenario`.
    #VerdictScenario("macro two-words") {
        Text("named")
    }
}

private typealias MacroCheckoutScenario = MacroScenarios.MacroCheckoutScenario
private typealias MacroSingleScenario = MacroScenarios.MacroSingleScenario
private typealias MacroTwoWordsScenario = MacroScenarios.MacroTwoWordsScenario

/// The runtime half of `#VerdictScenario`'s evidence.
///
/// Everything here uses the macro for real: the scenarios above are hosted
/// through ``OracleHost`` exactly as a hand-written conformance would be, so a
/// macro that generated a type the harness cannot accept fails here rather than
/// in a consumer's build.
@MainActor
final class VerdictScenarioCompilationTests: XCTestCase {
    /// Drains the autorelease pool around every test in this class.
    ///
    /// `swift test` has no window-server run loop to pump the pool between
    /// tests, so `NSHostingView` hierarchies and their CoreAnimation layers
    /// accumulate until the suite wedges at 0% CPU. Each test still passes in
    /// isolation, which is what makes the failure so late and so confusing.
    override func invokeTest() {
        autoreleasepool { super.invokeTest() }
    }

    func testTheGeneratedTypeConformsAndCarriesTheAuthoredName() {
        // `name` is the key a verdict is filed under and, from Wave 5, a
        // baseline key — so it must be the string the author wrote, never the
        // derived type name.
        XCTAssertEqual(MacroCheckoutScenario().name, "macro-checkout")
        XCTAssertEqual(MacroTwoWordsScenario().name, "macro two-words")
    }

    func testTheScenarioRendersThroughTheHarness() async throws {
        // The claim that matters: a macro-declared scenario is a scenario. If
        // the generated `body(state:)` did not satisfy the protocol, or the
        // type were not one `OracleHost` can instantiate, this would not build.
        let host = MacroCheckoutScenario.verdictEntry.host()
        let tree = try await host.currentTree()
        let lines = descriptors(of: tree)
        for expected in ["Total: $42.00", "Pay"] {
            XCTAssertTrue(
                lines.contains { $0.hasSuffix("|\(expected)") },
                "'\(expected)' never reached the tree: \(lines)"
            )
        }
    }

    func testTheScenarioBodyIsProbedByTheMacroAlone() async throws {
        // The wave's adoption claim. The closure above carries NO manual probe,
        // so every node below the root exists only because the walk ran. A
        // scenario macro that declared a conformance without probing would
        // produce a tree with a root and nothing under it, and every rule would
        // report PASS on a screen nobody instrumented.
        let host = MacroSingleScenario.verdictEntry.host()
        let tree = try await host.currentTree()
        var ids: [String] = []
        func collect(_ node: SemanticNode) {
            ids.append(node.id)
            node.children.forEach(collect)
        }
        collect(tree)
        // Generated ids only: the root's own container is reported with an EMPTY
        // id and unprobed nodes are named from their structural path with an `@`
        // prefix, so neither is the macro's output.
        let generated = ids.filter { !$0.hasPrefix("@") && !$0.isEmpty }
        XCTAssertFalse(
            generated.isEmpty,
            "The scenario body was never probed — tree ids were: \(ids)"
        )
        XCTAssertTrue(
            generated.contains { $0.hasPrefix("MacroSingleScenario.") },
            "Generated ids are not namespaced under the scenario type: \(generated)"
        )
    }

    func testAGeneratedScenarioIdIsALegalProbeId() async throws {
        // `verdictProbe` PRECONDITIONS on the id, so an illegal generated id
        // crashes the consumer's process instead of producing a finding — the
        // one macro defect no rule can report. Asserted against the kernel's own
        // judgement rather than a shape this test invents.
        let host = MacroTwoWordsScenario.verdictEntry.host()
        let tree = try await host.currentTree()
        var ids: [String] = []
        func collect(_ node: SemanticNode) {
            ids.append(node.id)
            node.children.forEach(collect)
        }
        collect(tree)
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

    // MARK: - The registry

    func testTheGeneratedEntryCarriesTheScenarioName() {
        // The entry reads its name off a constructed instance, so an entry and
        // its scenario cannot disagree about what a verdict is filed under.
        XCTAssertEqual(MacroCheckoutScenario.verdictEntry.name, "macro-checkout")
    }

    func testARegistryLooksUpEveryRegisteredScenarioByName() {
        let registry = ScenarioRegistry([
            MacroCheckoutScenario.verdictEntry,
            MacroSingleScenario.verdictEntry,
            MacroTwoWordsScenario.verdictEntry,
        ])
        XCTAssertEqual(registry.names, ["macro-checkout", "macro-single", "macro two-words"])
        XCTAssertEqual(registry.entry(named: "macro-single")?.name, "macro-single")
        XCTAssertNil(registry.entry(named: "never-registered"))
    }

    func testAnUnregisteredScenarioIsAbsentRatherThanQuietlyPresent() {
        // The cost of static registration, pinned as a fact: a scenario that
        // exists as a type but was never listed is NOT in the registry. This is
        // the behaviour a runtime scan would paper over, and pinning it here is
        // what stops someone "fixing" the registry into a reflection-based one
        // without the ADR that decision would need.
        let registry = ScenarioRegistry([MacroCheckoutScenario.verdictEntry])
        XCTAssertEqual(registry.names, ["macro-checkout"])
        XCTAssertNil(registry.entry(named: "macro-single"))
    }

    func testDuplicateNamesAreReportedRatherThanSilentlyDropped() {
        // A name is a verdict's filing key, so a collision files two scenarios'
        // results under one identity. The registry keeps both and reports the
        // collision: dropping one would make a scenario vanish from a run with
        // nothing anywhere saying so.
        let registry = ScenarioRegistry([
            MacroCheckoutScenario.verdictEntry,
            MacroCheckoutScenario.verdictEntry,
            MacroSingleScenario.verdictEntry,
        ])
        XCTAssertEqual(registry.duplicateNames, ["macro-checkout"])
        XCTAssertEqual(registry.entries.count, 3, "A duplicate must not be dropped")
    }

    func testARegistryWithNoCollisionsReportsNone() {
        // The control for the test above: without it, `duplicateNames` could
        // return every name and still satisfy the duplicate assertion.
        let registry = ScenarioRegistry([
            MacroCheckoutScenario.verdictEntry,
            MacroSingleScenario.verdictEntry,
        ])
        XCTAssertEqual(registry.duplicateNames, [])
    }

    func testEachHostCallBuildsAFreshScenario() async throws {
        // A host owns the render it was constructed for, so two hosts must not
        // share one scenario value. Asserted by rendering twice and requiring
        // both trees — a stored-instance entry would still return a tree here,
        // so this pins that repeated hosting WORKS rather than merely that the
        // closure exists.
        let first = try await MacroSingleScenario.verdictEntry.host().currentTree()
        let second = try await MacroSingleScenario.verdictEntry.host().currentTree()
        XCTAssertEqual(descriptors(of: first), descriptors(of: second))
    }

    // MARK: - Helpers

    /// Flattens a tree to `id|role|text` lines, sorted.
    ///
    /// Sorted because sibling order is not the property under test here, and an
    /// order-sensitive comparison would fail for reasons unrelated to the macro.
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
