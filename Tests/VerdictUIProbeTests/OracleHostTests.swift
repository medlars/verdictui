import AppKit
import SwiftUI
import VerdictUIKernel
import XCTest

// `@testable` for the sizing arithmetic: `resolveHostSize(_:)` is the clamp guard,
// and the degenerate inputs it exists for (an infinite `fittingSize`, a NaN one)
// are reachable as function arguments but not reliably reachable through a real
// SwiftUI scenario. Exposing it publicly to test it would be API nobody calls.
@testable import VerdictUIProbe

/// The harness, held to the four promises it makes: the size it renders at, the
/// environment it renders in, the moment it decides the layout has stopped
/// changing, and what it does when that moment never comes.
final class OracleHostTests: XCTestCase {
    /// Every test here builds an AppKit view hierarchy, and `swift test` has no
    /// window-server run loop to drain the autorelease pool between tests. Without
    /// this the hosted hierarchies and their layers accumulate until the suite
    /// wedges at 0% CPU, each test still passing in isolation.
    override func invokeTest() {
        autoreleasepool { super.invokeTest() }
    }

    private static let badgesViewport = Size(width: 200, height: 100)

    // MARK: - The tree

    /// Exact ids, roles, frames and structural paths — the whole tree, compared as
    /// one value.
    ///
    /// Every size in ``BadgesScenario`` is one VerdictUI's own modifiers chose, so
    /// the expected geometry is arithmetic rather than a font metric: the stack is
    /// 100 x 60 (the wider child, plus 30 + 10 + 20), centred in a 200 x 100
    /// viewport at (50, 20); each child is centred within the stack. That is what
    /// makes an exact assertion honest here — a test that pinned the width of a
    /// `Text` would be testing Apple's glyph advances.
    @MainActor
    func testCurrentTreeReturnsTheExpectedTree() async throws {
        let host = OracleHost(scenario: BadgesScenario(), viewport: Self.badgesViewport)
        let tree = try await host.currentTree()

        let expected = SemanticNode(
            id: "",
            role: .container,
            frame: Rect(x: 0, y: 0, width: 200, height: 100),
            structuralPath: "root",
            children: [
                SemanticNode(
                    id: "stack",
                    role: .container,
                    frame: Rect(x: 50, y: 20, width: 100, height: 60),
                    structuralPath: "root/container[0]",
                    children: [
                        SemanticNode(
                            id: "top",
                            role: .image,
                            frame: Rect(x: 50, y: 20, width: 100, height: 30),
                            structuralPath: "root/container[0]/image[0]"
                        ),
                        SemanticNode(
                            id: "bottom",
                            role: .image,
                            frame: Rect(x: 70, y: 60, width: 60, height: 20),
                            structuralPath: "root/container[0]/image[1]"
                        ),
                    ]
                )
            ]
        )

        let rendered = try Self.encoded(tree)
        XCTAssertEqual(tree, expected, "hosted tree differs from the expected one:\n\(rendered)")
    }

    @MainActor
    func testAScenarioWithNoProbesYieldsARootOnlyTree() async throws {
        // Documented, and deliberately not an error: a screen with nothing probed
        // is a screen with nothing to say about it, and the root frame is still a
        // true statement about the viewport. Wave 4's `@Verifiable` macro is what
        // removes the need to probe by hand; until then an unprobed scenario must
        // not look like a broken harness.
        let host = OracleHost(scenario: UnprobedScenario(), viewport: Size(width: 120, height: 40))
        let tree = try await host.currentTree()

        XCTAssertEqual(tree.frame, Rect(x: 0, y: 0, width: 120, height: 40))
        XCTAssertEqual(tree.id, "")
        XCTAssertEqual(tree.role, .container)
        XCTAssertEqual(tree.structuralPath, "root")
        XCTAssertTrue(tree.children.isEmpty)
    }

    // MARK: - Sizing

    @MainActor
    func testAnExplicitViewportBecomesTheRootFrame() async throws {
        let host = OracleHost(scenario: BadgesScenario(), viewport: Size(width: 320, height: 240))
        XCTAssertEqual(host.hostSize, Size(width: 320, height: 240))
        XCTAssertFalse(host.wasClamped)

        let tree = try await host.currentTree()
        XCTAssertEqual(
            tree.frame,
            Rect(x: 0, y: 0, width: 320, height: 240),
            "the root must be the viewport the caller asked for, not the content's own size"
        )
        // Same content, different viewport: the content re-centres, which is the
        // proof that the viewport is what changed rather than the assertion.
        let stack = try XCTUnwrap(tree.node(withID: "stack"))
        XCTAssertEqual(stack.frame, Rect(x: 110, y: 90, width: 100, height: 60))
    }

    @MainActor
    func testAFractionalViewportIsRoundedUpToWholePoints() async throws {
        // Rounding up, never down: hosting content in less space than it asked for
        // would manufacture the truncation findings the engine exists to detect.
        let host = OracleHost(
            scenario: BadgesScenario(),
            viewport: Size(width: 200.4, height: 100.6)
        )
        XCTAssertEqual(host.hostSize, Size(width: 201, height: 101))
        XCTAssertFalse(host.wasClamped, "rounding is not clamping")

        let tree = try await host.currentTree()
        XCTAssertEqual(tree.frame, Rect(x: 0, y: 0, width: 201, height: 101))
    }

    @MainActor
    func testTheFittingSizePathProducesTheContentsOwnSize() async throws {
        let host = OracleHost(scenario: BadgesScenario())
        XCTAssertEqual(
            host.hostSize,
            Size(width: 100, height: 60),
            "fittingSize must report the stack's own ideal size: 100 wide, 30 + 10 + 20 tall"
        )
        XCTAssertFalse(host.wasClamped)

        let tree = try await host.currentTree()
        XCTAssertEqual(tree.frame, Rect(x: 0, y: 0, width: 100, height: 60))
        // Sized to its content, the probed stack now spans the viewport, so
        // `TreeAssembly` keeps its identity instead of synthesizing a root above
        // it — the same content, a different tree, entirely because of the size.
        XCTAssertEqual(tree.id, "stack")
        XCTAssertEqual(tree.children.map(\.id), ["top", "bottom"])
        XCTAssertEqual(
            tree.children.map(\.frame),
            [
                Rect(x: 0, y: 0, width: 100, height: 30),
                Rect(x: 20, y: 40, width: 60, height: 20),
            ]
        )
    }

    // MARK: - The clamp guard

    @MainActor
    func testUnboundedContentIsClampedToTheCapAndSaysSo() async throws {
        // 300 rows of 20 pt: `fittingSize` answers 6000 pt tall, honestly and
        // uselessly. Hosting at that size lays out a screen nobody can see.
        let host = OracleHost(scenario: UnboundedScenario())

        XCTAssertEqual(host.hostSize.height, OracleHost.sizeCap.height)
        XCTAssertTrue(
            host.wasClamped,
            "the clamp must be observable — a silently capped host produces a tree that "
                + "describes a viewport the scenario never asked for"
        )

        let tree = try await host.currentTree()
        XCTAssertEqual(tree.frame.height, OracleHost.sizeCap.height)

        // The clamp actually bit: the content still wants its full 6000 pt, and it
        // is the host that stopped at the cap.
        let rows = try XCTUnwrap(tree.node(withID: "rows"))
        XCTAssertEqual(rows.frame.height, 6000)
        XCTAssertGreaterThan(
            rows.frame.height,
            tree.frame.height,
            "the content fits inside the host, so this scenario is not unbounded and the "
                + "test proves nothing about clamping"
        )
    }

    @MainActor
    func testAnAbsurdExplicitViewportIsClampedToo() {
        // An explicit viewport wins over the measurement, but not over arithmetic:
        // `.infinity` is not a viewport, it is a mistake, and obeying it hangs the
        // caller.
        let host = OracleHost(
            scenario: BadgesScenario(),
            viewport: Size(width: .infinity, height: 100)
        )
        XCTAssertEqual(host.hostSize, Size(width: OracleHost.sizeCap.width, height: 100))
        XCTAssertTrue(host.wasClamped)
    }

    /// The clamp arithmetic on inputs a real `fittingSize` can produce but which
    /// no scenario reliably provokes — infinity, NaN, a negative measurement.
    ///
    /// Exercised directly and deliberately: the one shape that did make
    /// `fittingSize` return an unusable value (`.frame(idealWidth: .infinity,
    /// idealHeight: .infinity)`) aborted the test process inside AppKit rather
    /// than returning, so it cannot be a test. The clamp still has to be correct
    /// for those inputs, so they are fed in as arguments instead.
    func testTheClampArithmeticCoversEveryDegenerateMeasurement() {
        func resolve(_ width: Double, _ height: Double) -> (size: Size, wasClamped: Bool) {
            OracleHost.resolveHostSize(Size(width: width, height: height))
        }

        XCTAssertEqual(resolve(300, 200).size, Size(width: 300, height: 200))
        XCTAssertFalse(resolve(300, 200).wasClamped, "a usable size is not clamped")

        XCTAssertEqual(resolve(199.2, 100.9).size, Size(width: 200, height: 101))
        XCTAssertFalse(resolve(199.2, 100.9).wasClamped)

        let cap = OracleHost.sizeCap
        XCTAssertEqual(resolve(cap.width, cap.height).size, cap)
        XCTAssertFalse(resolve(cap.width, cap.height).wasClamped, "exactly at the cap is not over it")

        XCTAssertEqual(resolve(cap.width + 1, 100).size, Size(width: cap.width, height: 100))
        XCTAssertTrue(resolve(cap.width + 1, 100).wasClamped)

        XCTAssertEqual(resolve(100, .infinity).size, Size(width: 100, height: cap.height))
        XCTAssertTrue(resolve(100, .infinity).wasClamped)

        XCTAssertEqual(resolve(.nan, 100).size, Size(width: cap.width, height: 100))
        XCTAssertTrue(
            resolve(.nan, 100).wasClamped,
            "a NaN width would make every frame in the tree NaN and encode as invalid JSON"
        )

        XCTAssertEqual(resolve(-40, 100).size, Size(width: cap.width, height: 100))
        XCTAssertTrue(resolve(-40, 100).wasClamped)

        XCTAssertEqual(resolve(0, 0).size, Size(width: 0, height: 0))
        XCTAssertFalse(
            resolve(0, 0).wasClamped,
            "zero is a real measurement — content with no ideal size — and clamping it up "
                + "would invent a viewport"
        )
    }

    // MARK: - Settling

    /// The confirming check is load-bearing: this layout delivers a complete but
    /// wrong tree first, and the right one a run-loop turn later.
    ///
    /// ``DeferredScenario`` publishes the green bar's measured width upward, stores
    /// it on a `Task { @MainActor … }` hop, and re-lays out — so delivery #1 places
    /// the 11 pt placeholder and delivery #2 places the real 70 pt bar. A settle
    /// rule that returned the first delivery would return the placeholder, and it
    /// would do so intermittently.
    @MainActor
    func testCurrentTreeWaitsForALayoutThatSettlesOnlyAfterARunLoopTurn() async throws {
        let host = OracleHost(scenario: DeferredScenario(), viewport: Size(width: 200, height: 80))
        let tree = try await host.currentTree()

        let bar = try XCTUnwrap(tree.node(withID: "bar"))
        XCTAssertEqual(
            bar.frame,
            Rect(x: 65, y: 35, width: 70, height: 20),
            "the bar is at its placeholder width, so the settle returned the first delivery "
                + "instead of waiting for the layout to stop changing"
        )
        XCTAssertNotEqual(
            bar.frame.width,
            DeferredScenario.placeholderWidth,
            "this is the placeholder geometry, not the settled geometry"
        )
    }

    /// The settle primitive on its own: an absent token never settles, and a
    /// constant one settles only after a confirming pass.
    @MainActor
    func testTheSettlePrimitiveNeedsTwoAgreeingChecksAndNeverSettlesOnNothing() {
        let view = NSView(frame: CGRect(x: 0, y: 0, width: 10, height: 10))

        let absent = LayoutSettle.pump(view, deadline: 0.05) { nil }
        XCTAssertFalse(
            absent.isSettled,
            "an absent token must never count as stable — a scenario that delivers nothing "
                + "would otherwise settle instantly on a tree that does not exist"
        )
        XCTAssertGreaterThan(
            absent.iterations,
            0,
            "the pump gave up without pumping, so it never gave the layout a chance"
        )

        XCTAssertEqual(
            LayoutSettle.pump(view, deadline: 1) { 7 },
            .settled(iterations: 1),
            "a constant token settles, but only after one confirming layout pass"
        )

        // Tokens 2, 1, 0, 0: the first three all differ from their predecessor, so
        // only the fourth check can agree — after three pumped passes.
        var remaining = 3
        let climbing = LayoutSettle.pump(view, deadline: 1) { () -> Int? in
            remaining -= 1
            return max(remaining, 0)
        }
        XCTAssertEqual(
            climbing,
            .settled(iterations: 3),
            "a token that keeps changing must keep the pump going until it stops"
        )

        XCTAssertEqual(
            LayoutSettle.pump(view, deadline: 0) { 7 },
            .expired(iterations: 0),
            "a zero deadline observes once and pumps nothing, so it can neither confirm "
                + "stability nor loop"
        )
    }

    // MARK: - Determinism

    @MainActor
    func testTwoCallsOnOneHostProduceEqualEncodedTrees() async throws {
        let host = OracleHost(scenario: BadgesScenario(), viewport: Self.badgesViewport)
        let first = try await host.currentTree()
        let second = try await host.currentTree()

        XCTAssertEqual(first, second)
        XCTAssertEqual(try Self.encoded(first), try Self.encoded(second))
        XCTAssertFalse(first.children.isEmpty, "guard against two vacuously equal empty trees")
    }

    @MainActor
    func testTwoFreshHostsOfTheSameScenarioProduceEqualEncodedTrees() async throws {
        func tree() async throws -> SemanticNode {
            try await OracleHost(scenario: BadgesScenario(), viewport: Self.badgesViewport)
                .currentTree()
        }

        let first = try await tree()
        let second = try await tree()

        XCTAssertEqual(
            try Self.encoded(first),
            try Self.encoded(second),
            "same scenario, same viewport, two hosts, different bytes — the harness is not "
                + "deterministic"
        )
        XCTAssertFalse(first.children.isEmpty, "guard against two vacuously equal empty trees")
    }

    /// Determinism through the path most likely to break it: a layout that needs
    /// more than one pass. Two fresh hosts must both land on the settled tree, not
    /// one on each side of the state change.
    @MainActor
    func testTwoFreshHostsAgreeEvenOnALayoutThatNeedsSeveralPasses() async throws {
        func tree() async throws -> SemanticNode {
            try await OracleHost(scenario: DeferredScenario(), viewport: Size(width: 200, height: 80))
                .currentTree()
        }

        let first = try await tree()
        let second = try await tree()

        XCTAssertEqual(try Self.encoded(first), try Self.encoded(second))
        XCTAssertEqual(
            first.node(withID: "bar")?.frame.width,
            70,
            "both hosts agreed, but on the placeholder rather than the settled geometry"
        )
    }

    // MARK: - Environment pinning

    /// Read every pin from inside the scenario body and assert the values that
    /// arrived, so the pins are checked where they are actually consumed.
    ///
    /// The expectations are absolute, not relative to the machine: this developer's
    /// Mac reports `en_CA` and `America/Toronto`, so any pin that quietly stopped
    /// being applied would show up here as the machine's own setting.
    @MainActor
    func testThePinnedEnvironmentIsWhatTheScenarioBodySees() async throws {
        let host = OracleHost(
            scenario: EnvironmentScenario(),
            viewport: Size(width: 300, height: 80)
        )
        let tree = try await host.currentTree()
        let node = try XCTUnwrap(tree.node(withID: "env"))

        XCTAssertEqual(node.attributes["displayScale"], .number(1))
        XCTAssertEqual(node.attributes["locale"], .string("en_US"))
        XCTAssertEqual(node.attributes["colorScheme"], .string("light"))
        XCTAssertEqual(node.attributes["dynamicTypeSize"], .string("medium"))
        XCTAssertEqual(node.attributes["layoutDirection"], .string("leftToRight"))
        // `TimeZone(identifier: "UTC")` normalises its identifier to "GMT".
        XCTAssertEqual(node.attributes["timeZone"], .string("GMT"))
        XCTAssertEqual(node.attributes["calendar"], .string("gregorian"))
        XCTAssertEqual(
            node.attributes["calendarTimeZone"],
            .string("GMT"),
            "a calendar carries its own time zone, so pinning \\.timeZone alone leaves the "
                + "machine's zone in every date a scenario formats"
        )
        XCTAssertEqual(node.attributes["calendarLocale"], .string("en_US"))
    }

    /// The pinned locale is load-bearing, and it is the pinned one.
    ///
    /// Two claims, each covering the other's gap. The inherited stamp must measure
    /// the same as one explicitly overridden to `en_US` — that is what says the
    /// inherited locale *is* `en_US` rather than whatever the machine reports. And
    /// it must measure differently from one overridden to `de_DE` — that is what
    /// says locale changes the geometry at all, without which the first claim would
    /// hold vacuously.
    ///
    /// Neither claim hard-codes a glyph width, so the test says nothing about
    /// Apple's font metrics and everything about which environment the harness
    /// installed.
    @MainActor
    func testLocaleSensitiveFormattingUsesThePinnedLocaleNotTheMachines() async throws {
        let host = OracleHost(scenario: StampScenario(), viewport: Size(width: 400, height: 90))
        let tree = try await host.currentTree()

        let inherited = try XCTUnwrap(tree.node(withID: "inherited"))
        let american = try XCTUnwrap(tree.node(withID: "explicit-en-US"))
        let german = try XCTUnwrap(tree.node(withID: "explicit-de-DE"))

        XCTAssertGreaterThan(inherited.frame.width, 0, "the stamp measured as zero width")
        XCTAssertEqual(
            inherited.frame.width,
            american.frame.width,
            accuracy: 0.001,
            "the inherited locale renders this instant differently from en_US, so the host's "
                + "locale pin is not en_US — it is the machine's"
        )
        XCTAssertNotEqual(
            inherited.frame.width,
            german.frame.width,
            "en_US and de_DE render this instant to the same width, so this test cannot "
                + "detect a missing locale pin"
        )
    }

    // MARK: - The deadline

    /// The budget is enforced, the failure is the documented one, and no tree is
    /// invented.
    ///
    /// A zero budget is how the timeout is reached on purpose. It is not a
    /// contrived substitute for a hostile scenario so much as the same condition
    /// stated exactly: the deadline passed before stability could be confirmed. No
    /// Wave 2 scenario reaches it any other way — see the report — and Wave 3's
    /// hostile suite (a `repeatForever` animation) is where a genuinely
    /// never-settling layout gets its own coverage.
    @MainActor
    func testTheDeadlineIsHonouredAndSurfacesTheDocumentedFailure() async {
        let host = OracleHost(
            scenario: BadgesScenario(),
            viewport: Self.badgesViewport,
            deadline: 0
        )
        let start = Date()
        do {
            let tree = try await host.currentTree()
            XCTFail(
                "an unsatisfiable settle budget returned a tree instead of failing: \(tree.frame)"
            )
        } catch let error as OracleHostError {
            let elapsed = Date().timeIntervalSince(start)
            XCTAssertLessThan(elapsed, 1, "the deadline was not honoured — this call hung")

            guard case .settleTimedOut(let scenario, let hostSize, let deadline, let iterations, let deliveries) = error
            else {
                XCTFail("unexpected error case: \(error)")
                return
            }
            XCTAssertEqual(scenario, "badges", "the failure must name the scenario it came from")
            XCTAssertEqual(hostSize, Self.badgesViewport)
            XCTAssertEqual(deadline, 0)
            XCTAssertEqual(iterations, 0, "a zero budget must pump nothing")
            XCTAssertGreaterThan(
                deliveries,
                0,
                "a tree had been delivered, so the diagnosis is 'never confirmed settled', "
                    + "not 'never rendered'"
            )
            XCTAssertTrue(
                error.description.contains("never confirmed settled"),
                "unhelpful message: \(error.description)"
            )
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    /// The other diagnosis the timeout carries — nothing was ever delivered —
    /// names the missing viewport, because that is the only thing a caller can act
    /// on.
    ///
    /// Asserted on the message rather than through a host: with the resolved size
    /// applied as an explicit frame, every scenario tried (including `EmptyView`,
    /// `Group {}`, and an always-false branch) reports a viewport and delivers a
    /// root-only tree. The branch is reachable in principle — the same bodies
    /// deliver nothing when no frame is applied, which is measured in the report —
    /// so the message it produces has to be right.
    func testTheZeroDeliveryTimeoutExplainsTheMissingViewport() {
        let error = OracleHostError.settleTimedOut(
            scenario: "ghost",
            hostSize: Size(width: 10, height: 10),
            deadline: 3,
            iterations: 171,
            deliveries: 0
        )
        XCTAssertTrue(error.description.contains("ghost"))
        XCTAssertTrue(error.description.contains("no semantic tree was ever delivered"))
        XCTAssertTrue(
            error.description.contains("viewport"),
            "the message must name the cause a caller can act on: \(error.description)"
        )
        XCTAssertTrue(error.description.contains("10 x 10 pt"), error.description)
    }

    // MARK: - Helpers

    /// Canonical encoding: sorted keys, so a byte comparison compares content and
    /// not dictionary iteration order.
    private static func encoded(_ tree: SemanticNode) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(tree), as: UTF8.self)
    }
}

// MARK: - Scenarios under test

/// Two fixed-size swatches in a probed stack. Every dimension is one VerdictUI
/// chose, so every expected frame is arithmetic rather than a font metric.
private struct BadgesScenario: VerdictScenario {
    let name = "badges"

    func body(state: ScenarioState) -> some View {
        VStack(spacing: 10) {
            Color.red.frame(width: 100, height: 30).verdictProbe("top", role: .image)
            Color.blue.frame(width: 60, height: 20).verdictProbe("bottom", role: .image)
        }
        .verdictProbe("stack", role: .container)
    }
}

private struct UnprobedScenario: VerdictScenario {
    let name = "unprobed"

    func body(state: ScenarioState) -> some View {
        Color.clear.frame(width: 30, height: 15)
    }
}

/// 300 rows of 20 pt inside a `ScrollView`: `fittingSize` measures 6000 pt tall,
/// which is exactly the unbounded-content risk the cap exists for.
private struct UnboundedScenario: VerdictScenario {
    let name = "unbounded"

    func body(state: ScenarioState) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(0..<300, id: \.self) { _ in
                    Color.gray.frame(height: 20)
                }
            }
            .verdictProbe("rows", role: .container)
        }
    }
}

private struct MeasuredWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// A layout that cannot finish in one pass: the blue bar's width is published
/// upward by the green bar above it and stored on a main-actor hop, so the first
/// delivered tree places a placeholder and the second places the real thing.
private struct DeferredScenario: VerdictScenario {
    /// The width the bar has before the measured one arrives — the geometry a
    /// settle rule that trusted the first delivery would return.
    static let placeholderWidth: Double = 11

    let name = "deferred"

    func body(state: ScenarioState) -> some View {
        DeferredContent()
    }
}

private struct DeferredContent: View {
    @State private var measured: CGFloat?

    var body: some View {
        VStack(spacing: 0) {
            Color.green
                .frame(width: 70, height: 10)
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(key: MeasuredWidthKey.self, value: proxy.size.width)
                    }
                }
            Color.blue
                .frame(width: measured ?? CGFloat(DeferredScenario.placeholderWidth), height: 20)
                .verdictProbe("bar", role: .image)
        }
        .onPreferenceChange(MeasuredWidthKey.self) { width in
            // Deliberately deferred a run-loop turn, which is what makes the first
            // delivered tree observably different from the settled one.
            Task { @MainActor in measured = width }
        }
    }
}

/// Reports every pinned environment value back through the tree as attributes.
private struct EnvironmentScenario: VerdictScenario {
    let name = "environment"

    func body(state: ScenarioState) -> some View {
        EnvironmentReadout()
    }
}

private struct EnvironmentReadout: View {
    @Environment(\.displayScale) private var displayScale
    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone
    @Environment(\.calendar) private var calendar
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.layoutDirection) private var layoutDirection

    var body: some View {
        Color.clear
            .frame(width: 40, height: 20)
            .verdictProbe(
                "env",
                role: .container,
                attributes: [
                    "displayScale": .number(Double(displayScale)),
                    "locale": .string(locale.identifier),
                    "timeZone": .string(timeZone.identifier),
                    "calendar": .string("\(calendar.identifier)"),
                    "calendarLocale": .string(calendar.locale?.identifier ?? "nil"),
                    "calendarTimeZone": .string(calendar.timeZone.identifier),
                    "colorScheme": .string(colorScheme == .light ? "light" : "dark"),
                    "dynamicTypeSize": .string("\(dynamicTypeSize)"),
                    "layoutDirection": .string("\(layoutDirection)"),
                ]
            )
    }
}

/// The same instant, formatted three ways: with whatever locale the host pinned,
/// and with two explicit ones.
private struct StampScenario: VerdictScenario {
    let name = "stamp"

    func body(state: ScenarioState) -> some View {
        VStack(spacing: 4) {
            stamp.verdictProbe("inherited", role: .text, text: "inherited")
            stamp
                .environment(\.locale, Locale(identifier: "en_US"))
                .verdictProbe("explicit-en-US", role: .text, text: "explicit-en-US")
            stamp
                .environment(\.locale, Locale(identifier: "de_DE"))
                .verdictProbe("explicit-de-DE", role: .text, text: "explicit-de-DE")
        }
    }

    private var stamp: some View {
        Text(
            Date(timeIntervalSince1970: 0),
            format: .dateTime.year().month().day().hour().minute()
        )
        .fixedSize()
    }
}
