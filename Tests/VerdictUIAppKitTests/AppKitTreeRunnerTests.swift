// The runner's own tests. `run(arguments:subjects:output:)` rather than
// `main(subjects:)` because the latter calls `exit`, and a test that ends the
// test process reports nothing at all.
import AppKit
import VerdictUIKernel
import XCTest

@testable import VerdictUIAppKit

@MainActor
final class AppKitTreeRunnerTests: XCTestCase {

    private func subjects() -> [AppKitSubject] {
        [
            AppKitSubject("panel", viewport: CGSize(width: 300, height: 200)) {
                let root = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
                root.identifier = NSUserInterfaceItemIdentifier("panel-root")
                let button = NSButton(title: "OK", target: nil, action: nil)
                button.identifier = NSUserInterfaceItemIdentifier("ok")
                button.frame = NSRect(x: 20, y: 20, width: 80, height: 32)
                root.addSubview(button)
                return root
            },
            AppKitSubject("empty") { NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10)) },
        ]
    }

    private func capture(
        _ arguments: [String]
    ) -> (status: AppKitTreeRunner.Status, out: String, err: String) {
        var out = ""
        var err = ""
        let status = AppKitTreeRunner.run(
            arguments: arguments,
            subjects: subjects(),
            output: { out += $0 },
            onError: { err += $0 }
        )
        return (status, out, err)
    }

    func testListPrintsEverySubjectName() {
        let result = capture(["list"])
        XCTAssertEqual(result.status, .ok)
        XCTAssertEqual(result.out, "panel\nempty\n")
    }

    func testRenderEmitsDecodableJSON() throws {
        let result = capture(["render", "panel"])
        XCTAssertEqual(result.status, .ok, result.err)

        let data = try XCTUnwrap(result.out.data(using: .utf8))
        let tree = try JSONDecoder().decode(SemanticNode.self, from: data)
        XCTAssertEqual(tree.id, "panel-root")
        XCTAssertEqual(tree.frame.width, 300, accuracy: 0.001)
        XCTAssertTrue(tree.flattened().contains { $0.id == "ok" })
    }

    /// An unknown subject is exit 2 — "I could not produce a tree" — and must
    /// never be exit 1, which a caller reads as "your UI is wrong".
    func testUnknownSubjectCannotProduceRatherThanFails() {
        let result = capture(["render", "nope"])
        XCTAssertEqual(result.status, .couldNotProduce)
        XCTAssertTrue(result.err.contains("unknown subject 'nope'"), result.err)
        // The error names what IS available, so the caller's next command works.
        XCTAssertTrue(result.err.contains("panel"), result.err)
        XCTAssertTrue(result.out.isEmpty, "wrote to stdout on failure: \(result.out)")
    }

    func testMissingArgumentsAreRefusedWithUsage() {
        XCTAssertEqual(capture([]).status, .couldNotProduce)
        XCTAssertEqual(capture(["render"]).status, .couldNotProduce)
        XCTAssertEqual(capture(["frobnicate"]).status, .couldNotProduce)
    }

    /// The runner's stdout must be exactly one JSON document and nothing else —
    /// the CLI pipes it straight into the decoder, and a progress line stapled
    /// to the front is not JSON.
    func testStdoutCarriesNothingButTheDocument() throws {
        let result = capture(["render", "panel"])
        let trimmed = result.out.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(trimmed.hasPrefix("{"), String(trimmed.prefix(40)))
        XCTAssertTrue(trimmed.hasSuffix("}"), String(trimmed.suffix(40)))
        XCTAssertTrue(result.err.isEmpty, result.err)
    }

    func testControllerSubjectLoadsTheViewWithoutAWindow() throws {
        let controllerSubject = AppKitSubject.controller("vc") {
            let controller = NSViewController()
            let view = NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 90))
            view.identifier = NSUserInterfaceItemIdentifier("vc-root")
            controller.view = view
            return controller
        }
        var out = ""
        let windowsBefore = NSApplication.shared.windows.count
        let status = AppKitTreeRunner.run(
            arguments: ["render", "vc"],
            subjects: [controllerSubject],
            output: { out += $0 }
        )
        XCTAssertEqual(status, .ok)
        XCTAssertEqual(NSApplication.shared.windows.count, windowsBefore)

        let tree = try JSONDecoder().decode(
            SemanticNode.self, from: try XCTUnwrap(out.data(using: .utf8)))
        XCTAssertEqual(tree.id, "vc-root")
    }
}
