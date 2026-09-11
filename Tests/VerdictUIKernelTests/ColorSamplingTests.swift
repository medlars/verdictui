import XCTest

@testable import VerdictUIKernel

/// Per-node colour from pixels (CIS-29DC2767) and the rule that judges it.
///
/// Every positive assertion has a control beside it: "finds a foreground" is
/// satisfied by a sampler that invents one, and "fires on low contrast" by a
/// rule that fires on everything.
final class ColorSamplingTests: XCTestCase {

    /// A `width` x `height` raster filled with `fill`, with the rectangle
    /// `[x0,x1) x [y0,y1)` painted `ink`.
    private func raster(
        width: Int, height: Int, fill: SampledColor, ink: SampledColor? = nil,
        inkRect: (Int, Int, Int, Int) = (0, 0, 0, 0), transparent: Bool = false
    ) throws -> PixelRaster {
        var samples = [UInt8]()
        samples.reserveCapacity(width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let inside =
                    ink != nil && x >= inkRect.0 && x < inkRect.2 && y >= inkRect.1
                    && y < inkRect.3
                let c = inside ? (ink ?? fill) : fill
                samples += [c.red, c.green, c.blue, transparent ? 0 : 255]
            }
        }
        return try PixelRaster(width: width, height: height, samples: samples)
    }

    private let white = SampledColor(red: 255, green: 255, blue: 255)
    private let black = SampledColor(red: 0, green: 0, blue: 0)

    // MARK: - SampledColor

    func testHexRoundTripsAndDescribesItself() throws {
        let color = try XCTUnwrap(SampledColor(hex: "#1A2B3C"))
        XCTAssertEqual(color, SampledColor(red: 0x1A, green: 0x2B, blue: 0x3C))
        XCTAssertEqual(color.hex, "#1A2B3C")
        XCTAssertEqual(color.description, "#1A2B3C")
        XCTAssertEqual(SampledColor(hex: "1A2B3C"), color, "the leading # is optional")
        XCTAssertNil(SampledColor(hex: "#12345"), "five digits is not a colour")
        XCTAssertNil(SampledColor(hex: "#GGGGGG"))
    }

    /// The WCAG anchor values: black on white is 21:1, identical colours 1:1.
    func testContrastRatioMatchesTheWCAGAnchors() {
        XCTAssertEqual(SampledColor.contrastRatio(black, white), 21, accuracy: 0.01)
        XCTAssertEqual(SampledColor.contrastRatio(white, black), 21, accuracy: 0.01)
        XCTAssertEqual(SampledColor.contrastRatio(white, white), 1, accuracy: 0.0001)
        // #767676 on white is the well-known 4.54:1 AA boundary grey.
        let grey = SampledColor(red: 0x76, green: 0x76, blue: 0x76)
        XCTAssertEqual(SampledColor.contrastRatio(grey, white), 4.54, accuracy: 0.01)
        XCTAssertEqual(white.relativeLuminance, 1, accuracy: 0.0001)
        XCTAssertEqual(black.relativeLuminance, 0, accuracy: 0.0001)
    }

    // MARK: - sampling

    func testTheModalColourIsTheBackgroundAndTheDistinctOneTheForeground() throws {
        let image = try raster(
            width: 20, height: 10, fill: white, ink: black, inkRect: (2, 2, 8, 6))
        let sample: ColorSampler.Sample = try XCTUnwrap(
            ColorSampler.sample(image, x0: 0, y0: 0, x1: 20, y1: 10))
        XCTAssertEqual(sample.background, white)
        XCTAssertEqual(sample.foreground, black)
        XCTAssertEqual(try XCTUnwrap(sample.contrast), 21, accuracy: 0.01)
    }

    /// The control for the test above: a flat region has NO foreground. A
    /// sampler that always reported one would pass the positive test and then
    /// assign every container an invented text colour.
    func testAFlatRegionHasABackgroundAndNoForeground() throws {
        let image = try raster(width: 10, height: 10, fill: white)
        let sample = try XCTUnwrap(ColorSampler.sample(image, x0: 0, y0: 0, x1: 10, y1: 10))
        XCTAssertEqual(sample.background, white)
        XCTAssertNil(sample.foreground)
        XCTAssertNil(sample.contrast)
    }

    /// Near-identical noise (a 1-channel rounding difference) is not a foreground.
    func testNoiseBelowTheDistanceFloorIsNotAForeground() throws {
        let almostWhite = SampledColor(red: 250, green: 250, blue: 250)
        let image = try raster(
            width: 10, height: 10, fill: white, ink: almostWhite, inkRect: (0, 0, 3, 3))
        let sample = try XCTUnwrap(ColorSampler.sample(image, x0: 0, y0: 0, x1: 10, y1: 10))
        XCTAssertNil(sample.foreground)
    }

    func testARegionOutsideTheRasterOrFullyTransparentHasNoColour() throws {
        let image = try raster(width: 10, height: 10, fill: white)
        XCTAssertNil(ColorSampler.sample(image, x0: 20, y0: 20, x1: 30, y1: 30))
        let clear = try raster(width: 10, height: 10, fill: white, transparent: true)
        XCTAssertNil(ColorSampler.sample(clear, x0: 0, y0: 0, x1: 10, y1: 10))
    }

    /// Text on a CLEAR canvas: without a backdrop only the glyphs are opaque, so
    /// the ink reads as the background (the control); with one, the transparent
    /// pixels composite to the backdrop and the ink becomes the foreground.
    func testATransparentCanvasIsCompositedOverTheBackdrop() throws {
        let image = try raster(
            width: 20, height: 10, fill: black, ink: black, inkRect: (0, 0, 20, 10),
            transparent: true)
        var samples = image.samples
        // Opaque black glyph block at x 2..<6.
        for y in 0..<10 { for x in 2..<6 { samples[(y * 20 + x) * 4 + 3] = 255 } }
        // Transparent pixels in premultiplied form carry zero colour.
        for i in stride(from: 0, to: samples.count, by: 4) where samples[i + 3] == 0 {
            samples[i] = 0
            samples[i + 1] = 0
            samples[i + 2] = 0
        }
        let canvas = try PixelRaster(width: 20, height: 10, samples: samples)

        let bare = try XCTUnwrap(ColorSampler.sample(canvas, x0: 0, y0: 0, x1: 20, y1: 10))
        XCTAssertEqual(bare.background, black)
        XCTAssertNil(bare.foreground)

        let composited = try XCTUnwrap(
            ColorSampler.sample(canvas, x0: 0, y0: 0, x1: 20, y1: 10, backdrop: white))
        XCTAssertEqual(composited.background, white)
        XCTAssertEqual(composited.foreground, black)
        XCTAssertEqual(try XCTUnwrap(composited.contrast), 21, accuracy: 0.01)
    }

    // MARK: - annotation

    /// Frames are in points, the raster in pixels, and the tree's origin sits
    /// below a titlebar — all three conversions are exercised by one node that
    /// only lands on its ink if every one is applied.
    func testAnnotationMapsPointFramesThroughScaleAndOffset() throws {
        // 2x raster, 40x40 px == 20x20 pt. Ink at px (20..30, 24..32), i.e.
        // pt (10..15, 12..16) in raster space; with a 4 pt titlebar offset the
        // tree frame is y 8..12.
        let image = try raster(
            width: 40, height: 40, fill: white, ink: black, inkRect: (20, 24, 30, 32))
        let label = SemanticNode(
            id: "label", role: .text, frame: Rect(x: 10, y: 8, width: 5, height: 4),
            text: "Hi", structuralPath: "root/text[0]")
        let root = SemanticNode(
            id: "root", role: .container, frame: Rect(x: 0, y: 0, width: 20, height: 16),
            structuralPath: "root", children: [label])
        let annotated = ColorSampler.annotate(
            root, raster: image, scale: 2, offsetX: 0, offsetY: 4)
        let node = try XCTUnwrap(annotated.children.first)
        XCTAssertEqual(node.attributes[ColorSampler.backgroundKey]?.stringValue, "#000000")
        XCTAssertEqual(
            annotated.attributes[ColorSampler.backgroundKey]?.stringValue, "#FFFFFF",
            "the root region is mostly white")
        XCTAssertEqual(annotated.attributes[ColorSampler.foregroundKey]?.stringValue, "#000000")
        XCTAssertEqual(annotated.attributes[ColorSampler.contrastKey]?.numberValue, 21)
    }

    func testAnEmptyFrameIsLeftUnannotated() throws {
        let image = try raster(width: 10, height: 10, fill: white)
        let node = SemanticNode(id: "z", role: .text, frame: Rect(x: 0, y: 0, width: 0, height: 0))
        let annotated = ColorSampler.annotate(node, raster: image, scale: 1, offsetX: 0, offsetY: 0)
        XCTAssertTrue(annotated.attributes.isEmpty)
    }

    // MARK: - low-contrast

    private func textNode(contrast: Double?, text: String? = "Terms") -> SemanticNode {
        var attributes: [String: AttributeValue] = [:]
        if let contrast {
            attributes[ColorSampler.contrastKey] = .number(contrast)
            attributes[ColorSampler.foregroundKey] = .string("#999999")
            attributes[ColorSampler.backgroundKey] = .string("#FFFFFF")
        }
        return SemanticNode(
            id: "caption", role: .text, frame: Rect(x: 0, y: 0, width: 60, height: 16),
            text: text, attributes: attributes, structuralPath: "root/text[0]")
    }

    private func findings(_ node: SemanticNode) -> [Finding] {
        let context = LintContext.macOS(
            viewport: Rect(x: 0, y: 0, width: 320, height: 240), scenario: "contrast")
        return LowContrastRule().evaluate(node, context: context)
    }

    func testLowContrastFiresBelowTheAAFloorAndCitesBothColours() throws {
        let found = findings(textNode(contrast: 2.85))
        XCTAssertEqual(found.count, 1)
        let finding = try XCTUnwrap(found.first)
        XCTAssertEqual(finding.rule, LowContrastRule.id)
        XCTAssertEqual(finding.severity, .warning)
        XCTAssertTrue(finding.message.contains("2.85:1"), finding.message)
        XCTAssertTrue(finding.message.contains("#999999 on #FFFFFF"), finding.message)
    }

    /// Controls: at or above the floor, without a sampled ratio, or without
    /// text, the rule is silent — a tree that was never colour-sampled must not
    /// read as failing, and a container's mixed sample is not a text contrast.
    func testLowContrastIsSilentAtTheFloorWithoutColourAndWithoutText() {
        XCTAssertTrue(findings(textNode(contrast: LowContrastRule.minimumRatio)).isEmpty)
        XCTAssertTrue(findings(textNode(contrast: 7.1)).isEmpty)
        XCTAssertTrue(findings(textNode(contrast: nil)).isEmpty)
        XCTAssertTrue(findings(textNode(contrast: 1.5, text: nil)).isEmpty)
    }

    /// The vacuity guard applies to probe-channel trees only, and its opt-out
    /// lives on the context so an externally observed tree (an AX read, a DOM
    /// walk) is not accused of having observed nothing.
    func testTheVacuityGuardIsOptOutOnlyForExternallyObservedTrees() {
        var context = LintContext.macOS(
            viewport: Rect(x: 0, y: 0, width: 200, height: 100), scenario: "external")
        XCTAssertTrue(context.requiresProbedNodes, "probe-channel trees keep the guard")
        let probeless = SemanticNode(
            id: "", role: .container, frame: Rect(x: 0, y: 0, width: 200, height: 100),
            structuralPath: "root")
        XCTAssertTrue(
            RuleEngine.run(rules: [], on: probeless, context: context).findings
                .contains { $0.rule == RuleEngine.vacuousVerdictRule })
        context.requiresProbedNodes = false
        XCTAssertTrue(RuleEngine.run(rules: [], on: probeless, context: context).findings.isEmpty)
    }

    func testLowContrastIsInTheStandardRuleSet() {
        XCTAssertTrue(RuleEngine.standardRules.contains { $0 is LowContrastRule })
    }

    func testSampleLimitsAreDeclared() {
        XCTAssertEqual(ColorSampler.minimumForegroundDistance, 40)
        XCTAssertGreaterThan(ColorSampler.maximumSamplesPerNode, 0)
    }
}
