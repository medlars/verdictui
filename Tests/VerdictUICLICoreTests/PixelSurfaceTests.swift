import Foundation
import VerdictUIDemoScenarios
import VerdictUIKernel
import VerdictUIProbe
import XCTest

@testable import VerdictUICLICore

/// This suite's own output sink.
///
/// Declared here rather than sharing `VerdictEngineTests`' `CapturedOutput`,
/// which is file-private — and that confinement is load-bearing in this target
/// (`no.md` #19): sibling test files own same-named fixtures only because
/// `private` keeps each to its own file, and widening one to `internal` to
/// share it collides the moment two files pick the same name. A twelve-line
/// fixture is cheaper than a namespace collision.
private final class PixelSurfaceOutput: OutputSink, @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = ""
    private var stderr = ""

    var out: String { lock.withLock { stdout } }
    var err: String { lock.withLock { stderr } }

    func writeOut(_ text: String) { lock.withLock { stdout += text } }
    func writeError(_ text: String) { lock.withLock { stderr += text } }
}

/// Wave 9 Task 6: the pixel channel as the CLI, daemon and MCP surfaces expose it.
///
/// The recurring finding of Waves 6–8 is that a library test cannot see the
/// artifact (`no.md` #32/#34/#37): a method surface can be correct and complete
/// while nothing reaches it, and prose can describe a wire nobody serves. So the
/// wire-shape assertions here read RAW JSON with `JSONSerialization` — the way a
/// foreign client does — rather than round-tripping through the type that
/// encoded it, which tests the pair and never the format.
final class PixelSurfaceTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        super.setUp()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("verdictui-pixelsurface-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    @MainActor
    private func environment() -> (CommandEnvironment, PixelSurfaceOutput) {
        let output = PixelSurfaceOutput()
        return (
            CommandEnvironment(
                engine: VerdictEngine(
                    registry: DemoScenarios.registry,
                    baselines: BaselineStore.standard(root: root)
                ),
                output: output,
                pixelArtifactRoot: root.appendingPathComponent(PixelArtifact.directory)
            ),
            output
        )
    }

    private var scenario: String { DemoScenarios.registry.names[0] }

    // MARK: - render --pixels

    @MainActor
    func testRenderWithoutPixelsIsUnchangedAndCarriesNoImage() async throws {
        let (environment, output) = self.environment()

        let code = await RenderCommand(scenario: scenario).run(environment, pretty: false)

        XCTAssertEqual(code, .pass)
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(output.out.utf8)) as? [String: Any])
        XCTAssertNil(json["image"], "the default render must not have grown an image field")
        XCTAssertNotNil(json["id"], "and must still be a bare tree")
    }

    @MainActor
    func testRenderWithPixelsReportsAPathAndWritesTheImageThere() async throws {
        let (environment, output) = self.environment()

        let code = await RenderCommand(scenario: scenario, pixels: true)
            .run(environment, pretty: false)

        XCTAssertEqual(code, .pass)
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(output.out.utf8)) as? [String: Any])

        let path = try XCTUnwrap(json["image"] as? String)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: path),
            "the reported path must name a file that exists — a path to nothing is worse "
                + "than no path, because it reads as evidence")
        // A real PNG, not merely a file: the magic number is what separates
        // "wrote something" from "wrote an image".
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        XCTAssertEqual(Array(bytes.prefix(4)), [0x89, 0x50, 0x4E, 0x47])

        XCTAssertEqual(json["scenario"] as? String, scenario)
        XCTAssertNotNil(json["tree"], "the tree is still the primary answer")
        XCTAssertGreaterThan(try XCTUnwrap(json["pixelsWide"] as? Int), 0)
        XCTAssertGreaterThan(try XCTUnwrap(json["pixelsHigh"] as? Int), 0)
        XCTAssertEqual(json["backend"] as? String, "cacheDisplay")
        XCTAssertNotNil(json["cacheHit"] as? Bool)
    }

    /// The token-frugality promise, asserted rather than merely documented.
    ///
    /// The output must not contain the image's bytes in any form. Checked by
    /// SIZE against the file on disk: a base64 payload is necessarily larger
    /// than the PNG it encodes, so an output smaller than the image cannot
    /// contain it — a claim that holds no matter how the bytes might have been
    /// smuggled in, which a search for a `data:` prefix would not.
    @MainActor
    func testTheImageBytesNeverAppearInTheOutput() async throws {
        let (environment, output) = self.environment()
        _ = await RenderCommand(scenario: scenario, pixels: true).run(environment, pretty: false)

        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(output.out.utf8)) as? [String: Any])
        let path = try XCTUnwrap(json["image"] as? String)
        let imageBytes = try Data(contentsOf: URL(fileURLWithPath: path)).count

        XCTAssertGreaterThan(imageBytes, 0, "control: the image is not empty")
        XCTAssertLessThan(
            output.out.utf8.count, imageBytes,
            "the payload (\(output.out.utf8.count) B) must be smaller than the image "
                + "(\(imageBytes) B), or it is carrying the bytes it promised to replace "
                + "with a path")
    }

    @MainActor
    func testASecondRenderOfAnUnchangedScreenReportsACacheHit() async throws {
        // Wired end to end rather than tested only at the cache: a `cacheHit`
        // field that is always false would pass every PixelCacheTests assertion
        // and still make the surface useless for reporting a hit rate.
        let (first, _) = environment()
        _ = await RenderCommand(scenario: scenario, pixels: true).run(first, pretty: false)

        let (second, output) = environment()
        _ = await RenderCommand(scenario: scenario, pixels: true).run(second, pretty: false)

        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(output.out.utf8)) as? [String: Any])
        XCTAssertEqual(json["cacheHit"] as? Bool, true)
    }

    @MainActor
    func testAnUnknownScenarioFailsRatherThanWritingAnImage() async {
        let (environment, _) = self.environment()

        let code = await RenderCommand(scenario: "no-such-scenario", pixels: true)
            .run(environment, pretty: false)

        // Exit 2, not 1: no verdict could be produced at all. A tool reporting
        // "not passing" for both a broken layout and an unreadable scenario
        // forces callers to treat infrastructure faults as product defects.
        XCTAssertEqual(code, .couldNotVerify)
    }

    // MARK: - The daemon wire, read as a client reads it

    @MainActor
    func testTheDaemonPixelRenderPublishesTheDocumentedKeys() async throws {
        let engine = VerdictEngine(
            registry: DemoScenarios.registry, baselines: BaselineStore.standard(root: root))

        let response = await VerdictDaemon.handle(
            DaemonRequest(method: "render", scenario: scenario, pixels: true, id: "1"),
            engine: engine,
            pixelArtifactRoot: root.appendingPathComponent(PixelArtifact.directory)
        )

        XCTAssertTrue(response.ok)
        // Read as raw JSON with a foreign parser. Round-tripping through
        // `DaemonResult` would agree with itself no matter what bytes travelled
        // — the defect that shipped a `_0`-wrapped wire for a whole wave.
        let encoded = try JSONEncoder().encode(try XCTUnwrap(response.result))
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let payload = try XCTUnwrap(
            json["pixelRender"] as? [String: Any],
            "the result must be keyed 'pixelRender', not wrapped in a synthesized key")
        XCTAssertNotNil(payload["image"] as? String)
        XCTAssertNotNil(payload["tree"])
        XCTAssertNil(payload["png"], "bytes must never cross this wire")
    }

    @MainActor
    func testADaemonRenderWithoutPixelsStillReturnsABareTree() async throws {
        let engine = VerdictEngine(
            registry: DemoScenarios.registry, baselines: BaselineStore.standard(root: root))

        let response = await VerdictDaemon.handle(
            DaemonRequest(method: "render", scenario: scenario, id: "1"), engine: engine)

        let encoded = try JSONEncoder().encode(try XCTUnwrap(response.result))
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNotNil(json["tree"], "the default shape must not have changed")
        XCTAssertNil(json["pixelRender"])
    }

    func testAPixelRenderResultSurvivesTheWireInBothDirections() throws {
        // The client-shape test above proves the KEYS; this proves the daemon
        // can read back what it wrote, which is what a socket client's reply
        // handling depends on. Both are needed: neither implies the other.
        let report = PixelRenderReport(
            scenario: "s",
            tree: SemanticNode(
                id: "root", role: .container, frame: Rect(x: 0, y: 0, width: 1, height: 1)),
            image: "/tmp/x.png",
            pixelsWide: 4,
            pixelsHigh: 5,
            backend: "cacheDisplay",
            contentHash: "abc",
            cacheHit: true
        )
        let encoded = try JSONEncoder().encode(DaemonResult.pixelRender(report))

        guard case let .pixelRender(decoded) = try JSONDecoder().decode(
            DaemonResult.self, from: encoded)
        else {
            return XCTFail("a pixelRender result did not decode as one")
        }
        XCTAssertEqual(decoded, report)
    }

    // MARK: - MCP

    func testTheRenderToolAdvertisesThePixelsArgument() throws {
        let render = try XCTUnwrap(MCPServer.tools.first { $0.name == "render" })
        let pixels = try XCTUnwrap(
            render.inputSchema.properties["pixels"],
            "an argument a client cannot discover is one no client will send")
        XCTAssertEqual(pixels.type, "boolean")
        // The description must say what the tool returns, because an agent
        // deciding whether to spend the call reads only this.
        XCTAssertTrue(pixels.description.contains("PATH"))
    }

    func testTheMCPPixelRenderShipsACompactTreeAndAPath() throws {
        let report = PixelRenderReport(
            scenario: "s",
            tree: SemanticNode(
                id: "root", role: .container, frame: Rect(x: 0, y: 0, width: 2, height: 2)),
            image: "/tmp/image.png",
            pixelsWide: 2,
            pixelsHigh: 2,
            backend: "cacheDisplay",
            contentHash: "hash",
            cacheHit: false
        )

        let rendered = try MCPTransport.render(.pixelRender(report))
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(rendered.utf8)) as? [String: Any])

        XCTAssertEqual(json["image"] as? String, "/tmp/image.png")
        // The COMPACT tree, matching what `render` alone ships over MCP. A raw
        // `SemanticNode` here would mean the socket and MCP carried two
        // different encodings for one method.
        let tree = try XCTUnwrap(json["tree"] as? [String: Any])
        XCTAssertNotNil(
            tree["frames"],
            "the MCP tree must be the compact parallel-array form, not the raw node")
        XCTAssertNil(tree["children"], "a nested 'children' means the raw form leaked through")
    }
}
