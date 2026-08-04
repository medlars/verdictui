import AppKit
import SwiftUI
import VerdictUIKernel
import VerdictUIProbe
import XCTest

// MARK: - Headless host

/// Hosts a view in an `NSHostingView` that is never attached to a window and
/// pumps the main run loop until the values under test arrive.
///
/// Same shape as `ProbeLayoutTests`' host, and duplicated rather than shared on
/// purpose: Task 3 replaces both with the shipping harness, and until then a test
/// file that owns its own host cannot be broken by a change made for the other's
/// benefit.
///
/// One `layoutSubtreeIfNeeded()` is not enough for this file in particular: a
/// tree is delivered through a *preference*, which SwiftUI propagates after the
/// layout pass that produced it. Expiry is a failure, never a skip — a root that
/// never delivers a tree is precisely the defect these tests exist to catch.
@MainActor
private final class HeadlessHost<Content: View> {
    private static var deadline: TimeInterval { 3 }

    private let hostingView: NSHostingView<Content>

    init(_ rootView: Content, size: CGSize = CGSize(width: 400, height: 300)) {
        hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = CGRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()
    }

    /// Pump layout and the main run loop until `isReady()` holds.
    ///
    /// - Returns: `true` once the condition holds; `false` after recording an
    ///   `XCTFail`, so the caller can stop instead of asserting on absent data.
    func pump(
        until description: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        isReady: () -> Bool
    ) -> Bool {
        let limit = Date().addingTimeInterval(Self.deadline)
        while true {
            if isReady() { return true }
            if Date() >= limit { break }
            hostingView.needsLayout = true
            hostingView.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
        XCTFail(
            "windowless layout never produced \(description) within "
                + "\(Self.deadline) s of run-loop pumping",
            file: file,
            line: line
        )
        return false
    }
}

// MARK: - Tests

final class VerdictUIProbeTests: XCTestCase {
    /// Every test here builds an AppKit view hierarchy, and `swift test` has no
    /// window-server run loop to drain the autorelease pool between tests.
    /// Without this the hosted hierarchies and their layers accumulate until the
    /// suite wedges at 0% CPU — each test still passing in isolation.
    override func invokeTest() {
        autoreleasepool { super.invokeTest() }
    }

    /// The viewport every test hosts in. 400 × 300 with the probed content sized
    /// explicitly inside it, so no assertion depends on the host's own size.
    private static let hostSize = CGSize(width: 400, height: 300)

    // MARK: - Tree shape, ids, roles, frames

    /// A card 300 × 200 inside the host: a probed `VStack` holding two `Text`s, a
    /// `Button`, and a fixed-size box.
    ///
    /// The stack is probed too, so the rendered tree has to recover real nesting
    /// (root → stack → four leaves) from frames rather than from the flat order
    /// the preference stream delivers.
    @MainActor
    private func card() -> some View {
        ZStack {
            VStack(spacing: 8) {
                Text("Title").verdictProbe("title", role: .text, text: "Title")
                Text("Subtitle").verdictProbe("subtitle", role: .text, text: "Subtitle")
                Button("Save") {}.verdictProbe("save", role: .button, text: "Save")
                Color.red.frame(width: 120, height: 40).verdictProbe("box", role: .image)
            }
            .verdictProbe("stack", role: .container)
        }
        .frame(width: 300, height: 200)
    }

    @MainActor
    func testProbedStackYieldsTreeWithRightIDsRolesAndRootSpaceFrames() throws {
        let sink = VerdictTreeSink()
        let host = HeadlessHost(card().verdictRoot(into: sink), size: Self.hostSize)
        guard host.pump(until: "a delivered tree", isReady: { sink.latestTree != nil }) else {
            return
        }
        let tree = try XCTUnwrap(sink.latestTree)

        // The root is synthesized: the probed stack sizes to its content, so
        // nothing spans the 300 × 200 viewport.
        XCTAssertEqual(tree.id, "")
        XCTAssertEqual(tree.role, .container)
        XCTAssertEqual(tree.frame, Rect(x: 0, y: 0, width: 300, height: 200))
        XCTAssertEqual(tree.structuralPath, "root")

        let stack = try XCTUnwrap(tree.children.first)
        XCTAssertEqual(tree.children.count, 1, "only the stack is top level; the rest nest inside")
        XCTAssertEqual(stack.id, "stack")
        XCTAssertEqual(stack.role, .container)
        XCTAssertEqual(stack.structuralPath, "root/container[0]")

        XCTAssertEqual(
            stack.children.map(\.id),
            ["title", "subtitle", "save", "box"],
            "sibling order is layout order, top to bottom"
        )
        XCTAssertEqual(stack.children.map(\.role), [.text, .text, .button, .image])
        XCTAssertEqual(stack.children.map(\.text), ["Title", "Subtitle", "Save", nil])
        XCTAssertEqual(stack.children.map(\.structuralPath), [
            "root/container[0]/text[0]",
            "root/container[0]/text[1]",
            "root/container[0]/button[2]",
            "root/container[0]/image[3]",
        ])

        let title = try XCTUnwrap(tree.node(withID: "title"))
        let subtitle = try XCTUnwrap(tree.node(withID: "subtitle"))
        let save = try XCTUnwrap(tree.node(withID: "save"))
        let box = try XCTUnwrap(tree.node(withID: "box"))

        // Exact frame for the element whose size VerdictUI controls. Glyph widths
        // are a system-font fact and would make an exact assertion on the text
        // nodes a test of Apple's font metrics, so those are asserted through the
        // geometry that *is* ours: the 8 pt spacing and the stack's centring.
        XCTAssertEqual(box.frame.width, 120)
        XCTAssertEqual(box.frame.height, 40)
        XCTAssertEqual(box.frame.x, stack.frame.x + (stack.frame.width - 120) / 2, accuracy: 0.001)
        XCTAssertEqual(box.frame.maxY, stack.frame.maxY, accuracy: 0.001)

        XCTAssertEqual(subtitle.frame.y, title.frame.maxY + 8, accuracy: 0.001)
        XCTAssertEqual(save.frame.y, subtitle.frame.maxY + 8, accuracy: 0.001)
        XCTAssertEqual(box.frame.y, save.frame.maxY + 8, accuracy: 0.001)
        XCTAssertEqual(title.frame.y, stack.frame.y, accuracy: 0.001)

        for child in stack.children {
            XCTAssertEqual(
                Self.midX(child.frame),
                Self.midX(stack.frame),
                accuracy: 0.001,
                "'\(child.id)' is not centred in the stack it reports inside"
            )
            XCTAssertGreaterThan(child.frame.width, 0, "'\(child.id)' measured as zero width")
            XCTAssertGreaterThan(child.frame.height, 0, "'\(child.id)' measured as zero height")
        }

        // Metrics land on the text-bearing nodes and nowhere else, and every line
        // count here is one line, because that is what a single-line label renders
        // and wants.
        for node in [title, subtitle, save] {
            let metrics = try XCTUnwrap(
                node.textMetrics,
                "'\(node.id)' renders text but carries no metrics"
            )
            XCTAssertGreaterThan(metrics.intrinsicWidth, 0)
            XCTAssertEqual(metrics.renderedLineCount, 1, "'\(node.id)' rendered lines")
            XCTAssertEqual(metrics.idealLineCount, 1, "'\(node.id)' ideal lines")
        }
        XCTAssertNil(box.textMetrics, "an image reports no text, so it gets no line counts")
        XCTAssertNil(stack.textMetrics, "a container reports no text")

        // Frames are root-relative: the stack is centred in the 300 × 200 root,
        // so its own origin is a positive offset from the root's, not from a
        // window's.
        XCTAssertEqual(Self.midX(stack.frame), 150, accuracy: 0.001)
        XCTAssertEqual(Self.midY(stack.frame), 100, accuracy: 0.001)
        XCTAssertGreaterThan(stack.frame.x, 0)
        XCTAssertGreaterThan(stack.frame.y, 0)
    }

    // MARK: - Text metrics

    @MainActor
    func testConstrainedTextCarriesAnIntrinsicWidthWiderThanItsFrame() throws {
        let label = "Cancel the pending subscription renewal"
        let sink = VerdictTreeSink()
        let host = HeadlessHost(
            ZStack {
                Text(label)
                    .lineLimit(1)
                    .verdictProbe("clipped-label", role: .text, text: label)
                    .frame(width: 120)
            }
            .frame(width: 300, height: 200)
            .verdictRoot(into: sink),
            size: Self.hostSize
        )
        guard host.pump(until: "a tree with metrics for 'clipped-label'", isReady: {
            sink.latestTree?.node(withID: "clipped-label")?.textMetrics != nil
        }) else { return }

        let node = try XCTUnwrap(sink.latestTree?.node(withID: "clipped-label"))
        let metrics = try XCTUnwrap(node.textMetrics)

        XCTAssertEqual(node.frame.width, 120, accuracy: 0.5, "the 120 pt frame was honoured")
        XCTAssertGreaterThan(
            metrics.intrinsicWidth,
            120,
            "this text needs more than 120 pt on one line; that shortfall is what "
                + "TruncationRule reads"
        )
        XCTAssertLessThan(
            metrics.intrinsicWidth,
            2000,
            "an intrinsic width this large means an infinite proposal leaked into the measurement"
        )
        XCTAssertEqual(metrics.renderedLineCount, 1, "lineLimit(1) renders one line")
        XCTAssertEqual(metrics.idealLineCount, 1, "lineLimit(1) wants one line, so nothing wrapped")
        XCTAssertFalse(metrics.isLineTruncated, "this is width clipping, not lost lines")
    }

    // MARK: - Coordinate space

    /// A 200 × 100 root holding one 90 × 30 swatch, centred.
    ///
    /// Hosted in differently sized hosting views, the root lands at a different
    /// place inside its host each time while nothing about its own contents
    /// changes. Frames in the `verdict-root` space are therefore identical across
    /// hosts; frames in `.global` space would be offset by wherever the host
    /// centred the root, which is what lets this test catch a coordinate-space
    /// regression.
    @MainActor
    private func swatchRoot(sink: VerdictTreeSink) -> some View {
        ZStack {
            Color.blue.frame(width: 90, height: 30).verdictProbe("swatch", role: .image)
        }
        .frame(width: 200, height: 100)
        .verdictRoot(into: sink)
    }

    @MainActor
    func testProbeFramesAreInVerdictRootSpaceNotGlobal() throws {
        // Both host sizes centre the 200 × 100 root on whole points — (100, 100)
        // and (140, 130) — so no half-pixel rounding enters the comparison. The
        // wobble that would introduce is why containment carries an epsilon at
        // all; it is not what this test is about.
        func tree(hostSize: CGSize) throws -> SemanticNode? {
            let sink = VerdictTreeSink()
            let host = HeadlessHost(swatchRoot(sink: sink), size: hostSize)
            guard host.pump(until: "a delivered tree in a \(hostSize) host", isReady: {
                sink.latestTree != nil
            }) else { return nil }
            return sink.latestTree
        }

        guard let small = try tree(hostSize: CGSize(width: 400, height: 300)),
            let large = try tree(hostSize: CGSize(width: 480, height: 360))
        else { return }

        // The root's bounds are its own size at its own origin, wherever the host
        // put it.
        XCTAssertEqual(small.frame, Rect(x: 0, y: 0, width: 200, height: 100))
        XCTAssertEqual(large.frame, Rect(x: 0, y: 0, width: 200, height: 100))

        let inSmall = try XCTUnwrap(small.node(withID: "swatch"))
        let inLarge = try XCTUnwrap(large.node(withID: "swatch"))
        // Centred in the root: (200 - 90) / 2, (100 - 30) / 2. In `.global` space
        // this would read (155, 135) in the small host and (195, 165) in the large
        // one — the host's placement, not the layout's.
        XCTAssertEqual(
            inSmall.frame,
            Rect(x: 55, y: 35, width: 90, height: 30),
            "the swatch's frame is measured from the root, not from the host"
        )
        XCTAssertEqual(
            inLarge.frame,
            inSmall.frame,
            "growing the host moved a reported frame — these are not root-space coordinates"
        )
        XCTAssertEqual(
            try Self.encoded(large),
            try Self.encoded(small),
            "the whole tree must be independent of where the host placed the root"
        )
    }

    // MARK: - Determinism

    @MainActor
    func testRenderingTheSameViewTwiceYieldsEqualEncodedTrees() throws {
        func tree() throws -> SemanticNode? {
            let sink = VerdictTreeSink()
            let host = HeadlessHost(card().verdictRoot(into: sink), size: Self.hostSize)
            guard host.pump(until: "a delivered tree", isReady: { sink.latestTree != nil }) else {
                return nil
            }
            return sink.latestTree
        }

        guard let first = try tree(), let second = try tree() else { return }

        XCTAssertEqual(first, second)
        XCTAssertEqual(
            try Self.encoded(first),
            try Self.encoded(second),
            "same view, same viewport, different bytes — the tree is not deterministic"
        )
        XCTAssertFalse(first.children.isEmpty, "guard against two vacuously equal empty trees")
    }

    // MARK: - Probe → kernel handshake

    @MainActor
    func testTheAssembledTreeFeedsTheKernelAndCatchesAPlantedTruncation() throws {
        let planted = "Cancel the pending subscription renewal"
        let sink = VerdictTreeSink()
        let host = HeadlessHost(
            VStack(spacing: 8) {
                Text(planted)
                    .lineLimit(1)
                    .verdictProbe("clipped-label", role: .text, text: planted)
                    .frame(width: 120)
                Text("OK").verdictProbe("fine-label", role: .text, text: "OK")
            }
            .frame(width: 300, height: 200)
            .verdictRoot(into: sink),
            size: Self.hostSize
        )
        guard host.pump(until: "a tree with metrics for the planted label", isReady: {
            sink.latestTree?.node(withID: "clipped-label")?.textMetrics != nil
        }) else { return }

        let tree = try XCTUnwrap(sink.latestTree)
        let verdict = RuleEngine.run(
            rules: RuleEngine.standardRules,
            on: tree,
            context: LintContext.macOS(viewport: tree.frame, scenario: "probe-kernel-handshake")
        )

        let truncation = verdict.findings.filter { $0.rule == TruncationRule.id }
        XCTAssertEqual(
            truncation.map(\.nodeID),
            ["clipped-label"],
            "the planted defect must be reported once, on the node that has it — found: "
                + "\(verdict.findings.map { "\($0.rule)/\($0.nodeID)" })"
        )
        let finding = try XCTUnwrap(truncation.first)
        XCTAssertEqual(finding.severity, .error)
        XCTAssertTrue(
            finding.message.contains("needs"),
            "unexpected truncation message: \(finding.message)"
        )
        XCTAssertEqual(verdict.status, .fail, "an error-severity finding fails the verdict")

        // The label that fits must not be reported: a first end-to-end proof is
        // worth nothing if the rule fires on everything.
        XCTAssertFalse(
            verdict.findings.contains { $0.rule == TruncationRule.id && $0.nodeID == "fine-label" },
            "truncation fired on a label that fits"
        )
    }

    // MARK: - Sink contract

    @MainActor
    func testTheSinkCountsDeliveriesAndResetsCleanly() throws {
        let sink = VerdictTreeSink()
        XCTAssertTrue(sink.isEmpty)
        XCTAssertEqual(sink.updateCount, 0)

        let host = HeadlessHost(card().verdictRoot(into: sink), size: Self.hostSize)
        guard host.pump(until: "a delivered tree", isReady: { sink.latestTree != nil }) else {
            return
        }
        XCTAssertGreaterThan(sink.updateCount, 0, "a delivered tree must be counted")
        XCTAssertFalse(sink.recorder.isEmpty, "the root must install its recorder in the subtree")

        sink.reset()
        XCTAssertNil(sink.latestTree)
        XCTAssertEqual(sink.updateCount, 0)
        XCTAssertTrue(sink.isEmpty)
        XCTAssertTrue(sink.recorder.isEmpty, "reset clears the layout recorder too")
    }

    @MainActor
    func testTheCallbackFlavourDeliversTheSameTree() throws {
        let collected = TreeCollector()
        let host = HeadlessHost(
            card().verdictRoot(onTree: { collected.record($0) }),
            size: Self.hostSize
        )
        guard host.pump(until: "a tree through the callback flavour", isReady: {
            collected.latest != nil
        }) else { return }

        let tree = try XCTUnwrap(collected.latest)
        XCTAssertEqual(tree.frame, Rect(x: 0, y: 0, width: 300, height: 200))
        XCTAssertEqual(tree.children.map(\.id), ["stack"])
    }

    // MARK: - Preference key

    func testPreferenceReductionConcatenatesRecordsAndKeepsTheFirstViewport() {
        var accumulated = VerdictProbeKey.defaultValue
        XCTAssertNil(accumulated.viewport)
        XCTAssertTrue(accumulated.records.isEmpty)

        VerdictProbeKey.reduce(value: &accumulated) {
            ProbeSnapshot(records: [
                ProbeRecord(id: "a", role: .text, frame: Rect(x: 0, y: 0, width: 10, height: 10))
            ])
        }
        VerdictProbeKey.reduce(value: &accumulated) {
            ProbeSnapshot(
                viewport: Rect(x: 0, y: 0, width: 300, height: 200),
                records: [
                    ProbeRecord(
                        id: "b", role: .text, frame: Rect(x: 0, y: 20, width: 10, height: 10))
                ]
            )
        }
        VerdictProbeKey.reduce(value: &accumulated) {
            ProbeSnapshot(viewport: Rect(x: 0, y: 0, width: 999, height: 999))
        }

        XCTAssertEqual(
            accumulated.records.map(\.id),
            ["a", "b"],
            "reduction order is layout order, and it is the only ordering token there is"
        )
        XCTAssertEqual(accumulated.viewport, Rect(x: 0, y: 0, width: 300, height: 200))
    }

    // MARK: - Helpers

    /// Horizontal centre of a kernel `Rect`, which models only its edges.
    private static func midX(_ rect: Rect) -> Double { rect.x + rect.width / 2 }

    /// Vertical centre of a kernel `Rect`.
    private static func midY(_ rect: Rect) -> Double { rect.y + rect.height / 2 }

    /// Canonical encoding: sorted keys so a byte comparison is a comparison of
    /// content, not of dictionary iteration order.
    private static func encoded(_ tree: SemanticNode) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(tree)
    }
}

/// Collects trees pushed through `verdictRoot(onTree:)`.
@MainActor
private final class TreeCollector {
    private(set) var latest: SemanticNode?
    private(set) var count = 0

    func record(_ tree: SemanticNode) {
        latest = tree
        count += 1
    }
}
