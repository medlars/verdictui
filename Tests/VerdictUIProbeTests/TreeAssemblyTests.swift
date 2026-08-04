import VerdictUIKernel
import VerdictUIProbe
import XCTest

/// Tree assembly, exercised without rendering anything.
///
/// The point of keeping `TreeAssembly` pure is that these cases — deep nesting,
/// ambiguous geometry, a measurement that does not describe the frame it is
/// filed under — are all reachable as plain function arguments. Reproducing them
/// through a hosted SwiftUI view would mean coaxing the layout engine into
/// producing a specific pathology, which is slow, indirect, and would leave the
/// interesting branches untested in practice.
final class TreeAssemblyTests: XCTestCase {
    private let viewport = Rect(x: 0, y: 0, width: 400, height: 300)

    // MARK: - Containment

    func testThreeLevelContainmentBecomesThreeLevelNesting() throws {
        // Deliberately fed in an order that does not match the nesting, so a
        // pass that happened to work by input order alone would fail here.
        let tree = TreeAssembly.assemble(
            records: [
                record("leaf", Rect(x: 40, y: 40, width: 40, height: 20)),
                record("outer", Rect(x: 10, y: 10, width: 200, height: 150)),
                record("middle", Rect(x: 20, y: 20, width: 120, height: 90)),
            ],
            measurements: [:],
            viewport: viewport
        )

        XCTAssertEqual(tree.children.map(\.id), ["outer"], "only the outermost probe is top level")
        let outer = try XCTUnwrap(tree.children.first)
        let middle = try XCTUnwrap(outer.children.first)
        XCTAssertEqual(outer.children.map(\.id), ["middle"])
        XCTAssertEqual(middle.children.map(\.id), ["leaf"])
        XCTAssertEqual(middle.children.first?.children.count, 0)
        XCTAssertEqual(
            tree.flattened().count,
            4,
            "root plus three probes: no node was lost or duplicated"
        )
    }

    func testAChildAttachesToItsInnermostContainerNotTheOutermost() {
        // Two containers both enclose the leaf; the tighter one must win, or deep
        // hierarchies flatten into a fan under the outermost box.
        let tree = TreeAssembly.assemble(
            records: [
                record("outer", Rect(x: 0, y: 0, width: 300, height: 200)),
                record("inner", Rect(x: 10, y: 10, width: 100, height: 100)),
                record("leaf", Rect(x: 20, y: 20, width: 10, height: 10)),
            ],
            measurements: [:],
            viewport: viewport
        )
        let outer = tree.children.first
        XCTAssertEqual(outer?.id, "outer")
        XCTAssertEqual(outer?.children.map(\.id), ["inner"])
        XCTAssertEqual(outer?.children.first?.children.map(\.id), ["leaf"])
    }

    func testOverlappingButNotNestedFramesStaySiblings() {
        // Partial overlap is the `SiblingOverlapRule` case: the kernel can only
        // report it if assembly leaves the two as siblings.
        let tree = TreeAssembly.assemble(
            records: [
                record("avatar", Rect(x: 0, y: 0, width: 48, height: 48)),
                record("badge", Rect(x: 32, y: 32, width: 24, height: 16)),
            ],
            measurements: [:],
            viewport: viewport
        )
        XCTAssertEqual(tree.children.map(\.id), ["avatar", "badge"])
        XCTAssertTrue(tree.children.allSatisfy { $0.children.isEmpty })
    }

    func testContainmentToleratesSubPointRoundingAtTheEdges() {
        // A child flush with its parent's edge can come back a fraction outside
        // it once AppKit has rounded to the pixel grid; that must still nest.
        let tree = TreeAssembly.assemble(
            records: [
                record("card", Rect(x: 10, y: 10, width: 100, height: 50)),
                record("label", Rect(x: 9.75, y: 10.25, width: 100.4, height: 20)),
            ],
            measurements: [:],
            viewport: viewport
        )
        XCTAssertEqual(tree.children.map(\.id), ["card"])
        XCTAssertEqual(tree.children.first?.children.map(\.id), ["label"])
        XCTAssertEqual(
            tree.children.first?.children.first?.frame,
            Rect(x: 9.75, y: 10.25, width: 100.4, height: 20),
            "the epsilon belongs to the comparison; the frame is stored as measured"
        )
    }

    // MARK: - Order

    func testSiblingOrderIsLayoutOrder() {
        let tree = TreeAssembly.assemble(
            records: [
                record("first", Rect(x: 0, y: 0, width: 100, height: 20)),
                record("second", Rect(x: 0, y: 30, width: 100, height: 20)),
                record("third", Rect(x: 0, y: 60, width: 100, height: 20)),
            ],
            measurements: [:],
            viewport: viewport
        )
        XCTAssertEqual(tree.children.map(\.id), ["first", "second", "third"])
    }

    func testSiblingOrderFollowsTheInputNotGeometry() {
        // Reverse the input: the reported order is layout order by construction,
        // so assembly must not re-derive it from position on screen.
        let tree = TreeAssembly.assemble(
            records: [
                record("bottom", Rect(x: 0, y: 60, width: 100, height: 20)),
                record("top", Rect(x: 0, y: 0, width: 100, height: 20)),
            ],
            measurements: [:],
            viewport: viewport
        )
        XCTAssertEqual(tree.children.map(\.id), ["bottom", "top"])
    }

    func testEqualFramesStaySiblingsInLayoutOrder() {
        // A view and its `.background`/overlay resolve to the same frame. Neither
        // strictly contains the other, so burying one inside the other would be a
        // parentage claim the geometry does not support.
        let frame = Rect(x: 5, y: 5, width: 80, height: 30)
        let tree = TreeAssembly.assemble(
            records: [record("a", frame), record("b", frame), record("c", frame)],
            measurements: [:],
            viewport: viewport
        )
        XCTAssertEqual(tree.children.map(\.id), ["a", "b", "c"])
        XCTAssertTrue(
            tree.children.allSatisfy { $0.children.isEmpty },
            "ambiguous containment must not invent nesting"
        )
    }

    func testNearlyEqualFramesStaySiblings() {
        // Within the epsilon the two frames are the same frame, so the same
        // argument applies as for exactly equal ones.
        let tree = TreeAssembly.assemble(
            records: [
                record("outerish", Rect(x: 0, y: 0, width: 100, height: 40)),
                record("innerish", Rect(x: 0.2, y: 0.2, width: 99.6, height: 39.6)),
            ],
            measurements: [:],
            viewport: viewport
        )
        XCTAssertEqual(tree.children.map(\.id), ["outerish", "innerish"])
    }

    // MARK: - Root synthesis

    func testRootIsSynthesizedWhenNoProbeSpansTheViewport() {
        let tree = TreeAssembly.assemble(
            records: [record("content", Rect(x: 20, y: 20, width: 100, height: 100))],
            measurements: [:],
            viewport: viewport
        )
        XCTAssertEqual(tree.id, "", "a synthesized root has no probe id")
        XCTAssertEqual(tree.role, .container)
        XCTAssertEqual(tree.frame, viewport)
        XCTAssertNil(tree.text)
        XCTAssertEqual(tree.children.map(\.id), ["content"])
    }

    func testTheSingleViewportSpanningProbeBecomesTheRoot() {
        let tree = TreeAssembly.assemble(
            records: [
                record("screen", viewport, role: .container),
                record("body", Rect(x: 0, y: 40, width: 400, height: 100)),
            ],
            measurements: [:],
            viewport: viewport
        )
        XCTAssertEqual(tree.id, "screen", "the probe that covers the viewport keeps its identity")
        XCTAssertEqual(tree.frame, viewport)
        XCTAssertEqual(tree.children.map(\.id), ["body"])
        XCTAssertEqual(tree.flattened().count, 2, "no anonymous wrapper was invented")
    }

    func testSeveralViewportSpanningProbesStaySiblingsUnderASynthesizedRoot() {
        let tree = TreeAssembly.assemble(
            records: [record("layer-a", viewport), record("layer-b", viewport)],
            measurements: [:],
            viewport: viewport
        )
        XCTAssertEqual(tree.id, "")
        XCTAssertEqual(tree.children.map(\.id), ["layer-a", "layer-b"])
    }

    func testAViewportSpanningProbeIsRecognizedWithinTheEpsilon() {
        let tree = TreeAssembly.assemble(
            records: [record("screen", Rect(x: 0.25, y: -0.25, width: 399.7, height: 300.3))],
            measurements: [:],
            viewport: viewport
        )
        XCTAssertEqual(tree.id, "screen")
    }

    func testNoRecordsYieldsTheSynthesizedRootAlone() {
        let tree = TreeAssembly.assemble(records: [], measurements: [:], viewport: viewport)
        XCTAssertEqual(tree.id, "")
        XCTAssertEqual(tree.frame, viewport)
        XCTAssertTrue(tree.children.isEmpty)
        XCTAssertEqual(tree.structuralPath, TreeAssembly.rootPath)
    }

    // MARK: - Structural paths

    func testEveryNodeCarriesAStructuralPath() {
        let tree = TreeAssembly.assemble(
            records: [
                record("card", Rect(x: 0, y: 0, width: 200, height: 100), role: .container),
                record("title", Rect(x: 10, y: 10, width: 100, height: 20), role: .text),
                record("save", Rect(x: 10, y: 40, width: 60, height: 24), role: .button),
            ],
            measurements: [:],
            viewport: viewport
        )
        XCTAssertEqual(tree.structuralPath, "root")
        XCTAssertEqual(tree.children.first?.structuralPath, "root/container[0]")
        XCTAssertEqual(tree.children.first?.children.map(\.structuralPath), [
            "root/container[0]/text[0]",
            "root/container[0]/button[1]",
        ])
        XCTAssertTrue(
            tree.flattened().allSatisfy { !$0.structuralPath.isEmpty },
            "a node with neither id nor path has no identity to be reported by"
        )
        // Probe ids win over structural paths as identity (kernel rule), and the
        // path is what unprobed and synthesized nodes fall back on.
        XCTAssertEqual(tree.children.first?.identity, "card")
        XCTAssertEqual(tree.identity, "@root")
    }

    // MARK: - Text metrics

    func testTextMetricsComeFromTheMeasurementThatMatchesTheFrame() {
        let frame = Rect(x: 0, y: 0, width: 120, height: 17)
        let tree = TreeAssembly.assemble(
            records: [record("label", frame, role: .text, text: "Cancel the renewal")],
            measurements: [
                "label": [
                    // A speculative pass at a different size: must not be used.
                    measurement(returned: Size(width: 400, height: 17),
                        intrinsic: Size(width: 260, height: 17),
                        idealAtWidth: Size(width: 400, height: 17)),
                    measurement(returned: Size(width: 120, height: 17),
                        intrinsic: Size(width: 260, height: 17),
                        idealAtWidth: Size(width: 120, height: 17)),
                ]
            ],
            viewport: viewport
        )
        let metrics = tree.children.first?.textMetrics
        XCTAssertEqual(metrics?.intrinsicWidth, 260, "intrinsicWidth is the measured value, as is")
        XCTAssertEqual(metrics?.renderedLineCount, 1)
        XCTAssertEqual(metrics?.idealLineCount, 1)
        XCTAssertFalse(metrics?.isLineTruncated ?? true)
    }

    func testLineCountsAreDerivedFromTheHeightRatios() {
        // 51 pt rendered over a 17 pt unconstrained line is three lines; 85 pt of
        // ideal height at the same width is five. Vertical truncation.
        let tree = TreeAssembly.assemble(
            records: [
                record("body", Rect(x: 0, y: 0, width: 200, height: 51), role: .text,
                    text: "a long paragraph")
            ],
            measurements: [
                "body": [
                    measurement(returned: Size(width: 200, height: 51),
                        intrinsic: Size(width: 900, height: 17),
                        idealAtWidth: Size(width: 200, height: 85))
                ]
            ],
            viewport: viewport
        )
        let metrics = tree.children.first?.textMetrics
        XCTAssertEqual(metrics?.renderedLineCount, 3)
        XCTAssertEqual(metrics?.idealLineCount, 5)
        XCTAssertTrue(metrics?.isLineTruncated ?? false)
    }

    func testTextMetricsAreAttachedOnlyWhereAMeasurementMatches() {
        let frame = Rect(x: 0, y: 0, width: 120, height: 17)
        let matching = [
            measurement(returned: Size(width: 120, height: 17),
                intrinsic: Size(width: 260, height: 17),
                idealAtWidth: Size(width: 120, height: 17))
        ]

        // Only "measured" has a measurement describing the frame being reported.
        let tree = TreeAssembly.assemble(
            records: [
                record("measured", frame, role: .text, text: "Cancel the renewal"),
                record("unmeasured", Rect(x: 0, y: 30, width: 120, height: 17), role: .text,
                    text: "Cancel the renewal"),
                record("mismatched", Rect(x: 0, y: 60, width: 120, height: 17), role: .text,
                    text: "Cancel the renewal"),
            ],
            measurements: [
                "measured": matching,
                "mismatched": [
                    measurement(returned: Size(width: 300, height: 17),
                        intrinsic: Size(width: 260, height: 17),
                        idealAtWidth: Size(width: 300, height: 17))
                ],
            ],
            viewport: viewport
        )

        let byID = Dictionary(uniqueKeysWithValues: tree.flattened().map { ($0.id, $0) })
        XCTAssertNotNil(byID["measured"]?.textMetrics)
        XCTAssertNil(
            byID["unmeasured"]?.textMetrics,
            "no measurement exists for this probe, so any metrics would be invented"
        )
        XCTAssertNil(
            byID["mismatched"]?.textMetrics,
            "the only measurement describes a 300 pt layout, not the 120 pt frame reported"
        )
        XCTAssertNil(tree.textMetrics, "the synthesized root renders no text")
    }

    func testTextMetricsAreWithheldWhereTheDerivationHasNoHonestBasis() {
        let frame = Rect(x: 0, y: 0, width: 120, height: 17)
        let usable = [
            measurement(returned: Size(width: 120, height: 17),
                intrinsic: Size(width: 260, height: 17),
                idealAtWidth: Size(width: 120, height: 17))
        ]
        let zeroHeight = [
            measurement(returned: Size(width: 120, height: 17),
                intrinsic: Size(width: 260, height: 0),
                idealAtWidth: Size(width: 120, height: 17))
        ]

        func metrics(_ record: ProbeRecord, _ measurements: [ProbeMeasurement]) -> TextMetrics? {
            TreeAssembly.textMetrics(for: record, measurements: measurements)
        }

        XCTAssertNotNil(
            metrics(record("ok", frame, role: .text, text: "Renew"), usable),
            "control: this record does support metrics"
        )
        XCTAssertNil(
            metrics(record("no-text", frame, role: .text, text: nil), usable),
            "without the string there is no way to know the unconstrained height is one line"
        )
        XCTAssertNil(
            metrics(record("empty-text", frame, role: .text, text: ""), usable),
            "empty text renders no lines"
        )
        XCTAssertNil(
            metrics(record("hard-break", frame, role: .text, text: "two\nlines"), usable),
            "a hard line break makes the per-line denominator unknown"
        )
        XCTAssertNil(
            metrics(record("not-text", frame, role: .image, text: "Renew"), usable),
            "an image has no lines to count"
        )
        XCTAssertNil(
            metrics(record("zero-line", frame, role: .text, text: "Renew"), zeroHeight),
            "a zero unconstrained height cannot be divided by"
        )
    }

    func testTextBearingNonTextRolesAlsoGetMetrics() {
        // `TruncationRule` inspects buttons and text fields as well as text; a
        // squeezed button label is the same defect as a squeezed label.
        let tree = TreeAssembly.assemble(
            records: [
                record("save", Rect(x: 0, y: 0, width: 40, height: 24), role: .button, text: "Save")
            ],
            measurements: [
                "save": [
                    measurement(returned: Size(width: 40, height: 24),
                        intrinsic: Size(width: 72, height: 24),
                        idealAtWidth: Size(width: 40, height: 24))
                ]
            ],
            viewport: viewport
        )
        XCTAssertEqual(tree.children.first?.textMetrics?.intrinsicWidth, 72)
    }

    // MARK: - Determinism

    func testTheSameInputsProduceTheSameTree() throws {
        let records = [
            record("card", Rect(x: 8, y: 8, width: 220, height: 120), role: .container),
            record("title", Rect(x: 16, y: 16, width: 180, height: 17), role: .text,
                text: "Monthly summary"),
            record("save", Rect(x: 16, y: 80, width: 64, height: 24), role: .button, text: "Save"),
        ]
        let measurements: [String: [ProbeMeasurement]] = [
            "title": [
                measurement(returned: Size(width: 180, height: 17),
                    intrinsic: Size(width: 240, height: 17),
                    idealAtWidth: Size(width: 180, height: 17))
            ]
        ]

        let first = TreeAssembly.assemble(
            records: records, measurements: measurements, viewport: viewport)
        let second = TreeAssembly.assemble(
            records: records, measurements: measurements, viewport: viewport)

        XCTAssertEqual(first, second)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(try encoder.encode(first), try encoder.encode(second))
    }

    // MARK: - Helpers

    private func record(
        _ id: String,
        _ frame: Rect,
        role: Role = ProbeRecord.unclassifiedRole,
        text: String? = nil,
        attributes: [String: AttributeValue] = [:]
    ) -> ProbeRecord {
        ProbeRecord(id: id, role: role, frame: frame, text: text, attributes: attributes)
    }

    private func measurement(
        returned: Size,
        intrinsic: Size,
        idealAtWidth: Size
    ) -> ProbeMeasurement {
        ProbeMeasurement(
            probeID: "ignored",
            proposal: ProbeProposal(width: returned.width, height: nil),
            returnedSize: returned,
            intrinsicSize: intrinsic,
            idealSizeAtProposedWidth: idealAtWidth
        )
    }
}
