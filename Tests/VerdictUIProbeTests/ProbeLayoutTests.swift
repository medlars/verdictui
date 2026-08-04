import AppKit
import SwiftUI
import VerdictUIKernel
import VerdictUIProbe
import XCTest

// MARK: - Headless host

/// Hosts a view in an `NSHostingView` that is never attached to a window and
/// pumps the main run loop until the values under test arrive.
///
/// This is the pre-wave spike's finding, kept deliberately small: a windowless
/// `NSHostingView` runs real layout passes with no window server, which is what
/// makes VerdictUI CI-safe. Task 3 replaces this with the shipping harness.
///
/// One `layoutSubtreeIfNeeded()` is not enough — the first pass can complete
/// before SwiftUI has evaluated the bodies that produce the values — so callers
/// state the condition they are waiting for and this type pumps until it holds or
/// the deadline expires. Expiry is a test failure, never a skip: a probe that
/// records nothing is the exact defect these tests exist to catch.
@MainActor
private final class HeadlessHost<Content: View> {
    /// Generous enough to absorb a cold first pass, short enough that a genuinely
    /// broken probe fails the suite quickly rather than hanging CI.
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

// MARK: - Frame measurement, independent of ProbeLayout

/// Collects resolved frames keyed by a test-local id.
@MainActor
private final class FrameSink {
    private var frames: [String: CGRect] = [:]

    func record(_ id: String, _ frame: CGRect) { frames[id] = frame }
    func frame(_ id: String) -> CGRect? { frames[id] }
}

/// Reports the frame of the view it backs, measured in the root space that
/// ``probeTestRoot(recorder:content:)`` establishes.
///
/// Deliberately `GeometryReader`-based rather than `ProbeLayout`-based: the
/// transparency test must compare frames with and without the probe, so its
/// measuring instrument cannot be the thing under test. Recording happens while
/// the geometry closure is evaluated — during layout — because `onAppear` does
/// not fire for a view that never joins a window.
private struct FrameReporter: View {
    static let coordinateSpaceName = "verdictui-probe-test-root"

    let id: String
    let sink: FrameSink

    var body: some View {
        GeometryReader { proxy in
            report(proxy.frame(in: .named(Self.coordinateSpaceName)))
        }
    }

    @MainActor
    private func report(_ frame: CGRect) -> Color {
        sink.record(id, frame)
        return .clear
    }
}

/// Reports the recorder it sees in the environment, so injection can be asserted
/// from inside the view tree.
@MainActor
private final class EnvironmentSink {
    private(set) var didRead = false
    private(set) var seen: ProbeRecorder?

    func record(_ recorder: ProbeRecorder?) {
        didRead = true
        seen = recorder
    }
}

private struct RecorderReader: View {
    let sink: EnvironmentSink

    @Environment(\.probeRecorder) private var recorder

    var body: some View {
        report()
    }

    @MainActor
    private func report() -> Color {
        sink.record(recorder)
        return .clear
    }
}

extension View {
    fileprivate func reportingFrame(_ id: String, to sink: FrameSink) -> some View {
        background { FrameReporter(id: id, sink: sink) }
    }
}

/// A fixed-size, centred root: content sits in a 300 × 120 region whose own
/// origin is fixed, so a size change anywhere inside moves the content and shows
/// up as a frame difference. Centring is what makes the transparency test able to
/// catch a probe that inflates its reported size.
@MainActor
private func probeTestRoot<Content: View>(
    recorder: ProbeRecorder?,
    @ViewBuilder content: () -> Content
) -> some View {
    ZStack { content() }
        .frame(width: 300, height: 120)
        .coordinateSpace(.named(FrameReporter.coordinateSpaceName))
        .environment(\.probeRecorder, recorder)
}

/// A root whose `ZStack` really is 200 × 100 and really does align its content,
/// which is what makes an alignment difference observable.
///
/// The spacer child is what fixes the stack's size: `ZStack { small }.frame(…)`
/// would leave the stack the size of `small` and let the outer frame centre it,
/// so every alignment would produce the same frame and the test would pass
/// vacuously. With the spacer inside, the stack's own bounds are 200 × 100 and
/// `alignment` is the only thing deciding where the 40 × 20 leaf lands. The outer
/// frame then pins the coordinate-space origin so frames are comparable across
/// hosts.
@MainActor
private func alignmentTestRoot<Content: View>(
    alignment: Alignment,
    recorder: ProbeRecorder?,
    @ViewBuilder content: () -> Content
) -> some View {
    ZStack(alignment: alignment) {
        Color.clear.frame(width: 200, height: 100)
        content()
    }
    .frame(width: 200, height: 100)
    .coordinateSpace(.named(FrameReporter.coordinateSpaceName))
    .environment(\.probeRecorder, recorder)
}

// MARK: - Observing the bounds SwiftUI hands a Layout

/// One `bounds` a `Layout` was handed, tagged with the callback that received it.
private struct BoundsObservation {
    enum Phase: String {
        /// `explicitAlignment(of:in:proposal:subviews:cache:)`.
        case guideEvaluation
        /// `placeSubviews(in:proposal:subviews:cache:)`.
        case placement
    }

    var phase: Phase
    var bounds: CGRect

    var hasZeroOrigin: Bool { bounds.origin == .zero }

    var description: String {
        "\(phase.rawValue) origin=(\(bounds.origin.x), \(bounds.origin.y)) "
            + "size=(\(bounds.size.width), \(bounds.size.height))"
    }
}

@MainActor
private final class BoundsObservationLog {
    private(set) var observations: [BoundsObservation] = []

    func record(_ observation: BoundsObservation) { observations.append(observation) }

    func observations(in phase: BoundsObservation.Phase) -> [BoundsObservation] {
        observations.filter { $0.phase == phase }
    }
}

/// Mirrors ``ProbeLayout``'s forwarding shape for one purpose: to observe which
/// `bounds` SwiftUI hands a `Layout` in each phase of a pass.
///
/// A mirror rather than the real type because the bounds a `Layout` receives is
/// an argument, not an output — ``ProbeRecorder`` records negotiations and
/// placements, and adding a guide-evaluation record to the shipping API to
/// support one test would be a worse trade than duplicating nine lines here. Its
/// structure is deliberately identical to the code under discussion: same two
/// callbacks, same placement at `bounds.origin`.
private struct GuideBoundsObserver: Layout {
    typealias Cache = Void

    let log: BoundsObservationLog

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        subviews.first?.sizeThatFits(proposal) ?? .zero
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void
    ) {
        record(.placement, bounds)
        for subview in subviews {
            subview.place(at: bounds.origin, anchor: .topLeading, proposal: proposal)
        }
    }

    func explicitAlignment(
        of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
        subviews: Subviews, cache: inout Void
    ) -> CGFloat? {
        record(.guideEvaluation, bounds)
        return subviews.first?.dimensions(in: proposal)[explicit: guide]
    }

    func explicitAlignment(
        of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
        subviews: Subviews, cache: inout Void
    ) -> CGFloat? {
        record(.guideEvaluation, bounds)
        return subviews.first?.dimensions(in: proposal)[explicit: guide]
    }

    private func record(_ phase: BoundsObservation.Phase, _ bounds: CGRect) {
        let observation = BoundsObservation(phase: phase, bounds: bounds)
        MainActor.assumeIsolated { log.record(observation) }
    }
}

/// A parent that allocates its child a region offset from its own origin *and*
/// reads the child's alignment guides while itself holding a nonzero-origin
/// `bounds` — the construction most likely to make a nested layout's guide
/// evaluation happen in an offset space, if that is possible at all.
private struct OffsetParentLayout: Layout {
    typealias Cache = Void

    let inset: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let inner = subviews.first?.sizeThatFits(proposal) ?? .zero
        return CGSize(width: inner.width + inset * 2, height: inner.height + inset * 2)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void
    ) {
        for subview in subviews {
            let dimensions = subview.dimensions(in: proposal)
            _ = dimensions[HorizontalAlignment.leading]
            _ = dimensions[VerticalAlignment.bottom]
            subview.place(
                at: CGPoint(x: bounds.minX + inset, y: bounds.minY + inset),
                anchor: .topLeading,
                proposal: proposal
            )
        }
    }
}

private enum CustomLeadingID: AlignmentID {
    static func defaultValue(in context: ViewDimensions) -> CGFloat { context.width / 4 }
}

private enum CustomTopID: AlignmentID {
    static func defaultValue(in context: ViewDimensions) -> CGFloat { context.height / 4 }
}

extension HorizontalAlignment {
    fileprivate static let customLeading = HorizontalAlignment(CustomLeadingID.self)
}

extension VerticalAlignment {
    fileprivate static let customTop = VerticalAlignment(CustomTopID.self)
}

// MARK: - Tests

final class ProbeLayoutTests: XCTestCase {
    /// Every test in this class builds an AppKit view hierarchy, and `swift test`
    /// has no window-server run loop to drain the autorelease pool between tests.
    /// Without this, hosted view hierarchies and their CoreAnimation layers
    /// accumulate until the whole suite wedges at 0% CPU — each test still passing
    /// in isolation, so the failure only appears as the suite grows.
    override func invokeTest() {
        autoreleasepool { super.invokeTest() }
    }

    @MainActor
    func testProbeLayoutDoesNotChangeTheRenderedFrame() throws {
        let plainSink = FrameSink()
        let plainHost = HeadlessHost(
            probeTestRoot(recorder: nil) {
                Color.red.frame(width: 97, height: 43).reportingFrame("leaf", to: plainSink)
            }
        )
        guard plainHost.pump(until: "a frame for the unwrapped view", isReady: {
            plainSink.frame("leaf") != nil
        }) else { return }

        let probedSink = FrameSink()
        let probedHost = HeadlessHost(
            probeTestRoot(recorder: ProbeRecorder()) {
                Color.red.frame(width: 97, height: 43)
                    .reportingFrame("leaf", to: probedSink)
                    .probeLayout(id: "wrapped")
            }
        )
        guard probedHost.pump(until: "a frame for the probe-wrapped view", isReady: {
            probedSink.frame("leaf") != nil
        }) else { return }

        let plain = try XCTUnwrap(plainSink.frame("leaf"))
        let probed = try XCTUnwrap(probedSink.frame("leaf"))

        // Guard against both measurements being vacuously zero: the frames must
        // be identical *and* be the frame the view actually asked for.
        XCTAssertEqual(plain.width, 97, accuracy: 0.01)
        XCTAssertEqual(plain.height, 43, accuracy: 0.01)

        XCTAssertEqual(probed.width, plain.width, accuracy: 0.01, "probe changed width")
        XCTAssertEqual(probed.height, plain.height, accuracy: 0.01, "probe changed height")
        XCTAssertEqual(probed.origin.x, plain.origin.x, accuracy: 0.01, "probe moved the view in x")
        XCTAssertEqual(probed.origin.y, plain.origin.y, accuracy: 0.01, "probe moved the view in y")
    }

    /// Alignment is part of transparency: a wrapper that reproduces size and
    /// position under a centring parent but not under an aligning one is not
    /// transparent, it is transparent-by-coincidence. `.topLeading` is the case
    /// Wave 2 Task 2 hit — the wrapped leaf came out centred in the stack.
    @MainActor
    func testProbeLayoutPreservesTopLeadingAlignmentInsideAZStack() throws {
        let frames = try XCTUnwrap(
            alignmentFrames(.topLeading) { sink in
                Color.red.frame(width: 40, height: 20).reportingFrame("leaf", to: sink)
            }
        )
        // The unwrapped leaf must actually be at the stack's top-leading corner,
        // otherwise "identical to unwrapped" would be a claim about nothing.
        XCTAssertEqual(frames.plain.origin.x, 0, accuracy: 0.01, "unwrapped leaf is not leading")
        XCTAssertEqual(frames.plain.origin.y, 0, accuracy: 0.01, "unwrapped leaf is not at the top")
        assertFramesMatch(frames, alignment: ".topLeading")
    }

    /// The opposite corner, so a fix cannot be a one-corner special case: the
    /// bottom-trailing guides resolve at the far edges of the leaf's own frame,
    /// which a wrapper that reports its own geometry instead of the child's gets
    /// wrong in the other direction.
    @MainActor
    func testProbeLayoutPreservesBottomTrailingAlignmentInsideAZStack() throws {
        let frames = try XCTUnwrap(
            alignmentFrames(.bottomTrailing) { sink in
                Color.red.frame(width: 40, height: 20).reportingFrame("leaf", to: sink)
            }
        )
        XCTAssertEqual(frames.plain.maxX, 200, accuracy: 0.01, "unwrapped leaf is not trailing")
        XCTAssertEqual(
            frames.plain.maxY, 100, accuracy: 0.01, "unwrapped leaf is not at the bottom"
        )
        assertFramesMatch(frames, alignment: ".bottomTrailing")
    }

    /// An *explicit* guide, which the wrapper's own default geometry cannot
    /// reproduce by accident: the leaf declares its leading edge to be its own
    /// horizontal centre, so the stack hangs it outside its leading edge. A
    /// wrapper that reports only its own default guides swallows the override and
    /// the leaf snaps back to the edge.
    ///
    /// The precondition is "moved leading-outward", not an exact coordinate: how
    /// far out the leaf ends up also depends on the outer frame re-centring a
    /// stack whose content now overhangs it, which is SwiftUI's business and not
    /// the property under test. What the test pins down is that the wrapped leaf
    /// lands wherever the unwrapped one does.
    @MainActor
    func testProbeLayoutForwardsAnExplicitAlignmentGuideOverride() throws {
        let frames = try XCTUnwrap(
            alignmentFrames(.topLeading) { sink in
                Color.red.frame(width: 40, height: 20)
                    .reportingFrame("leaf", to: sink)
                    .alignmentGuide(.leading) { dimensions in dimensions.width / 2 }
            }
        )
        XCTAssertLessThan(
            frames.plain.origin.x,
            -0.5,
            "the unwrapped leaf must honour its own .leading override — hanging "
                + "outside the leading edge — before the wrapper can be asked to "
                + "reproduce it"
        )
        assertFramesMatch(frames, alignment: ".topLeading with a .leading override")
    }

    /// The vertical half of the same property, and the half that fails in the
    /// other direction: the leaf declares its bottom edge to be its own vertical
    /// centre, so a bottom-aligning stack lets it hang below. Covering both axes
    /// keeps the fix from being a one-overload patch, since `Layout` declares
    /// `explicitAlignment` separately for horizontal and vertical guides.
    @MainActor
    func testProbeLayoutForwardsAnExplicitVerticalAlignmentGuideOverride() throws {
        let frames = try XCTUnwrap(
            alignmentFrames(.bottomTrailing) { sink in
                Color.red.frame(width: 40, height: 20)
                    .reportingFrame("leaf", to: sink)
                    .alignmentGuide(.bottom) { dimensions in dimensions.height / 2 }
            }
        )
        XCTAssertGreaterThan(
            frames.plain.maxY,
            100.5,
            "the unwrapped leaf must honour its own .bottom override — hanging "
                + "below the stack's bottom edge — before the wrapper can be asked "
                + "to reproduce it"
        )
        assertFramesMatch(frames, alignment: ".bottomTrailing with a .bottom override")
    }

    @MainActor
    func testRecorderCapturesTheSizeAndPlacementOfTheProbedView() throws {
        let recorder = ProbeRecorder()
        let host = HeadlessHost(
            probeTestRoot(recorder: recorder) {
                Color.red.frame(width: 97, height: 43).probeLayout(id: "box")
            }
        )
        guard host.pump(until: "a measurement and a placement for probe 'box'", isReady: {
            recorder.latestMeasurement(for: "box") != nil
                && recorder.latestPlacement(for: "box") != nil
        }) else { return }

        let measurement = try XCTUnwrap(recorder.latestMeasurement(for: "box"))
        XCTAssertEqual(measurement.probeID, "box")
        assertSize(measurement.returnedSize, width: 97, height: 43)
        // A fixed frame answers the same size whatever it is offered, so its
        // intrinsic measurement must agree with its constrained one.
        assertSize(measurement.intrinsicSize, width: 97, height: 43)
        XCTAssertNotNil(
            measurement.proposal.width,
            "the ZStack root proposes a concrete width; recording nil means the "
                + "received proposal was not the one forwarded"
        )

        let placement = try XCTUnwrap(recorder.latestPlacement(for: "box"))
        XCTAssertEqual(placement.probeID, "box")
        XCTAssertEqual(placement.anchor, .topLeading)
        XCTAssertEqual(placement.frame.x, placement.bounds.x, accuracy: 0.01)
        XCTAssertEqual(placement.frame.y, placement.bounds.y, accuracy: 0.01)
        assertSize(placement.frame.size, width: 97, height: 43)
    }

    @MainActor
    func testUnconstrainedMeasurementExceedsTheConstrainedWidthForClippedText() throws {
        let recorder = ProbeRecorder()
        let host = HeadlessHost(
            probeTestRoot(recorder: recorder) {
                Text("Cancel the pending subscription renewal")
                    .lineLimit(1)
                    .probeLayout(id: "label")
                    .frame(width: 120)
            }
        )
        guard host.pump(until: "a measurement for probe 'label'", isReady: {
            recorder.latestMeasurement(for: "label") != nil
        }) else { return }

        let measurement = try XCTUnwrap(recorder.latestMeasurement(for: "label"))
        XCTAssertLessThanOrEqual(
            measurement.returnedSize.width,
            120.5,
            "constrained width must respect the 120 pt frame it was proposed"
        )
        XCTAssertGreaterThan(
            measurement.intrinsicSize.width,
            120,
            "a single line of this text needs more than 120 pt; the unconstrained "
                + "measurement is what TruncationRule reads as intrinsicWidth"
        )
        XCTAssertGreaterThan(
            measurement.intrinsicSize.width,
            measurement.returnedSize.width,
            "intrinsic measurement is recording the constrained proposal"
        )
        XCTAssertLessThan(
            measurement.intrinsicSize.width,
            2000,
            "an intrinsic width this large means an infinite proposal leaked in"
        )
        XCTAssertGreaterThan(measurement.returnedSize.height, 0, "text measured as zero height")
        XCTAssertEqual(
            measurement.intrinsicSize.height,
            measurement.returnedSize.height,
            accuracy: 0.5,
            "one line either way, so the heights must agree"
        )
    }

    @MainActor
    func testWidthConstrainedMeasurementReportsTheHeightWrappingWouldNeed() throws {
        // The measurement that separates truncation from clipping: the text is
        // given a height that fits roughly one line, so its answer under the real
        // proposal says nothing about how much it wanted. Only the
        // width-constrained, height-unconstrained query does.
        let recorder = ProbeRecorder()
        let host = HeadlessHost(
            probeTestRoot(recorder: recorder) {
                Text("Cancel the pending subscription renewal for this account")
                    .probeLayout(id: "paragraph")
                    .frame(width: 100, height: 18)
            }
        )
        guard host.pump(until: "a measurement for probe 'paragraph'", isReady: {
            recorder.latestMeasurement(for: "paragraph") != nil
        }) else { return }

        let measurement = try XCTUnwrap(recorder.latestMeasurement(for: "paragraph"))
        XCTAssertGreaterThan(
            measurement.idealSizeAtProposedWidth.height,
            measurement.returnedSize.height,
            "at 100 pt wide this text needs several lines; the ideal height must exceed "
                + "the height the 18 pt frame allowed"
        )
        XCTAssertGreaterThan(
            measurement.idealSizeAtProposedWidth.height,
            measurement.intrinsicSize.height,
            "the unconstrained measurement is one line, so wrapping at 100 pt must be taller"
        )
        XCTAssertLessThanOrEqual(
            measurement.idealSizeAtProposedWidth.width,
            100.5,
            "the ideal measurement must stay inside the proposed 100 pt width — only the "
                + "height is opened up. (It need not equal the constrained width: text "
                + "reports the width its chosen line breaks actually use, and opening the "
                + "height changes where those breaks fall.)"
        )
        XCTAssertGreaterThanOrEqual(
            measurement.idealSizeAtProposedWidth.height / measurement.intrinsicSize.height,
            2,
            "this text cannot fit in fewer than two lines at 100 pt"
        )
    }

    @MainActor
    func testWidthUnconstrainedProposalMakesTheIdealMeasurementTheIntrinsicOne() throws {
        // Control for the test above: with the width left open there is nothing
        // extra to learn, and the third measurement must simply agree with the
        // unconstrained one rather than quietly reporting something else.
        let recorder = ProbeRecorder()
        let host = HeadlessHost(
            probeTestRoot(recorder: recorder) {
                Text("Renew")
                    .probeLayout(id: "short")
                    .fixedSize()
            }
        )
        guard host.pump(until: "a measurement for probe 'short'", isReady: {
            recorder.latestMeasurement(for: "short") != nil
        }) else { return }

        let measurement = try XCTUnwrap(recorder.latestMeasurement(for: "short"))
        XCTAssertGreaterThan(measurement.intrinsicSize.height, 0, "text measured as zero height")
        XCTAssertEqual(
            measurement.idealSizeAtProposedWidth.height,
            measurement.intrinsicSize.height,
            accuracy: 0.5,
            "one line either way, so the two heights must agree"
        )
    }

    @MainActor
    func testTwoProbesRecordUnderTheirOwnIDsWithoutCrossContamination() throws {
        let recorder = ProbeRecorder()
        let host = HeadlessHost(
            probeTestRoot(recorder: recorder) {
                VStack(spacing: 0) {
                    Color.red.frame(width: 40, height: 20).probeLayout(id: "first")
                    Color.blue.frame(width: 80, height: 30).probeLayout(id: "second")
                }
            }
        )
        guard host.pump(until: "measurements for probes 'first' and 'second'", isReady: {
            recorder.latestMeasurement(for: "first") != nil
                && recorder.latestMeasurement(for: "second") != nil
        }) else { return }

        XCTAssertEqual(recorder.recordedProbeIDs, ["first", "second"])

        assertSize(try XCTUnwrap(recorder.latestMeasurement(for: "first")).returnedSize,
            width: 40, height: 20)
        assertSize(try XCTUnwrap(recorder.latestMeasurement(for: "second")).returnedSize,
            width: 80, height: 30)

        // Every record filed under an id must describe that id's view, not its
        // sibling's — including the speculative measurements before the last one.
        for measurement in recorder.measurements(for: "first") {
            assertSize(measurement.returnedSize, width: 40, height: 20)
        }
        for measurement in recorder.measurements(for: "second") {
            assertSize(measurement.returnedSize, width: 80, height: 30)
        }
        for placement in recorder.placements(for: "first") {
            assertSize(placement.frame.size, width: 40, height: 20)
        }
        for placement in recorder.placements(for: "second") {
            assertSize(placement.frame.size, width: 80, height: 30)
        }
    }

    /// The documented degenerate case: content that resolves to several subviews
    /// (a `Group`, a `ForEach`) is reported as their union and stacked at a
    /// common origin, rather than dropped or reported as the first subview alone.
    @MainActor
    func testAProbeWrappingAGroupReportsTheUnionOfItsSubviews() throws {
        let recorder = ProbeRecorder()
        let sink = FrameSink()
        let host = HeadlessHost(
            probeTestRoot(recorder: recorder) {
                Group {
                    Color.red.frame(width: 40, height: 20).reportingFrame("small", to: sink)
                    Color.blue.frame(width: 80, height: 30).reportingFrame("large", to: sink)
                }
                .probeLayout(id: "multi")
            }
        )
        guard host.pump(until: "a measurement for probe 'multi' and both leaf frames", isReady: {
            recorder.latestMeasurement(for: "multi") != nil
                && sink.frame("small") != nil
                && sink.frame("large") != nil
        }) else { return }

        let measurement = try XCTUnwrap(recorder.latestMeasurement(for: "multi"))
        // The union of (40 x 20) and (80 x 30) is (80 x 30) — not the first
        // subview's answer, and not zero.
        assertSize(measurement.returnedSize, width: 80, height: 30)

        // "Stacked at a common origin": both subviews are placed top-leading at
        // the probe's bounds, so their origins coincide.
        let small = try XCTUnwrap(sink.frame("small"))
        let large = try XCTUnwrap(sink.frame("large"))
        XCTAssertEqual(small.origin.x, large.origin.x, accuracy: 0.01, "origins diverged in x")
        XCTAssertEqual(small.origin.y, large.origin.y, accuracy: 0.01, "origins diverged in y")
        XCTAssertEqual(small.width, 40, accuracy: 0.01, "the smaller subview changed size")
        XCTAssertEqual(large.width, 80, accuracy: 0.01, "the larger subview changed size")
    }

    @MainActor
    func testResetEmptiesTheRecorder() {
        let recorder = ProbeRecorder()
        XCTAssertTrue(recorder.isEmpty, "a fresh recorder holds nothing")

        let host = HeadlessHost(
            probeTestRoot(recorder: recorder) {
                Color.green.frame(width: 60, height: 24).probeLayout(id: "resettable")
            }
        )
        guard host.pump(until: "a measurement for probe 'resettable'", isReady: {
            !recorder.measurements.isEmpty && !recorder.placements.isEmpty
        }) else { return }

        recorder.reset()

        XCTAssertTrue(recorder.isEmpty)
        XCTAssertEqual(recorder.measurements.count, 0)
        XCTAssertEqual(recorder.placements.count, 0)
        XCTAssertTrue(recorder.recordedProbeIDs.isEmpty)
        XCTAssertNil(recorder.latestMeasurement(for: "resettable"))
        XCTAssertNil(recorder.latestPlacement(for: "resettable"))
    }

    @MainActor
    func testViewsReadTheInjectedRecorderFromTheEnvironment() {
        let recorder = ProbeRecorder()
        let injectedSink = EnvironmentSink()
        let injectedHost = HeadlessHost(
            probeTestRoot(recorder: recorder) { RecorderReader(sink: injectedSink) }
        )
        guard injectedHost.pump(until: "an environment read below the injection", isReady: {
            injectedSink.didRead
        }) else { return }
        XCTAssertTrue(
            injectedSink.seen === recorder,
            "a view below .environment(\\.probeRecorder, recorder) must see that instance"
        )

        let defaultSink = EnvironmentSink()
        let defaultHost = HeadlessHost(ZStack { RecorderReader(sink: defaultSink) })
        guard defaultHost.pump(until: "an environment read with no injection", isReady: {
            defaultSink.didRead
        }) else { return }
        XCTAssertNil(defaultSink.seen, "the environment default must be nil, not a shared sink")
    }

    /// Pins the assumption that lets ``ProbeLayout`` forward a guide value
    /// untranslated: a `Layout` is asked for its alignment guides in its *own*
    /// unoffset space, never in an offset one.
    ///
    /// This is the half of the fix that no frame comparison can reach.
    /// `ProbeLayout.explicitAlignment` returns the child's guide value as-is; that
    /// is correct only if the `bounds` it is handed is always origin-zero, because
    /// a nonzero origin would mean the value owed the caller a translation. A
    /// translation term added "just in case" is the worse option — under this
    /// assumption it is unreachable arithmetic that no test can falsify, which is
    /// how a wrong adjustment survives review.
    ///
    /// So the assumption is measured instead of assumed, across shapes that all
    /// displace the layout: a stack alignment, a custom parent that both offsets
    /// its child's region and reads its guides while holding a nonzero-origin
    /// bounds itself, padding, a five-deep nest of custom layouts, a text-baseline
    /// stack, and a custom `AlignmentID`. Two things are asserted together —
    /// every guide evaluation gets a zero origin, and some placement in the same
    /// shapes does not. The second half is what keeps the first from being
    /// vacuous: it proves these constructions really do move the layout, so the
    /// zero origins describe guide evaluation rather than a set of shapes that
    /// happened to sit at the origin.
    ///
    /// If a future SwiftUI ever hands a nonzero origin to `explicitAlignment`,
    /// this test fails and ``ProbeLayout`` must start translating by
    /// `bounds.origin`. It observes a mirror layout, not `ProbeLayout` itself, so
    /// it constrains SwiftUI's contract rather than our conformance — the
    /// conformance is held by the frame-equality tests above.
    @MainActor
    func testAlignmentGuidesAreEvaluatedInTheLayoutsOwnUnoffsetSpace() {
        let log = BoundsObservationLog()
        let leaf = Color.red.frame(width: 40, height: 20)
            .alignmentGuide(.leading) { dimensions in dimensions.width / 2 }
            .alignmentGuide(.bottom) { dimensions in dimensions.height / 2 }

        func observe<Content: View>(_ shape: Content) {
            let host = HeadlessHost(shape)
            _ = host.pump(until: "a recorded layout callback", isReady: {
                !log.observations.isEmpty
            })
        }

        observe(
            ZStack(alignment: .topLeading) {
                Color.clear.frame(width: 200, height: 100)
                GuideBoundsObserver(log: log) { leaf }
            }
            .frame(width: 200, height: 100)
        )
        observe(
            ZStack(alignment: .bottomTrailing) {
                Color.clear.frame(width: 200, height: 100)
                OffsetParentLayout(inset: 25) { GuideBoundsObserver(log: log) { leaf } }
            }
            .frame(width: 200, height: 100)
        )
        observe(
            ZStack(alignment: .topLeading) {
                Color.clear.frame(width: 200, height: 100)
                GuideBoundsObserver(log: log) { leaf }
                    .padding(EdgeInsets(top: 13, leading: 17, bottom: 3, trailing: 5))
            }
            .frame(width: 200, height: 100)
        )
        observe(
            ZStack(alignment: .topLeading) {
                Color.clear.frame(width: 200, height: 100)
                OffsetParentLayout(inset: 7) {
                    GuideBoundsObserver(log: log) {
                        OffsetParentLayout(inset: 5) { GuideBoundsObserver(log: log) { leaf } }
                    }
                }
            }
            .frame(width: 200, height: 100)
        )
        observe(
            HStack(alignment: .firstTextBaseline) {
                Text("tall").font(.largeTitle)
                GuideBoundsObserver(log: log) { Text("small").font(.caption) }
            }
            .frame(width: 200, height: 100)
        )
        observe(
            ZStack(alignment: Alignment(horizontal: .customLeading, vertical: .customTop)) {
                Color.clear.frame(width: 200, height: 100)
                GuideBoundsObserver(log: log) { leaf }
            }
            .frame(width: 200, height: 100)
        )

        let guideEvaluations = log.observations(in: .guideEvaluation)
        let placements = log.observations(in: .placement)

        XCTAssertFalse(
            guideEvaluations.isEmpty,
            "no guide was evaluated at all, so this test asserts nothing — the "
                + "shapes stopped asking their children for alignment guides"
        )
        let offsetGuideEvaluations = guideEvaluations.filter { !$0.hasZeroOrigin }
        XCTAssertEqual(
            offsetGuideEvaluations.count,
            0,
            "a Layout was asked for an alignment guide in an offset space: "
                + "\(offsetGuideEvaluations.map(\.description)). ProbeLayout forwards "
                + "the child's guide value untranslated on the assumption that this "
                + "never happens; if it now does, it must translate by bounds.origin."
        )
        XCTAssertFalse(
            placements.filter { !$0.hasZeroOrigin }.isEmpty,
            "every placement in these shapes was at the origin, so the zero origins "
                + "above prove nothing about guide evaluation — the shapes are no "
                + "longer displacing the observed layout"
        )
    }

    // MARK: - Helpers

    /// The frame the leaf resolves to without the probe and with it, measured in
    /// two hosts that differ in nothing but the wrapper.
    ///
    /// `leaf` is built twice because each host needs its own sink; taking a
    /// closure keeps the two view trees provably identical up to the wrapper.
    /// Returns `nil` after an `XCTFail` when either host never produced a frame.
    @MainActor
    private func alignmentFrames<Leaf: View>(
        _ alignment: Alignment,
        file: StaticString = #filePath,
        line: UInt = #line,
        leaf: (FrameSink) -> Leaf
    ) -> (plain: CGRect, probed: CGRect)? {
        let plainSink = FrameSink()
        let plainHost = HeadlessHost(
            alignmentTestRoot(alignment: alignment, recorder: nil) { leaf(plainSink) }
        )
        guard plainHost.pump(
            until: "a frame for the unwrapped leaf under \(alignment)",
            file: file,
            line: line,
            isReady: { plainSink.frame("leaf") != nil }
        ) else { return nil }

        let probedSink = FrameSink()
        let probedHost = HeadlessHost(
            alignmentTestRoot(alignment: alignment, recorder: ProbeRecorder()) {
                leaf(probedSink).probeLayout(id: "aligned")
            }
        )
        guard probedHost.pump(
            until: "a frame for the probe-wrapped leaf under \(alignment)",
            file: file,
            line: line,
            isReady: { probedSink.frame("leaf") != nil }
        ) else { return nil }

        guard let plain = plainSink.frame("leaf"), let probed = probedSink.frame("leaf") else {
            XCTFail("a pumped sink reported ready but held no frame", file: file, line: line)
            return nil
        }
        return (plain, probed)
    }

    @MainActor
    private func assertFramesMatch(
        _ frames: (plain: CGRect, probed: CGRect),
        alignment: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            frames.probed.origin.x,
            frames.plain.origin.x,
            accuracy: 0.01,
            "probe moved the leaf in x under \(alignment): "
                + "unwrapped \(frames.plain), wrapped \(frames.probed)",
            file: file,
            line: line
        )
        XCTAssertEqual(
            frames.probed.origin.y,
            frames.plain.origin.y,
            accuracy: 0.01,
            "probe moved the leaf in y under \(alignment): "
                + "unwrapped \(frames.plain), wrapped \(frames.probed)",
            file: file,
            line: line
        )
        XCTAssertEqual(
            frames.probed.width,
            frames.plain.width,
            accuracy: 0.01,
            "probe changed the leaf's width under \(alignment)",
            file: file,
            line: line
        )
        XCTAssertEqual(
            frames.probed.height,
            frames.plain.height,
            accuracy: 0.01,
            "probe changed the leaf's height under \(alignment)",
            file: file,
            line: line
        )
    }

    @MainActor
    private func assertSize(
        _ size: Size,
        width: Double,
        height: Double,
        accuracy: Double = 0.01,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(size.width, width, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(size.height, height, accuracy: accuracy, file: file, line: line)
    }
}
