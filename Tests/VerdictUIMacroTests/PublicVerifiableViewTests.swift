// A `public` view carrying `@Verifiable`.
//
// This file exists because every other macro test in this target declares its
// fixtures INTERNAL — most of them nested inside a test class, where `public`
// is not even expressible. That made one whole population invisible: a view
// exported by a library module, which is what any framework, any SPM package,
// and every `SagaMailUI`-style UI target actually ships.
//
// The defect it caught: `VerifiableView` is a PUBLIC protocol requiring
// `verdictProbedContent`, and the macro emitted that member with no access
// modifier — so it was internal, and Swift refuses to satisfy a public
// protocol requirement with an internal member. `@Verifiable` therefore failed
// to compile on every public view, while 775 tests stayed green because not one
// of them was public.
//
// The fixture must be at FILE SCOPE. A type nested in an XCTestCase cannot be
// public, so a nested fixture cannot reproduce this and would silently be
// testing the already-covered internal case.
import SwiftUI
import VerdictUIKernel
import VerdictUIMacroSupport
import XCTest

/// A view as a library module would export it.
///
/// `public` is the entire point of this fixture — demoting it to internal makes
/// the test pass against the broken macro, which is the mistake this comment
/// exists to prevent.
@Verifiable
public struct PublicSettingsRow: View {
    public init() {}

    public var body: some View {
        HStack {
            Text("Notifications")
            Spacer()
            Text("On")
        }
    }
}

/// The same shape without `public`, as the control.
///
/// Without it, "a `@Verifiable` view compiles" is satisfied by a macro that
/// works for nobody — the two fixtures differ in exactly one token, so a
/// failure here separates "public is broken" from "the macro is broken".
@Verifiable
struct InternalSettingsRow: View {
    var body: some View {
        HStack {
            Text("Notifications")
            Spacer()
            Text("On")
        }
    }
}

@MainActor
final class PublicVerifiableViewTests: XCTestCase {
    override func invokeTest() {
        autoreleasepool { super.invokeTest() }
    }

    /// The compile-time half. If the macro emits a non-public
    /// `verdictProbedContent`, this target does not build at all and the
    /// failure is the compiler's, not this assertion's — which is exactly the
    /// signal wanted, because the defect IS a build failure in a consumer.
    ///
    /// The runtime assertion then proves the conformance is real rather than
    /// merely accepted: `verdictProbing` selects its constrained overload only
    /// for a `VerifiableView`, so a probed tree here means the public type
    /// genuinely conforms.
    func testAPublicViewIsProbedThroughItsPublicConformance() throws {
        let sink = VerdictTreeSink()
        let hosting = NSHostingView(
            rootView: AnyView(
                verdictProbing(PublicSettingsRow())
                    .verdictRoot(into: sink)
            )
        )
        hosting.frame = CGRect(x: 0, y: 0, width: 320, height: 44)
        hosting.layoutSubtreeIfNeeded()

        let tree = try XCTUnwrap(sink.latestTree, "no tree delivered for a public view")
        // The macro derives ids as `TypeName.role.index`, so a node named for
        // this type is proof the PUBLIC type's generated content was what
        // rendered — not merely that something rendered.
        let ids = tree.flattened().map(\.id)
        XCTAssertTrue(
            ids.contains { $0.hasPrefix("PublicSettingsRow.") },
            "a public @Verifiable view produced no probed nodes of its own: \(ids)"
        )
    }

    /// The control: the internal spelling must keep working. If a fix to the
    /// public case regressed this, the macro would merely have swapped which
    /// population it fails for.
    func testTheInternalSpellingStillWorks() throws {
        let sink = VerdictTreeSink()
        let hosting = NSHostingView(
            rootView: AnyView(
                verdictProbing(InternalSettingsRow())
                    .verdictRoot(into: sink)
            )
        )
        hosting.frame = CGRect(x: 0, y: 0, width: 320, height: 44)
        hosting.layoutSubtreeIfNeeded()

        let tree = try XCTUnwrap(sink.latestTree, "no tree delivered for an internal view")
        let ids = tree.flattened().map(\.id)
        XCTAssertTrue(
            ids.contains { $0.hasPrefix("InternalSettingsRow.") },
            "the internal spelling regressed: \(ids)"
        )
    }
}
